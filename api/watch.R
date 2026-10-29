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

# The messages are read by people who look after the server, not only by
# those who built it: each says what stopped working and what that means for
# visitors, in plain words.
problems <- character(0)
health <- tryCatch(httr2::request(paste0(API, "/health")) |> httr2::req_timeout(20) |>
                     httr2::req_perform() |> httr2::resp_body_json(),
                   error = function(e) NULL)
if (is.null(health)) {
  problems <- c(problems, web = paste(
    "The website's checking service does not answer, so no papers can be checked on the website."))
}

# The models tried first (llm_first.R), and this server's own model, which is
# used when they cannot do the check; for the messages below too.
first <- sub("/+$", "", Sys.getenv("METACHECK_LLM_FIRST_URL"))
first_models <- trimws(strsplit(Sys.getenv("METACHECK_LLM_FIRST_MODELS"), ",")[[1]])
first_name <- Sys.getenv("METACHECK_LLM_FIRST_NAME", "the other language model server")
local_model <- Sys.getenv("METACHECK_LLM_MODEL")
local_desc <- paste0("the smaller model on the SURF server",
                     if (nzchar(local_model)) paste0(" (", local_model, ")"))

bibr <- Sys.getenv("BIBR_API_URL")
grobid <- Sys.getenv("METACHECK_GROBID_URL")
if (nzchar(bibr) && !answers(paste0(bibr, "/ready"))) {
  problems <- c(problems, bibr = paste0(
    "bibr, the service that turns PDFs into text, does not answer (", bibr, "), so ",
    if (nzchar(grobid)) "GROBID turns PDFs into text instead." else "uploaded PDFs cannot be checked."))
}
if (nzchar(grobid) && !answers(paste0(grobid, "/api/isalive"),
                               ok = function(r) grepl("true", httr2::resp_body_string(r)))) {
  problems <- c(problems, grobid = if (nzchar(bibr)) {
    "GROBID, the program that turns PDFs into text when bibr fails, does not answer."
  } else {
    "GROBID, the program that turns PDFs into text, does not answer, so uploaded PDFs cannot be checked."
  })
}
docx <- Sys.getenv("METACHECK_DOCX_URL")
if (nzchar(docx) && !answers(paste0(docx, "/health"))) {
  problems <- c(problems, docx = paste(
    "LibreOffice, the program that turns Word files into PDFs, does not answer,",
    "so uploaded Word files cannot be checked."))
}
llm <- Sys.getenv("OLLAMA_BASE_URL")
if (nzchar(llm) && nzchar(local_model)) {
  key <- Sys.getenv("VLLM_API_KEY")
  if (!answers(paste0(llm, "/v1/models"),
               headers = if (nzchar(key)) list(Authorization = paste("Bearer", key)) else list())) {
    problems <- c(problems, llm = paste0(
      "The language model on the SURF server does not answer, so ",
      if (nzchar(first)) paste0("the power check has no fallback when ", first_name, " does not answer.")
      else "the power check runs without a language model."))
  }
}
# The server of the models tried first: a problem when it does not answer or
# offers none of them, not when none of them is running, which is normal
# (SPIKE-1 unloads a model that has not been used for 15-60 minutes, and a job
# wakes it).
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
      first_name, " does not answer, or none of the chosen models (",
      paste(first_models, collapse = ", "), ") is available, so the power check uses ",
      local_desc, "."))
  }
}

free_gb <- tryCatch({
  out <- system2("df", c("-P", "-B1G", shQuote(JOBS)), stdout = TRUE)
  as.numeric(strsplit(trimws(out[length(out)]), "\\s+")[[1]][4])
}, error = function(e) NA)
if (!is.na(free_gb) && free_gb < MIN_FREE_GB) {
  problems <- c(problems, disk = sprintf(paste(
    "The server has only %s GB of free disk space for checks.",
    "Below 10 GB it refuses new checks."), free_gb))
}

