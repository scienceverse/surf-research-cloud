# Captures the docker commands metacheck sends with the SURF worker's settings,
# through the stand-in docker in /out/bin. Writes /out/calls.jsonl, the install
# scripts, and /out/paths.json (the host folders, to map onto a job folder).
imports <- trimws(sub("\\(.*", "", strsplit(read.dcf("/pkg/DESCRIPTION", "Imports")[1, 1], ",")[[1]]))
need <- imports[!vapply(imports, requireNamespace, logical(1), quietly = TRUE)]
if (length(need)) {
  lib <- "/out/rlib-capture"; dir.create(lib, showWarnings = FALSE); .libPaths(c(lib, .libPaths()))
  install.packages(need, lib = lib, quiet = TRUE,
                   repos = "https://packagemanager.posit.co/cran/__linux__/noble/latest")
}
suppressMessages(pkgload::load_all("/pkg", quiet = TRUE, helpers = FALSE))
# The worker's own settings (api/worker.R's .sandbox_options()), not a copy of
# them, and every function of the worker that runs code must set them: one
# that did not made every container of the PsyArXiv reports be refused.
worker <- parse("/out/worker.R", keep.source = TRUE)
w <- new.env()
for (e in worker) {
  if (!is.call(e) || !identical(e[[1]], as.name("<-")) || !is.name(e[[2]])) next
  name <- as.character(e[[2]])
  if (name %in% c(".sandbox_limits", ".sandbox_options")) eval(e, w)
  body <- paste(deparse(e[[3]]), collapse = "\n")
  if (grepl(".code_sandbox()", body, fixed = TRUE) && !grepl(".sandbox_options()", body, fixed = TRUE))
    stop("api/worker.R: ", name, "() runs code without .sandbox_options()")
}
w$.sandbox_options()
Sys.setenv(PATH = paste("/out/bin", Sys.getenv("PATH"), sep = ":"))
unlink("/out/calls.jsonl")

root <- file.path(tempdir(), "sandbox")
sub <- file.path(root, "Analysis (final)")
dir.create(sub, recursive = TRUE)
writeLines("x <- 1", file.path(root, "a.R"))
writeLines("print(1)", file.path(sub, "b.R"))
writeLines("print(1)", file.path(root, "c.py"))
writeLines("print(2)", file.path(sub, "d.py"))
rlib <- file.path(tempdir(), "rlib"); dir.create(rlib)
pylib <- file.path(tempdir(), "pylib"); dir.create(pylib)
img_r <- "ghcr.io/scienceverse/metacheck_r_large:latest"
img_py <- "ghcr.io/scienceverse/metacheck_py_small:latest"

deps <- data.frame(package = c("R6", "dplyr"), source = "cran", ref = NA_character_,
                   version = NA_character_)
invisible(suppressWarnings(suppressMessages(
  repro_install_deps_docker(deps, rlib, image = img_r, timeout = 20))))
pydeps <- data.frame(package = c("six", "numpy"), source = "pypi", ref = c(NA, "numpy==1.26.4"))
invisible(suppressWarnings(suppressMessages(
  repro_install_deps_py_docker(pydeps, pylib, image = img_py, timeout = 20))))
file.copy("/out/install.sh", "/out/install_py3.sh", overwrite = TRUE)

run_r <- data.frame(file_name = c("a.R", "b.R"),
                    script_path = c(file.path(root, "a.R"), file.path(sub, "b.R")),
                    run_dir = c(root, sub))
invisible(suppressWarnings(suppressMessages(
  repro_run_scripts_docker(run_r, run_r$file_name, root, lib_dir = rlib, image = img_r, timeout = 20))))
run_py <- data.frame(file_name = c("c.py", "d.py"),
                     script_path = c(file.path(root, "c.py"), file.path(sub, "d.py")),
                     run_dir = c(root, sub), module_folders = c(".", "Analysis (final)"))
invisible(suppressWarnings(suppressMessages(
  repro_run_scripts_py_docker(run_py, run_py$file_name, root, lib_dir = pylib, image = img_py, timeout = 20))))

# Python 2: its packages in _pylib2, as the module keeps them, in its own image
py2lib <- file.path(root, "_pylib2"); dir.create(py2lib)
writeLines('print "half", 5/2', file.path(root, "old.py"))
img_py2 <- "python:2.7-slim"
invisible(suppressWarnings(suppressMessages(
  repro_install_deps_py_docker(data.frame(package = "six", source = "pypi", ref = NA_character_),
                               py2lib, image = img_py2, timeout = 20))))
file.copy("/out/install.sh", "/out/install_py2.sh", overwrite = TRUE)
run_py2 <- data.frame(file_name = "old.py", script_path = file.path(root, "old.py"),
                      run_dir = root, module_folders = ".")
invisible(suppressWarnings(suppressMessages(
  repro_run_scripts_py_docker(run_py2, "old.py", root, lib_dir = py2lib, image = img_py2, timeout = 20))))

jsonlite::write_json(list(tmp = normalizePath(tempdir())), "/out/paths.json", auto_unbox = TRUE)
cat(length(readLines("/out/calls.jsonl")), "calls recorded\n")
