# psyarxiv-reports-generate.R --------------------------------------------------
# PsyArXiv reports (prototype): makes metacheck's checklist report for each of
# the PSYARXIV_REPORTS_NEWEST newest PsyArXiv preprints that has none yet for
# its current version (and was not deleted through a delete link), through
# this server's own web interface (POST /jobs, kind=report, psyarxiv=<id>,
# report_type=checklist, every allowed module, run_code=true, crossref=true,
# one job at a time; preprints are public, so their reference lists may go to
# Crossref, which the reference checks need). Writes
# <PSYARXIV_REPORTS_DIR>/reports/<id>.html and <id>.json; see
# psyarxiv_reports.R. Run as shiny by metacheck-psyarxiv-reports.timer.
#
# When the full report fails (a large repository can take longer than the
# job's hour), a second try leaves out the repository checks and running the
# code, and says so at the top of the report; when that fails too, a page
# saying the automated check failed is stored instead, so that version is not
# tried again. Errors of the server itself (busy, restarting, not answering)
# leave nothing behind and are tried again at the next run.

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
DIR <- Sys.getenv("PSYARXIV_REPORTS_DIR")
N <- as.integer(Sys.getenv("PSYARXIV_REPORTS_NEWEST", "0"))
API <- Sys.getenv("METACHECK_API_LOCAL", "http://127.0.0.1:2005")
PSY <- Sys.getenv("PSYARXIV_API", "https://next.psyarxiv.org/api/v1")
SITE <- sub("/api(/.*)?$", "", PSY)
UA <- "metacheck SURF Research Cloud server, PsyArXiv reports (scienceverse/surf-research-cloud)"
# messages to Discord (notify.R): each finished or failed report, and runs
# that could not start
source("notify.R")

if (!nzchar(DIR) || is.na(N) || N < 1) quit(save = "no")
for (d in c("reports", "feedback", "deleted")) dir.create(file.path(DIR, d), recursive = TRUE, showWarnings = FALSE)
log <- function(...) cat(format(Sys.time(), "%F %T"), " ", ..., "\n", sep = "",
                         file = file.path(DIR, "generate.log"), append = TRUE)

get_json <- function(url) {
  httr2::request(url) |> httr2::req_headers(`User-Agent` = UA) |> httr2::req_timeout(120) |>
    httr2::req_retry(max_tries = 3) |> httr2::req_perform() |> httr2::resp_body_json()
}

modules <- tryCatch(unlist(get_json(paste0(API, "/modules"))$allowed), error = function(e) NULL)
if (!length(modules)) {
  log("the web interface did not answer; trying again at the next run")
  notify(paste("This hour's reports on new PsyArXiv preprints were skipped, because the website's",
               "checking service did not answer. The next attempt is in an hour."))
  quit(save = "no")
}
newest <- tryCatch(get_json(sprintf("%s/preprints?sort=newest&per_page=%d", PSY, min(N, 100)))$results,
                   error = function(e) {
                     log("PsyArXiv did not answer: ", conditionMessage(e))
                     notify(paste("This hour's reports on new PsyArXiv preprints were skipped,",
                                  "because PsyArXiv did not answer. The next attempt is in an hour."))
                     NULL
                   })

# For testing, or to redo particular preprints: only these (ids, separated by
# commas), instead of the newest.
only <- strsplit(trimws(Sys.getenv("PSYARXIV_REPORTS_ONLY")), "[, ]+")[[1]]
if (length(only)) newest <- lapply(only, function(id) get_json(paste0(PSY, "/preprints/", id)))

# The repository checks: left out of the second try.
REPO_MODULES <- c("repo_check", "code_check", "data_check", "codebook_check")

# Errors that say nothing about the preprint (the server or a service was
# busy, restarting or not answering): no report and no failure page; the next
# run tries again.
transient <- function(err) {
  grepl(paste("queue is full", "did not answer", "service restarted", "Connection refused",
              "Couldn't connect", "Failed to connect", "Could not resolve", "Timeout was reached",
              "HTTP 50[234]", sep = "|"), err, ignore.case = TRUE)
}

# One report through the web interface, saved as `out`, with the code of the
# paper's repository run when `run_code`. Returns list(ok, converter), or
# list(ok = FALSE, error).
make_report <- function(id, mods, run_code, out) {
  t0 <- Sys.time()
  tryCatch({
    resp <- httr2::request(paste0(API, "/jobs")) |>
      httr2::req_body_multipart(kind = "report", psyarxiv = id, report_type = "checklist",
                                modules = paste(mods, collapse = ","), crossref = "true",
                                source = "code",
                                # the sandbox (reproducibility_check), where the server has one
                                run_code = if (run_code) "true" else "false") |>
      httr2::req_error(is_error = function(r) FALSE) |> httr2::req_perform()
    job <- httr2::resp_body_json(resp)
    if (httr2::resp_status(resp) == 503) stop("the queue is full")
    if (httr2::resp_status(resp) >= 400) stop(job$error %||% httr2::resp_status(resp))
    converter <- NULL
    repeat {
      Sys.sleep(10)
      st <- get_json(paste0(API, "/jobs/", job$id))
      if (identical(st$status, "done")) { converter <- st$converter; break }
      if (identical(st$status, "failed")) stop(st$error %||% "the job failed")
      if (difftime(Sys.time(), t0, units = "mins") > 70) stop("no result after 70 minutes")
    }
    httr2::request(paste0(API, "/jobs/", job$id, "/result")) |> httr2::req_timeout(120) |>
      httr2::req_perform(path = out)
    list(ok = TRUE, converter = converter %||% "?")
  }, error = function(e) list(ok = FALSE, error = conditionMessage(e)))
}

