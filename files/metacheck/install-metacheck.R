# Managed by the metacheck SURF Research Cloud component.
# Installs the metacheck R package from GitHub. CRAN dependencies were installed
# as Ubuntu binary packages (r2u) by the playbook, so only metacheck itself is
# built here. Usage: Rscript install-metacheck.R <owner/repo> <git ref>
# Reinstalls only when the commit on GitHub differs from the installed one.
#
# Through git, not GitHub's API: install_github() asks the API, which allows
# 60 requests an hour without a token and on 8 November 2026 answered with
# HTTP 504 pages for hours ("JSON: EXPECTED value GOT <"), so no update could
# install; git itself still answered. install_git() records the commit
# (RemoteSha), which metacheck-auto-update compares with GitHub's.
args <- commandArgs(trailingOnly = TRUE)
repo <- if (length(args) >= 1) args[[1]] else "scienceverse/metacheck"
ref <- if (length(args) >= 2) args[[2]] else "main"

options(timeout = 600)
remotes::install_git(
  sprintf("https://github.com/%s.git", repo),
  ref = ref,
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
cat("metacheck", desc$Version, "from", desc$RemoteUrl %||% repo, "at",
    substr(desc$RemoteSha %||% "?", 1, 10), "\n")
