# worker.R ---------------------------------------------------------------------
# Runs ONE job of the metacheck web interface, in its own R process (started
# by api.R with callr). A job lives in its own folder:
#   job.json      what to do: kind (report | check | convert | repocheck),
#                 modules, report, name (the uploaded file's name)
#   input.pdf / input.json / input.zip   the upload (deleted once it has been read)
#   input.url     for a repository check of a link: the link (also in job.json)
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
# only the checks in LLM_MODULES (the power check) use the model
source("llm_modules.R")

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

# The time by which a job's code must be done (reproducibility_check's
# total_timeout as a clock time, metacheck 0.4.1.5 and later): the job's time
# limit (api.R gives it as METACHECK_JOB_LIMIT_MINUTES) from its start, minus
# CODE_REPORT_MINUTES for the checks after the code and the report, so a job
# whose code runs long still returns its report (metacheck #523). NULL without
# a limit or with an older metacheck, which then keeps its own default.
CODE_REPORT_MINUTES <- 10
.code_deadline <- function(job_dir) {
  limit <- suppressWarnings(as.numeric(Sys.getenv("METACHECK_JOB_LIMIT_MINUTES")))
  if (is.na(limit) || utils::packageVersion("metacheck") < "0.4.1.5") return(NULL)
  started <- tryCatch(jsonlite::read_json(file.path(job_dir, "status.json"))$started,
                      error = function(e) NULL)
  start <- if (is.null(started)) NA else as.POSIXct(started, format = "%Y-%m-%dT%H:%M:%S%z")
  if (is.na(start)) start <- Sys.time()
  start + (limit - CODE_REPORT_MINUTES) * 60
}

.setup_llm <- function() {
  llm_cache(FALSE)
  if (nzchar(Sys.getenv("OLLAMA_BASE_URL")) && nzchar(Sys.getenv("METACHECK_LLM_MODEL"))) {
    options(metacheck.llm.vllm.base_url = paste0(Sys.getenv("OLLAMA_BASE_URL"), "/v1"))
    if (!nzchar(Sys.getenv("VLLM_API_KEY"))) Sys.setenv(VLLM_API_KEY = "ollama")
    llm_only_for_listed_modules(TRUE)
    llm_model(paste0("vllm/", Sys.getenv("METACHECK_LLM_MODEL")))
    llm_max_calls(200L)
    # a model that reasons before it answers needs longer answers
    # (metacheck_llm_max_tokens)
    max_tokens <- suppressWarnings(as.integer(Sys.getenv("METACHECK_LLM_MAX_TOKENS")))
    if (!is.na(max_tokens) && max_tokens > 0) llm_max_tokens(max_tokens)
  } else {
    llm_only_for_listed_modules(FALSE)
  }
}

