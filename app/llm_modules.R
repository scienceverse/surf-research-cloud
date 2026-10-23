## llm_modules.R ---------------------------------------------------------------
## Which metacheck checks may use the language model on this server: only the
## power check, for now (LLM_MODULES). metacheck has one switch for all checks
## (llm_use()), so this sets it at the start of every check (a trace on
## metacheck's module_run(), which runs every check, also the ones a module
## such as tue_datamanager_check runs itself): on for the checks listed here
## when the model is available, off for all others, which then work by rules
## only. Used by the paper report app (app.R) and the web interface (worker.R).

LLM_MODULES <- c("power")

# enabled: whether a model is available and wanted for this job at all.
llm_only_for_listed_modules <- function(enabled) {
  hook <- bquote(metacheck::llm_use(.(isTRUE(enabled)) && isTRUE(module %in% .(LLM_MODULES))))
  # metacheck's own calls (report(), report_module_run(), modules running
  # other modules) use the namespace's module_run(); a plain module_run() call
  # after library(metacheck) uses the attached package's copy, so both get it.
  places <- list(asNamespace("metacheck"))
  if ("package:metacheck" %in% search()) places <- c(places, list(as.environment("package:metacheck")))
  for (where in places) {
    suppressMessages(trace("module_run", tracer = hook, where = where, print = FALSE))
  }
  metacheck::llm_use(FALSE)
  invisible()
}