# The data repositories' keys the server provides that were refused or
# reached their limit (key_problems of /health: metacheck::api_key_status()),
# and a GitHub key that expires within two weeks: GitHub gives the date with
# each answer to a request with the key, and /rate_limit does not count
# toward the limit. The message for the visitor (p$message) asks for their
# own key; this one says what to do on the server.
NEW_KEY <- "(see secrets.md in the bus_factor repository) and give it to the playbook"
key_message <- function(p) {
  s <- p$label %||% p$service
  until <- if (length(p$until)) paste(" until", p$until) else ""
  then <- if (length(p$until)) "Until then" else "Until the limit is reset"
  if (identical(p$problem, "rejected")) {
    paste(sprintf("%s refused the server's %s key; it may have expired or been withdrawn.", s, s),
          paste0("Make a new one ", NEW_KEY, "."))
  } else if (identical(p$problem, "limit") && identical(p$source, "none")) {
    sprintf(paste("The server has no %s key, and %s's limit for requests without a key",
                  "was reached%s. %s, visitors are asked to enter their own key."), s, s, until, then)
  } else if (identical(p$problem, "limit")) {
    sprintf("The server's %s key has reached %s's limit%s. %s, visitors are asked to enter their own key.",
            s, s, until, then)
  } else {
    p$message   # a /health from before problem and source were given
  }
}
for (p in health$key_problems %||% list()) {
  problems <- c(problems, stats::setNames(key_message(p), paste0("key_", p$service)))
}
github_key <- Sys.getenv("GITHUB_PAT")
if (nzchar(github_key)) {
  expires <- tryCatch({
    resp <- httr2::request("https://api.github.com/rate_limit") |>
      httr2::req_headers(Authorization = paste("token", github_key), `User-Agent` = "metacheck") |>
      httr2::req_timeout(20) |> httr2::req_error(is_error = function(r) FALSE) |>
      httr2::req_perform()
    # "2026-11-27 12:00:00 UTC"; none for a key without an end date
    httr2::resp_header(resp, "github-authentication-token-expiration")
  }, error = function(e) NULL)
  when <- if (!is.null(expires)) as.POSIXct(expires, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
  if (length(when) == 1 && !is.na(when) && difftime(when, Sys.time(), units = "days") < 14) {
    problems <- c(problems, key_github_expiry = paste(
      "The server's GitHub key expires on", format(when, "%Y-%m-%d"), "(UTC).",
      paste0("Make a new one before then ", NEW_KEY, " as metacheck_github_pat.")))
  }
}

before <- tryCatch(unlist(jsonlite::read_json(STATE)), error = function(e) character(0))
# Without an answer from the web interface, the keys' problems are not known:
# they stay as they were, rather than being reported as over.
if (is.null(health)) {
  unknown <- grepl("^key_", names(before)) & names(before) != "key_github_expiry" &
    !names(before) %in% names(problems)
  problems <- c(problems, before[unknown])
}
new <-problems[!names(problems) %in% names(before)]
over <- before[!names(before) %in% names(problems)]
site <- notify_site()
where <- paste0("the metacheck server", if (nzchar(site)) paste0(" (", site, ")"))
items <- function(x) paste("-", trimws(x), collapse = "\n")
if (length(new)) {
  notify(paste0("Something stopped working on ", where, ":\n", items(new), "\n",
                if (length(new) == 1) "You will get a message when it works again."
                else "You will get a message when each of these works again."))
}
if (length(over)) {
  notify(paste0(if (length(over) == 1) "This problem on " else "These problems on ", where,
                if (length(over) == 1) " is over:\n" else " are over:\n", items(over)))
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
      papers <- function(n) if (n == 1) "1 paper" else paste(n, "papers")
      # "2 by A, 1 by B"; `say` turns each value into words
      counts <- function(x, say) {
        n <- sort(table(x), decreasing = TRUE)
        paste(paste(n, vapply(names(n), say, "")), collapse = ", ")
      }
      # the reasons llm_first.R writes for this server's model
      why <- function(r) {
        if (r == "no answer") paste("because", first_name, "did not answer")
        else if (r == "none of the models listed")
          paste("because", first_name, "offered none of the chosen models")
        else if (r == "no model running")
          paste("because the model on", first_name, "was not loaded yet",
                "(it is unloaded after a while without use; metacheck asked it to load again)")
        else if (grepl("failed$", r)) paste("because the check on", first_name, "failed")
        else paste0("(", r, ")")
      }
      n <- nrow(y)
      on_first <- y$model != "local"
      n_first <- sum(on_first)
      n_local <- n - n_first
      day <- today - 1
      models <- unique(y$model[on_first])
      first_line <- if (n_first == 0) {
        NULL
      } else if (length(models) == 1) {
        paste0(if (n_first == n) { if (n == 1) "It was" else "All were" }
               else paste(n_first, if (n_first == 1) "was" else "were"),
               " checked by the ", models, " model on ", first_name, ".")
      } else {
        paste0(if (n_first == n) "All were" else paste(n_first, "were"), " checked on ", first_name,
               ": ", counts(y$model[on_first], function(m) paste("by", m)), ".")
      }
      reasons <- sub(";.*", "", y$reason[!on_first])
      local_line <- if (n_local == 0) {
        paste0(if (n == 1) "It did not need " else "None needed ", local_desc,
               ", which is used only when ", first_name, " cannot do the check.")
      } else if (n_local == 1) {
        paste0(if (n == 1) "It was" else "1 was", " checked by ", local_desc, ", ", why(reasons), ".")
      } else {
        paste0(n_local, if (n_local == 1) " was" else " were", " checked by ", local_desc, ": ",
               counts(reasons, why), ".")
      }
      notify(paste(c(
        paste0("Yesterday (", as.integer(format(day, "%d")), " ", format(day, "%B"), "), ",
               "metacheck checked the statistical power of ", papers(n), ": ",
               sum(y$where == "app"), " through the app and ", sum(y$where == "web"),
               " through the website's checking service."),
        first_line, local_line), collapse = " "))
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
