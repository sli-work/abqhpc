#!/bin/bash
# nohup entry for abqctl scheduler (runs on HPC login node)
set -euo pipefail

QUEUE_DIR="${ABQCTL_QUEUE_DIR:-/public/home/tsyg/tsyg/abqctl_queue}"
HERE="$(cd "$(dirname "$0")" && pwd)"
export ABQCTL_QUEUE_DIR="$QUEUE_DIR"
export PYTHONUNBUFFERED=1

mkdir -p "$QUEUE_DIR"
cd "$QUEUE_DIR"

# Prefer scripts from this directory (deployed copy)
export PATH="$HERE:$PATH"

exec python3 "$HERE/abqctl_scheduler.py"
