# worker.R ---------------------------------------------------------------------
# Runs ONE job of the metacheck web interface, in its own R process (started
# by api.R with callr). A job lives in its own folder:
#   job.json      what to do: kind (report | check | convert), modules, report
#   input.pdf / input.json   the upload (deleted as soon as it has been read)
#   status.json   written here: status, step, timestamps, error
#   result.html / result.json   the result (deleted later by api.R)
#
# Uses metacheck's API helper code (metacheck-plumber/utils) and the app's
# bibr client, like the rest of the interface.

suppressPackageStartupMessages(library(metacheck))
source(file.path("metacheck-plumber", "utils", "validators.R"))
source(file.path("metacheck-plumber", "utils", "helpers.R"))
source("bibr_client.R")

.now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")

# Atomic status update: other processes (api.R) read status.json at any time.
.set_status <- function(job_dir, ...) {
  path <- file.path(job_dir, "status.json")
  st <- if (file.exists(path)) jsonlite::read_json(path) else list()
  new <- list(...)
  st[names(new)] <- new
  tmp <- tempfile(tmpdir = job_dir)
  jsonlite::write_json(st, tmp, auto_unbox = TRUE, null = "null")
  file.rename(tmp, path)
  invisible(st)
}

.setup_llm <- function() {
  llm_cache(FALSE)
  if (nzchar(Sys.getenv("OLLAMA_BASE_URL")) && nzchar(Sys.getenv("METACHECK_LLM_MODEL"))) {
    options(metacheck.llm.vllm.base_url = paste0(Sys.getenv("OLLAMA_BASE_URL"), "/v1"))
    if (!nzchar(Sys.getenv("VLLM_API_KEY"))) Sys.setenv(VLLM_API_KEY = "ollama")
    llm_use(TRUE)
    llm_model(paste0("vllm/", Sys.getenv("METACHECK_LLM_MODEL")))
    llm_max_calls(200L)
  } else {
    llm_use(FALSE)
  }
}

do_job <- function(job_dir) {
  job <- jsonlite::read_json(file.path(job_dir, "job.json"), simplifyVector = TRUE)
  input <- file.path(job_dir, job$input_file)
  .set_status(job_dir, status = "running", step = "starting", started = .now())
  tryCatch({
    .setup_llm()

    # 1. bibr JSON: convert the PDF, or use the uploaded JSON
    if (job$input_kind == "pdf") {
      .set_status(job_dir, step = "converting the PDF with bibr")
      json <- bibr_convert(input, job_dir)            # writes <job_dir>/input.json
    } else {
      json <- input
    }
    if (job$input_kind == "pdf") unlink(input)        # the PDF is no longer needed

    if (job$kind == "convert") {
      file.rename(json, file.path(job_dir, "result.json"))
      .set_status(job_dir, status = "done", step = "done", finished = .now(),
                  result_type = "application/json")
      return(invisible())
    }

    # 2. the paper
    .set_status(job_dir, step = "reading the paper")
    paper <- tryCatch(bibr_read(json), error = function(e) {
      stop("The file could not be read as bibr JSON (", conditionMessage(e), ").", call. = FALSE)
    })
    unlink(json)                                      # the upload/conversion is read
    # read() accepts any JSON; a file without a paper gives one without an id,
    # on which every module fails with an unclear message.
    if (!length(paper$paper_id) || !nrow(paper$text)) {
      stop("The file contains no paper text. Send a PDF, or the JSON that bibr returns for a PDF.",
           call. = FALSE)
    }
    ttl <- paper$info$title
    if (is.null(ttl) || length(ttl) == 0 || is.na(ttl[1]) || !nzchar(trimws(ttl[1]))) {
      paper$info$title <- "(no title found in the PDF)"  # metacheck #497
    }

    # 3. the modules, one by one, with progress
    modules <- unlist(job$modules)
    full <- list()
    for (i in seq_along(modules)) {
      m <- modules[[i]]
      .set_status(job_dir, step = sprintf("running module %d of %d: %s", i, length(modules), m))
      full[[m]] <- tryCatch(module_run(paper, m), error = function(e) {
        structure(list(module = m, title = m, table = NULL, summary_table = NULL,
                       summary_text = "Error running module",
                       report = paste0("Error running module '", m, "': ", conditionMessage(e)),
                       traffic_light = "fail", section = "general"),
                  class = "metacheck_module_output")
      })
    }

    # 4. the result
    want_report <- job$kind == "report" || isTRUE(job$report)
    html <- ""
    if (want_report) {
      .set_status(job_dir, step = "rendering the report")
      html <- render_report_html(full, paper)
      if (job$kind == "report" && !nzchar(html)) stop("The report could not be rendered.")
    }
    if (job$kind == "report") {
      writeLines(html, file.path(job_dir, "result.html"), useBytes = TRUE)
      type <- "text/html; charset=utf-8"
    } else {
      results <- lapply(full, function(r) json_safe(list(
        module = r$module, title = r$title, traffic_light = r$traffic_light,
        summary_text = r$summary_text, table = r$table, summary_table = r$summary_table)))
      out <- list(
        metacheck_version = as.character(utils::packageVersion("metacheck")),
        paper_info = as.list(info_fields(paper, c("title", "doi"))[1, , drop = FALSE]),
        modules = results,
        report_html = html
      )
      writeLines(jsonlite::toJSON(out, auto_unbox = TRUE, null = "null", na = "null", digits = NA),
                 file.path(job_dir, "result.json"), useBytes = TRUE)
      type <- "application/json"
    }
    .set_status(job_dir, status = "done", step = "done", finished = .now(), result_type = type)
  }, error = function(e) {
    unlink(list.files(job_dir, pattern = "^input\\.", full.names = TRUE))
    .set_status(job_dir, status = "failed", step = "failed", finished = .now(),
                error = conditionMessage(e))
  })
  invisible()
}
