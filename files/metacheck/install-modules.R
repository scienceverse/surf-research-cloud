# Managed by the metacheck SURF Research Cloud component.
# Installs metacheck modules from GitHub (metacheck::module_install()) into
# METACHECK_MODULES_DIR, where the paper report app and the web interface find
# them, or updates an installed one to the newest commit of its branch.
# Usage: Rscript install-modules.R <owner/repo> [<owner/repo> ...]
# A module that cannot be installed (for example because it needs a newer
# metacheck) is reported, and does not stop the others or the playbook.
repos <- commandArgs(trailingOnly = TRUE)
if (!nzchar(Sys.getenv("METACHECK_MODULES_DIR"))) stop("METACHECK_MODULES_DIR is not set")
installed <- metacheck::module_installed()
for (r in repos) {
  done <- tryCatch({
    if (tolower(r) %in% tolower(installed$repo)) metacheck::module_update(r) else metacheck::module_install(r)
    TRUE
  }, error = function(e) {
    message("NOT INSTALLED: ", r, ": ", conditionMessage(e))
    FALSE
  })
}
now <- metacheck::module_installed()
cat("installed modules:", if (nrow(now)) paste(sprintf("%s (%s, %s)", now$repo, now$modules, substr(now$sha, 1, 7)), collapse = "; ") else "none", "\n")