# The PDF (or .docx) as bibr JSON: from bibr, or, when bibr fails, from the
# GROBID server in METACHECK_GROBID_URL (metacheck_grobid_url; TU/e's by
# default), through metacheck's own convert(). GROBID reads PDFs only and
# gives a less complete conversion, so the job records which one was used. A
# Word file is first made into a PDF by LibreOffice on this server
# (METACHECK_DOCX_URL; metacheck_docx_converter = local), when there is one.
# Returns list(json = <path>, converter = "bibr" | "grobid" | "word+grobid").
.convert_paper <- function(input, job_dir, ext, crossref, file_name) {
  bibr_error <- NULL
  if (!nzchar(Sys.getenv("BIBR_API_URL"))) {
    bibr_error <- "This server has no bibr server."
  } else if (!bibr_ready()) {
    # asked first (5 s), so a bibr that is switched off does not keep the
    # job waiting for the connection to time out
    bibr_error <- "The bibr server does not answer."
  } else {
    json <- tryCatch(bibr_convert(input, job_dir, crossref = crossref, file_name = file_name),
                     error = function(e) { bibr_error <<- conditionMessage(e); NULL })
    if (!is.null(json)) return(list(json = json, converter = "bibr"))
  }
  grobid <- Sys.getenv("METACHECK_GROBID_URL")
  if (!nzchar(grobid)) stop(bibr_error, call. = FALSE)
  from_word <- ext != ".pdf"
  if (from_word) {
    docx <- Sys.getenv("METACHECK_DOCX_URL")
    if (!nzchar(docx)) {
      stop(bibr_error, " GROBID reads only PDF files, and this is a Word file.", call. = FALSE)
    }
    .set_status(job_dir, step = "converting the Word file to PDF with LibreOffice")
    input <- tryCatch(.word_to_pdf(input, docx, job_dir),
                      error = function(e) stop(bibr_error, " ", conditionMessage(e), call. = FALSE))
    on.exit(unlink(input), add = TRUE)
  }
  .set_status(job_dir, step = paste0(
    "converting the PDF with GROBID",
    if (crossref) " and looking up the references at Crossref" else "",
    if (nzchar(Sys.getenv("BIBR_API_URL"))) " (bibr could not convert it)" else ""))
  # With crossref (asked for by the visitor, and always by the PsyArXiv
  # reports), metacheck completes the reference list at Crossref, as bibr
  # does; when that lookup fails, the PDF is converted again without it.
  grobid_convert <- function(lookup) {
    metacheck::convert(input, job_dir, method = "grobid", api_url = grobid,
                       keep_xml = FALSE, crossref_lookup = lookup)
  }
  json <- tryCatch(
    if (crossref) tryCatch(grobid_convert(TRUE), error = function(e) grobid_convert(FALSE))
    else grobid_convert(FALSE),
    error = function(e) {
      stop(bibr_error, " The GROBID server could not convert it either (",
           conditionMessage(e), ").", call. = FALSE)
    })
  if (length(json) != 1 || is.na(json) || !file.exists(json)) {
    stop(bibr_error, " The GROBID server could not convert it either.", call. = FALSE)
  }
  list(json = json, converter = if (from_word) "word+grobid" else "grobid")
}

# A Word file as a PDF, made by LibreOffice on this server (Gotenberg's
# /forms/libreoffice/convert, at METACHECK_DOCX_URL); returns the PDF's path.
.word_to_pdf <- function(input, docx_url, job_dir) {
  pdf <- file.path(job_dir, "input-from-word.pdf")
  resp <- tryCatch(
    httr2::request(paste0(sub("/+$", "", docx_url), "/forms/libreoffice/convert")) |>
      httr2::req_body_multipart(files = curl::form_file(input)) |>
      httr2::req_timeout(300) |>
      httr2::req_error(is_error = function(r) FALSE) |>
      httr2::req_perform(path = pdf),
    error = function(e) {
      stop("LibreOffice could not make a PDF of the Word file (", conditionMessage(e), ").", call. = FALSE)
    })
  if (httr2::resp_status(resp) != 200 || !identical(readBin(pdf, "raw", 4), charToRaw("%PDF"))) {
    unlink(pdf)
    stop("LibreOffice could not make a PDF of the Word file (HTTP ", httr2::resp_status(resp), ").",
         call. = FALSE)
  }
  pdf
}

# A line at the top of an HTML report saying what converted the PDF.
.add_converter_note <- function(html, converter) {
  if (is.null(converter) || !nzchar(html)) return(html)
  note <- if (identical(converter, "word+grobid")) {
    paste("The Word file was made into a PDF by LibreOffice, and the PDF was converted by GROBID.",
          "GROBID's conversion is less complete than bibr's, so some checks may find less.")
  } else if (identical(converter, "grobid") && !nzchar(Sys.getenv("BIBR_API_URL"))) {
    paste("The PDF was converted by GROBID.",
          "GROBID's conversion is less complete than bibr's, so some checks may find less.")
  } else if (identical(converter, "grobid")) {
    paste("The PDF was converted by a GROBID server, because bibr could not convert it.",
          "GROBID's conversion is less complete than bibr's, so some checks may find less.")
  } else {
    "The PDF was converted by bibr."
  }
  div <- paste0('<div class="metacheck-converter" style="margin:8px auto;max-width:1200px;',
                'padding:6px 12px;font-size:0.9em;border-left:4px solid ',
                if (converter %in% c("grobid", "word+grobid")) "#c77700" else "#999", ';">', note, '</div>')
  sub("(<body[^>]*>)", paste0("\\1", div), html)
}

