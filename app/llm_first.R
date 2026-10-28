## llm_first.R -----------------------------------------------------------------
## Models tried before this server's own model (metacheck_llm_first_*), such
## as TU/e's SPIKE-1 through the relay on TU/e's Shiny server. When the power
## check is about to run, the server in METACHECK_LLM_FIRST_URL is asked for
## its models (/models), and the first model of METACHECK_LLM_FIRST_MODELS
## that it lists as "running" is used. The status must be exactly "running":
## SPIKE-1 also lists a model that is still loading as running (running = true,
## status "initializing (loading onto GPU)"), and that model does not answer
## yet. A server that gives no status counts every model it lists as running.
## When none is running, this server's own model is used, and the first
## model is sent a one-word question without waiting for the answer, which
## makes SPIKE-1 load it for the next paper. When the check fails on the first
## server (paragraphs it could not check, or the whole check), it runs again
## on this server's own model.
## Every power check writes one line to METACHECK_LLM_FIRST_LOG (time, app or
## web interface, the model, the reason), from which the server watch
## (watch.R) posts a daily summary to Discord. Nothing about the paper is in it.
## Used by the paper report app (app.R) and the web interface (worker.R), after
## they set up this server's own model, which stays the fallback.

LLM_FIRST_URL <- sub("/+$", "", Sys.getenv("METACHECK_LLM_FIRST_URL"))
LLM_FIRST_MODELS <- trimws(strsplit(Sys.getenv("METACHECK_LLM_FIRST_MODELS"), ",")[[1]])
LLM_FIRST_MODELS <- LLM_FIRST_MODELS[nzchar(LLM_FIRST_MODELS)]
LLM_FIRST_NAME <- Sys.getenv("METACHECK_LLM_FIRST_NAME", "another server")
# a request to the first server may take this long; SPIKE-1 itself ends
# requests after about 30 s, and ellmer otherwise waits 5 minutes, 3 times
LLM_FIRST_TIMEOUT <- 60

.llm_first <- new.env()

# TRUE when models to try first are set up.
llm_first_set <- function() nzchar(LLM_FIRST_URL) && length(LLM_FIRST_MODELS) > 0

# The first model of LLM_FIRST_MODELS that the first server lists as running,
# or NULL; reason says why (for the log).
.llm_first_pick <- function() {
  key <- Sys.getenv("METACHECK_LLM_FIRST_KEY")
  # up to 30 s: the relay answers one request at a time, so this may wait for
  # another paper's question (SPIKE-1 ends those after about 30 s)
  req <- httr2::request(paste0(LLM_FIRST_URL, "/models")) |> httr2::req_timeout(30)
  if (nzchar(key)) req <- httr2::req_headers(req, Authorization = paste("Bearer", key))
  listed <- tryCatch(httr2::req_perform(req) |> httr2::resp_body_json(),
                     error = function(e) e)
  if (inherits(listed, "error")) {
    return(list(model = NULL, reason = "no answer"))
  }
  ids <- vapply(listed$data, function(m) m$id %||% "", character(1))
  usable <- vapply(listed$data, function(m) !isFALSE(m$accessible), logical(1))
  running <- vapply(listed$data, function(m) is.null(m$status_label) ||
                      identical(m$status_label, "running"), logical(1))
  wanted <- LLM_FIRST_MODELS[LLM_FIRST_MODELS %in% ids[usable]]
  for (m in wanted) {
    if (any(running[ids == m])) return(list(model = m, reason = "running"))
  }
  if (!length(wanted)) return(list(model = NULL, reason = "none of the models listed"))
  .llm_first_wake(wanted[1], key)
  list(model = NULL, reason = paste("no model running; woke", wanted[1]))
}

# A one-word question to the model, from a process of its own that outlives
# this one, so nobody waits for it: SPIKE-1 answers a model that is not loaded
# with an error after about 45 s, but starts loading it. The relay answers
# one request at a time, so "X-Relay-Wait: no" asks it to send the question
# on by itself and answer at once (other servers ignore the header). The key
# goes to curl through its standard input (-K -), written by the shell's own
# printf, not on a command line, which other users of this server can see.
.llm_first_wake <- function(model, key) {
  if (!nzchar(Sys.which("curl"))) return(invisible())
  body <- jsonlite::toJSON(list(model = model, max_tokens = 1,
                                messages = list(list(role = "user", content = "hi"))),
                           auto_unbox = TRUE)
  tryCatch(processx::process$new(
    "sh", c("-c", paste(
      'printf \'header = "Authorization: Bearer %s"\\n\' "$LLM_FIRST_KEY" |',
      'curl -s -K - -o /dev/null -m 120 -H "Content-Type: application/json"',
      '-H "X-Relay-Wait: no" -d "$LLM_FIRST_BODY" "$LLM_FIRST_URL/chat/completions"')),
    env = c("current", LLM_FIRST_KEY = key, LLM_FIRST_BODY = body, LLM_FIRST_URL = LLM_FIRST_URL),
    stdout = NULL, stderr = NULL, cleanup = FALSE),
    error = function(e) NULL)
  invisible()
}

