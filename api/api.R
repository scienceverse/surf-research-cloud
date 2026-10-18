# api.R ----------------------------------------------------------------------
# metacheck web interface (SURF Research Cloud component), run by plumber.
#
# Send a PDF (or bibr JSON) and get a metacheck report back, from any language.
#
# With a job (for websites and long papers):
#   POST /jobs                 file + kind (report | check | convert | repocheck) -> job id
#   GET  /jobs/{id}            status: queued | running | done | failed, step, position
#   GET  /jobs/{id}/result     the result once done
# In one call (waits for the result; same queue):
#   POST /report               PDF or bibr JSON -> HTML report
#   POST /check                PDF or bibr JSON -> module results as JSON
#   POST /convert              PDF              -> bibr JSON
#   POST /repocheck            .zip of a data/code folder, or a link to an
#                              online repository (field url) -> HTML report of
#                              repo_check, code_check and data_check; or, with
#                              modules=<an installed module>,
#                              that module's report
# Other:
#   GET  /modules, GET /health; documentation at /__docs__/ (under /api/).
#
# Jobs run in separate R processes (worker.R, via callr), at most
# METACHECK_API_WORKERS at a time (default 2), so this process stays free to
# answer. Uploads are deleted once a worker has read them; results are deleted
# RESULT_KEEP_MINUTES after they are finished. The job id is a random UUID: only
# whoever submitted a job can fetch its result.
#
# PDFs are converted by the bibr server the component is connected to
# (BIBR_API_URL / BIBR_API_KEY). Only the modules the paper report app offers
# can be requested.

suppressPackageStartupMessages({
  library(plumber)
  library(promises)
})

API_DIR <- getwd()
JOBS_DIR <- Sys.getenv("METACHECK_API_JOBS", "/var/lib/metacheck-api/jobs")
dir.create(JOBS_DIR, recursive = TRUE, showWarnings = FALSE, mode = "0700")
MAX_WORKERS <- as.integer(Sys.getenv("METACHECK_API_WORKERS", "2"))
MAX_WAITING <- 20L                  # queued jobs; more are refused (HTTP 503)
RESULT_KEEP_MINUTES <- as.numeric(Sys.getenv("METACHECK_API_KEEP_MINUTES", "60"))
JOB_TIMEOUT_MINUTES <- 30
# Running a repository's code (metacheck's reproducibility check) in the
# Docker sandbox set up by the playbook (tasks/sandbox.yml): only when the
# playbook found everything in place (METACHECK_SANDBOX=on).
SANDBOX_ON <- identical(Sys.getenv("METACHECK_SANDBOX"), "on")
SANDBOX_ROOT <- "/srv/metacheck-sandbox"
SANDBOX_BIN <- Sys.getenv("METACHECK_SANDBOX_BIN", "/opt/metacheck-component/sandbox-bin")
SANDBOX_TIMEOUT_MINUTES <- 60       # a job that runs code may take longer
MAX_UPLOAD_BYTES <- 50 * 1024^2     # PDF or bibr JSON
MAX_ZIP_BYTES <- 500 * 1024^2       # .zip of a data/code folder (as metacheck's repocheck app)
MIN_FREE_DISK_MB <- 10000           # refuse new jobs when less is free (as the repocheck app)
# Use log: one line per finished job, in metacheck's usage folder (as the app's
# own counts). See .usage_record().
USAGE_DIR <- Sys.getenv("METACHECK_USAGE_DIR", file.path(JOBS_DIR, "..", "metacheck-usage"))

# The modules the paper report app offers (app/app.R, VALIDATED_MODULES).
ALLOWED_MODULES <- c(
  "power", "marginal", "prereg_check", "ethics_check",
  "ref_pubpeer", "ref_retraction", "ref_replication", "ref_accuracy",
  "stat_check", "stat_p_exact", "stat_p_nonsig", "stat_effect_size",
  "repo_check", "code_check", "data_check", "codebook_check"
)
# Default: the modules that need no other online service, so a report is quick.
DEFAULT_MODULES <- c(
  "power", "marginal", "ethics_check", "stat_check", "stat_p_exact",
  "stat_p_nonsig", "stat_effect_size"
)

