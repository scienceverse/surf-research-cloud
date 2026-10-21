#!/bin/bash
# Managed by the metacheck SURF Research Cloud component.
# metacheck's API helper code (inst/plumber/utils) and its repository check
# app (inst/app/shiny_app_repocheck, for folder checks) are not part of the
# installed package (.Rbuildignore), so they are taken from the same
# repository and branch metacheck was installed from. Prints "changed <folder>"
# for each folder it replaced. Used by the playbook and by
# metacheck-auto-update.
# Usage: fetch-api-helpers.sh <owner/repo> <git ref> <component dir>
set -euo pipefail
repo=$1; ref=$2; component_dir=$3
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 --filter=blob:none --sparse -b "$ref" "https://github.com/$repo.git" "$tmp/mc"
git -C "$tmp/mc" sparse-checkout set inst/plumber/utils inst/app/shiny_app_repocheck
api="$component_dir/api"
for pair in "inst/plumber/utils:metacheck-plumber/utils" "inst/app/shiny_app_repocheck:metacheck-repocheck"; do
  src="$tmp/mc/${pair%%:*}"; dest="$api/${pair#*:}"
  if ! diff -rq "$src" "$dest" >/dev/null 2>&1; then
    rm -rf "$dest"; cp -r "$src" "$dest"; chmod -R a+rX "$dest"; echo "changed $dest"
  fi
done
