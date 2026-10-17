# api.R ----------------------------------------------------------------------
# metacheck web interface (SURF Research Cloud component), run by plumber.
#
# Send a PDF (or bibr JSON) and get a metacheck report back, from any language.
#
# With a job (for websites and long papers):
#   POST /jobs                 file + kind (report | check | convert) -> job id
#   GET  /jobs/{id}            status: queued | running | done | failed, step, position
#   GET  /jobs/{id}/result     the result once done
# In one call (waits for the result; same queue):
#   POST /report               PDF or bibr JSON -> HTML report
#   POST /check                PDF or bibr JSON -> module results as JSON
#   POST /convert              PDF              -> bibr JSON
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
MAX_UPLOAD_BYTES <- 50 * 1024 * 1024

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

.position <- function(id) {
  p <- match(id, .queued_ids())
  if (is.na(p)) NA_integer_ else p
}

.start_worker <- function(id) {
  st <- .read_status(id)
  st$status <- "running"; st$step <- "starting"; st$started <- .now()
  .write_status(id, st)
  running[[id]] <- callr::r_bg(
    function(api_dir, job_dir) {
      setwd(api_dir)
      source("worker.R")
      do_job(job_dir)
    },
    args = list(api_dir = API_DIR, job_dir = .job_dir(id)),
    stdout = file.path(.job_dir(id), "worker.log"),
    stderr = "2>&1",
    supervise = TRUE
  )
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
        unlink(file.path(.job_dir(id), "worker.log"))
      } else {
        started <- as.POSIXct(.read_status(id)$started %||% .now(), format = "%Y-%m-%dT%H:%M:%S%z")
        if (difftime(Sys.time(), started, units = "mins") > JOB_TIMEOUT_MINUTES) {
          p$kill()
          rm(list = id, envir = running)
          unlink(list.files(.job_dir(id), pattern = "^input\\.", full.names = TRUE))
          st <- .read_status(id)
          st$status <- "failed"; st$step <- "failed"; st$finished <- .now()
          st$error <- sprintf("The job took longer than %d minutes and was stopped.", JOB_TIMEOUT_MINUTES)
          .write_status(id, st)
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
  }
}
later::later(.scheduler, 1)

# ---- submitting --------------------------------------------------------------

# Reads the multipart upload with webutils (plumber's own parser), not
# mime::parse_multipart() as metacheck's API helpers do: mime only finds a part
# when its Content-Disposition header comes first, and .NET (so PowerShell)
# sends Content-Type first, which is equally valid (metacheck #498).
.parse_upload <- function(req) {
  body <- req$bodyRaw
  if (is.null(body) || length(body) == 0) {
    req$rook.input$rewind()
    body <- req$rook.input$read()
  }
  ctype <- req$CONTENT_TYPE
  if (is.null(ctype) || !grepl("^multipart/form-data", ctype)) {
    stop("Send the file as multipart/form-data, in the form field 'file'.", call. = FALSE)
  }
  parts <- webutils::parse_http(body, ctype)
  f <- parts[["file"]]
  if (is.null(f) || is.null(f$value) || length(f$value) == 0) {
    stop("Send exactly one file in the form field 'file'.", call. = FALSE)
  }
  raw <- f$value
  if (length(raw) > MAX_UPLOAD_BYTES) stop("The file is larger than 50 MB.", call. = FALSE)
  kind <- if (length(raw) >= 4 && identical(rawToChar(raw[1:4]), "%PDF")) "pdf"
          else if (rawToChar(raw[1]) %in% c("{", "[")) "json"
          else stop("The file is neither a PDF nor bibr JSON.", call. = FALSE)
  fields <- lapply(parts[setdiff(names(parts), "file")], function(p) {
    if (is.raw(p$value)) rawToChar(p$value) else as.character(p$value)
  })
  list(raw = raw, kind = kind, fields = fields)
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
  kind <- kind %||% up$fields$kind %||% "report"
  if (!kind %in% c("report", "check", "convert")) {
    stop("kind must be report, check or convert.", call. = FALSE)
  }
  if (kind == "convert" && up$kind != "pdf") stop("convert needs a PDF.", call. = FALSE)
  if (up$kind == "pdf" && !nzchar(Sys.getenv("BIBR_API_URL"))) {
    stop("This server has no bibr: send bibr JSON instead of a PDF.", call. = FALSE)
  }
  modules <- if (kind == "convert") character(0) else .parse_modules(up$fields$modules)
  if (length(.queued_ids()) >= MAX_WAITING) {
    e <- simpleError("The queue is full; try again in a few minutes.")
    class(e) <- c("queue_full", class(e))
    stop(e)
  }
  id <- uuid::UUIDgenerate()
  dir.create(.job_dir(id), mode = "0700")
  input <- paste0("input.", up$kind)
  writeBin(up$raw, file.path(.job_dir(id), input))
  jsonlite::write_json(list(kind = kind, modules = modules, input_kind = up$kind, input_file = input,
                            report = tolower(up$fields$report %||% "false") %in% c("true", "1", "yes")),
                       file.path(.job_dir(id), "job.json"), auto_unbox = TRUE)
  .write_status(id, list(status = "queued", step = "waiting in the queue", created = .now(),
                        seq = as.numeric(Sys.time())))
  id
}

.status_body <- function(id, req) {
  st <- .read_status(id)
  # Full links as the client sees them (nginx passes the scheme and the /api
  # prefix); without nginx, links relative to this service.
  host <- req$HTTP_HOST %||% ""
  base <- if (nzchar(host)) {
    paste0(req$HTTP_X_FORWARDED_PROTO %||% "http", "://", host, req$HTTP_X_FORWARDED_PREFIX %||% "")
  } else ""
  list(
    id = id,
    status = st$status,
    step = st$step,
    position = if (identical(st$status, "queued")) .position(id) else NULL,
    created = st$created, started = st$started, finished = st$finished,
    error = st$error,
    status_url = paste0(base, "/jobs/", id),
    result_url = paste0(base, "/jobs/", id, "/result")
  )
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
#* @apiDescription Send a scientific paper (PDF, or bibr JSON) and get metacheck's report or results back. PDFs are converted with bibr on SURF Research Cloud. Uploads are deleted once processed, results one hour after they are finished.

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
       workers = MAX_WORKERS)
}

#* The modules that may be requested (and the default set)
#* @get /modules
#* @serializer json
function() {
  list(allowed = ALLOWED_MODULES, default = DEFAULT_MODULES)
}

#* Submit a job; answers at once with the job's id and where to follow it
#* @post /jobs
#* @parser multi
#* @parser octet
#* @param file:file The PDF or bibr JSON
#* @param kind "report" (default), "check" or "convert"
#* @param modules Comma-separated module names (optional; see GET /modules)
#* @param report "true" to include the HTML report in a check result (optional)
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
function(req, res) .one_call(req, res, "report")

#* Run metacheck modules on a PDF or bibr JSON and return the results as JSON, in one call
#* @post /check
#* @parser multi
#* @parser octet
#* @param file:file The PDF or bibr JSON
#* @param modules Comma-separated module names (optional; see GET /modules)
#* @param report "true" to include the HTML report as report_html (optional, default false)
function(req, res) .one_call(req, res, "check")

#* Convert a PDF to bibr JSON, in one call
#* @post /convert
#* @parser multi
#* @parser octet
#* @param file:file The PDF
function(req, res) .one_call(req, res, "convert")