.now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
.job_dir <- function(id) file.path(JOBS_DIR, id)
.valid_id <- function(id) grepl("^[0-9a-f-]{36}$", id) && dir.exists(.job_dir(id))
.read_status <- function(id) {
  p <- file.path(.job_dir(id), "status.json")
  tryCatch(jsonlite::read_json(p), error = function(e) list(status = "unknown"))
}
.write_status <- function(id, st) {
  tmp <- tempfile(tmpdir = .job_dir(id))
  jsonlite::write_json(st, tmp, auto_unbox = TRUE, null = "null")
  file.rename(tmp, file.path(.job_dir(id), "status.json"))
}

# ---- the queue ---------------------------------------------------------------

running <- new.env()          # job id -> callr process

.queued_ids <- function() {
  ids <- list.dirs(JOBS_DIR, full.names = FALSE, recursive = FALSE)
  if (!length(ids)) return(character(0))
  st <- vapply(ids, function(id) .read_status(id)$status %||% "", character(1))
  q <- ids[st == "queued"]
  # submission order: `seq` is the submission time with sub-second precision
  seq <- vapply(q, function(id) as.numeric(.read_status(id)$seq %||% Inf), numeric(1))
  q[order(seq)]
}

# ---- use log -----------------------------------------------------------------
# One line per finished job in api_usage.csv, with the columns of metacheck's
# own app counts (date, event, reports, modules) plus: status (done/failed),
# source (website/code) and visitor. No file names, titles or contents.
# `visitor` stands for one visitor on one day: a code made from the visitor's
# internet address and browser name and a random secret that is replaced every
# day, so the same visitor gets the same code within a day only, and once the
# day's secret is gone a code cannot be traced back to an address.
.daily_secret <- function() {
  dir.create(USAGE_DIR, showWarnings = FALSE, recursive = TRUE, mode = "0700")
  path <- file.path(USAGE_DIR, ".daily-secret")
  today <- format(Sys.Date())
  old <- tryCatch(readLines(path, warn = FALSE), error = function(e) character(0))
  if (length(old) == 2 && identical(old[1], today)) return(old[2])
  secret <- paste(sample(c(letters, LETTERS, 0:9), 40, replace = TRUE), collapse = "")
  tmp <- tempfile(tmpdir = USAGE_DIR)
  writeLines(c(today, secret), tmp)
  Sys.chmod(tmp, "0600")
  file.rename(tmp, path)
  secret
}

.visitor_code <- function(req) {
  ip <- req$HTTP_X_REAL_IP %||% req$REMOTE_ADDR %||% ""
  agent <- req$HTTP_USER_AGENT %||% ""
  substr(digest::digest(paste(.daily_secret(), ip, agent, sep = "|"),
                        algo = "sha256", serialize = FALSE), 1, 16)
}

.usage_record <- function(id, status) {
  tryCatch({
    job <- jsonlite::read_json(file.path(.job_dir(id), "job.json"))
    row <- data.frame(
      date = format(Sys.Date()), event = job$kind,
      reports = as.integer(identical(status, "done") && job$kind != "convert"),
      modules = if (job$kind == "repocheck") 3L + isTRUE(job$run_code)
                else length(unique(c(unlist(job$modules),
                                     if (isTRUE(job$run_code)) c("repo_check", "code_check", "data_check", "reproducibility_check")))),
      status = status, source = job$source %||% "code", visitor = job$visitor %||% "")
    path <- file.path(USAGE_DIR, "api_usage.csv")
    utils::write.table(row, path, sep = ",", row.names = FALSE,
                       col.names = !file.exists(path), append = file.exists(path))
  }, error = function(e) message("use log: ", conditionMessage(e)))
}

.position <- function(id) {
  p <- match(id, .queued_ids())
  if (is.na(p)) NA_integer_ else p
}

.start_worker <- function(id) {
  st <- .read_status(id)
  st$status <- "running"; st$step <- "starting"; st$started <- .now()
  .write_status(id, st)
  job <- .read_job(id)
  env <- callr::rcmd_safe_env()
  if (isTRUE(job$run_code)) {
    # The job's own folder on the sandbox file system holds everything the
    # code can see and write (R's temporary folder, so metacheck's sandbox
    # folders, are made there), and its `docker` is the guard's command.
    tmp <- file.path(SANDBOX_ROOT, id, "tmp")
    dir.create(tmp, recursive = TRUE, mode = "0700")
    env <- c(env, TMPDIR = tmp, METACHECK_JOB_ID = id,
             PATH = paste(SANDBOX_BIN, Sys.getenv("PATH"), sep = ":"))
  }
  running[[id]] <- callr::r_bg(
    function(api_dir, job_dir) {
      setwd(api_dir)
      source("worker.R")
      do_job(job_dir)
    },
    args = list(api_dir = API_DIR, job_dir = .job_dir(id)),
    stdout = file.path(.job_dir(id), "worker.log"),
    stderr = "2>&1",
    env = env,
    supervise = TRUE
  )
}

