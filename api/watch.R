# watch.R ----------------------------------------------------------------------
# The server watch: every 15 minutes (metacheck-watch.timer, as the shiny user)
# it checks that the web interface, the PDF converters and the language model
# answer and that there is disk space for jobs, and sends a message to Discord
# (notify.R) when a problem starts and when it is over, not while it lasts.
# What was wrong at the last check is kept in METACHECK_WATCH_STATE.

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
llm <- Sys.getenv("OLLAMA_BASE_URL")
if (nzchar(llm) && nzchar(Sys.getenv("METACHECK_LLM_MODEL"))) {
  key <- Sys.getenv("VLLM_API_KEY")
  if (!answers(paste0(llm, "/v1/models"),
               headers = if (nzchar(key)) list(Authorization = paste("Bearer", key)) else list())) {
    problems <- c(problems, llm = "The language model does not answer; the power check runs without it.")
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
