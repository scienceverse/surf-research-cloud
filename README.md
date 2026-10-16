# metacheck on SURF Research Cloud

A [SURF Research Cloud](https://www.surf.nl/en/services/surf-research-cloud) (SRC)
component that turns one GPU workspace into a self-contained paper-checking server:

- **bibr** (`bibr serve`, the GLM-OCR model server and Redis, in Docker) extracts a
  PDF into structured JSON on the workspace's own GPU.
- **Ollama** serves a small language model (default `qwen3.5:4b`) on the same GPU
  for bibr's metadata extraction and for metacheck's optional LLM modules.
- **metacheck** (R package, `dev` branch) reads that JSON and runs its checks. The
  paper report app in `app/` (see "The paper report app") is served by Shiny Server.
- Both are reachable through the workspace URL behind the SRAM login:
  `/metacheck/` (the app) and `/bibr/` (the extraction API).

Workflow: PDF → bibr JSON → metacheck → report, all on one machine. With the
default local model no document leaves the workspace. Reference lists are looked
up in Crossref, and metacheck's online modules contact the services they check
(PubPeer, data repositories) when those options are on in the app.

Tested on `Ubuntu 2204 with CUDA`, `A10 - 1 GPU` (October 2026), with metacheck
`dev` 0.3.3.8 and bibr 0.7.3. bibr's extraction takes about 25 seconds for a 6-page
paper and about 65 seconds for a 16-page one without Crossref lookups; Crossref
adds up to a minute. A full report through the app took 55 seconds for metacheck's
demo paper, including the power check with the local model. GPU memory in use is
about 19.7 of 23 GB.

## Requirements

| Item | Value |
|---|---|
| Catalog item base | `Ubuntu 2204 with CUDA` (Ubuntu 22.04, NVIDIA driver and CUDA preinstalled) |
| Flavour | `A10 - 1 GPU` or larger (24 GB GPU memory; 30 GB or more system memory) |
| Disk | Docker's images need about 90 GB while building and 30 GB afterwards. The playbook puts them on the first attached SRC storage volume (mounted under `/data/`, persistent) if there is one, else on the ephemeral `/mnt/scratch` disk that GPU flavours have (images are rebuilt after a reboot), else on the boot disk, which must then be 150 GB or larger. |
| Components, in this order | `SRC-OS`, `SRC-CO`, `SRC-Nginx`, `SRC-External plugin`, `metacheck` (this repository) |
| Access button | `Webinterface (https:)` |

Ubuntu 24.04 is not supported yet because SRC's `SRC-External` component, which
every non-SURF component needs, is not available for it.

## Component definition (SRC portal, Development → Components → +)

| Field | Value |
|---|---|
| Script type | Ansible Playbook |
| Repository URL | `https://github.com/scienceverse/surf-research-cloud.git` |
| Path | `metacheck.yml` |
| Tag | `main` (or a release tag) |
| Script availability | publicly available on Git |
| Access format / label | `/metacheck/` → "metacheck report app"; `/bibr/docs` → "bibr API" |

## Parameters

All values are strings. SRC does not allow an empty value, so `none` means "not set".

| Key | Default | Meaning |
|---|---|---|
| `metacheck_llm_provider` | `ollama` | `ollama` runs the model on the workspace GPU. `google`, `anthropic` or `openai` use a cloud model with the matching key below. |
| `metacheck_llm_model` | `qwen3.5:4b` | For `ollama`, the model tag that is pulled; a 4B model fits next to the OCR server on a 24 GB card, a 2-GPU flavour can take a larger one. For a cloud provider, its model name (`default` keeps bibr's default). |
| `metacheck_google_api_key` | `none` | Google AI key, for `google` and for metacheck's LLM modules. |
| `metacheck_anthropic_api_key` | `none` | Anthropic key (alternative provider). |
| `metacheck_openai_api_key` | `none` | OpenAI-compatible key (alternative provider). |
| `metacheck_crossref_email` | `none` | Contact e-mail for Crossref's polite pool. Strongly recommended: without it Crossref lookups run at the anonymous rate and take most of the processing time. |
| `metacheck_bibr_ref` | `v0.7.3` | bibr git tag or branch to deploy. |
| `metacheck_metacheck_repo` | `scienceverse/metacheck` | GitHub repository to install metacheck from (a fork or another owner's copy). |
| `metacheck_metacheck_ref` | `dev` | metacheck git branch or tag to install. `dev` is where metacheck is developed; `main` lags months behind. |
| `metacheck_ocr_mem_fraction` | `0.60` | Share of GPU memory reserved by the OCR server. |
| `metacheck_max_upload` | `100M` | Largest PDF accepted by nginx. |
| `metacheck_start_bibr` | `true` | Set to `false` to install everything but not build or start the bibr containers. |
| `metacheck_docker_root` | `auto` | Directory for Docker's images; `auto` picks a large disk as described under "Disk". |

Secrets the component needs internally (bibr bearer token, OCR token, Redis
password) are generated on the workspace at first run and stored in
`/etc/metacheck/` (root only). Nothing secret is kept in this repository or in SRC.

## How the local model is configured

bibr reaches Ollama through its OpenAI-compatible provider
(`LLM_BASE_URL=http://host.docker.internal:11434/v1`), because only that provider
passes `reasoning_effort`. It is set to `none`: Qwen 3.5's hidden reasoning step
made each call 5 to 10 times slower with the same output. `LLM_INSTRUCTOR_MODE=json`
is set because under the default strict output grammar the 4B model returned no
author affiliations. Both were measured on bibr's sample paper and on real papers.

The metacheck side has its own version of this problem: its Ollama route asks
for no reasoning in a way Ollama's OpenAI-compatible address ignores, so every
structured extraction ran out of tokens (metacheck issue
[#494](https://github.com/scienceverse/metacheck/issues/494), fixed in pull request
[#496](https://github.com/scienceverse/metacheck/pull/496)). The app therefore
reaches the local model through metacheck's OpenAI-compatible ("vllm") route,
which does switch the reasoning off.

## The paper report app

`app/` is this component's own edition of metacheck's paper report app, the Shiny
Server edition in `inst/app/shiny_app` (the one deployed at TU/e), taken from
metacheck `dev` at commit 532a84d (0.3.3.8). The header of `app/app.R` lists what
differs. In short:

- **Local bibr.** "Use bibr on this server" is offered first and preselected. The
  app calls bibr through its own small client (`app/bibr_client.R`), because
  metacheck's bibr route has open bugs
  ([#489](https://github.com/scienceverse/metacheck/issues/489),
  [#490](https://github.com/scienceverse/metacheck/issues/490),
  [#491](https://github.com/scienceverse/metacheck/issues/491); fixed in pull
  request [#496](https://github.com/scienceverse/metacheck/pull/496)).
- **Local model.** "This server (local model)" is offered first, and
  preselected, for the optional LLM power check.
- **Nothing on disk.** Report jobs switch off metacheck's LLM answer cache, which
  would otherwise keep extracted values in the app folder.
- **Repository switch.** Unticking "Query Data Repositories" also skips the
  preregistration check, which contacts the OSF
  ([#495](https://github.com/scienceverse/metacheck/issues/495)).

The first two are switched on by environment variables the playbook writes for the
shiny user (`BIBR_API_URL`, `BIBR_API_KEY`, `OLLAMA_BASE_URL`,
`METACHECK_LLM_MODEL`); without them the app behaves like metacheck's own. To take
over later changes from metacheck, compare `inst/app/shiny_app` at commit 532a84d
with its current version and carry the differences over. Once the issues above are
fixed in metacheck, `app/bibr_client.R` can be replaced by
`metacheck::convert(method = "bibr", backend = "selfhosted")`.

## What the playbook does

1. Checks for Ubuntu 22.04 and an NVIDIA GPU.
2. Installs Docker and the NVIDIA container toolkit, with Docker's images on the
   large disk (see "Disk").
3. Installs Ollama, with its models on the large disk.
4. Clones bibr at the pinned release, writes its `.env`, and starts the
   `bibr-stack` systemd service, which pulls the Ollama model and builds and
   starts the Compose stack **in the background** (SRC gives a component 15
   minutes; the first build downloads several GB and takes 20–40 minutes, a
   later restart takes seconds because existing images are reused).
5. Installs R from CRAN's Ubuntu repository and metacheck's CRAN dependencies as
   binary packages from [r2u](https://eddelbuettel.github.io/r2u/), plus Quarto
   and Shiny Server.
6. Installs metacheck from GitHub (`dev`), plus the optional packages its data and
   codebook checks use, and serves the app in `app/` at `/metacheck/`.
7. Adds nginx locations (behind the SRAM login) for the app, the bibr API and a
   progress page.

Progress of the background build is shown at `/metacheck-status` on the workspace
URL and in `/var/log/metacheck/status.txt`. The bibr stack is ready when that
file says `READY`.

## Using the bibr API from outside

```
TOKEN=$(sudo cat /etc/metacheck/bibr_api_key)      # on the workspace
curl -X POST https://<workspace domain>/bibr/papers/extract \
     -H "Authorization: Bearer $TOKEN" -F "file=@paper.pdf"
```

The browser session's SRAM login is also required by nginx, so from a script
outside the workspace use an SSH tunnel to port 8000 instead.

## Operating the workspace

```
sudo systemctl status bibr-stack            # background build / start
sudo journalctl -u bibr-stack -f            # its log
cd /opt/metacheck/bibr && sudo docker compose --profile serve --profile ocr ps
sudo tail -f /var/log/shiny-server/*.log    # app logs
sudo systemctl restart shiny-server
```

## Developing this component

Run the playbook by hand on a workspace made from `Ubuntu 2204 with CUDA`, the
same way SRC's External plugin runs it:

```
git clone https://github.com/scienceverse/surf-research-cloud.git
cd surf-research-cloud
uv venv ~/ansible-env --python 3.12 --seed
VIRTUAL_ENV=~/ansible-env uv pip install ansible==11.1.0
sudo ~/ansible-env/bin/ansible-playbook --connection=local -i localhost, -b \
     --extra-vars='{"metacheck_google_api_key": "..."}' metacheck.yml
```

## Licence

The files in `app/` are derived from metacheck and are therefore under AGPL-3.0.
No licence has been chosen yet for the other files in this repository. bibr and
metacheck are AGPL-3.0 and are installed from their own repositories.