# Stops a job's sandbox containers and deletes its sandbox folder (as root,
# through the guard, since the code's files belong to the sandbox's user).
.sandbox_cleanup <- function(id) {
  if (dir.exists(file.path(SANDBOX_ROOT, id))) {
    system2("sudo", c("-n", "/usr/local/sbin/metacheck-sandbox", "cleanup", id),
            stdout = FALSE, stderr = FALSE, wait = FALSE)
  }
}

.job_timeout <- function(id) {
  if (isTRUE(.read_job(id)$run_code)) SANDBOX_TIMEOUT_MINUTES else JOB_TIMEOUT_MINUTES
}

.read_job <- function(id) {
  tryCatch(jsonlite::read_json(file.path(.job_dir(id), "job.json")), error = function(e) list())
}

.scheduler <- function() {
  tryCatch({
    # collect finished workers; stop ones that ran too long
    for (id in ls(running)) {
      p <- running[[id]]
      if (!p$is_alive()) {
        rm(list = id, envir = running)
        st <- .read_status(id)
        if (!(st$status %in% c("done", "failed"))) {
          st$status <- "failed"; st$step <- "failed"; st$finished <- .now()
          st$error <- "The job stopped unexpectedly."
          .write_status(id, st)
        }
        .usage_record(id, st$status)
        .sandbox_cleanup(id)
        unlink(file.path(.job_dir(id), "worker.log"))
      } else {
        started <- as.POSIXct(.read_status(id)$started %||% .now(), format = "%Y-%m-%dT%H:%M:%S%z")
        limit <- .job_timeout(id)
        if (difftime(Sys.time(), started, units = "mins") > limit) {
          p$kill()
          .sandbox_cleanup(id)
          rm(list = id, envir = running)
          unlink(list.files(.job_dir(id), pattern = "^input\\.", full.names = TRUE))
          st <- .read_status(id)
          st$status <- "failed"; st$step <- "failed"; st$finished <- .now()
          st$error <- sprintf("The job took longer than %d minutes and was stopped.", limit)
          .write_status(id, st)
          .usage_record(id, "failed")
        }
      }
    }
    # start queued jobs, oldest first
    free <- MAX_WORKERS - length(ls(running))
    if (free > 0) for (id in head(.queued_ids(), free)) .start_worker(id)
    # delete finished jobs after RESULT_KEEP_MINUTES
    for (id in list.dirs(JOBS_DIR, full.names = FALSE, recursive = FALSE)) {
      st <- .read_status(id)
      if (st$status %in% c("done", "failed", "unknown")) {
        fin <- as.POSIXct(st$finished %||% st$created %||% "1970-01-01T00:00:00+0000",
                          format = "%Y-%m-%dT%H:%M:%S%z")
        if (is.na(fin) || difftime(Sys.time(), fin, units = "mins") > RESULT_KEEP_MINUTES) {
          unlink(.job_dir(id), recursive = TRUE)
        }
      }
    }
  }, error = function(e) message("scheduler: ", conditionMessage(e)))
  later::later(.scheduler, 1)
}

# Jobs left "queued" or "running" by an earlier run of this service: running
# ones cannot be resumed (their worker is gone), queued ones are picked up.
for (id in list.dirs(JOBS_DIR, full.names = FALSE, recursive = FALSE)) {
  st <- .read_status(id)
  if (identical(st$status, "running")) {
    st$status <- "failed"; st$step <- "failed"; st$finished <- .now()
    st$error <- "The service restarted while the job was running."
    .write_status(id, st)
    unlink(list.files(.job_dir(id), pattern = "^input\\.", full.names = TRUE))
    .sandbox_cleanup(id)
  }
}
later::later(.scheduler, 1)

# ---- submitting --------------------------------------------------------------

