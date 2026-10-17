# worker.R ---------------------------------------------------------------------
# Runs ONE job of the metacheck web interface, in its own R process (started
# by api.R with callr). A job lives in its own folder:
#   job.json      what to do: kind (report | check | convert | repocheck),
#                 modules, report, name (the uploaded file's name)
#   input.pdf / input.json / input.zip   the upload (deleted once it has been read)
#   repo/, cache/ a folder check's unpacked files (deleted when it ends)
#   progress.txt  a folder check's progress, written by metacheck's progress code
#   status.json   written here: status, step, timestamps, error
#   result.html / result.json   the result (deleted later by api.R)
#
# Uses metacheck's API helper code (metacheck-plumber/utils) and the app's
# bibr client, like the rest of the interface. A folder check (repocheck) uses
# the code of metacheck's repository check app (metacheck-repocheck/, from
# inst/app/shiny_app_repocheck), so it gives that app's report.

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

# The repository check app's code, in its own environment: its report and
# progress files, plus the limits, module list and .zip helpers defined in its
# app.R (taken by name, without running the app itself).
.repocheck_env <- function() {
  dir <- "metacheck-repocheck"
  env <- new.env(parent = globalenv())
  for (f in c("render_report.R", "brief_report.R", "shiny_progress.R")) {
    sys.source(file.path(dir, f), envir = env)
  }
  wanted <- c("MAX_UPLOAD_MB", "MAX_EXTRACTED_MB", "MAX_ZIP_FILES", "MODULES",
              "MODULE_LABELS", "check_zip", "extract_zip", "explain_error")
  for (e in parse(file.path(dir, "app.R"), keep.source = FALSE)) {
    if (is.call(e) && identical(e[[1]], as.name("<-")) && is.name(e[[2]]) &&
        as.character(e[[2]]) %in% wanted) {
      eval(e, env)
    }
  }
  missing <- setdiff(wanted, ls(env))
  if (length(missing)) stop("The repository check app no longer defines: ", paste(missing, collapse = ", "))
  env
}

do_repocheck <- function(job_dir, job) {
  rc <- .repocheck_env()
  input <- file.path(job_dir, job$input_file)
  repo <- file.path(job_dir, "repo")
  on.exit(unlink(c(input, repo, file.path(job_dir, c("unpacked", "cache", "progress.txt"))),
                 recursive = TRUE), add = TRUE)
  tryCatch({
    .set_status(job_dir, step = "checking the .zip file")
    rc$check_zip(input)
    .set_status(job_dir, step = "unpacking the .zip file")
    title <- if (nzchar(job$name %||% "")) job$name else "data and code folder"
    unpacked <- rc$extract_zip(input, file.path(job_dir, "unpacked"))
    unlink(input)
    # The report names the folder by the path it is given, so the check runs
    # from inside repo/ on a folder named after the upload (or after the
    # folder the .zip wraps everything in), not on the full server path.
    folder <- if (normalizePath(unpacked) == normalizePath(file.path(job_dir, "unpacked"))) title else basename(unpacked)
    folder <- gsub("[/[:cntrl:]]", "_", folder)
    if (folder %in% c("", ".", "..")) folder <- "folder"
    dir.create(repo)
    file.rename(unpacked, file.path(repo, folder))
    unlink(file.path(job_dir, "unpacked"), recursive = TRUE)
    old_wd <- setwd(repo)
    on.exit(setwd(old_wd), add = TRUE)
    repo_dir <- folder
    paper <- metacheck::test_paper()
    paper$info$title <- title
    rc$ensure_quarto()
    # metacheck's progress messages go to progress.txt, which api.R shows as
    # the job's step.
    options(shiny_progress_file = file.path(job_dir, "progress.txt"),
            metacheck.repo_cache.dir = file.path(job_dir, "cache"))
    modules <- rc$MODULES
    labels <- rc$MODULE_LABELS[rc$MODULES]
    args <- list(repo_check = list(local_path = repo_dir, local_only = TRUE))
    if (isTRUE(job$run_code)) {
      # metacheck's reproducibility check, running the code: always in the
      # Docker sandbox (api.R gave this process the guard's `docker` and a
      # temporary folder on the sandbox file system), never installing
      # packages (so the network stays closed), at most 5 minutes per script.
      modules <- c(modules, "reproducibility_check")
      labels <- c(labels, reproducibility_check = "Running the R and Python code in the sandbox")
      args$reproducibility_check <- list(
        execute = TRUE, sandbox = "docker", install_missing = FALSE,
        docker_use_declared_version = FALSE, timeout = 300,
        local_path = repo_dir, local_only = TRUE)
      options(metacheck.docker_resource_limits = list(cpus = 4, memory_gb = 16))
      # The sandbox's user (an unused id on this server) must be able to write
      # into the folders metacheck makes for it; they lie inside this job's
      # own folder on the sandbox file system, which only this server's
      # shiny user and root can reach.
      Sys.umask("000")
    }
    rc$use_shiny_progress()
    rc$shiny_progress_modules(labels, from = 0.1, to = 0.9)
    rc$render_brief_report(paper, modules, file.path(job_dir, "result.html"), args = args)
  }, error = function(e) stop(rc$explain_error(conditionMessage(e)), call. = FALSE))
  unlink(file.path(job_dir, "progress.txt"))
  .set_status(job_dir, status = "done", step = "done", finished = .now(),
              result_type = "text/html; charset=utf-8")
}

do_job <- function(job_dir) {
  job <- jsonlite::read_json(file.path(job_dir, "job.json"), simplifyVector = TRUE)
  input <- file.path(job_dir, job$input_file)
  .set_status(job_dir, status = "running", step = "starting", started = .now())
  tryCatch({
    if (job$kind == "repocheck") return(do_repocheck(job_dir, job))
    .setup_llm()

    # 1. bibr JSON: convert the PDF, or use the uploaded JSON
    if (job$input_kind == "pdf") {
      .set_status(job_dir, step = "converting the PDF with bibr")
      # bibr uses Crossref only when asked (it sends the reference list there)
      json <- bibr_convert(input, job_dir, crossref = isTRUE(job$crossref))  # writes <job_dir>/input.json
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
    unlink(list.files(job_dir, pattern = "^input[.]", full.names = TRUE))
    unlink(file.path(job_dir, c("repo", "unpacked", "cache", "progress.txt")), recursive = TRUE)
    .set_status(job_dir, status = "failed", step = "failed", finished = .now(),
                error = conditionMessage(e))
  })
  invisible()
}