# What one job's code may use in the Docker sandbox (metacheck_sandbox_cpus and
# metacheck_sandbox_memory, which the playbook writes into the web interface's
# service); the guard holds the same limits and never allows more.
.sandbox_limits <- function() {
  num <- function(var, default) {
    x <- suppressWarnings(as.numeric(Sys.getenv(var)))
    if (is.na(x) || x <= 0) default else x
  }
  list(cpus = num("METACHECK_SANDBOX_CPUS", 4),
       memory_gb = num("METACHECK_SANDBOX_MEMORY_MB", 16384) / 1024)
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
  wanted <- c("MAX_UPLOAD_MB", "MAX_EXTRACTED_MB", "MAX_ZIP_FILES", "MAX_FILE_MB",
              "MAX_DOWNLOAD_MB", "MODULES", "MODULE_LABELS", "check_zip", "extract_zip",
              "explain_error", "normalise_repo_url", "download_args")
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
    if (identical(job$input_kind, "url")) {
      # A link to an online repository: metacheck fetches the public files
      # itself (as the repository check app does), at most MAX_FILE_MB per file
      # and MAX_DOWNLOAD_MB per repository, into this job's cache folder.
      url <- rc$normalise_repo_url(job$url)
      paper <- metacheck::test_paper(text = url, url = url)
      paper$info$title <- url
      fetch <- rc$download_args
      args <- list(code_check = fetch, data_check = fetch)
      code_place <- c(list(local_only = FALSE), fetch)
    } else {
      # A .zip of a folder: checked, unpacked, and checked from inside repo/.
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
      # metacheck looks for a module in ./modules/ before the installed ones
      # (module_find()), and the check runs from inside repo/: an upload named
      # modules.zip holding tue_datamanager_check.R would run its own code
      # outside the sandbox. So the folder is never called "modules".
      if (identical(folder, "modules")) folder <- "modules_folder"
      dir.create(repo)
      file.rename(unpacked, file.path(repo, folder))
      unlink(file.path(job_dir, "unpacked"), recursive = TRUE)
      old_wd <- setwd(repo)
      on.exit(setwd(old_wd), add = TRUE)
      repo_dir <- folder
      paper <- metacheck::test_paper()
      paper$info$title <- title
      args <- list(repo_check = list(local_path = repo_dir, local_only = TRUE))
      code_place <- list(local_path = repo_dir, local_only = TRUE)
    }
    rc$ensure_quarto()
    # metacheck's progress messages go to progress.txt, which api.R shows as
    # the job's step.
    options(shiny_progress_file = file.path(job_dir, "progress.txt"),
            metacheck.repo_cache.dir = file.path(job_dir, "cache"))
    # no language model: only the power check may use it (llm_modules.R)
    llm_only_for_listed_modules(FALSE)
    if (length(job$modules)) {
      # An installed module (api.R allows only those: INSTALLED_MODULES), such
      # as tue_datamanager_check: run on the unpacked folder or the link, with
      # its own full report. It runs the metacheck modules it needs itself.
      # No language model, also not for the module's own calls: only the
      # power check may use it (llm_modules.R). metacheck's default model is
      # the local Ollama, which tue_datamanager_check would use, so the model
      # is cleared too.
      llm_cache(FALSE)
      llm_model(NULL)
      m <- job$modules[[1]]
      # an unpacked .zip, or a link (checked by api.R: public addresses only),
      # whose files the module fetches itself (100 MB per file, 500 MB in all)
      margs <- list(local_path = if (identical(job$input_kind, "url")) job$url else repo_dir,
                    readme_revised_dir = job_dir)
      if (is.logical(job$human_participants) && length(job$human_participants) == 1 &&
          !is.na(job$human_participants)) {
        margs$human_participants <- job$human_participants
      }
      if (isTRUE(job$run_code)) {
        # the module runs the code with metacheck's reproducibility check, as
        # for a repository check: in the Docker sandbox, installing missing
        # CRAN and PyPI packages first, at most 5 minutes per script (see below)
        margs$run_code <- TRUE
        margs$run_args <- list(sandbox = "docker", install_missing = TRUE,
                               docker_use_declared_version = FALSE, timeout = 300)
        deadline <- .code_deadline(job_dir)
        if (!is.null(deadline)) margs$run_args$total_timeout <- deadline
        options(metacheck.docker_resource_limits = .sandbox_limits())
        Sys.umask("000")   # see below: the sandbox's user writes into these folders
      }
      rc$use_shiny_progress()
      .set_status(job_dir, step = sprintf("running %s", m))
      # the checklist report: what to fix and to improve first, with what was
      # found and what to do on separate lines (metacheck 0.4.0.6)
      metacheck::report(paper, modules = m, output_file = file.path(job_dir, "result.html"),
                        report_type = "checklist",
                        args = stats::setNames(list(margs), m))
      unlink(file.path(job_dir, "progress.txt"))
      .set_status(job_dir, status = "done", step = "done", finished = .now(),
                  result_type = "text/html; charset=utf-8")
      return(invisible())
    }
    modules <- rc$MODULES
    labels <- rc$MODULE_LABELS[rc$MODULES]
    if (isTRUE(job$run_code)) {
      # metacheck's reproducibility check, running the code: always in the
      # Docker sandbox (api.R gave this process the guard's `docker` and a
      # temporary folder on the sandbox file system), installing missing CRAN
      # and PyPI packages first (the guard's install container is the only one
      # with the network; the code runs without it), at most 5 minutes per script.
      modules <- c(modules, "reproducibility_check")
      labels <- c(labels, reproducibility_check = "Running the R and Python code in the sandbox")
      args$reproducibility_check <- c(list(
        execute = TRUE, sandbox = "docker", install_missing = TRUE,
        docker_use_declared_version = FALSE, timeout = 300), code_place)
      deadline <- .code_deadline(job_dir)
      if (!is.null(deadline)) args$reproducibility_check$total_timeout <- deadline
      options(metacheck.docker_resource_limits = .sandbox_limits())
      # The sandbox's user (an unused id on this server) must be able to write
      # into the folders metacheck makes for it; they lie inside this job's
      # own folder on the sandbox file system, which only this server's
      # shiny user and root can reach.
      Sys.umask("000")
    }
    rc$use_shiny_progress()
    rc$shiny_progress_modules(labels, from = 0.1, to = 0.9)
    if (identical(job$report_type, "checklist")) {
      # metacheck's checklist report (what to fix and to improve first), as the
      # ResearchBox page asks for, instead of the app's brief report
      metacheck::report(paper, modules = modules, output_file = file.path(job_dir, "result.html"),
                        report_type = "checklist", args = args)
    } else {
      rc$render_brief_report(paper, modules, file.path(job_dir, "result.html"), args = args)
    }
  }, error = function(e) stop(rc$explain_error(conditionMessage(e)), call. = FALSE))
  unlink(file.path(job_dir, "progress.txt"))
  .set_status(job_dir, status = "done", step = "done", finished = .now(),
              result_type = "text/html; charset=utf-8")
}