# Reads the multipart upload with webutils (plumber's own parser), as
# metacheck's API helpers also do since 0.3.3.16 (parse_upload(), metacheck
# #498: mime missed uploads from .NET and PowerShell). This interface keeps its
# own reader because it needs the bytes, not a temporary file, to tell a PDF,
# bibr JSON and a .zip apart and to apply each one's size limit, and because it
# reports a broken upload instead of treating it as no upload.
.parse_upload <- function(req) {
  body <- req$bodyRaw
  if (is.null(body) || length(body) == 0) {
    req$rook.input$rewind()
    body <- req$rook.input$read()
  }
  if (length(body) > MAX_ZIP_BYTES + 1024^2) stop("The file is larger than 500 MB.", call. = FALSE)
  ctype <- req$CONTENT_TYPE
  if (is.null(ctype) || !grepl("^multipart/form-data", ctype)) {
    stop("Send the file as multipart/form-data, in the form field 'file'.", call. = FALSE)
  }
  parts <- webutils::parse_http(body, ctype)
  fields <- lapply(parts[setdiff(names(parts), "file")], function(p) {
    if (is.raw(p$value)) rawToChar(p$value) else as.character(p$value)
  })
  f <- parts[["file"]]
  if (is.null(f) || is.null(f$value) || length(f$value) == 0) {
    # no file: a repository check of a link to an online repository
    if (nzchar(trimws(fields$url %||% ""))) {
      return(list(raw = NULL, kind = "url", name = "", fields = fields))
    }
    stop("Send exactly one file in the form field 'file' (or, for a repository check, a link in the field 'url').",
         call. = FALSE)
  }
  raw <- f$value
  head4 <- if (length(raw) >= 4) raw[1:4] else raw
  kind <- if (identical(head4, charToRaw("%PDF"))) "pdf"
          else if (identical(head4, as.raw(c(0x50, 0x4b, 0x03, 0x04))) ||
                   identical(head4, as.raw(c(0x50, 0x4b, 0x05, 0x06)))) "zip"
          else if (length(raw) && rawToChar(raw[1]) %in% c("{", "[")) "json"
          else stop("The file is not a PDF, bibr JSON or a .zip file.", call. = FALSE)
  if (kind == "zip" && length(raw) > MAX_ZIP_BYTES) {
    stop("The .zip file is larger than 500 MB. Leave out large data or output files that do not need checking, and try again.", call. = FALSE)
  }
  if (kind != "zip" && length(raw) > MAX_UPLOAD_BYTES) stop("The file is larger than 50 MB.", call. = FALSE)
  # the uploaded file's name without folders and extension (the report's title)
  name <- tools::file_path_sans_ext(basename(gsub("\\\\", "/", f$filename %||% "")))
  name <- substr(gsub("[[:cntrl:]]", "", name), 1, 120)
  list(raw = raw, kind = kind, name = name, fields = fields)
}

# Free space (MB) where the jobs are kept; NA if df gives no answer.
.disk_free_mb <- function(path = JOBS_DIR) {
  out <- tryCatch(system2("df", c("-Pk", shQuote(path)), stdout = TRUE, stderr = FALSE),
                  error = function(e) character(0), warning = function(w) character(0))
  if (length(out) < 2) return(NA_real_)
  as.numeric(strsplit(trimws(out[length(out)]), "[[:space:]]+")[[1]][4]) / 1024
}

# A link to check: written as the repository check app expects it, and only
# to a host whose addresses are all on the public internet, so a link cannot
# make this server fetch from itself or from SURF's private network (the bibr
# server, Ollama). metacheck only fetches from the repository platforms it
# knows, but some of those (Dataverse, DSpace) run on any institution's server.
.private_ip <- function(ip) {
  if (grepl(":", ip, fixed = TRUE)) {               # IPv6
    ip <- tolower(ip)
    return(ip %in% c("::", "::1") || grepl("^(fc|fd|fe8|fe9|fea|feb)", ip) ||
             grepl("^::ffff:", ip))
  }
  o <- suppressWarnings(as.integer(strsplit(ip, ".", fixed = TRUE)[[1]]))
  if (length(o) != 4 || anyNA(o)) return(TRUE)
  o[1] %in% c(0, 10, 127) || o[1] >= 224 ||
    (o[1] == 100 && o[2] >= 64 && o[2] <= 127) ||
    (o[1] == 169 && o[2] == 254) ||
    (o[1] == 172 && o[2] >= 16 && o[2] <= 31) ||
    (o[1] == 192 && o[2] == 168) ||
    (o[1] == 192 && o[2] == 0 && o[3] %in% c(0, 2)) ||
    (o[1] == 198 && o[2] %in% c(18, 19))
}

