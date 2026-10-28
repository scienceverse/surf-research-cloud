# watch.R ----------------------------------------------------------------------
# The server watch: every 15 minutes (metacheck-watch.timer, as the shiny user)
# it checks that the web interface, the PDF converters and the language model
# answer and that there is disk space for jobs, and sends a message to Discord
# (notify.R) when a problem starts and when it is over, not while it lasts.
# What was wrong at the last check is kept in METACHECK_WATCH_STATE. With
# models tried first for the power check (llm_first.R), it also checks their
# server, and posts once a day which model the power checks used.

source("notify.R")
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

STATE <- Sys.getenv("METACHECK_WATCH_STATE", "/var/lib/metacheck-watch/state.json")
API <- Sys.getenv("METACHECK_API_LOCAL", "http://127.0.0.1:2005")
JOBS <- Sys.getenv("METACHECK_API_JOBS", "/var/lib/metacheck-api/jobs")
MIN_FREE_GB <- 15   # the web interface refuses new jobs below 10 GB

answers <- function(url, headers = list(), ok = function(resp) TRUE) {
  tryCatch({
    req <- httr2::request(url) |> httr2::req_timeout(20) |>
      httr2::req_error(is_error = function(r) FALSE)
    if (length(headers)) req <- httr2::req_headers(req, !!!headers)
    resp <- httr2::req_perform(req)
    httr2::resp_status(resp) == 200 && ok(resp)
  }, error = function(e) FALSE)
}

problems <- character(0)
health <- tryCatch(httr2::request(paste0(API, "/health")) |> httr2::req_timeout(20) |>
                     httr2::req_perform() |> httr2::resp_body_json(),
                   error = function(e) NULL)
if (is.null(health)) problems <- c(problems, web = "The web interface does not answer.")

bibr <- Sys.getenv("BIBR_API_URL")
if (nzchar(bibr) && !answers(paste0(bibr, "/ready"))) {
  problems <- c(problems, bibr = paste("bibr does not answer", paste0("(", bibr, ").")))
}
grobid <- Sys.getenv("METACHECK_GROBID_URL")
if (nzchar(grobid) && !answers(paste0(grobid, "/api/isalive"),
                               ok = function(r) grepl("true", httr2::resp_body_string(r)))) {
  problems <- c(problems, grobid = paste("GROBID does not answer", paste0("(", grobid, ")."),
                                         if (!nzchar(bibr)) "PDFs cannot be converted." else ""))
}
docx <- Sys.getenv("METACHECK_DOCX_URL")
if (nzchar(docx) && !answers(paste0(docx, "/health"))) {
  problems <- c(problems, docx = paste("LibreOffice (for Word files) does not answer",
                                       paste0("(", docx, ")."), "Word files cannot be converted."))
}
llm <- Sys.getenv("OLLAMA_BASE_URL")
if (nzchar(llm) && nzchar(Sys.getenv("METACHECK_LLM_MODEL"))) {
  key <- Sys.getenv("VLLM_API_KEY")
  if (!answers(paste0(llm, "/v1/models"),
               headers = if (nzchar(key)) list(Authorization = paste("Bearer", key)) else list())) {
    problems <- c(problems, llm = "The language model does not answer; the power check runs without it.")
  }
}
# The server of the models tried first (llm_first.R): a problem when it does
# not answer or offers none of them, not when none of them is running, which
# is normal (SPIKE-1 unloads a model that has not been used for 15-60 minutes,
# and a job wakes it).
first <- sub("/+$", "", Sys.getenv("METACHECK_LLM_FIRST_URL"))
first_models <- trimws(strsplit(Sys.getenv("METACHECK_LLM_FIRST_MODELS"), ",")[[1]])
first_name <- Sys.getenv("METACHECK_LLM_FIRST_NAME", "The server of the models tried first")
if (nzchar(first) && length(first_models)) {
  key <- Sys.getenv("METACHECK_LLM_FIRST_KEY")
  offered <- function(resp) {
    ids <- vapply(httr2::resp_body_json(resp)$data,
                  function(m) if (isFALSE(m$accessible)) "" else m$id %||% "", character(1))
    any(first_models %in% ids)
  }
  if (!answers(paste0(first, "/models"), ok = offered,
               headers = if (nzchar(key)) list(Authorization = paste("Bearer", key)) else list())) {
    problems <- c(problems, llm_first = paste0(
      first_name, " does not answer, or offers none of ", paste(first_models, collapse = ", "),
      "; the power check uses this server's model."))
  }
}