# The model settings now in use, to go back to.
.llm_first_save <- function() {
  list(base_url = getOption("metacheck.llm.vllm.base_url"),
       key = Sys.getenv("VLLM_API_KEY"),
       model = metacheck::llm_model(),
       max_tokens = getOption("metacheck.llm_max_tokens"),
       timeout = getOption("ellmer_timeout_s"),
       tries = getOption("ellmer_max_tries"))
}

.llm_first_use <- function(model) {
  options(metacheck.llm.vllm.base_url = LLM_FIRST_URL,
          metacheck.llm_max_tokens = NULL,        # metacheck's default
          ellmer_timeout_s = LLM_FIRST_TIMEOUT, ellmer_max_tries = 2)
  Sys.setenv(VLLM_API_KEY = Sys.getenv("METACHECK_LLM_FIRST_KEY"))
  metacheck::llm_model(paste0("vllm/", model))
}

.llm_first_restore <- function(s) {
  options(metacheck.llm.vllm.base_url = s$base_url, metacheck.llm_max_tokens = s$max_tokens,
          ellmer_timeout_s = s$timeout, ellmer_max_tries = s$tries)
  Sys.setenv(VLLM_API_KEY = s$key)
  metacheck::llm_model(s$model)
}

# TRUE when the power check could not check every paragraph with the model,
# or failed as a whole (metacheck's inst/modules/power.R).
.llm_first_failed <- function(res) {
  if (!inherits(res, "metacheck_module_output")) return(TRUE)
  unchecked <- res$summary_table$power_unchecked
  any(unchecked > 0, na.rm = TRUE) ||
    any(grepl("LLM check for power analyses failed to run", res$summary_text, fixed = TRUE))
}

.llm_first_log <- function(model, reason) {
  path <- Sys.getenv("METACHECK_LLM_FIRST_LOG")
  if (!nzchar(path)) return(invisible())
  line <- paste(format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"), .llm_first$where, model, reason, sep = "\t")
  tryCatch(cat(line, "\n", file = path, sep = "", append = TRUE), error = function(e) NULL)
  invisible()
}

# One power check: on the first server's model when one is running, and again
# on this server's model when that fails. The choice is made once per process
# (one paper), at the first power check.
.llm_first_run <- function(run, paper, module, ...) {
  if (is.null(.llm_first$pick)) .llm_first$pick <- .llm_first_pick()
  model <- .llm_first$pick$model
  if (is.null(model)) {
    .llm_first_log("local", .llm_first$pick$reason)
    return(run(paper, module, ...))
  }
  .llm_first_use(model)
  res <- tryCatch(run(paper, module, ...), error = function(e) e)
  .llm_first_restore(.llm_first$local)
  if (!inherits(res, "error") && !.llm_first_failed(res)) {
    .llm_first_log(model, "running")
    return(res)
  }
  # the rest of this paper's checks stay on this server's model
  .llm_first$pick <- list(model = NULL, reason = paste("after", model, "failed"))
  .llm_first_log("local", paste("again after", model, "failed"))
  run(paper, module, ...)
}

# Call after this server's own model is set up (llm_model() and its address);
# where: "app" or "web", for the log. Wraps metacheck's module_run(), which
# runs every check, also the ones that metacheck's report() and other modules
# run, so the power check goes through .llm_first_run() wherever it is run
# from. Does nothing when no first models are set up, or when called again.
llm_first_wrap <- function(where) {
  if (!llm_first_set() || isTRUE(.llm_first$wrapped)) return(invisible())
  .llm_first$where <- where
  .llm_first$local <- .llm_first_save()
  # as in llm_modules.R: the namespace's copy, which metacheck's own calls
  # use, and the attached package's copy, which a plain module_run() call uses
  places <- list(asNamespace("metacheck"))
  if ("package:metacheck" %in% search()) places <- c(places, list(as.environment("package:metacheck")))
  for (where_env in places) {
    run <- get("module_run", envir = where_env)
    # the same arguments as module_run(), so that the trace of llm_modules.R,
    # which reads `module`, also works when it is set after this
    wrapped <- local({
      run <- run
      function(paper, module, ...) {
        if (isTRUE(module %in% LLM_MODULES)) .llm_first_run(run, paper, module, ...)
        else run(paper, module, ...)
      }
    })
    locked <- bindingIsLocked("module_run", where_env)
    if (locked) unlockBinding("module_run", where_env)
    assign("module_run", wrapped, envir = where_env)
    if (locked) lockBinding("module_run", where_env)
  }
  .llm_first$wrapped <- TRUE
  invisible()
}
