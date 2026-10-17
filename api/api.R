# api.R ----------------------------------------------------------------------
# metacheck web interface (SURF Research Cloud component), run by plumber.
#
# Send a PDF (or bibr JSON) and get a metacheck report back, from any language:
#   POST /report    PDF or bibr JSON -> HTML report
#   POST /check     PDF or bibr JSON -> module results as JSON (+ report_html)
#   POST /convert   PDF              -> bibr JSON
#   GET  /modules                    -> the modules that may be requested
#   GET  /health
# Interactive documentation: /__docs__/ (under /api/ on the workspace).
#
# PDFs are converted by the bibr server the metacheck component is connected
# to (BIBR_API_URL / BIBR_API_KEY, the same as the app). Reports use metacheck's
# own report and helper code (inst/plumber/utils of the installed metacheck
# version, copied to ./metacheck-plumber/) and the local model for the power
# check (OLLAMA_BASE_URL / METACHECK_LLM_MODEL). Only the modules the paper
# report app offers can be requested.
#
# plumber runs one request at a time: further requests wait their turn.
#
# Uploads: like metacheck's own API, only the "multi" and "octet" parsers
# are used, so mime::parse_multipart() can read the raw upload (see
# metacheck inst/plumber/api.R for why).

suppressPackageStartupMessages({
  library(plumber)
  library(metacheck)
})

API_DIR <- getwd()
source(file.path(API_DIR, "metacheck-plumber", "utils", "validators.R"))
source(file.path(API_DIR, "metacheck-plumber", "utils", "helpers.R"))
source(file.path(API_DIR, "bibr_client.R"))

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
MAX_PDF_BYTES <- 50 * 1024 * 1024

# Local model for the power check, the way the app sets it up (see app/app.R):
# metacheck's OpenAI-compatible ("vllm") route to Ollama's /v1 address.
llm_cache(FALSE)
if (nzchar(Sys.getenv("OLLAMA_BASE_URL")) && nzchar(Sys.getenv("METACHECK_LLM_MODEL"))) {
  options(metacheck.llm.vllm.base_url = paste0(Sys.getenv("OLLAMA_BASE_URL"), "/v1"))
  if (!nzchar(Sys.getenv("VLLM_API_KEY"))) Sys.setenv(VLLM_API_KEY = "ollama")
  llm_use(TRUE)
  llm_model(paste0("vllm/", Sys.getenv("METACHECK_LLM_MODEL")))
  llm_max_calls(200L)
  logger::log_info("LLM: {llm_model()}")
} else {
  llm_use(FALSE)
  logger::log_info("No local model configured: the power check runs without LLM")
}

# ---- helpers ---------------------------------------------------------------

.modules_or_error <- function(param) {
  mods <- if (!is.null(param) && nzchar(param)) trimws(strsplit(param, ",")[[1]]) else DEFAULT_MODULES
  bad <- setdiff(mods, ALLOWED_MODULES)
  if (length(bad)) {
    stop(sprintf("Unknown or not allowed modules: %s. Allowed: %s",
                 paste(bad, collapse = ", "), paste(ALLOWED_MODULES, collapse = ", ")),
         call. = FALSE)
  }
  mods
}

# Reads the multipart upload with webutils (plumber's own parser), not
# mime::parse_multipart() as metacheck's API helpers do: mime only finds a part
# when its Content-Disposition header comes first, and .NET (so PowerShell)
# sends Content-Type first, which is equally valid.
.uploaded <- function(req) {
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
  if (length(raw) > MAX_PDF_BYTES) stop("The file is larger than 50 MB.", call. = FALSE)
  kind <- if (length(raw) >= 4 && identical(rawToChar(raw[1:4]), "%PDF")) "pdf"
          else if (rawToChar(raw[1]) %in% c("{", "[")) "json"
          else stop("The file is neither a PDF nor bibr JSON.", call. = FALSE)
  # bibr and metacheck's read() both decide the file type from the extension.
  typed <- tempfile(fileext = paste0(".", kind))
  writeBin(raw, typed)
  # the other (text) form fields, such as modules and report
  fields <- lapply(parts[setdiff(names(parts), "file")], function(p) {
    if (is.raw(p$value)) rawToChar(p$value) else as.character(p$value)
  })
  list(mp = fields, path = typed, kind = kind)
}