.check_repo_url <- function(url) {
  url <- trimws(url %||% "")
  if (nchar(url) > 500) stop("That link is too long.", call. = FALSE)
  if (!grepl("^https?://", url, ignore.case = TRUE)) url <- paste0("https://", url)
  if (!grepl("^https?://[A-Za-z0-9.-]+\\.[A-Za-z]{2,}(/|$)", url)) {
    stop("That does not look like a link to an online repository, such as https://github.com/user/repo or https://osf.io/abcde.",
         call. = FALSE)
  }
  host <- tolower(sub("^https?://([^/]+).*$", "\\1", url, ignore.case = TRUE))
  ips <- curl::nslookup(host, multiple = TRUE, error = FALSE)
  if (is.null(ips) || !length(ips)) stop("The address ", host, " could not be found.", call. = FALSE)
  if (any(vapply(ips, .private_ip, logical(1)))) {
    stop("Links to ", host, " are not accepted: it is not on the public internet.", call. = FALSE)
  }
  url
}

.parse_flag <- function(x) tolower(trimws(x %||% "false")) %in% c("true", "1", "yes")

# "true"/"false" as TRUE/FALSE; anything else (or nothing) as NA, "not known".
.parse_answer <- function(x) {
  x <- tolower(trimws(x %||% ""))
  if (x %in% c("true", "1", "yes")) TRUE else if (x %in% c("false", "0", "no")) FALSE else NA
}

# The installed module a repository check runs (field `modules`), or none (the
# usual repository check). One module at a time, and only one installed on
# this server (INSTALLED_MODULES): nobody can install a module through the API.
.parse_installed_module <- function(param) {
  if (is.null(param) || !nzchar(trimws(param))) return(character(0))
  mods <- trimws(strsplit(param, ",")[[1]])
  mods <- mods[nzchar(mods)]
  if (length(mods) != 1) stop("A repository check runs one installed module at a time.", call. = FALSE)
  if (!mods %in% INSTALLED_MODULES$name) {
    stop(sprintf("%s is not installed on this server. Installed modules: %s", mods,
                 if (nrow(INSTALLED_MODULES)) paste(INSTALLED_MODULES$name, collapse = ", ") else "none"),
         call. = FALSE)
  }
  mods
}

.parse_modules <- function(param) {
  mods <- if (!is.null(param) && nzchar(param)) trimws(strsplit(param, ",")[[1]]) else DEFAULT_MODULES
  bad <- setdiff(mods, ALLOWED_MODULES)
  if (length(bad)) {
    stop(sprintf("Unknown or not allowed modules: %s. Allowed: %s",
                 paste(bad, collapse = ", "), paste(ALLOWED_MODULES, collapse = ", ")),
         call. = FALSE)
  }
  mods
}