free_gb <- tryCatch({
  out <- system2("df", c("-P", "-B1G", shQuote(JOBS)), stdout = TRUE)
  as.numeric(strsplit(trimws(out[length(out)]), "\\s+")[[1]][4])
}, error = function(e) NA)
if (!is.na(free_gb) && free_gb < MIN_FREE_GB) {
  problems <- c(problems, disk = sprintf("Only %s GB free for jobs; below 10 GB new jobs are refused.", free_gb))
}

before <- tryCatch(unlist(jsonlite::read_json(STATE)), error = function(e) character(0))
new <- problems[!names(problems) %in% names(before)]
over <- before[!names(before) %in% names(problems)]
site <- notify_site()
if (length(new)) {
  notify(paste0("Problem on the metacheck server", if (nzchar(site)) paste0(" (", site, ")") else "", ":\n",
                paste("-", trimws(new), collapse = "\n")))
}
if (length(over)) {
  notify(paste0("Solved on the metacheck server; this problem is over:\n", paste("-", trimws(over), collapse = "\n")))
}
dir.create(dirname(STATE), recursive = TRUE, showWarnings = FALSE)
jsonlite::write_json(as.list(problems), STATE, auto_unbox = TRUE)

# Once a day, from 08:00 Dutch time: which model the power checks of the day
# before used (METACHECK_LLM_FIRST_LOG, one line per check, llm_first.R), when
# there were any. The log keeps the last 30 days; LAST_SUMMARY the date of the
# last summary.
LOG <- Sys.getenv("METACHECK_LLM_FIRST_LOG")
LAST_SUMMARY <- file.path(dirname(STATE), "llm-first-summary.txt")
now <- as.POSIXlt(Sys.time(), tz = "Europe/Amsterdam")
today <- as.Date(format(now, "%Y-%m-%d"))
last <- if (file.exists(LAST_SUMMARY))
  tryCatch(as.Date(readLines(LAST_SUMMARY, warn = FALSE)[1]), error = function(e) NA) else NA
if (nzchar(LOG) && file.exists(LOG) && now$hour >= 8 && (is.na(last) || last < today)) {
  log <- tryCatch(utils::read.delim(LOG, header = FALSE, quote = "", stringsAsFactors = FALSE,
                                    col.names = c("time", "where", "model", "reason")),
                  error = function(e) NULL)
  if (!is.null(log) && nrow(log)) {
    when <- as.POSIXct(log$time, format = "%Y-%m-%dT%H:%M:%S%z")
    day <- as.Date(format(when, "%Y-%m-%d", tz = "Europe/Amsterdam"))
    y <- log[!is.na(day) & day == today - 1, , drop = FALSE]
    if (nrow(y)) {
      counts <- function(x) {
        n <- sort(table(x), decreasing = TRUE)
        paste(paste(names(n), n), collapse = ", ")
      }
      on_first <- y$model != "local"
      local <- y[!on_first, , drop = FALSE]
      notify(paste0(
        "Power checks on ", format(today - 1, "%d %B"), ": ", nrow(y),
        " (app ", sum(y$where == "app"), ", web interface ", sum(y$where == "web"), ").\n",
        "- on ", first_name, ": ", sum(on_first),
        if (any(on_first)) paste0(" (", counts(y$model[on_first]), ")"), "\n",
        "- on this server's model: ", nrow(local),
        if (nrow(local)) paste0(" (", counts(sub(";.*", "", local$reason)), ")")))
    }
    keep <- !is.na(day) & day >= today - 30
    if (!all(keep)) {
      tmp <- tempfile(tmpdir = dirname(LOG))
      utils::write.table(log[keep, , drop = FALSE], tmp, sep = "\t", quote = FALSE,
                         row.names = FALSE, col.names = FALSE)
      file.rename(tmp, LOG)
    }
  }
  writeLines(as.character(today), LAST_SUMMARY)
}
