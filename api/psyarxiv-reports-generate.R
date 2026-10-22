# psyarxiv-reports-generate.R --------------------------------------------------
# PsyArXiv reports (prototype): makes metacheck's checklist report for each of
# the PSYARXIV_REPORTS_NEWEST newest PsyArXiv preprints that has none yet for
# its current version (and was not deleted through a delete link), through
# this server's own web interface (POST /jobs, kind=report, psyarxiv=<id>,
# report_type=checklist, every allowed module, crossref=true, one job at a
# time; preprints are public, so their reference lists may go to Crossref,
# which the reference checks need). Writes
# <PSYARXIV_REPORTS_DIR>/reports/<id>.html and <id>.json; see
# psyarxiv_reports.R. Run as shiny by metacheck-psyarxiv-reports.timer.

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
DIR <- Sys.getenv("PSYARXIV_REPORTS_DIR")
N <- as.integer(Sys.getenv("PSYARXIV_REPORTS_NEWEST", "0"))
API <- Sys.getenv("METACHECK_API_LOCAL", "http://127.0.0.1:2005")
PSY <- Sys.getenv("PSYARXIV_API", "https://next.psyarxiv.org/api/v1")
SITE <- sub("/api(/.*)?$", "", PSY)
UA <- "metacheck SURF Research Cloud server, PsyArXiv reports (scienceverse/surf-research-cloud)"

if (!nzchar(DIR) || is.na(N) || N < 1) quit(save = "no")
for (d in c("reports", "feedback", "deleted")) dir.create(file.path(DIR, d), recursive = TRUE, showWarnings = FALSE)
log <- function(...) cat(format(Sys.time(), "%F %T"), " ", ..., "\n", sep = "",
                         file = file.path(DIR, "generate.log"), append = TRUE)

get_json <- function(url) {
  httr2::request(url) |> httr2::req_headers(`User-Agent` = UA) |> httr2::req_timeout(120) |>
    httr2::req_retry(max_tries = 3) |> httr2::req_perform() |> httr2::resp_body_json()
}

modules <- tryCatch(unlist(get_json(paste0(API, "/modules"))$allowed), error = function(e) NULL)
if (!length(modules)) { log("the web interface did not answer; trying again at the next run"); quit(save = "no") }
newest <- tryCatch(get_json(sprintf("%s/preprints?sort=newest&per_page=%d", PSY, min(N, 100)))$results,
                   error = function(e) { log("PsyArXiv did not answer: ", conditionMessage(e)); NULL })

for (p in newest) {
  id <- p$id
  meta_file <- file.path(DIR, "reports", paste0(id, ".json"))
  if (file.exists(file.path(DIR, "deleted", paste0(id, ".json")))) next
  if (file.exists(meta_file) &&
      identical(as.integer(jsonlite::read_json(meta_file)$version), as.integer(p$version))) next
  t0 <- Sys.time()
  res <- tryCatch({
    resp <- httr2::request(paste0(API, "/jobs")) |>
      httr2::req_body_multipart(kind = "report", psyarxiv = id, report_type = "checklist",
                                modules = paste(modules, collapse = ","), crossref = "true",
                                source = "code") |>
      httr2::req_error(is_error = function(r) FALSE) |> httr2::req_perform()
    job <- httr2::resp_body_json(resp)
    if (httr2::resp_status(resp) == 503) stop("the queue is full")
    if (httr2::resp_status(resp) >= 400) stop(job$error %||% httr2::resp_status(resp))
    repeat {
      Sys.sleep(10)
      st <- get_json(paste0(API, "/jobs/", job$id))
      if (identical(st$status, "done")) break
      if (identical(st$status, "failed")) stop(st$error %||% "the job failed")
      if (difftime(Sys.time(), t0, units = "mins") > 70) stop("no result after 70 minutes")
    }
    out <- file.path(DIR, "reports", paste0(id, ".html"))
    httr2::request(paste0(API, "/jobs/", job$id, "/result")) |> httr2::req_timeout(120) |>
      httr2::req_perform(path = out)
    rec <- get_json(paste0(PSY, "/preprints/", id))
    jsonlite::write_json(list(
      id = id, version = rec$version, title = rec$title,
      authors = vapply(rec$authors %||% list(), function(a) a$name %||% "", ""),
      doi = rec$doi, posted = rec$versionPostedAt, first_posted = rec$firstPostedAt,
      url = paste0(SITE, "/preprint/", id),
      generated = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
      metacheck_version = as.character(utils::packageVersion("metacheck")),
      modules = modules), meta_file, auto_unbox = TRUE, pretty = TRUE)
    "ok"
  }, error = function(e) paste("FAILED:", conditionMessage(e)))
  log(id, " v", p$version, ": ", res, " (", round(as.numeric(difftime(Sys.time(), t0, units = "secs"))), " s)")
}
