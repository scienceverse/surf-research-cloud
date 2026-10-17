# Managed by the metacheck SURF Research Cloud component.
# Installs the metacheck R package from GitHub. CRAN dependencies were installed
# as Ubuntu binary packages (r2u) by the playbook, so only metacheck itself is
# built here. Usage: Rscript install-metacheck.R <owner/repo> <git ref>
# Reinstalls only when the commit on GitHub differs from the installed one.
args <- commandArgs(trailingOnly = TRUE)
repo <- if (length(args) >= 1) args[[1]] else "scienceverse/metacheck"
ref <- if (length(args) >= 2) args[[2]] else "main"

options(timeout = 600)
remotes::install_github(
  paste0(repo, "@", ref),
  dependencies = FALSE,   # all Imports came from r2u; keep the build deterministic
  upgrade = "never",
  build_vignettes = FALSE,
  quiet = FALSE
)

# Fail the playbook task if the package does not load.
if (!requireNamespace("metacheck", quietly = TRUE)) {
  stop("metacheck did not install")
}
desc <- utils::packageDescription("metacheck")
cat("metacheck", desc$Version, "from", desc$RemoteUsername %||% "?", "/",
    desc$RemoteRepo %||% "?", "at", substr(desc$RemoteSha %||% "?", 1, 10), "\n")