# Creates a queued job from a request; returns the job id. `kind` may come
# from the endpoint (one-call endpoints) or the form field `kind` (/jobs).
.submit <- function(req, kind = NULL) {
  up <- .parse_upload(req)
  kind <- kind %||% up$fields$kind %||% (if (up$kind %in% c("zip", "url")) "repocheck" else "report")
  if (!kind %in% c("report", "check", "convert", "repocheck")) {
    stop("kind must be report, check, convert or repocheck.", call. = FALSE)
  }
  if (kind == "convert" && up$kind != "pdf") stop("convert needs a PDF.", call. = FALSE)
  if (kind == "repocheck" && !up$kind %in% c("zip", "url")) {
    stop("repocheck needs a .zip file of a data and code folder, or a link to an online repository (field 'url').", call. = FALSE)
  }
  if (kind != "repocheck" && up$kind == "url") {
    stop("A link can only be checked as a repository (kind=repocheck, or POST /repocheck).", call. = FALSE)
  }
  url <- if (up$kind == "url") .check_repo_url(up$fields$url) else NULL
  if (kind != "repocheck" && up$kind == "zip") {
    stop("A .zip file is checked with kind=repocheck (or POST /repocheck).", call. = FALSE)
  }
  if (up$kind == "pdf" && !nzchar(Sys.getenv("BIBR_API_URL"))) {
    stop("This server has no bibr: send bibr JSON instead of a PDF.", call. = FALSE)
  }
  modules <- if (kind == "convert") character(0)
             else if (kind == "repocheck") .parse_installed_module(up$fields$modules)
             else .parse_modules(up$fields$modules)
  busy <- function(msg) {
    e <- simpleError(msg); class(e) <- c("queue_full", class(e)); stop(e)
  }
  if (length(.queued_ids()) >= MAX_WAITING) busy("The queue is full; try again in a few minutes.")
  free <- .disk_free_mb()
  if (!is.na(free) && free < MIN_FREE_DISK_MB) busy("The server is short of disk space; try again later.")
  id <- uuid::UUIDgenerate()
  dir.create(.job_dir(id), mode = "0700")
  input <- paste0("input.", up$kind)
  if (is.null(url)) writeBin(up$raw, file.path(.job_dir(id), input))
  else writeLines(url, file.path(.job_dir(id), input))
  jsonlite::write_json(list(kind = kind, modules = modules, input_kind = up$kind, input_file = input,
                            name = if (is.null(url)) up$name else url,
                            url = url,
                            crossref = .parse_flag(up$fields$crossref),
                            # run the code in the sandbox: for a repository check by
                            # default, for a paper (its repository, through the links in
                            # the paper) only when asked; only where the sandbox is on
                            # an installed module runs no code in the sandbox
                            run_code = SANDBOX_ON && kind != "convert" && !length(modules) &&
                              (if (kind == "repocheck") is.null(up$fields$run_code) || .parse_flag(up$fields$run_code)
                               else .parse_flag(up$fields$run_code)),
                            # for an installed module: whether people took part, if
                            # the sender knows (true/false); null lets it decide
                            human_participants = .parse_answer(up$fields$human_participants),
                            source = if (identical(up$fields$source, "website")) "website" else "code",
                            visitor = .visitor_code(req),
                            report = .parse_flag(up$fields$report)),
                       file.path(.job_dir(id), "job.json"), auto_unbox = TRUE)
  .write_status(id, list(status = "queued", step = "waiting in the queue", created = .now(),
                        seq = as.numeric(Sys.time())))
  id
}

.status_body <- function(id, req) {
  st <- .read_status(id)
  # A folder check reports its steps through metacheck's progress code
  # (shiny_progress.R): "<fraction done>\t<what it is doing>".
  pf <- file.path(.job_dir(id), "progress.txt")
  progress <- NULL
  if (identical(st$status, "running") && file.exists(pf)) {
    line <- tryCatch(readLines(pf, n = 1, warn = FALSE, encoding = "UTF-8"), error = function(e) "")
    if (length(line) && grepl("\t", line)) {
      progress <- round(as.numeric(sub("\t.*", "", line)), 2)
      detail <- sub("^[^\t]*\t", "", line)
      if (nzchar(detail)) st$step <- detail
    }
  }
  # Full links as the client sees them (nginx passes the scheme and the /api
  # prefix); without nginx, links relative to this service.
  host <- req$HTTP_HOST %||% ""
  base <- if (nzchar(host)) {
    paste0(req$HTTP_X_FORWARDED_PROTO %||% "http", "://", host, req$HTTP_X_FORWARDED_PREFIX %||% "")
  } else ""
  # empty fields are left out (unboxedJSON would show them as {})
  Filter(Negate(is.null), list(
    id = id,
    status = st$status,
    step = st$step,
    position = if (identical(st$status, "queued")) .position(id) else NULL,
    progress = progress,
    run_code = if (isTRUE(.read_job(id)$run_code)) TRUE else NULL,
    created = st$created, started = st$started, finished = st$finished,
    error = st$error,
    status_url = paste0(base, "/jobs/", id),
    result_url = paste0(base, "/jobs/", id, "/result")
  ))
}

