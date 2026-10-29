# bibr and metacheck on SURF Research Cloud

Two [SURF Research Cloud](https://www.surf.nl/en/services/surf-research-cloud) (SRC)
components for checking scientific papers without sending them to outside services:

- **`bibr.yml`, the bibr component**: [bibr](https://github.com/scienceverse/bibr)
  (`bibr serve`, the GLM-OCR model server and Redis, in Docker) turns a PDF into
  structured JSON on the workspace's GPU, with a small local language model
  (Ollama) for the title, author and metadata step. It offers bibr's API to the
  workspace and to other workspaces on the same SRC private network.
- **`metacheck.yml`, the metacheck component**: R, Quarto, Shiny Server and
  [metacheck](https://github.com/scienceverse/metacheck) (`dev` branch), with this
  repository's edition of metacheck's paper report app (`app/`). It converts PDFs
  with a bibr server (on the same workspace or on the private network), or with the
  GROBID servers the app lists. With a GPU it runs its own local model for the
  app's LLM power check.

The single-workspace version that came before this split is kept as the tag
[`v0.1-single-workspace`](https://github.com/scienceverse/surf-research-cloud/tree/v0.1-single-workspace).

## Catalog items

A catalog item is a list of components. The two components make three:

| Catalog item | Components, in this order | Flavour | Use |
|---|---|---|---|
| bibr server | `SRC-OS`, `SRC-CO`, `SRC-Nginx`, `SRC-External plugin`, `bibr` | A10 (GPU required) | PDF extraction for the collaboration, through its API |
| metacheck server | `SRC-OS`, `SRC-CO`, `SRC-Nginx`, `SRC-External plugin`, `metacheck` | A10 for a local model; any flavour without | the paper report app |
| metacheck + bibr | `SRC-OS`, `SRC-CO`, `SRC-Nginx`, `SRC-External plugin`, `bibr`, `metacheck` | A10 (one or two GPUs) | everything on one workspace |

`bibr` must come before `metacheck` when both are on one workspace: metacheck
then finds the local bibr and its token by itself, and both use the same Ollama.

All use `Ubuntu 2204 with CUDA` (or `Ubuntu 2204` for a metacheck server without
GPU). Ubuntu 24.04 is not supported because SRC's `SRC-External` component, which
every non-SURF component needs, is not available for it.

Further settings of each catalog item:

| Wizard step | Setting | Value | Why |
|---|---|---|---|
| 1, components | SRC-External | `SRC-External plugin` (not the Docker or ansible2.11 variants) | runs Ansible playbooks with Ansible 11.1, as tested |
| 1, components | CUDA | `CUDA`, after SRC-External plugin and before bibr/metacheck | installs the NVIDIA driver and CUDA; the operating system choice "Ubuntu 22.04" has none |
| 5, cloud provider | operating system / flavours | `Ubuntu 22.04` / `A10 - 1 GPU`, `A10 - 2 GPU` | RTX2080 has too little GPU memory |
| 6, parameters | `co_passwordless_sudo` (SRC-CO) | `true` | without it, sudo on the workspace asks for a password nobody has |
| 7, workspace settings | boot disk size | 100 GB | with the default 20 GB the CUDA component alone filled the disk to 98% |
| 7, workspace settings | access button | `Webinterface (https:)` | |

Do not open extra ports.

## A bibr server and a metacheck server on a private network

On an SRC private network every port a program listens on is reachable from the
other workspaces on that network (addresses `10.10.10.x`), and nothing else is.
That is how the metacheck server reaches bibr. A workspace can only join a
private network when it is created.

1. In the SRC portal, create a private network for the collaboration (provider
   SURF HPC Cloud). Wait until it is "available".
2. Create the **bibr server** workspace and select that network in the
   workspace's options. Attach a storage volume of at least 150 GB.
3. When the bibr component has run, its install log (and the summary at the end)
   shows the address for metacheck workspaces, for example
   `http://10.10.10.12:8000`. The token is in `/etc/bibr/api_key` on that
   workspace (`sudo cat /etc/bibr/api_key`). Alternatively, set `bibr_api_key` to a
   token of your own (32 or more characters) when creating the bibr workspace, so
   it is known in advance.
4. Create the **metacheck server** workspace on the same network, with
   `metacheck_bibr_url` set to that address and `metacheck_bibr_api_key` to the
   token.

The first start of a bibr server builds its Docker images in the background (20
to 40 minutes; progress at `/bibr-status`). Until bibr answers, the app shows a
warning when its bibr option is selected.

Note: a parameter value is visible in plain text in the workspace's "Logs" tab
in the SRC portal when a component fails (SRC's own hiding of values missed the
token). Anyone in the collaboration who can read workspace logs can then see
bibr's token.

A storage volume can be reused by a later workspace: Docker images and model
files on it are reused, and their ownership is corrected for the new workspace.

## A public bibr

A bibr workspace can also be opened to anyone, without the SRAM login, so people
can convert papers and get bibr's JSON back. It is the same bibr: metacheck
workspaces on the private network keep using it as before.

On the bibr workspace (or with `bibr_public = true` when it is created):

```
sudo bibr-public on       # open:   https://<workspace>/docs and /papers/extract
sudo bibr-public off      # closed: SRAM login only (/bibr/docs)
bibr-public status
```

While open:

- **In a browser:** `https://<workspace>/docs` (bibr's API page): open
  `POST /papers/extract`, "Try it out", choose a PDF, "Execute"; the JSON appears
  below and can be downloaded.
- **From a script:** `curl -F file=@paper.pdf https://<workspace>/papers/extract > paper.json`,
  or the job routes (`/papers/jobs`) for long papers.
- nginx adds bibr's token to every request; visitors need none and never see it
  (the nginx file holding it is readable by root only).
- At most 6 uploads per minute per visitor (burst 10), answered with HTTP 429
  beyond that; bibr itself refuses files over 50 MB and work beyond its queue.
- The progress page and `/bibr/` stay behind the SRAM login.

Before opening it: check SURF Research Cloud's acceptable use policy, and who is
responsible for what visitors upload. Public use slows down the metacheck app that
uses the same bibr; a separate public bibr workspace avoids that. Reference
lookups at Crossref are made with `bibr_crossref_email` as contact address.

## The website

The workspace address (`https://<workspace>/`) shows a small website (`site/`): one
page, in three columns, for the three things the web interface below does:

1. **Run Metacheck on a Paper**: a PDF (or bibr JSON) in, Metacheck's report out,
   with the default checks ticked and the others (which contact other services) to
   choose.
2. **Run Metacheck on a Repository**: a folder, chosen or dropped onto the page, a .zip,
   or a link to an online repository (GitHub, OSF, Zenodo, Dataverse, Dryad, ...). The
   browser packs a folder into a .zip ([JSZip](https://stuk.github.io/jszip/),
   served from the workspace) and leaves out `.git`, `.svn` and `.hg` folders; it
   refuses a folder over 1000 MB or 20,000 files, and a .zip over 500 MB, before
   uploading.
3. **Convert a Paper with bibr**: a PDF in, bibr's JSON out.

Columns 1 and 2 ask for metacheck's checklist report (`report_type=checklist`):
every check sorted by its result, to fix, to improve, and so on, and for a repository
also its file tree, under "Files in the repository" (metacheck 0.4.1.9 and later;
earlier versions leave the tree out). Scripts that call the web interface without
`report_type` still get the full report of a paper and the brief report of a
repository.

Columns 1 and 3 have an unticked box "Look up the references at Crossref". Only when
it is ticked does bibr complete the reference list through Crossref, which sends the
paper's reference list to Crossref; with the default settings nothing leaves the
workspace. (The checks that can be ticked in column 1, such as Reference Accuracy
and PubPeer Comments, contact their own services.)

While a job runs the page shows the upload, the place in the queue and each step;
the report then opens in a new tab or can be downloaded. For a paper, each check is
shown with its number ("Power Analysis Check (step 1 of 7)") and the bar moves on
after each; the power check also counts its questions to the language model, one
per paragraph that may describe a power analysis ("Extracting data (...) 1/2"),
since on a workspace without a GPU each takes a while. The other checks take about
a second each, so the page, which asks every 2 seconds, mostly skips them. The page is static files
served by nginx (`location /site/`; the root is passed to it by `00-root.conf`) and
needs nothing on the server beyond the web interface. The font is
[Cabin](https://github.com/impallari/Cabin), a humanist sans serif (SIL Open Font
License, `site/fonts/OFL-Cabin.txt`), also served from the workspace, so visitors'
browsers contact no other site. The colours are
metacheck's logo green and a light grey.

Tested in Edge (Playwright): a PDF report, a conversion and a folder check at the
same time, a chosen .zip, a wrong file, the list of checks, and the layout at 375,
500 and 1400 pixels wide. Not tested: dropping a folder onto the page (the
browser's drag and drop cannot be scripted with real folders).

Before packing a folder, the page tries every file, because the browser lists some
files it cannot read: on Windows, files whose full path is longer than 260
characters (the browser lists them as empty, or leaves them out without a word),
files OneDrive keeps online only, and files opened or moved since. Packing used to
stop on the first one with the browser's message "A requested file or directory
could not be found at the time an operation was processed."; the page now names the
files and says what to do (move the folder to a short path, keep it on the device,
or pack it with 7-Zip). Tested in Edge on cached repositories with long paths
(20 October 2026).

### Check pages

Three more pages, each at a short address (rewritten by `00-root.conf` to
`site/<page>/`, so they follow the same login/public setting as the website), and
linked from it under "More checks". They were apps on the TU/e Shiny server before;
here they use this workspace's web interface.

| Address | Page | What it sends | Report |
|---|---|---|---|
| `/psyarxiv/` | `site/psyarxiv/` | `kind=report`, `psyarxiv=<id>`, `report_type=checklist`, every module in `GET /modules` `allowed`; optional `crossref`, `run_code` | metacheck's checklist report on the paper, after the page's own checks of the PsyArXiv record (open data reachable, preregistration, license, conflict of interest, ORCID iDs), read in the browser from PsyArXiv's API |
| `/researchbox/` | `site/researchbox/` | `kind=repocheck`, `url=https://researchbox.org/<n>`, `report_type=checklist`, `run_code` | metacheck's checklist report on the box's data and code |
| `/datamanager/` | `site/datamanager/` | as on the TU/e server: `kind=repocheck`, `modules=tue_datamanager_check` | the TU/e module's own checklist report |

`site/datamanager/` is a copy of `web/` in
[Lakens/tue_datamanager_check](https://github.com/Lakens/tue_datamanager_check)
(main, 22 October 2026) with `www/config.js` pointing at this server
(`location.origin + "/api"`); copy it again when the page changes there. The PsyArXiv
and ResearchBox pages share `site/check-link.js` (send, follow, offer the report;
a 502/503 while the server restarts for an update is tried again) and
`site/check-pages.css`. A page address with `?api=<address>` uses another server,
for testing. Tested in Edge (22 October 2026): link parsing, the PsyArXiv record and
its checks, an unknown id, and the layout.

### PsyArXiv reports (prototype)

Every hour, `metacheck-psyarxiv-reports.timer` runs `api/psyarxiv-reports-generate.R`
as the shiny user: for each of the `metacheck_psyarxiv_reports` (default 10) newest
PsyArXiv preprints without a report for its current version, it asks this server's
web interface for metacheck's checklist report (`kind=report`, `psyarxiv=<id>`,
`report_type=checklist`, every allowed module, `run_code=true` so the code of the
paper's repository runs in the sandbox with `reproducibility_check`, `crossref=true`:
preprints are public, and the reference checks need the Crossref lookup; set
`bibr_crossref_email` on the bibr server so Crossref answers at its faster rate), one
at a time, and keeps it in
`<storage volume>/psyarxiv-reports/reports/<id>.html` with the preprint's details in
`<id>.json`. `metacheck_psyarxiv_reports: "0"` switches it off.

When the full report fails, for example because a repository is so large that the
repository checks do not finish within the job's hour, a second try leaves out the
repository checks (`repo_check`, `code_check`, `data_check`, `codebook_check`) and
running the code, and the report says so at its top. When that fails too, for
example for a Word file (GROBID reads only PDFs), a page saying the automated check
failed is stored instead of a report, with both reasons, so that version is not
tried again; a new version gets a new attempt. `<id>.json` records which of the
three it was (`outcome`: `full`, `without_repository_checks` or `failed`). Errors
of the server itself (the queue is full, the web interface or GROBID is restarting
or does not answer) leave nothing behind and are tried again at the next run.
Discord gets one message per preprint, saying which of the three it was.
`PSYARXIV_REPORTS_ONLY` (preprint ids, separated by commas) makes the script handle
only those preprints, for testing or to redo one.

- **`/psyarxiv-reports/`** (`site/psyarxiv-reports/`) lists the reports;
  **`/psyarxiv-reports/?id=<id>`** shows one, under a bar with the preprint's title,
  version and date, the metacheck version, and *"If the report contains mistakes,
  let us know."* with two links: **Report a mistake by email** (a mail to
  metacheck.scienceverse@gmail.com) and **Report a mistake on GitHub** (a new issue on
  scienceverse/metacheck), both with the preprint and the report's address filled
  in (`MISTAKE_MAIL` and `MISTAKE_ISSUES` in `site/psyarxiv-reports/reports.js`).
  This is the address PsyArXiv could link to. The report itself is a static file at
  `/psyarxiv-reports-files/<id>.html`.
- Not in use yet (no SMTP account): the web interface can also take a message
  (`POST /api/psyarxiv-reports/<id>/feedback`, at most 5 an hour per visitor), save
  it in `feedback/` and mail it to `metacheck_mail_to` through `metacheck_smtp_url`
  (with `metacheck_smtp_user`/`_password`), with the report attached and a red
  **Delete this report** button. That button opens
  **`/psyarxiv-reports/?delete=<id>&key=<key>`**, which asks for confirmation
  (`POST /api/psyarxiv-reports/<id>/delete`). The key is an HMAC of the id with a
  secret made once on the workspace
  (`/opt/metacheck-component/psyarxiv-reports.secret`), so only links from those
  mails can delete. A deleted report leaves `deleted/<id>.json` and is not made again.
  The page has no form for it now; to use it, set the mail settings and bring back
  the form (git history of `site/psyarxiv-reports/`).
- A preprint whose file is a Word document (`.docx`, about one in four new ones) is
  sent to bibr as it is: bibr reads .docx natively. An old `.doc` (none in a sample of
  200 preprints from 2017 to 2026) is refused.

Tested on 22 October 2026 with a local plumber server and the real helpers,
endpoints and page: list, report view, unknown id, feedback saved, wrong and right
delete keys, delete and its marker, deleting twice, the mail (built and checked,
with the report attached, not sent), and fetching a Word and a PDF preprint. Not
tested: bibr converting a .docx on the workspace, sending mail through a real SMTP
server, and the timer.

## Running a repository's code

The repository check (`/api/repocheck`, column 2 of the website) also runs the
uploaded R and Python code with metacheck's reproducibility check
(`reproducibility_check(execute = TRUE, sandbox = "docker")`), unless the request
says `run_code=false` or the box on the website is unticked. The report then shows,
per script, whether it ran, failed or ran out of time, with its output. Each
script may run 5 minutes, a job 60 minutes. All scripts together must be done 10
minutes before the job's limit (`total_timeout` as a clock time, metacheck 0.4.1.5
and later; `CODE_REPORT_MINUTES` in `api/worker.R`): then a running script is
stopped and the rest are not started, so the report still comes back with what
ran. Packages the images lack are installed
first (`install_missing = TRUE`), in a container of their own: the only container
with the network, running only the guard's own install script, for packages from
CRAN (ready built, from Posit's package manager) and PyPI (wheels only). Packages
from GitHub or other links are not installed. They go into the guard's packages
folder for the job (`/var/lib/metacheck-sandbox-lib`, on the large disk), which the
code then sees read-only; the code itself still runs without the network.

Images (`metacheck_sandbox_images`): `ghcr.io/scienceverse/metacheck_r_large`
(~750 R packages, JAGS, a JDK, the geospatial stack) and
`ghcr.io/scienceverse/metacheck_py_large` (the common data-science stack plus
~70 packages and CPU-only torch and tensorflow). metacheck asks for the small
Python image; the guard (below) serves the large one instead. The playbook
downloads both; when it cannot (they need a GitHub login while they are not
public), it says so and code is not run until they are present, for example built
on the workspace from
[metacheck_docker_reproducibility](https://github.com/scienceverse/metacheck_docker_reproducibility)
under the same names (the large R image takes hours to build).

How the server is protected (`tasks/sandbox.yml`, `files/metacheck/metacheck-sandbox`):

1. **No direct Docker access.** The shiny user, which runs the public website,
   web interface and app, is not in the docker group (that would make it equal to
   root). A job finds a `docker` command that calls `/usr/local/sbin/metacheck-sandbox`
   through one sudo rule. That guard accepts only `docker info`, `docker stop` of
   the job's own containers, and `docker run` exactly as metacheck builds it; it
   refuses every other option, image, mount or command, rebuilds the command from
   the checked parts and logs every decision (`journalctl -t metacheck-sandbox`).
2. **Locked-down containers.** No network (`--network none`; no images are
   downloaded at run time either), a read-only system, all capabilities dropped,
   no new privileges, a non-root user, at most 512 processes, 4 processors and 16 GB
   memory without swap (by default; see "A smaller metacheck workspace"), files
   of at most 10 GB, and a `/tmp` without program
   execution. The only writable mount is the job's own sandbox folder. The one
   exception is the install container (see above): it has the network and may
   write into the job's packages folder, but it runs only the guard's own install
   script, with the names of CRAN and PyPI packages the guard has checked, never a
   file the job wrote.
3. **User remapping.** Docker runs with `userns-remap`: users inside a container,
   root included, are unused numbers on the host, never a host account. AppArmor
   and seccomp profiles are on, containers cannot reach each other.
4. **A separate, size-limited disk.** Each job's sandbox folder lies on its own
   60 GB file system (`/srv/metacheck-sandbox`, a file on the volume mounted as a
   disk), mounted without device files, privilege changes or program execution,
   so code that fills it cannot fill anything else.
5. **Cleanup.** A job's containers are stopped and its sandbox and packages
   folders deleted when the job ends or is stopped; a timer stops any sandbox
   container after 45 minutes and deletes leftover folders.

Not run on a workspace that also runs bibr (bibr's containers need other Docker
settings); `metacheck_run_code = false` switches it off. `GET /api/health` says
whether this server runs code (`run_code`).

## Running a paper's code

Column 1 of the website (and `run_code=true` with `/api/report`, `/api/check` or
`/api/jobs`) can also run the code of the repository a paper links to: the chosen
checks, then `repo_check`, `code_check` and `data_check` on the repositories the
paper links (fetched as for a link: 100 MB per file, 500 MB per repository), and
`reproducibility_check`, which runs the R and Python code in the same sandbox and
compares the statistics it prints with those in the paper. They run as one chain
(`report_module_run()`), so each check gets the results of the ones before it.
Off by default; it can take ten minutes or more, mostly for listing OSF projects.
Tested on two PLOS ONE papers with OSF repositories: their code was fetched and run;
scripts failed on a package missing from the image (`preregr`) and on values the
authors had blanked out.

## Use counts

Every finished job of the web interface (from the website or from code) adds one
line to `api_usage.csv` in `METACHECK_USAGE_DIR` (`/data/<volume>/metacheck-usage`,
or `/var/lib/metacheck-usage` without a volume), with the columns of metacheck's own
app counts plus three: `date, event, reports, modules, status, source, visitor`.
`event` is the tool (`report`, `repocheck`, `convert`, `check`), `source` is
`website` or `code`. No file names, titles or contents are kept.

`visitor` counts unique visitors per day: a 16-character code made from the
visitor's internet address and browser name and a random secret that is replaced
every day (`.daily-secret`, readable by the shiny user only). Within a day the same
visitor gets the same code; once the secret is replaced, a code cannot be traced back
to an address. A visitor who returns on another day counts again, and people sharing
one address and browser on one day count as one. The paper report app writes its own
counts (`shiny_app_usage.csv`, metacheck's `usage_record()`) to the same folder.

```
sudo metacheck-usage           # per month: jobs per tool, succeeded, website/code, visitors
sudo metacheck-usage --daily   # per day
```

## A metacheck workspace without a GPU

The metacheck workspace needs its GPU only for the small model of the LLM power
check. bibr's workspace already has that model loaded, so a metacheck workspace on
the same private network can use it instead and run on a workspace without a GPU,
which halves the GPU-hours of the pair.

- `bibr.yml` (`bibr_share_llm = true`, the default) adds an nginx entrance on the
  bibr workspace's private network address, port 11435
  (`templates/bibr/bibr-llm-share-nginx.conf.j2`). It requires bibr's token and
  passes on only the two OpenAI-compatible requests metacheck makes
  (`/v1/chat/completions`, `/v1/models`); everything else, such as downloading or
  deleting models, gets HTTP 404. Ollama itself still listens only on the
  workspace.
- `metacheck.yml` with `metacheck_llm = ollama` (the default) uses a local model
  when the workspace has a GPU, and otherwise the bibr workspace's model;
  `metacheck_llm = bibr` always uses the bibr workspace's model. `metacheck_llm_model`
  must be the model bibr serves (`qwen3.5:4b`). The playbook checks that the model
  answers.

Tested: with `metacheck_llm = bibr`, the power check of a PLOS ONE paper took 8 s
and gave the same results as the local model; without the token the entrance
answers HTTP 401.

For a workspace without a GPU, use a catalog item like "metacheck server" but
without the CUDA component and with CPU flavours. With the defaults, 8 or more
cores and 32 GB or more are advisable, since a sandbox container may use 4 cores
and 16 GB and two jobs can run at once; a smaller workspace works too (next
section).

## A smaller metacheck workspace

What the workspace needs is set by how many jobs run at once and by what the code
of one job may use in the sandbox:

- `metacheck_api_workers = 1`: one job at a time; the others wait in the queue
  (at most 20). A new 16-page paper takes about 60 s.
- `metacheck_sandbox_cpus` and `metacheck_sandbox_memory` (both `auto`): what one
  job's code may use. `auto` gives 4 processors and 16 GB, and less on a small
  workspace: never more processors than it has (Docker refuses a container that
  asks for more), and at most its memory minus 4 GB, divided among the jobs that
  may run at once. Docker stops code that needs more memory. The playbook writes the limits to
  `/etc/metacheck-sandbox.conf`, which the guard reads (only when root owns it and
  nobody else can write it, so a job cannot raise its own limits), and to the web
  interface's service.
- `metacheck_psyarxiv_reports = 0`: no hourly reports on new PsyArXiv preprints,
  which otherwise keep the queue busy.
- A model on another server, or the bibr workspace's: the metacheck workspace then
  needs no GPU.

The rest needs little: while a job ran on the 8-core, 64 GB workspace (October
2026), the web interface's R process used 0.15 GB, the job's R process 0.6 GB,
Shiny Server and Docker 0.2 GB together. The disk needs do not change: the sandbox's
60 GB file system and the two images.

## A workspace without bibr

A metacheck workspace can convert PDFs and run the LLM power check without a
GPU and without bibr:

```
metacheck_bibr_url=none
metacheck_grobid_url=local
metacheck_docx_converter=local
metacheck_llm=ollama-cpu
```

- `metacheck_grobid_url = local` runs GROBID on the workspace (`tasks/grobid.yml`):
  the image without deep learning models (`metacheck_grobid_image`,
  `grobid/grobid:0.9.1-crf`, about 0.5 GB), in Docker as the service
  `metacheck-grobid`, reachable only from the workspace (`127.0.0.1:8070`), with
  at most 6 GB of memory, half of it for Java's data (with 4 GB and three quarters, a long paper
  made it run out of memory). The web interface converts every PDF with it (and says so
  in the report), and the paper report app offers it first ("Use GROBID on this
  server"). GROBID reads PDFs only, not Word files, and its conversion is less
  complete than bibr's. It needs Docker, which the playbook installs for the
  sandbox (`metacheck_run_code`).
- `metacheck_docx_converter = local` runs LibreOffice on the workspace
  (`tasks/docx.yml`): Gotenberg's image with LibreOffice only
  (`metacheck_docx_image`, `gotenberg/gotenberg:8.38.1-libreoffice`, about 0.45 GB),
  in Docker as the service `metacheck-docx`, reachable only from the workspace
  (`127.0.0.1:3000`), with at most 2 GB of memory. Without bibr, the web interface
  sends it a Word file (`.docx`, about a quarter of PsyArXiv's preprints), gives the
  PDF it returns to GROBID, and says so at the top of the report (`converter`:
  `word+grobid`). It also needs Docker.
- `metacheck_llm = ollama-cpu` runs Ollama with `metacheck_llm_model` on the
  processors, with half the processor weight of other programs (`CPUWeight=50`),
  so the website and code runs keep theirs. On a 2-core workspace (October 2026),
  the power check of a text with three power analyses took 36 to 51 s and found
  all three; the model keeps about 4.3 GB of memory.
- `auto` sandbox memory keeps 6 GB more for GROBID, 2 GB more for LibreOffice and 4.5 GB more for the model.
  On `4 Core - 32 GB RAM` with all three, a code run then gets about 14.7 GB with
  one job at a time and about 7.2 GB with two; on `2 Core- 16 GB RAM` only 1 GB, too
  little for most code.

## Which checks use the language model

Only the power check (`power`) uses the language model on this server, in the paper
report app and in the web interface; every other check works by rules only, also
when the model is available. metacheck has one switch for all checks (`llm_use()`),
so `app/llm_modules.R` sets it at the start of every check, through a trace on
metacheck's `module_run()`, which runs every check, also the ones a module such as
`tue_datamanager_check` runs itself: on for the checks in `LLM_MODULES` when the
job has a model, off for the rest. The checks that would otherwise use it are
`codebook_check`, `data_check`, `repo_check`, `psychds_check` and
`reproducibility_check`; on processors only (`ollama-cpu`) the codebook check alone
took most of an hour. Installed modules get no model at all, also not for their own
calls: `tue_datamanager_check` then checks the README by its headings and writes no
revised README. To let another check use the model, add it to `LLM_MODULES`.

## Messages to Discord

With `metacheck_discord_webhook` set to a Discord channel's webhook address
(channel settings, Integrations, Webhooks, New Webhook, Copy Webhook URL), the
server posts short messages there (`api/notify.R`):

- each finished PsyArXiv report: title, preprint id and version, a link to the
  report (`/psyarxiv-reports/?id=<id>`), the converter and the time it took;
- each failed PsyArXiv report, with the error, and a run that could not start
  because PsyArXiv or the web interface did not answer;
- each mistake a reader reports in a PsyArXiv report, with the reader's message
  but not their e-mail address;
- problems the server watch finds (`api/watch.R`, every 15 minutes through
  `metacheck-watch.timer`, only with a webhook): the web interface, bibr, GROBID or
  the language model does not answer, the server of the models tried first does
  not answer or offers none of them, or less than 15 GB is free for jobs. It posts
  when a problem starts and when it is over, not while it lasts;
- with models tried first (see "Models tried first"), once a day from 08:00 Dutch
  time, how many power checks of the day before used them and how many this
  server's own model, and why.

The address is kept in `/etc/metacheck-discord-webhook` (root only) and written to
the shiny user's `~/.Renviron`, so a later run with the default `keep` keeps it,
and `none` removes it. Anyone who has the address can post to the channel, so pass
it as a parameter only where the workspace logs are not read by others, or put it in
that file on the workspace yourself. Messages never mention anyone (no `@everyone`,
whatever a title contains).

## API keys for the data repositories

metacheck reads the data and code repositories a paper links to. Some of them
need a key, or allow far more requests with one, and all visitors of this
server share its internet address (checked 2026-10-28):

| Setting | Service | Without a key | With a key |
|---|---|---|---|
| `metacheck_dryad_client_id`, `metacheck_dryad_client_secret` | Dryad | files cannot be downloaded | downloads work (100 per hour) |
| `metacheck_researchbox_api_key` | ResearchBox | the web page, which asks for a captcha after a few downloads | its API |
| `metacheck_github_pat` | GitHub | 60 requests per hour | 5,000 per hour |
| `metacheck_osf_pat` | OSF | 100 requests per hour | 10,000 per day |
| `metacheck_gitlab_pat` | GitLab | 500 per minute (GitLab has announced 60 per hour) | 2,000 per minute |
| `metacheck_openalex_api_key` | OpenAlex | US$0.10 of searches per day | US$1 per day |

Zenodo, Figshare, Dataverse and the other repositories gave no gain for public
records, so they get no key here.

**A key gives every visitor what its account can read.** An OSF key needs the
`osf.full_read` scope, which opens its owner's private projects, so use an OSF
account that belongs to no projects; the same holds for GitLab, and for Dryad
and ResearchBox accounts with unpublished datasets. For GitHub, a fine-grained
token with "Public repositories" access and no permissions reads only public
repositories. Dryad gives client ids for services at help@datadryad.org.

Each key is kept in `/etc/metacheck-keys/<variable>` (root only) and written to
the shiny user's `~/.Renviron`, so a later run with the default `keep` keeps
it, and `none` removes it. A key added to `~/.Renviron` by hand is gone after
the next run. As with the Discord webhook, pass a key as a parameter only where
the workspace logs are not read by others, or put it in its file on the
workspace yourself (`sudo sh -c 'umask 077; cat > /etc/metacheck-keys/GITHUB_PAT'`)
and run the playbook with `keep`.

When a key is refused (expired or withdrawn) or reaches its limit, metacheck
records that in `METACHECK_STATE_DIR` (`/var/lib/metacheck-state`), which the
app, the web interface's jobs and the PsyArXiv reports share (see
`metacheck::api_key_status()`). Then:

- a refused key is left out, so requests go without a key, and checked again
  after an hour;
- the paper report app shows the message ("The Dryad key provided by
  metacheck has reached Dryad's limit until 15:00 UTC. Please provide your own
  Dryad key to continue (you can make one at ...)"), and its Options tab has a
  folded box "Your own API keys (optional)";
- `GET /api/health` lists the problems in `key_problems`, and the website then
  shows the message and a field for the visitor's own key;
- the server watch posts the problem on Discord, and also when the GitHub key
  expires within two weeks.

A visitor's own key (the app's box, the website's field, or the web interface's
fields `key_github`, `key_osf`, `key_dryad`, `key_researchbox`, `key_gitlab`,
`key_openalex`) is used for that visitor's job only. The app passes it to the
job's own R process; the web interface keeps it in memory until the job starts
and never writes it to the job's folder. The server's keys stay in place for
everyone else.

## A model on another server

With `metacheck_llm = url`, the power check (in the app and the web interface) and
the installed modules use the model of another server, through its
OpenAI-compatible address (`/v1/chat/completions`; vLLM, Ollama, LiteLLM and
similar gateways all offer one):

```
metacheck_llm=url
metacheck_llm_url=https://spike-gateway-runai-aiteam.inference.spike.tue.nl/v1
metacheck_llm_api_key=<the key>
metacheck_llm_model=DeepSeek-V41-Flash-1017-FP8
metacheck_llm_name=TU/e's SPIKE-1
metacheck_llm_max_tokens=16000
```

The playbook asks the server for its models (`/v1/models`) and says whether it
answers and lists `metacheck_llm_model`; it goes on either way. The app names the
server in its privacy note and says the paragraphs are sent there. The installed
modules treat this model as the workspace's own: `tue_datamanager_check`, which
otherwise only uses a local model, sends the README and up to three documents of a
package to it. So name only a server you trust with what people upload.

TU/e's SPIKE-1 answers only on TU/e's network or VPN. From the metacheck workspace
on SURF Research Cloud its gateway did not answer on 23 October 2026 (no
connection within 20 s), while other TU/e servers did. It does answer through a
relay on TU/e's Shiny server (`https://shiny.ieis.tue.nl/spike_relay`, a small
Shiny app that passes requests with its own key on to SPIKE-1 with the SPIKE-1
key), which is how "Models tried first" uses it.

## Models tried first

With `metacheck_llm_first_url` and `metacheck_llm_first_models`, the power check
(in the app and the web interface) first tries the models of another server, and
uses the model of `metacheck_llm` only when none of them is available:

```
metacheck_llm_first_url=https://shiny.ieis.tue.nl/spike_relay
metacheck_llm_first_models=qwen3-8-27b-fp8,DeepSeek-V41-Flash-1017-FP8
metacheck_llm_first_api_key=<the relay's key>
metacheck_llm_first_name=TU/e's SPIKE-1
```

`app/llm_first.R` does this through a wrapper around metacheck's `module_run()`,
so metacheck itself is not changed:

- When a paper's power check starts, it asks the server for its models
  (`<url>/models`, at most 30 s) and uses the first model of the list that the
  server lists as `running`. SPIKE-1 also lists a model that is still loading as
  running (`running: true`, status "initializing (loading onto GPU)"), and that
  model does not answer yet, so only the status `running` counts. A server that
  gives no status counts every model it lists.
- When none is running, the check uses this server's model, and the first model
  of the list is sent a one-word question without waiting for the answer: SPIKE-1
  then loads it for the next paper (SPIKE-1 unloads a model after 15 to 60
  minutes without use). The relay answers one request at a time, and SPIKE-1
  answers this question only after about 45 s, so the question carries the header
  `X-Relay-Wait: no`, on which the relay sends it on by itself and answers at once.
- When the check on the first server could not check every paragraph, or failed
  as a whole, it runs again on this server's model.
- Each request to the first server may take at most 60 s, with one retry;
  SPIKE-1 itself ends requests after about 30 s.

metacheck switches the model's thinking off only for Qwen 3 models, so DeepSeek
thinks before it answers: on 28 October 2026 it answered 39 of 40 test paragraphs,
most in 1 to 5 s, one in 21 s, and one ran out of answer length (which this
server's model then checks again).

Each power check writes one line to `/var/lib/metacheck-watch/llm-first.log`
(`METACHECK_LLM_FIRST_LOG`): the time, `app` or `web`, the model (`local` for this
server's) and why, but nothing about the paper. The server watch posts a summary
of it to Discord once a day (see "Messages to Discord") and keeps the last 30 days.

## A public metacheck app

The website, the paper report app and the web interface can be opened to anyone in
the same way. On the metacheck workspace (or with `metacheck_public = true` when it
is created):

```
sudo metacheck-public on       # open:   https://<workspace>/, /metacheck/ and /api/ without login
sudo metacheck-public off      # SRAM login required again
metacheck-public status
```

The component keeps two variants of the app's nginx file, made from one template,
in `/opt/metacheck-component/nginx/`; the switch puts one in place and restores the
previous one if nginx rejects it. While open, POST requests (uploads, and Shiny's
fallback transport) are limited to 20 per minute per visitor, burst 40; the app
itself runs at most 4 reports at once and makes each session wait between reports.
The progress page always requires the SRAM login.

## The web interface: a report from any programming language

The metacheck component also runs a small web interface (`api/api.R`, plumber,
service `metacheck-api`) at `https://<workspace>/api/`. Send a paper, get the
report back; or send a .zip of a data and code folder and get a report on that
folder. It follows the same switch as the app: open to anyone while
`metacheck-public on`, behind the SRAM login otherwise.

| Request | Send (form field `file`) | Get |
|---|---|---|
| `POST /api/jobs` | PDF or bibr JSON; `kind` = `report` (default), `check` or `convert`; optional `modules`, `report=true`. Or a .zip with `kind` = `repocheck` | at once (HTTP 202): the job's `id`, `status_url` and `result_url` |
| `GET /api/jobs/<id>` | | `status` (`queued`, `running`, `done`, `failed`), `step` (such as "running module 3 of 7: stat_check"), `position` in the queue, for a folder check `progress` (0 to 1), `error`; fields without a value are left out |
| `GET /api/jobs/<id>/result` | | the result once `done`; HTTP 409 before that, 422 with `error` if the job failed |
| `POST /api/report` | PDF or bibr JSON; optional `modules` | the HTML report (self-contained) |
| `POST /api/check` | PDF or bibr JSON; optional `modules`, `report=true` | module results as JSON (and `report_html`) |
| `POST /api/convert` | PDF | bibr's JSON |
| `POST /api/repocheck` | .zip of a data and code folder, or instead a field `url` with a link to an online repository; optional `modules` = an installed module, `human_participants` = `true`/`false` | the HTML report of `repo_check`, `code_check` and `data_check`, or of the installed module |
| `GET /api/modules` | | the modules that may be requested, the default set, and (`installed`) the modules installed on this server |
| `GET /api/health` | | status, whether bibr answers, metacheck version |

Two fields work with several of these (22 October 2026):

- `report_type=checklist`: metacheck's checklist report (every check sorted by its
  result: to fix, to improve, to decide by hand, fine, ...; what was found and what
  to do on separate lines) instead of the full report of a paper (`report`, and
  `check` with `report=true`) or the brief report of a repository check
  (`repocheck`). For a paper it is drawn from the module results that already ran
  (`render_checklist_html()` in `worker.R`). An installed module always gives its
  own checklist.
- `psyarxiv=<link, DOI or id>` (`report` and `check`, instead of a file): the worker
  reads the preprint's record from PsyArXiv's API and fetches its current PDF from
  PsyArXiv (or, when PsyArXiv has only that link, from the OSF), then checks it like
  an uploaded PDF. Only the id is passed on (checked by `.psyarxiv_id()` in `api.R`),
  so the field cannot make the server fetch anything else. PsyArXiv's files send no
  CORS header, which is why a web page cannot fetch the PDF itself. The PsyArXiv API
  address is `PSYARXIV_API` (default `https://next.psyarxiv.org/api/v1`).

`run_code=true` with `report` or `check` now runs the paper's code as documented;
before, a paper job always had `run_code` false (`!length(modules)` in `.submit()`
applied to papers too, and a paper always has modules).
| `/api/__docs__/` | | interactive documentation in the browser |

PDFs are converted by the bibr the component is connected to (bibr itself stays
closed). Only the modules the app offers can be requested; the default is a quick
set that needs no other online service (`power`, `marginal`, `ethics_check`,
`stat_check`, `stat_p_exact`, `stat_p_nonsig`, `stat_effect_size`).

A folder check (`repocheck`) is the check of metacheck's repository check app
(`inst/app/shiny_app_repocheck`): the playbook takes that app's code from the same
metacheck branch, and the interface uses its .zip checks, its three modules and its
short report with a folded file list, so both give the same report. The report names
the folder after the .zip (or after the one folder the .zip contains), not after its
place on the server (metacheck issue #500), and never `modules`: metacheck looks
for a module in `./modules/` before the installed ones, and the check runs from
the unpacking folder, so an upload named `modules.zip` could otherwise replace an
installed module with its own code. A small folder takes about 10 s.

When the R process that runs a job ends without saying why (a crash in compiled
code, or no memory left), the job's `error` says so, with its last step, instead of
"The job stopped unexpectedly."

Instead of a .zip, a folder check can get a link to an online repository (form
field `url`, without a file). The server then fetches the public files itself, as the
repository check app does: files over 100 MB are skipped and at most 500 MB is
fetched per repository, into the job's own folder. Only links whose host name points
to public internet addresses are accepted, so a link cannot make the server fetch
from itself or from SURF's private network (metacheck fetches only from repository
platforms it knows, but Dataverse and DSpace run on any institution's server).
A GitHub repository with a Quarto analysis took 15 s, its code run included.

Size limits: PDFs and bibr JSON at most 50 MB; a .zip at most 500 MB, at most
1000 MB and 20,000 files once unpacked, and without paths that point outside the
folder (the app's limits). Larger uploads get HTTP 413 with a JSON `error`. A
480 MB .zip took 43 s to upload from a university network. New jobs are refused
while less than 10 GB is free where the jobs are kept.

bibr completes references through Crossref only when a request includes
`crossref=true` (form field); the default is `false`, so the paper's reference
list is not sent to Crossref. bibr stores conversions with and without Crossref
separately, so one never stands in for the other. The paper report app does the
same: its "Query CrossRef" box (unticked by default) now also decides whether bibr
uses Crossref. When GROBID converts the PDF in the web interface (no bibr, or bibr
failed), `crossref=true` has metacheck complete the reference list at Crossref
(`convert(crossref_lookup = TRUE)`, by DOI or by the reference's text); when that
lookup fails, the PDF is converted again without it. The PsyArXiv reports always
ask for Crossref.

When bibr does not answer (the job asks it first, for 5 s) or cannot convert a PDF,
the job converts it with the GROBID server in `metacheck_grobid_url` (TU/e's by
default), through metacheck's own `convert()`. GROBID reads PDFs only, not Word
files, and its conversion is less complete than bibr's. The report says at its top
which one converted the PDF, and `/jobs/{id}` and the JSON of `/check` give it as
`converter` (`bibr` or `grobid`). The paper report app (`/metacheck/`) is not
affected: there the visitor chooses the converter.

Every paper or folder becomes a job in one queue, whichever request sent it. At most two jobs
run at a time (`metacheck_api_workers`), each in its own R process, so the interface
keeps answering while they run; at most 20 wait, and further uploads get HTTP 503.
While the interface is not running (during an automatic update, or a restart),
nginx answers HTTP 503 with a JSON `error` and `Retry-After: 120` instead of its
own "502 Bad Gateway" page.
`/jobs` answers at once and suits web pages and long papers; `/report`, `/check` and
`/convert` keep the connection open until their job is finished, so they are one line
of code. A job is stopped after 30 minutes. A new 16-page paper took about 60 s from
upload to report, and three new papers sent together were done after 211 s; a paper
bibr has seen before takes about 10 s.

Jobs are kept on the storage volume when there is one
(`/data/<volume>/metacheck-api-jobs`), otherwise in `/var/lib/metacheck-api/jobs`.
Uploads are deleted as soon as a job has read them, and a folder's unpacked files
when its check ends. Results are deleted 60 minutes
after the job finished (`METACHECK_API_KEEP_MINUTES`); until then anyone with the
job's id can fetch them, and the id is a random UUID. While public: 6 uploads per
minute per visitor (burst 6), beyond that HTTP 429 with a JSON `error`; status and
result requests are not limited.

### Installed modules

Modules installed from GitHub (`metacheck_modules`), such as
[`tue_datamanager_check`](https://github.com/Lakens/tue_datamanager_check) (a check of a
data package the way TU/e's data managers do), run on an uploaded .zip or a link
instead of the usual folder check: `POST /api/jobs` with `kind=repocheck`, or
`POST /api/repocheck`, with the field `modules=tue_datamanager_check`. For a .zip the
worker unpacks it as for a folder check; a link (checked as for a folder check: public
addresses only) is given to the module, which fetches the repository's public files
itself (100 MB per file, 500 MB in all). The worker sets up the workspace's language
model, runs that one module and returns the module's own full report; the module runs
the metacheck modules it needs itself. `tue_datamanager_check` also takes
`human_participants=true` or `false` (whether people took part, when the sender knows).
Only the administrator installs modules; a module that is not installed or more than
one module is refused (HTTP 400), and a paper report cannot ask for an installed
module. `GET /api/modules` lists them under `installed`.

```sh
curl -F kind=repocheck -F modules=tue_datamanager_check -F file=@package.zip \
     https://<workspace>/api/jobs
curl -F kind=repocheck -F modules=tue_datamanager_check -F url=https://github.com/user/repo \
     https://<workspace>/api/jobs
```

While the web interface is open to anyone (`metacheck-public on`), it allows web pages
on any website, and pages opened from disk, to use it (CORS: `Access-Control-Allow-Origin:
*`, also on nginx's own answers about too large files and too many uploads). The
TU/e data manager check has such a page (`web/` in its repository), which runs on any
website, as a Shiny app or locally. Behind the SRAM login nothing changes: a page
elsewhere cannot log in.

Examples (all tested; replace the address with your workspace's):

```
curl -F file=@paper.pdf https://<workspace>/api/report -o report.html
curl -F file=@paper.pdf -F modules=power,stat_check https://<workspace>/api/check
curl -F file=@paper.pdf https://<workspace>/api/convert -o paper.json
curl -F file=@my_study.zip https://<workspace>/api/repocheck -o folder_report.html
curl -F url=https://github.com/user/repo https://<workspace>/api/repocheck -o repo_report.html
```

```r
library(httr2)
api <- "https://<workspace>/api"
request(paste0(api, "/report")) |>
  req_body_multipart(file = curl::form_file("paper.pdf")) |>
  req_timeout(1800) |>
  req_perform(path = "report.html")

res <- request(paste0(api, "/check")) |>
  req_body_multipart(file = curl::form_file("paper.pdf"), modules = "power,stat_check") |>
  req_timeout(1800) |> req_perform() |> resp_body_json()
```

```python
import requests
api = "https://<workspace>/api"
with open("paper.pdf", "rb") as f:
    r = requests.post(f"{api}/report", files={"file": f}, timeout=1800)
open("report.html", "wb").write(r.content)
```

```powershell
# Windows PowerShell 5.1 and PowerShell 7
Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromMinutes(30)
$form = New-Object System.Net.Http.MultipartFormDataContent
$file = New-Object System.Net.Http.ByteArrayContent(,[System.IO.File]::ReadAllBytes("C:\papers\paper.pdf"))
$file.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/pdf")
$disp = New-Object System.Net.Http.Headers.ContentDispositionHeaderValue("form-data")
$disp.Name = '"file"'; $disp.FileName = '"paper.pdf"'
$file.Headers.ContentDisposition = $disp
$form.Add($file)
$r = $client.PostAsync("https://<workspace>/api/report", $form).Result
[System.IO.File]::WriteAllBytes("C:\papers\report.html", $r.Content.ReadAsByteArrayAsync().Result)
```

(Windows also has `curl.exe`, which takes the curl lines above unchanged.)

With a job, in R and Python (tested):

```r
library(httr2)
api <- "https://<workspace>/api"
job <- request(paste0(api, "/jobs")) |>
  req_body_multipart(file = curl::form_file("paper.pdf"), kind = "report") |>
  req_error(is_error = \(r) FALSE) |> req_perform() |> resp_body_json()
repeat {
  st <- request(job$status_url) |> req_perform() |> resp_body_json()
  message(st$status, ": ", st$step)
  if (st$status %in% c("done", "failed")) break
  Sys.sleep(5)
}
request(job$result_url) |> req_perform(path = "report.html")
```

```python
import time, requests
api = "https://<workspace>/api"
with open("paper.pdf", "rb") as f:
    job = requests.post(f"{api}/jobs", files={"file": f}, data={"kind": "report"}).json()
while (st := requests.get(job["status_url"]).json())["status"] not in ("done", "failed"):
    print(st["status"], st["step"]); time.sleep(5)
open("report.html", "wb").write(requests.get(job["result_url"]).content)
```

The interface reuses metacheck's own API helper code (`inst/plumber/utils`, fetched
from the same metacheck version, since it is not part of the installed package)
for running modules and rendering the report. It reads uploads with `webutils`
rather than metacheck's `mime`-based helper, because `mime` does not find the file
when its `Content-Type` line comes before its `Content-Disposition` line, which is
how .NET and PowerShell send it.

## Component definitions (SRC portal, Development → Components → +)

| Field | bibr | metacheck |
|---|---|---|
| Script type | Ansible Playbook | Ansible Playbook |
| Repository URL | `https://github.com/scienceverse/surf-research-cloud.git` | same |
| Path | `bibr.yml` | `metacheck.yml` |
| Tag | `main` (or a release tag) | same |
| Script availability | publicly available on Git | same |
| Access format / label | `/bibr/docs` → "bibr API" | `/metacheck/` → "metacheck report app" |

## Parameters

All values are strings. SRC does not allow empty values, so `none` means "not set"
and `auto` means "decide on the workspace".

### bibr

| Key | Default | Meaning |
|---|---|---|
| `bibr_ref` | `v0.7.3` | bibr version (git tag) |
| `bibr_llm_provider` | `ollama` | `ollama` = local model on the GPU; `google`, `anthropic` or `openai` = cloud model with a key below |
| `bibr_llm_model` | `qwen3.5:4b` | Ollama model tag, or the cloud model name |
| `bibr_ollama_context` | `16384` | Ollama's context window in tokens (its default of 4,096 cut off bibr's title step) |
| `bibr_google_api_key`, `bibr_anthropic_api_key`, `bibr_openai_api_key` | `none` | cloud keys, only for cloud providers |
| `bibr_crossref_email` | `none` | contact e-mail for Crossref's polite pool; set it, Crossref lookups are slow without it |
| `bibr_ocr_mem_fraction` | `0.60` | share of GPU memory the OCR server reserves |
| `bibr_api_key` | `auto` | bibr's bearer token: generated on the workspace, or a fixed one of 32 or more characters |
| `bibr_listen` | `auto` | `auto` = 127.0.0.1 plus the private network address; `local` = 127.0.0.1 only; or an extra IPv4 address |
| `bibr_public` | `false` | `true` opens bibr to anyone at the workspace's web address, without the SRAM login (see "A public bibr") |
| `bibr_docker_root` | `auto` | where Docker keeps its images (about 110 GB) |
| `bibr_max_upload` | `100M` | largest PDF nginx accepts on `/bibr/` |
| `bibr_start` | `true` | `false` installs everything but does not build or start the containers |

### metacheck

| Key | Default | Meaning |
|---|---|---|
| `metacheck_repo` / `metacheck_ref` | `scienceverse/metacheck` / `dev` | where metacheck comes from (`dev`: `main` lags months behind) |
| `metacheck_modules` | `Lakens/tue_datamanager_check` | modules to install from GitHub (`owner/repo`, separated by commas or spaces; `none` = none), with `metacheck::module_install()` into `/opt/metacheck-component/modules` (`METACHECK_MODULES_DIR`); each set-up updates them to the newest commit. Needs metacheck 0.4.0.4 or later; a module that cannot be installed is reported and skipped (see "Installed modules") |
| `metacheck_bibr_url` | `auto` | `auto` = the bibr on this workspace, if any; `none` = no bibr; or an address such as `http://10.10.10.12:8000` |
| `metacheck_bibr_api_key` | `none` | bibr's token; required with an address |
| `metacheck_docx_converter` | `none` | `local` = LibreOffice on this workspace makes a PDF of a Word file for GROBID when there is no bibr (see "A workspace without bibr"); `none` = Word files need bibr |
| `metacheck_grobid_url` | `https://grobid.hti.ieis.tue.nl` | the GROBID server the web interface converts a PDF with when bibr fails or there is none; `local` = GROBID on this workspace (see "A workspace without bibr"); `none` = no fallback |
| `metacheck_llm` | `ollama` | `ollama` = local model for the power check when the workspace has a GPU, otherwise the bibr workspace's; `bibr` = always the bibr workspace's; `ollama-cpu` = a local model on the processors, without a GPU (see "A workspace without bibr"); `url` = another server's (see "A model on another server"); `none` = no model |
| `metacheck_llm_model` | `qwen3.5:4b` | Ollama model tag; on a workspace of its own, a larger model fits; with `url`, the name the other server gives the model |
| `metacheck_ollama_context` | `16384` | Ollama's context window in tokens |
| `metacheck_llm_url` | `none` | with `metacheck_llm = url`: the other server's OpenAI-compatible address, with or without `/v1` |
| `metacheck_llm_api_key` | `none` | with `url`: that server's key (sent as `Authorization: Bearer`); `none` = no key |
| `metacheck_llm_name` | `none` | with `url`: the name the app shows for that server; `none` = its host name |
| `metacheck_llm_max_tokens` | `none` | the longest answer, in tokens, the server's model may give; `none` = metacheck's default. A model that reasons first needs more (16000 for DeepSeek on SPIKE-1) |
| `metacheck_llm_first_url` | `none` | an OpenAI-compatible address whose models the power check tries before the model of `metacheck_llm` (see "Models tried first"), used as given: `/models` and `/chat/completions` follow it; `none` = none |
| `metacheck_llm_first_models` | `none` | with `metacheck_llm_first_url`: the models to try, in order, separated by commas |
| `metacheck_llm_first_api_key` | `none` | with `metacheck_llm_first_url`: that server's key; `none` = no key |
| `metacheck_llm_first_name` | `none` | with `metacheck_llm_first_url`: the name the app shows for that server; `none` = its host name |
| `metacheck_discord_webhook` | `keep` | a Discord channel's webhook for messages about PsyArXiv reports and server problems (see "Messages to Discord"); `keep` = the one stored before, `none` = none |
| `metacheck_github_pat`, `metacheck_osf_pat`, `metacheck_dryad_client_id`, `metacheck_dryad_client_secret`, `metacheck_researchbox_api_key`, `metacheck_gitlab_pat`, `metacheck_openalex_api_key` | `keep` | API keys for the data repositories and OpenAlex (see "API keys for the data repositories"); `keep` = the one stored before, `none` = none |
| `metacheck_api_workers` | `2` | web interface jobs at a time; the others wait in the queue |
| `metacheck_sandbox_cpus` | `auto` | processors one job's code may use in the sandbox; `auto` = 4, or fewer when the workspace has fewer |
| `metacheck_sandbox_memory` | `auto` | memory one job's code may use, such as `8G` or `6000M`; `auto` = 16G, or less: the workspace's memory minus 4G, shared among `metacheck_api_workers` jobs |
| `metacheck_mistral_api_key`, `metacheck_groq_api_key` | `none` | keys for the app's cloud model providers (optional) |
| `metacheck_max_upload` | `100M` | largest PDF nginx accepts |
| `metacheck_public` | `false` | `true` opens the app and the web interface to anyone, without the SRAM login (see "A public metacheck app") |
| `metacheck_auto_update` | `true` | `true` installs new versions of metacheck (`metacheck_ref`) and of the modules by itself (see "Installing new versions by itself"); `false` = only when the playbook runs |

Secrets are generated on the workspace (`/etc/bibr/`, root only); nothing secret is
kept in this repository or in SRC.

## What each component does

**bibr** (`bibr.yml`):
1. Checks for Ubuntu 22.04 and a GPU (stops without one).
2. Generates bibr's bearer token, the OCR token and the Redis password once, in
   `/etc/bibr/` (or uses a fixed `bibr_api_key`).
3. Installs Docker and the NVIDIA container toolkit; Docker's images go on the
   first attached storage volume (`/data/...`), else `/mnt/scratch`, else the boot
   disk (needs 90 GB free). Switches off Docker 29's containerd image store, which
   ignores Docker's data directory.
4. Installs Ollama (`tasks/ollama.yml`), listening only on Docker's bridge address
   `172.17.0.1`, which bibr's container reaches and other workspaces cannot; Ollama
   has no login. Pulls the model.
5. Clones bibr into `/opt/bibr`, writes its settings, and starts the `bibr-stack`
   service, which builds the images (only when missing or bibr's version changed)
   and starts the containers in the background.
6. With SRC-Nginx: `/bibr/` (API, behind the SRAM login) and `/bibr-status`; the
   workspace root goes to `/bibr/docs` unless metacheck is installed too.

**metacheck** (`metacheck.yml`):
1. Checks for Ubuntu 22.04; notes whether there is a GPU.
2. Decides which bibr to use and checks that it answers (a warning, not an error:
   a new bibr may still be building).
3. With a GPU and `metacheck_llm = ollama`: installs Ollama (`127.0.0.1` only, or
   Docker's bridge address when bibr is on the same workspace) and pulls the model.
4. Installs R and its packages as Ubuntu binaries from
   [r2u](https://eddelbuettel.github.io/r2u/), Quarto 1.10.19, Shiny Server 1.5.23,
   and metacheck from GitHub; serves `app/` at `/metacheck/`.
5. With SRC-Nginx: the website at the workspace root (`/site/`), the app at
   `/metacheck/`, the web interface at `/api/`, and `/metacheck-status`.

A repeat run of either component changes nothing but its progress log and restarts
no service.

## The local model

bibr reaches Ollama through its OpenAI-compatible provider
(`LLM_BASE_URL=http://host.docker.internal:11434/v1`), because only that provider
passes `reasoning_effort`. It is set to `none`: Qwen 3.5's hidden reasoning step
made each call 5 to 10 times slower with the same output. `LLM_INSTRUCTOR_MODE=json`
is set because under the default strict output format the 4B model returned no
author affiliations. Ollama's context window is raised to 16,384 tokens: with the
default 4,096, bibr's title step for a real paper (3,602 tokens of input) was cut
off and the paper got no title.

The app reaches the local model through metacheck's OpenAI-compatible ("vllm")
route, because metacheck's Ollama route made every structured extraction run out
of tokens (metacheck issue
[#494](https://github.com/scienceverse/metacheck/issues/494), fixed in pull request
[#496](https://github.com/scienceverse/metacheck/pull/496)).

## The paper report app (`app/`)

`app/` is this repository's edition of metacheck's paper report app, the Shiny
Server edition in `inst/app/shiny_app` (the one deployed at TU/e), taken from
metacheck `dev` at commit 532a84d (0.3.3.8). The header of `app/app.R` lists what
differs:

- **bibr.** "Use bibr on this server", or "Use the bibr server of this research
  collaboration" when bibr is on another workspace, is offered first and
  preselected. The app calls bibr through its own small client
  (`app/bibr_client.R`), because metacheck's bibr route has open bugs
  ([#489](https://github.com/scienceverse/metacheck/issues/489),
  [#490](https://github.com/scienceverse/metacheck/issues/490),
  [#491](https://github.com/scienceverse/metacheck/issues/491); fixed in
  [#496](https://github.com/scienceverse/metacheck/pull/496)).
- **Local model.** "This server (local model)" is offered first, and
  preselected, for the optional LLM power check.
- **Missing title.** A paper without a title gets "(no title found in the PDF)",
  because a missing title makes metacheck's report lose its whole layout
  ([#497](https://github.com/scienceverse/metacheck/issues/497)).
- **Nothing on disk.** Report jobs switch off metacheck's LLM answer cache.
- **Repository switch.** Unticking "Query Data Repositories" also skips the
  preregistration check, which contacts the OSF
  ([#495](https://github.com/scienceverse/metacheck/issues/495)).

These are switched on by environment variables the metacheck component writes
for the shiny user (`BIBR_API_URL`, `BIBR_API_KEY`, `BIBR_REMOTE`,
`OLLAMA_BASE_URL`, `METACHECK_LLM_MODEL`); without them the app behaves like
metacheck's own. To take over later changes from metacheck, compare
`inst/app/shiny_app` at commit 532a84d with its current version and carry the
differences over.

## Tested

On an A10 workspace (`Ubuntu 2204 with CUDA`), October 2026, metacheck `dev`
0.3.3.8, bibr 0.7.3, Ollama 0.40.5, `qwen3.5:4b`:

- both components on one workspace: report through the app in a headless browser
  (6-page paper: 111 s including a fresh bibr extraction with Crossref);
- metacheck using bibr at a network address with its token, as on a private
  network (the workspace's own internal address stood in for a `10.10.10.x`
  address): bibr refuses requests without the token, the app labels and describes
  the remote bibr, report in 45 s;
- metacheck without bibr and without a local model: the app offers only the GROBID
  servers and the cloud providers, and a report through TU/e's GROBID took 15 s;
- repeat runs, and a reboot.

Not yet tested: two separate workspaces on a real SRC private network.

## Operating a workspace

```
sudo systemctl status bibr-stack ollama shiny-server docker
cat /var/log/bibr/status.txt /var/log/metacheck/status.txt
cd /opt/bibr && sudo docker compose --profile serve --profile ocr ps
sudo docker logs --tail 50 bibr-bibr-serve-1
sudo journalctl -u ollama -n 50
sudo ls -t /var/log/shiny-server/ | head
```

Use bibr directly on its workspace:

```
TOKEN=$(sudo cat /etc/bibr/api_key)
curl -X POST http://127.0.0.1:8000/papers/extract -H "Authorization: Bearer $TOKEN" -F "file=@paper.pdf"
```

## Installing new versions by itself

With `metacheck_auto_update = true` (the default) the metacheck workspace keeps
metacheck and its modules up to date with GitHub. The timer
`metacheck-auto-update.timer` runs `/usr/local/sbin/metacheck-auto-update` 15
minutes after the workspace starts, then 15 minutes after each run ends. When
the branch metacheck is installed from (`metacheck_ref`, `dev`) or an installed
module has a newer commit, the script

1. waits until the web interface has no running or waiting job (at most 30
   minutes; otherwise it tries again at the next run), because a job's R
   process stops with the web interface;
2. stops the web interface, so no job starts during the install;
3. installs with the playbook's own scripts (`install-metacheck.R`,
   `install-modules.R`, `fetch-api-helpers.sh`); when an install fails, R keeps
   the previous version;
4. starts the web interface again, restarts Shiny Server when metacheck changed
   (its R processes keep the old version loaded), and checks that the web
   interface answers.

The script and the playbook never install at the same time: the script holds
`/run/metacheck-auto-update.lock` while it runs and skips a turn when the lock is
taken, and the playbook takes that lock (after waiting up to 30 minutes for a
running update) through a helper unit, `metacheck-playbook-hold`, until it ends.
A playbook run that stops early leaves the helper running for at most an hour.

Every version on `metacheck_ref` goes live this way, also an unfinished one;
to install only releases, set `metacheck_ref` to a tag. The script changes
nothing else: the web interface, website and app of this repository still
change only when the playbook runs.

```
tail -n 30 /var/log/metacheck/auto-update.log      # what it did
systemctl list-timers metacheck-auto-update.timer  # when it runs next
sudo metacheck-auto-update --force                 # install now, without waiting for jobs
sudo systemctl disable --now metacheck-auto-update.timer   # switch it off until the next playbook run
```

## The SPIKE relay

`spike_relay/app.R` is the relay through which the SURF workspace reaches TU/e's
SPIKE-1 (see "Models tried first"). It is not part of a workspace: it runs as a
Shiny app on TU/e's Shiny server (`shiny-op01.ieis.tue.nl`, folder
`ShinyApps/spike_relay/`, address `https://shiny.ieis.tue.nl/spike_relay`), which
SPIKE-1 does answer. It answers on every address under the app, accepts POST,
checks the caller's key and passes the request on with the SPIKE-1 key. Nothing
is stored or logged. Shiny Server runs one R process per app, so the relay
answers one request at a time.

Its settings go in a `.Renviron` file next to `app.R`, readable only by its owner
and the group `shiny` (`chmod 640`, `chgrp shiny`), never in this repository:

```
RELAY_KEY=<a long random key; the same as metacheck_llm_first_api_key>
SPIKE_API_KEY=<the SPIKE-1 key>
# SPIKE_GATEWAY=<optional; default https://spike-gateway-runai-aiteam.inference.spike.tue.nl/v1>
```

To update it, copy `app.R` into that folder and `touch restart.txt` there. The
Shiny server can be reached only from TU/e's network.

## Developing these components

Run a playbook by hand on a workspace, the way SRC's External plugin does:

```
git clone https://github.com/scienceverse/surf-research-cloud.git
cd surf-research-cloud
uv venv ~/ansible-env --python 3.12 --seed
VIRTUAL_ENV=~/ansible-env uv pip install ansible==11.1.0
sudo ~/ansible-env/bin/ansible-playbook --connection=local -i localhost, -b bibr.yml
sudo ~/ansible-env/bin/ansible-playbook --connection=local -i localhost, -b metacheck.yml \
     -e "metacheck_bibr_url=http://10.10.10.12:8000 metacheck_bibr_api_key=..."
```

## Licence

The files in `app/` are derived from metacheck and are therefore under AGPL-3.0.
`site/fonts/` holds Cabin under the SIL Open Font License 1.1 (`OFL-Cabin.txt`), and
`site/vendor/jszip.min.js` is JSZip 3.10.1 under the MIT licence (or GPLv3).
No licence has been chosen yet for the other files in this repository. bibr and
metacheck are AGPL-3.0 and are installed from their own repositories.