# A paper with "run the code" ticked: the chosen modules, then the paper's
# repository through the links in the paper (repo_check, code_check,
# data_check) and metacheck's reproducibility check, which runs the code in the
# Docker sandbox (as for a repository check) and compares the statistics it
# prints with those in the paper. Run as one chain (report_module_run), so
# each module gets the results of the ones before it; progress through
# metacheck's progress code, as in the repository check.
.run_paper_code <- function(paper, modules, job_dir) {
  rc <- .repocheck_env()
  chain <- c("repo_check", "code_check", "data_check", "reproducibility_check")
  modules <- c(setdiff(modules, chain), chain)
  fetch <- rc$download_args
  args <- list(
    code_check = fetch, data_check = fetch,
    reproducibility_check = c(list(
      execute = TRUE, sandbox = "docker", install_missing = TRUE,
      docker_use_declared_version = FALSE, timeout = 300, local_only = FALSE), fetch))
  deadline <- .code_deadline(job_dir)
  if (!is.null(deadline)) args$reproducibility_check$total_timeout <- deadline
  progress <- file.path(job_dir, "progress.txt")
  on.exit(unlink(c(progress, file.path(job_dir, "cache")), recursive = TRUE), add = TRUE)
  options(shiny_progress_file = progress,
          metacheck.repo_cache.dir = file.path(job_dir, "cache"),
          metacheck.docker_resource_limits = .sandbox_limits())
  Sys.umask("000")   # see do_repocheck(): the sandbox's user writes into these folders
  labels <- vapply(modules, function(m) {
    tryCatch(metacheck::module_info(m)$title, error = function(e) m) %||% m
  }, character(1))
  labels["reproducibility_check"] <- "Running the code of the paper's repository in the sandbox"
  rc$use_shiny_progress()
  rc$shiny_progress_modules(stats::setNames(labels, modules), from = 0.1, to = 0.9)
  metacheck::report_module_run(paper, modules, args)
}