.result_response <- function(id, res) {
  st <- .read_status(id)
  if (identical(st$status, "failed")) {
    res$status <- 422
    res$setHeader("Content-Type", "application/json")
    res$body <- jsonlite::toJSON(list(error = st$error), auto_unbox = TRUE)
    return(res)
  }
  if (!identical(st$status, "done")) {
    res$status <- 409
    res$setHeader("Content-Type", "application/json")
    res$body <- jsonlite::toJSON(list(error = "The job is not finished yet.", status = st$status), auto_unbox = TRUE)
    return(res)
  }
  f <- list.files(.job_dir(id), pattern = "^result\\.", full.names = TRUE)[1]
  res$status <- 200
  res$setHeader("Content-Type", st$result_type %||% "application/octet-stream")
  res$body <- readBin(f, "raw", file.size(f))
  res
}

.error_response <- function(res, e) {
  res$status <- if (inherits(e, "queue_full")) 503 else 400
  res$setHeader("Content-Type", "application/json")
  res$body <- jsonlite::toJSON(list(error = conditionMessage(e)), auto_unbox = TRUE)
  res
}

# Waits (without blocking this process) until the job is finished, then
# answers with its result: used by the one-call endpoints.
.wait_for_result <- function(id, res) {
  promise(function(resolve, reject) {
    check <- function() {
      st <- .read_status(id)$status
      if (st %in% c("done", "failed")) resolve(TRUE) else later::later(check, 1)
    }
    check()
  }) %...>% (function(x) .result_response(id, res))
}

.one_call <- function(req, res, kind) {
  id <- tryCatch(.submit(req, kind), error = function(e) e)
  if (inherits(id, "error")) return(.error_response(res, id))
  .wait_for_result(id, res)
}

# ---- endpoints -----------------------------------------------------------------

#* @apiTitle metacheck on SURF Research Cloud
#* @apiDescription Send a scientific paper (PDF, or bibr JSON) and get metacheck's report or results back, or a .zip of a data and code folder and get a report on it. PDFs are converted with bibr on SURF Research Cloud. Uploads are deleted once processed, results one hour after they are finished.

source(file.path(API_DIR, "bibr_client.R"))
# bibr's readiness, asked at most every 10 seconds (bibr can be slow to answer
# while it converts).
.bibr_cache <- new.env()
.bibr_ready_cached <- function() {
  if (is.null(.bibr_cache$t) || difftime(Sys.time(), .bibr_cache$t, units = "secs") > 10) {
    .bibr_cache$ok <- bibr_ready()
    .bibr_cache$t <- Sys.time()
  }
  .bibr_cache$ok
}

#* Health check
#* @get /health
#* @serializer unboxedJSON
function() {
  list(status = "ok", bibr = .bibr_ready_cached(),
       metacheck_version = as.character(utils::packageVersion("metacheck")),
       jobs_running = length(ls(running)), jobs_waiting = length(.queued_ids()),
       run_code = SANDBOX_ON,
       workers = MAX_WORKERS)
}

# Each allowed module's title and description, from metacheck's module list
# (the titles the paper report app shows).
MODULE_INFO <- tryCatch({
  ml <- as.data.frame(metacheck::module_list())
  ml <- ml[match(ALLOWED_MODULES, ml$name), c("name", "title", "description")]
  ml$description <- trimws(gsub("[[:space:]]+", " ", ml$description))
  ml$default <- ml$name %in% DEFAULT_MODULES
  rownames(ml) <- NULL
  ml
}, error = function(e) NULL)

# Modules installed from GitHub on this server (the playbook's
# metacheck_modules, with metacheck::module_install()), such as
# tue_datamanager_check: a repository check of an uploaded .zip runs one of
# them when asked (field `modules`) and returns its own report. Only the
# administrator installs them; read once, when the API starts.
INSTALLED_MODULES <- tryCatch({
  ml <- as.data.frame(metacheck::module_list())
  ml <- ml[!is.na(ml$source), c("name", "title", "description", "source")]
  ml$description <- trimws(gsub("[[:space:]]+", " ", ml$description))
  rownames(ml) <- NULL
  ml
}, error = function(e) data.frame(name = character(0), title = character(0),
                                  description = character(0), source = character(0)))

#* The modules that may be requested, the default set, and each one's title and description; `installed`: the modules installed on this server that a repository check (.zip) can run instead
#* @get /modules
#* @serializer json
function() {
  list(allowed = ALLOWED_MODULES, default = DEFAULT_MODULES, info = MODULE_INFO,
       installed = INSTALLED_MODULES)
}