esc <- function(x) htmltools::htmlEscape(x %||% "")

# A line at the top of a report made without the repository checks.
add_note <- function(out, why) {
  html <- paste(readLines(out, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  note <- paste0("<div style=\"margin:8px auto;max-width:1200px;padding:6px 12px;font-size:0.9em;",
                 "border-left:4px solid #c77700;\">The repository checks (the repository, code, ",
                 "data and codebook checks, and running the code) were left out of this report, ",
                 "because the full check did not finish: ", esc(why), "</div>")
  writeLines(sub("(<body[^>]*>)", paste0("\\1", note), html), out, useBytes = TRUE)
}

# The page shown instead of a report when both tries failed.
failure_page <- function(out, p, first, second) {
  writeLines(c(
    "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>No metacheck report</title>",
    "<style>body{font-family:sans-serif;max-width:760px;margin:40px auto;padding:0 16px;line-height:1.5}",
    "li{margin-bottom:8px}</style></head><body>",
    "<h1>The automated check failed</h1>",
    paste0("<p>Metacheck could not make a report on <strong>", esc(p$title), "</strong> (PsyArXiv ",
           esc(p$id), ", version ", esc(p$version), ").</p>"),
    "<ul>",
    paste0("<li>The full check: ", esc(first %||% "-"), "</li>"),
    paste0("<li>The check without the repository checks: ", esc(second), "</li>"),
    "</ul>",
    "<p>This version is not tried again; a new version of the preprint gets a new report.</p>",
    "</body></html>"), out, useBytes = TRUE)
}

for (p in newest) {
  id <- p$id
  meta_file <- file.path(DIR, "reports", paste0(id, ".json"))
  if (file.exists(file.path(DIR, "deleted", paste0(id, ".json")))) next
  if (file.exists(meta_file) &&
      identical(as.integer(jsonlite::read_json(meta_file)$version), as.integer(p$version))) next
  t0 <- Sys.time()
  out <- file.path(DIR, "reports", paste0(id, ".html"))
  part <- paste0(out, ".part")   # replaces the report only when this run has one
  title <- gsub("[*_`~|]", "", p$title %||% id)   # no Discord formatting from a title
  link <- sprintf("%s/psyarxiv-reports/?id=%s", notify_site(), id)
  mins <- function() round(as.numeric(difftime(Sys.time(), t0, units = "mins")))
  took <- function() {
    m <- mins()
    paste0("The check took ", m, if (m == 1) " minute." else " minutes.")
  }

  # 1. the full report: every check, and the code of the paper's repository
  outcome <- "full"
  used <- modules
  first <- NULL
  r <- make_report(id, modules, TRUE, part)
  # 2. without the repository checks, when the full report failed for a
  # reason that has to do with the preprint (a large repository, say)
  if (!r$ok && !transient(r$error)) {
    first <- r$error
    outcome <- "without_repository_checks"
    used <- setdiff(modules, REPO_MODULES)
    r <- make_report(id, used, FALSE, part)
    if (r$ok) add_note(part, first)
  }
  if (!r$ok && transient(r$error)) {
    unlink(part)
    log(id, " v", p$version, ": not now, trying again at the next run: ", r$error, " (", mins(), " min)")
    next
  }
  # 3. both failed: a page that says so, so that this version is not tried again
  if (!r$ok) {
    outcome <- "failed"
    used <- character(0)
    failure_page(part, p, first, r$error)
  }
  file.rename(part, out)
  rec <- tryCatch(get_json(paste0(PSY, "/preprints/", id)), error = function(e) p)
  jsonlite::write_json(list(
    id = id, version = rec$version %||% p$version, title = rec$title %||% p$title,
    authors = vapply(rec$authors %||% list(), function(a) a$name %||% "", ""),
    doi = rec$doi, posted = rec$versionPostedAt, first_posted = rec$firstPostedAt,
    url = paste0(SITE, "/preprint/", id),
    generated = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    metacheck_version = as.character(utils::packageVersion("metacheck")),
    outcome = outcome, errors = c(first, if (!r$ok) r$error),
    modules = used), meta_file, auto_unbox = TRUE, pretty = TRUE)
  log(id, " v", p$version, ": ", outcome,
      if (length(first)) paste0(" (full check: ", first, ")"),
      if (!r$ok) paste0(" (second try: ", r$error, ")"), " (", mins(), " min)")
  if (identical(outcome, "full")) {
    notify(sprintf("metacheck made a report on a new PsyArXiv preprint: **%s** (version %s)\n%s\n%s",
                   title, p$version, link, took()))
  } else if (identical(outcome, "without_repository_checks")) {
    notify(sprintf(paste0("metacheck made a report on a new PsyArXiv preprint: **%s** (version %s), ",
                          "but without checking its data and code repositories, because the check ",
                          "with them failed: %s\n%s\n%s"),
                   title, p$version, first, link, took()))
  } else {
    notify(sprintf(paste0("metacheck could not make a report on the new PsyArXiv preprint **%s** ",
                          "(version %s). Its report page now says the automated check failed.\n%s\n",
                          "Reason for the full check: %s\n",
                          "Reason for the check without the data and code repositories: %s"),
                   title, p$version, link, first %||% "-", r$error))
  }
}
