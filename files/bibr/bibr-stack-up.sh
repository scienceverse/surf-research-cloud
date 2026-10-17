#!/usr/bin/env bash
# Managed by the bibr SURF Research Cloud component (scienceverse/surf-research-cloud).
#
# Builds and starts bibr's Docker Compose stack (bibr serve, GLM-OCR, Redis).
# The first run downloads the SGLang base image and the GLM-OCR weights,
# which takes well over the time SRC allows a component, so this script is
# started by systemd in the background and writes its progress to
# $BIBR_LOG_DIR/status.txt (shown at /bibr-status on the workspace).
set -euo pipefail

BIBR_DIR="${BIBR_DIR:-/opt/bibr}"
LOG_DIR="${BIBR_LOG_DIR:-/var/log/bibr}"
PORT="${BIBR_PORT:-8000}"
STATUS="$LOG_DIR/status.txt"
LOG="$LOG_DIR/bibr-stack.log"
mkdir -p "$LOG_DIR"

status() {
  echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" | tee -a "$STATUS"
}

cd "$BIBR_DIR"

# Build an image only when it is missing or when the playbook flagged a new
# bibr version (.rebuild). A restart for a configuration change then takes
# seconds instead of a 20 minute rebuild. One image at a time: building both
# together needed over 80 GB of disk at its peak.
REBUILD=0
if [ -f "$BIBR_DIR/.rebuild" ]; then REBUILD=1; fi
for svc in bibr-ocr bibr-serve; do
  image="bibr-$svc"
  if [ "$REBUILD" -eq 0 ] && docker image inspect "$image" >/dev/null 2>&1; then
    status "bibr stack: image $image present, not rebuilt"
    continue
  fi
  built=0
  # Package mirrors and PPAs answer 503 now and then; retry a few times.
  for attempt in 1 2 3 4; do
    status "bibr stack: building $svc (attempt $attempt; first build downloads several GB, 10-20 minutes)"
    if docker compose --profile serve --profile ocr build "$svc" >>"$LOG" 2>&1; then
      built=1
      break
    fi
    sleep 60
  done
  if [ "$built" -eq 0 ]; then
    status "bibr stack: BUILD FAILED for $svc after 4 attempts, see $LOG"
    exit 1
  fi
done
rm -f "$BIBR_DIR/.rebuild"
# Keep the build cache (fast rebuilds) unless the disk is getting small.
free_gb=$(df -BG --output=avail "$(docker info -f '{{.DockerRootDir}}')" | tail -1 | tr -dc '0-9')
if [ "${free_gb:-0}" -lt 60 ]; then
  docker builder prune -af >>"$LOG" 2>&1 || true
fi
status "bibr stack: images ready"

status "bibr stack: starting containers"
docker compose --profile serve --profile ocr up -d >>"$LOG" 2>&1

# Wait for bibr serve to report ready (OCR reachable, Redis up).
for i in $(seq 1 120); do
  if curl -sf "http://127.0.0.1:$PORT/ready" >/dev/null 2>&1; then
    status "bibr stack: READY (bibr serve answers on 127.0.0.1:$PORT)"
    exit 0
  fi
  sleep 15
done

status "bibr stack: containers started but /ready not reached after 30 minutes, see $LOG"
exit 1