# A PsyArXiv preprint (field `psyarxiv`, an id checked by api.R): its record
# from PsyArXiv's API, and its current PDF saved as <job_dir>/input.pdf. The
# addresses are built here from PSYARXIV_API (the id is the only input), and a
# file comes only from PsyArXiv itself or, when PsyArXiv has only that link,
# from the OSF. PsyArXiv's files send no CORS header, which is why a web page
# cannot fetch the PDF and send it on itself.
.fetch_psyarxiv <- function(id, job_dir) {
  api <- Sys.getenv("PSYARXIV_API", "https://next.psyarxiv.org/api/v1")
  site <- sub("/api(/.*)?$", "", api)
  ua <- "metacheck SURF Research Cloud server (scienceverse/surf-research-cloud)"
  resp <- httr2::request(paste0(api, "/preprints/", id)) |>
    httr2::req_headers(`User-Agent` = ua) |>
    httr2::req_timeout(60) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_error(is_error = function(r) FALSE) |>
    httr2::req_perform()
  if (httr2::resp_status(resp) == 404) stop("PsyArXiv has no preprint with the id '", id, "'.", call. = FALSE)
  if (httr2::resp_status(resp) >= 400) {
    stop("PsyArXiv did not answer (HTTP ", httr2::resp_status(resp), "); try again later.", call. = FALSE)
  }
  rec <- httr2::resp_body_json(resp, simplifyVector = FALSE)
  if (identical(rec$state, "withdrawn")) stop("This preprint was withdrawn from PsyArXiv; it has no file to check.", call. = FALSE)
  v <- if (length(rec$versions)) rec$versions[[1]] else list()
  # fileUrl is normally relative to PsyArXiv's site; an absolute one is
  # accepted only on that site (seen once in a batch on 22 October 2026)
  src <- rec$fileUrl %||% v$fileUrl
  src <- if (is.null(src)) NULL
         else if (startsWith(src, "/")) paste0(site, src)
         else if (startsWith(src, paste0(site, "/"))) src
         else NULL
  if (is.null(src) && is.character(v$osfFileUrl) && startsWith(v$osfFileUrl, "https://osf.io/")) src <- v$osfFileUrl
  if (is.null(src)) stop("This preprint has no file to check on PsyArXiv.", call. = FALSE)
  # About one in four PsyArXiv preprints is a Word file (.docx, uploaded to
  # the OSF as such). bibr reads .docx itself (natively, from the document's
  # structure), so it is sent on as it is; an old .doc it refuses.
  type <- tolower(v$contentType %||% "application/pdf")
  ext <- if (identical(type, "application/pdf")) ".pdf"
         else if (identical(type, "application/vnd.openxmlformats-officedocument.wordprocessingml.document")) ".docx"
         else stop("This preprint's file is a ", v$contentType, " file; metacheck reads PDF and Word (.docx) files.", call. = FALSE)
  dest <- file.path(job_dir, paste0("input", ext))
  httr2::request(src) |>
    httr2::req_headers(`User-Agent` = ua) |>
    httr2::req_timeout(300) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_perform(path = dest)
  if (file.size(dest) > 50 * 1024^2) stop("The preprint's file is larger than 50 MB.", call. = FALSE)
  head4 <- readBin(dest, "raw", 4)
  ok <- if (ext == ".pdf") identical(head4, charToRaw("%PDF"))
        else identical(head4, as.raw(c(0x50, 0x4b, 0x03, 0x04)))   # a .docx is a zip
  if (!ok) stop("The file PsyArXiv sent is not the ", sub("^.", "", ext), " file it says it is.", call. = FALSE)
  list(path = dest, ext = ext, title = rec$title %||% "", version = rec$version %||% NA)
}

