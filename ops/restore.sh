#!/usr/bin/env bash
# Usage: ops/restore.sh <backup-dir>
# Destructive: replaces the data volume's contents. Config is left for a manual diff.
set -euo pipefail
SRC="${1:?usage: restore.sh <backup-dir>}"
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DC=(docker compose --env-file .env.docker -f compose.yml -f compose.deploy.yml)
cd "$COMPOSE_DIR"
read -r -p "Type 'restore' to replace the live data with $SRC: " ans
[[ "$ans" == restore ]] || { echo aborted; exit 1; }
"${DC[@]}" stop wealthfolio
docker run --rm -v wealthfolio_wealthfolio-data:/data -v "$(cd "$SRC" && pwd)":/backup:ro alpine \
  sh -c 'find /data -mindepth 1 -delete && tar xzf /backup/wealthfolio-data.tar.gz -C /data'
"${DC[@]}" start wealthfolio
echo "Restored. Diff $SRC/config against the live .env.docker/compose.deploy.yml by hand if needed."
