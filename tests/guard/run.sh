#!/bin/sh
# Checks that the guard (files/metacheck/metacheck-sandbox) lets through the
# docker commands a metacheck version sends, with the settings of this
# server's worker (api/worker.R), and still refuses what it must.
#
#   tests/guard/run.sh /path/to/metacheck
#
# 1. capture.R loads that metacheck in its R image and calls its four Docker
#    functions (installing R and Python packages, running R and Python
#    scripts, one in a folder "Analysis (final)"), with a stand-in docker
#    (bin/docker) that records each command.
# 2. replay.py sends those commands through the guard's checks, as root in a
#    Python image, and then ten changed commands the guard must refuse.
# Needs Docker. Run it after a change to the guard, and before installing a
# new metacheck version on the server. On Windows it runs in Git Bash.
set -e
pkg=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
guard=$(cd "$here/../../files/metacheck" && pwd)
work=$(mktemp -d)
cp -r "$here/bin" "$here/capture.R" "$here/replay.py" "$work/"
chmod +x "$work/bin/docker"
mkdir -p "$work/srv"
# Docker on Windows wants Windows paths
p() { if command -v cygpath > /dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }
export MSYS_NO_PATHCONV=1
job=12345678-1234-1234-1234-123456789abc

docker run --rm -v "$(p "$pkg"):/pkg:ro" -v "$(p "$work"):/out" -v "$(p "$work/srv"):/srv/metacheck-sandbox" \
  -e TMPDIR=/srv/metacheck-sandbox/$job/tmp ghcr.io/scienceverse/metacheck_r_large:latest \
  sh -c "mkdir -p /srv/metacheck-sandbox/$job/tmp && Rscript /out/capture.R"
status=0
docker run --rm -v "$(p "$guard"):/guard:ro" -v "$(p "$work"):/out" -v "$(p "$work/srv"):/srv/metacheck-sandbox" \
  python:3.12-slim python /out/replay.py || status=$?
# 3. The guard's own Python install script (written by replay.py), run with the
#    internet in Python 2.7 and 3: six is installed, a package PyPI does not
#    have and one from GitHub are not.
for img in python:2.7-slim python:3.12-slim; do
  docker run --rm -v "$(p "$work"):/out" "$img" sh -c '
    mkdir -p /pylib && python /out/install_guard.py && python -c "
import json
r = dict((d[\"package\"], d[\"installed\"]) for d in map(json.loads, open(\"/out/guard_install.jsonl\")))
ok = r == {\"six\": True, \"no-such-package-mc-test\": False, \"frompgithub\": False}
print(\"install script: %s %s\" % (\"ok\" if ok else \"WRONG\", r))
raise SystemExit(0 if ok else 1)
"' && echo "  ($img)" || { echo "install script failed in $img"; status=1; }
done
# the containers' files belong to root: removed by a container
docker run --rm -v "$(p "$work"):/w" python:3.12-slim sh -c 'rm -rf /w/* /w/.[!.]*'
rm -rf "$work"
exit $status
