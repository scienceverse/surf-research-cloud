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
| `metacheck_bibr_url` | `auto` | `auto` = the bibr on this workspace, if any; `none` = no bibr; or an address such as `http://10.10.10.12:8000` |
| `metacheck_bibr_api_key` | `none` | bibr's token; required with an address |
| `metacheck_llm` | `ollama` | `ollama` = local model for the power check when the workspace has a GPU; `none` = no local model |
| `metacheck_llm_model` | `qwen3.5:4b` | Ollama model tag; on a workspace of its own, a larger model fits |
| `metacheck_ollama_context` | `16384` | Ollama's context window in tokens |
| `metacheck_mistral_api_key`, `metacheck_groq_api_key` | `none` | keys for the app's cloud model providers (optional) |
| `metacheck_max_upload` | `100M` | largest PDF nginx accepts |

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
5. With SRC-Nginx: `/metacheck/` and `/metacheck-status`; the workspace root goes
   to `/metacheck/`.

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
No licence has been chosen yet for the other files in this repository. bibr and
metacheck are AGPL-3.0 and are installed from their own repositories.