#* Submit a job; answers at once with the job's id and where to follow it
#* @post /jobs
#* @parser multi
#* @parser octet
#* @param file:file The PDF or bibr JSON (at most 50 MB), or for repocheck a .zip (at most 500 MB)
#* @param url for repocheck, instead of a file: a link to an online repository (GitHub, OSF, Zenodo, ...)
#* @param kind "report" (default), "check", "convert" or "repocheck"
#* @param modules Comma-separated module names (optional; see GET /modules); for repocheck, one installed module to run on the .zip or link instead (see `installed` in GET /modules)
#* @param human_participants repocheck with an installed module: "true" or "false" when you know whether people took part or personal data was used (optional)
#* @param report "true" to include the HTML report in a check result (optional)
#* @param crossref "true" to let bibr complete the references through Crossref, which sends the paper's reference list to Crossref (optional, default false)
#* @param run_code repocheck: "false" to skip running the repository's R and Python code in the sandbox (default true where the server offers it; see GET /health). report and check: "true" to also fetch the repository the paper links to, run its code in the sandbox and compare the results with the paper (default false)
#* @serializer unboxedJSON
function(req, res) {
  id <- tryCatch(.submit(req), error = function(e) e)
  if (inherits(id, "error")) return(.error_response(res, id))
  res$status <- 202
  .status_body(id, req)
}

#* The status of a job
#* @get /jobs/<id>
#* @serializer unboxedJSON
function(id, req, res) {
  if (!.valid_id(id)) { res$status <- 404; return(list(error = "No such job (results are kept for one hour).")) }
  .status_body(id, req)
}

#* The result of a finished job (HTML report or JSON)
#* @get /jobs/<id>/result
function(id, res) {
  if (!.valid_id(id)) {
    res$status <- 404
    res$setHeader("Content-Type", "application/json")
    res$body <- jsonlite::toJSON(list(error = "No such job (results are kept for one hour)."), auto_unbox = TRUE)
    return(res)
  }
  .result_response(id, res)
}

#* Make a metacheck report (HTML) from a PDF or bibr JSON, in one call
#* @post /report
#* @parser multi
#* @parser octet
#* @param file:file The PDF or bibr JSON
#* @param modules Comma-separated module names (optional; see GET /modules)
#* @param crossref "true" to let bibr complete the references through Crossref (sends the reference list to Crossref; default false)
#* @param run_code "true" to also fetch the repository the paper links to, run its code in the sandbox and compare the results with the paper (default false)
function(req, res) .one_call(req, res, "report")

#* Run metacheck modules on a PDF or bibr JSON and return the results as JSON, in one call
#* @post /check
#* @parser multi
#* @parser octet
#* @param file:file The PDF or bibr JSON
#* @param modules Comma-separated module names (optional; see GET /modules)
#* @param crossref "true" to let bibr complete the references through Crossref (sends the reference list to Crossref; default false)
#* @param run_code "true" to also fetch the repository the paper links to, run its code in the sandbox and compare the results with the paper (default false)
#* @param report "true" to include the HTML report as report_html (optional, default false)
function(req, res) .one_call(req, res, "check")

#* Convert a PDF to bibr JSON, in one call
#* @post /convert
#* @parser multi
#* @parser octet
#* @param file:file The PDF
#* @param crossref "true" to let bibr complete the references through Crossref (sends the reference list to Crossref; default false)
function(req, res) .one_call(req, res, "convert")

#* Check a data and code folder (.zip, at most 500 MB) with repo_check, code_check and data_check, and run its R and Python code in a sandbox (reproducibility_check), in one call; returns the HTML report
#* @post /repocheck
#* @parser multi
#* @parser octet
#* @param file:file The .zip of the folder (or, instead, `url`)
#* @param url A link to an online repository (GitHub, OSF, Zenodo, Dataverse, ...), instead of a .zip; the server fetches its public files
#* @param run_code "false" to skip running the R and Python code in the sandbox (default true where the server offers it; see GET /health)
#* @param modules An installed module to run on the .zip or link instead, such as tue_datamanager_check (optional; see `installed` in GET /modules); returns that module's report
#* @param human_participants For an installed module: "true" or "false" when you know whether people took part or personal data was used (optional; the module decides otherwise)
function(req, res) .one_call(req, res, "repocheck")