# PDF -> bibr JSON (via the connected bibr), or the uploaded bibr JSON; returns
# a metacheck paper.
.paper_from_upload <- function(up) {
  json <- if (up$kind == "pdf") {
    if (!nzchar(Sys.getenv("BIBR_API_URL"))) stop("This server has no bibr: send bibr JSON instead of a PDF.", call. = FALSE)
    bibr_convert(up$path, tempfile())
  } else up$path
  paper <- bibr_read(json)
  # a missing title would wipe metacheck's report header (metacheck #497)
  ttl <- paper$info$title
  if (is.null(ttl) || length(ttl) == 0 || is.na(ttl[1]) || !nzchar(trimws(ttl[1]))) {
    paper$info$title <- "(no title found in the PDF)"
  }
  paper
}

.run_modules <- function(paper, modules) {
  out <- lapply(modules, function(m) {
    tryCatch(module_run(paper, m), error = function(e) {
      structure(list(module = m, title = m, table = NULL, summary_table = NULL,
                     summary_text = "Error running module",
                     report = paste0("Error running module '", m, "': ", conditionMessage(e)),
                     traffic_light = "fail", section = "general"),
                class = "metacheck_module_output")
    })
  })
  names(out) <- modules
  out
}

.fail <- function(res, status, e) {
  res$status <- status
  list(error = if (inherits(e, "condition")) conditionMessage(e) else as.character(e))
}

# ---- endpoints ---------------------------------------------------------------

#* @apiTitle metacheck on SURF Research Cloud
#* @apiDescription Send a scientific paper (PDF, or bibr JSON) and get metacheck's report or results back. PDFs are converted with bibr on SURF Research Cloud. Papers are not stored. Requests are handled one at a time.

#* Health check
#* @get /health
#* @serializer unboxedJSON
function() {
  list(status = "ok", bibr = bibr_ready(), metacheck_version = as.character(packageVersion("metacheck")))
}

#* The modules that may be requested (and the default set)
#* @get /modules
#* @serializer json
function() {
  list(allowed = ALLOWED_MODULES, default = DEFAULT_MODULES)
}

#* Convert a PDF to bibr JSON
#* @post /convert
#* @parser multi
#* @parser octet
#* @param file:file The PDF
#* @serializer contentType list(type = "application/json")
function(req, res) {
  tryCatch({
    up <- .uploaded(req)
    on.exit(unlink(up$path), add = TRUE)
    if (up$kind != "pdf") stop("Send a PDF.", call. = FALSE)
    json <- bibr_convert(up$path, tempfile())
    on.exit(unlink(json), add = TRUE)
    readBin(json, "raw", file.size(json))
  }, error = function(e) {
    res$status <- 400
    charToRaw(jsonlite::toJSON(list(error = conditionMessage(e)), auto_unbox = TRUE))
  })
}

#* Make a metacheck report (HTML) from a PDF or bibr JSON
#* @post /report
#* @parser multi
#* @parser octet
#* @param file:file The PDF or bibr JSON
#* @param modules Comma-separated module names (optional; see GET /modules)
#* @serializer html
function(req, res) {
  tryCatch({
    up <- .uploaded(req)
    on.exit(unlink(up$path), add = TRUE)
    modules <- .modules_or_error(up$mp$modules)
    paper <- .paper_from_upload(up)
    html <- render_report_html(.run_modules(paper, modules), paper)
    if (!nzchar(html)) stop("The report could not be rendered.", call. = FALSE)
    html
  }, error = function(e) {
    res$status <- 400
    paste0("<html><body><h1>Error</h1><p>", htmltools::htmlEscape(conditionMessage(e)), "</p></body></html>")
  })
}

#* Run metacheck modules on a PDF or bibr JSON and return the results as JSON
#* @post /check
#* @parser multi
#* @parser octet
#* @param file:file The PDF or bibr JSON
#* @param modules Comma-separated module names (optional; see GET /modules)
#* @param report "true" to include the HTML report as report_html (optional, default false)
#* @serializer unboxedJSON
function(req, res) {
  tryCatch({
    up <- .uploaded(req)
    on.exit(unlink(up$path), add = TRUE)
    modules <- .modules_or_error(up$mp$modules)
    paper <- .paper_from_upload(up)
    full <- .run_modules(paper, modules)
    results <- lapply(full, function(r) json_safe(list(
      module = r$module, title = r$title, traffic_light = r$traffic_light,
      summary_text = r$summary_text, table = r$table, summary_table = r$summary_table)))
    list(
      metacheck_version = as.character(packageVersion("metacheck")),
      paper_info = as.list(info_fields(paper, c("title", "doi"))[1, , drop = FALSE]),
      modules = results,
      report_html = if (parse_bool(up$mp$report, default = FALSE)) render_report_html(full, paper) else ""
    )
  }, error = function(e) .fail(res, 400, e))
}
