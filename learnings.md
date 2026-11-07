# Learnings: the reproducibility check stopped running code on the server (November 2026)

From 2 to 7 November 2026 the server ran no code at all in the reproducibility
check. Six jobs were refused by the guard (`journalctl -t metacheck-sandbox`). The
reports said that scripts could not run, but not that the guard had refused them.
At the same time, the full metacheck test suite failed 15 tests on GitHub's
Linux machine. This file records what caused both, what was changed, and what to
do differently.

## What happened

1. metacheck changed how it starts Docker containers (#568, #575): `--ulimit`,
   `/tmp:exec`, the package library as a Docker volume, writable package folders,
   environment variables, a working folder below `/sandbox`, and a new form of
   the Python install script.
2. The guard (`files/metacheck/metacheck-sandbox`) refuses every option it does
   not know. The server installs metacheck from `dev` by itself every 15 minutes
   (`metacheck-auto-update`). So the new metacheck reached the server on
   2 November, and from then on every code run was refused.
3. Separately, the containers always ran as user 1000. On Linux only a folder's
   owner may write in it, and R runs as another user on GitHub (1001) and on the
   server (`shiny`, 499999). Installs stopped with `Permission denied`.
4. The full test suite runs on GitHub only after a push to `main`, so these
   failures were found only after the code was there.

## Learnings

### Merging into metacheck's `dev` installs it on the server

The server follows `dev` (`metacheck_ref: "dev"`) and installs a new commit
within 15 minutes. A merge into `dev` is therefore a release to the server. The
guard and the worker live in this repository, and change separately. A change
in metacheck that the guard does not know stops the server's code runs, without
an error anyone sees.

**Do:** before a change to metacheck's Docker code is merged into `dev`, run
`tests/guard/run.sh /path/to/metacheck` (from this repository). It captures the
commands that metacheck version sends and sends them through the guard. Against
the guard of 6 November it gave exactly the refusals in the server's log.

### Docker Desktop hides Linux's folder permissions

On Windows and macOS, Docker Desktop lets a container write in every shared
folder. On Linux, a container's user (1000 in metacheck's images) may write only
in folders it owns or that are open to everyone. Tests on Windows passed, and
the same code failed on GitHub and on the server.

**Do:** test Docker code on Linux, with R running as a user other than 1000
(GitHub's machine is user 1001; metacheck's `full-tests.yaml` stops if it is
1000). metacheck now runs the containers as the user running R on Linux
(`.repro_docker_uid()`). The server's guard requires 1000:1000 with user
remapping, so `api/worker.R` sets `metacheck.docker_user = "1000:1000"` and
`Sys.umask("000")`.

### A failure can look like success

R's `download.file()` into a folder it may not write in gives only a warning
("cannot open destfile ... Permission denied"), so the script ended normally and
counted as `ran_ok`. The download-limit tests therefore failed for the wrong
reason, and on the server a refused run looked like a script failure.

**Do:** when a test fails in a surprising way, reproduce it in the same setting
(here: a folder owned by another user, in a Linux container) before reading the
code for a cause.

### The tests must run before code reaches `main`

R CMD check does not run metacheck's tests (they are not in the build,
`.Rbuildignore`), and the coverage run with every test ran only on `main`.

**Do:** metacheck's `full-tests.yaml` now runs every test, with Docker and
Python, on every push to `dev` and every pull request into it. It installs
metacheck from the branch, because the parallel workers (`callr`) and the
rendered reports (`library(metacheck)` in the report template) load the
installed package, not the source the tests load. R CMD check also fails on a
note now, builds the PDF manual with HTML Tidy, runs with only the required
packages, and checks every web address.

### New versions of tools change what code means

GitHub's machine has Python 3.14, which reads Python 2's `except E, e:` as two
exception types (PEP 758), so Python 2 code was no longer recognised. metacheck
now also parses with the grammar of 3.13.

### Tests that depend on the computer's speed fail elsewhere

A test that left a script "one second" passed on a slow Windows computer and
failed on GitHub's faster machine. **Do:** build such tests so the outcome does
not depend on speed (here: a slow script uses up the time, whatever the
machine).

### The playbook did not keep its parameters

`metacheck.yml` received all its settings at every run and remembered only the
data repositories' keys and the Discord webhook. The settings files of the
earlier runs (`/root/metacheck-vars.json`) were deleted after use, so no record
existed. A run without them would have turned off the local GROBID and
LibreOffice, the model on the processors, SPIKE-1 and public access.

**Do:** the playbook now keeps every parameter it is given in
`/etc/metacheck-settings.json` (root only), and a run without parameters leaves
the workspace as it is. The file was filled once from the server's own settings
on 7 November 2026. PsyArXiv reports were not kept at 10, so the default of 0
(switched off in commit `fc1db9a`) applies.

### Ansible's check mode does not show what this playbook will do

`--check` skips the commands the playbook uses to look things up (the large
disk, the GPU, the local GROBID), so its decisions differed from a real run
("Large disk: none", "No model"), and it stopped at a step that needs the output
of an install. **Do:** compare the summary of a real run with the summary of the
previous run (`~/playbook.log`).

### Read before concluding

- A symbolic link always shows mode `0777`. `/usr/lib/R/etc/Rprofile.site` looked
  writable for everyone, but it is a link to `/etc/R/Rprofile.site`, which is
  `0644`.
- A web-address check that times out on a large file (the Retraction Watch
  database) does not mean the address is wrong: it had sent 68 MB.
- `exists("cov")` in the coverage workflow found R's own `stats::cov`, so the
  error message after a failed test was about coverage, not about the tests.

## Before a metacheck change reaches the server

1. The full tests pass on GitHub (`full-tests.yaml`).
2. `tests/guard/run.sh /path/to/metacheck` passes, with every command of the
   new version let through.
3. If the guard or the worker had to change: install them on the server first
   (a playbook run, or by hand as on 7 November), then merge metacheck into
   `dev`.
4. After the server installed it, send one small repository with R and Python
   code to `http://127.0.0.1:2005/jobs` (`kind=repocheck`) on the server, and
   check that `journalctl -t metacheck-sandbox` shows no `refused`.