# metacheck's checklist report (report_type = "checklist") from module results
# that already ran: as metacheck::report() renders it (rmarkdown, with the
# pandoc Quarto ships), without running the modules a second time. Returns the
# HTML, or "" when it could not be rendered.
render_checklist_html <- function(module_output, paper) {
  tryCatch({
    prev <- metacheck::report_type()
    metacheck::report_type("checklist")
    on.exit(metacheck::report_type(prev), add = TRUE)
    rmd <- tempfile(fileext = ".Rmd")
    html <- sub("Rmd$", "html", rmd)
    on.exit(unlink(c(rmd, html)), add = TRUE)
    writeLines(metacheck::report_qmd(module_output, paper), rmd, useBytes = TRUE)
    pandoc <- tryCatch(metacheck:::.report_pandoc_dir(), error = function(e) NULL)
    if (is.null(pandoc)) {
      # on Linux, Quarto keeps pandoc one folder deeper, in tools/<arch>/,
      # where metacheck's .report_pandoc_dir() does not look
      q <- tryCatch(quarto::quarto_path(), error = function(e) NULL)
      hits <- if (length(q) && nzchar(q)) Sys.glob(file.path(dirname(q), "tools", "*", "pandoc")) else character(0)
      if (length(hits)) pandoc <- dirname(hits[1])
    }
    if (!is.null(pandoc)) {
      old <- Sys.getenv("RSTUDIO_PANDOC", unset = NA)
      Sys.setenv(RSTUDIO_PANDOC = pandoc)
      on.exit(if (is.na(old)) Sys.unsetenv("RSTUDIO_PANDOC") else Sys.setenv(RSTUDIO_PANDOC = old), add = TRUE)
    }
    rmarkdown::render(rmd, output_file = basename(html), output_dir = dirname(html),
                      quiet = TRUE, envir = new.env(parent = globalenv()))
    paste(readLines(html, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  }, error = function(e) {
    message("checklist report not rendered: ", conditionMessage(e))
    ""
  })
}

do_job <- function(job_dir) {
  job <- jsonlite::read_json(file.path(job_dir, "job.json"), simplifyVector = TRUE)
  input <- file.path(job_dir, job$input_file)
  .set_status(job_dir, status = "running", step = "starting", started = .now())
  tryCatch({
    if (job$kind == "repocheck") return(do_repocheck(job_dir, job))
    .setup_llm()

    # 0. a PsyArXiv preprint: fetch its file (PDF, or a Word .docx, which bibr
    # reads too), then go on as for an uploaded PDF
    ext <- ".pdf"
    if (identical(job$input_kind, "psyarxiv")) {
      .set_status(job_dir, step = "fetching the preprint from PsyArXiv")
      pp <- .fetch_psyarxiv(job$psyarxiv, job_dir)
      unlink(input)
      input <- pp$path
      ext <- pp$ext
      job$input_kind <- "pdf"
    }

    # 1. bibr JSON: convert the PDF (or .docx), or use the uploaded JSON
    converter <- NULL
    if (job$input_kind == "pdf") {
      .set_status(job_dir, step = if (ext == ".docx") "converting the Word file with bibr" else "converting the PDF with bibr")
      # bibr uses Crossref only when asked (it sends the reference list there)
      # writes <job_dir>/input.json, with the upload's own name in it (the
      # upload is saved as input.pdf; job$name is its name without extension);
      # GROBID when bibr fails (.convert_paper())
      conv <- .convert_paper(input, job_dir, ext, crossref = isTRUE(job$crossref),
                             file_name = if (nzchar(job$name %||% "")) paste0(job$name, ext) else NULL)
      json <- conv$json
      converter <- conv$converter
      .set_status(job_dir, converter = converter)
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
    if (isTRUE(job$run_code)) {
      full <- .run_paper_code(paper, modules, job_dir)
      modules <- character(0)          # all ran in the chain above
    }
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
      html <- if (identical(job$report_type, "checklist")) render_checklist_html(full, paper)
              else render_report_html(full, paper)
      if (job$kind == "report" && !nzchar(html)) stop("The report could not be rendered.")
      html <- .add_converter_note(html, converter)
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
        # "bibr" or "grobid" for a PDF; null for an uploaded bibr JSON
        converter = converter,
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
