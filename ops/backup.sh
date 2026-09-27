#!/usr/bin/env bash
# Backs up the self-hosted Wealthfolio stack: the data volume (SQLite DB +
# profiles.json + encrypted secrets) and .env.docker/compose.deploy.yml.
# The container is stopped for the tar so the SQLite file and its WAL are
# copied consistently (single-user app; downtime is seconds at 03:00), and
# restarted even if the copy fails.
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${WEALTHFOLIO_BACKUP_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/backups/wealthfolio}"
RETENTION_DAYS="${WEALTHFOLIO_BACKUP_RETENTION_DAYS:-7}"
STAMP="$(date +%Y-%m-%dT%H-%M-%S)"
DEST="$BACKUP_ROOT/$STAMP"
DC=(docker compose --env-file .env.docker -f compose.yml -f compose.deploy.yml)

cd "$COMPOSE_DIR"
umask 077
mkdir -p "$DEST"

trap '"${DC[@]}" start wealthfolio >/dev/null' EXIT
echo "[$STAMP] Stopping wealthfolio for a consistent copy..."
"${DC[@]}" stop wealthfolio >/dev/null

echo "[$STAMP] Backing up data volume..."
docker run --rm \
  -v wealthfolio_wealthfolio-data:/data:ro \
  -v "$DEST":/backup \
  alpine tar czf /backup/wealthfolio-data.tar.gz -C /data .

echo "[$STAMP] Backing up config..."
mkdir -p "$DEST/config"
cp .env.docker compose.deploy.yml "$DEST/config/"
git describe --tags >"$DEST/WEALTHFOLIO_VERSION.txt" 2>/dev/null || echo unknown >"$DEST/WEALTHFOLIO_VERSION.txt"

echo "[$STAMP] Backup complete: $DEST ($(du -sh "$DEST" | cut -f1))"

# Off-host copy: an IAM user with only List/Put/Get on the backup bucket (no
# DeleteObject), so a leaked key cannot wipe existing backups. The bucket has its
# own lifecycle, independent of RETENTION_DAYS. The bucket name is personal
# config, kept out of this (public) repo: set WEALTHFOLIO_BACKUP_S3_BUCKET in
# ${XDG_CONFIG_HOME:-~/.config}/wealthfolio/backup.env, or export it. An
# explicitly empty value skips the sync; an unset one fails the run.
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/wealthfolio/backup.env"
[[ -f "$CONFIG" ]] && source "$CONFIG"
S3_BUCKET="${WEALTHFOLIO_BACKUP_S3_BUCKET-__unset__}"
S3_PROFILE="${WEALTHFOLIO_BACKUP_S3_PROFILE:-s3-backup}"
# A shared backup bucket keeps every service under its own prefix.
S3_PREFIX="${WEALTHFOLIO_BACKUP_S3_PREFIX:-wealthfolio}"
SYNC_OK=1
if [[ "$S3_BUCKET" == "__unset__" ]]; then
  SYNC_OK=0
  echo "[$STAMP] ERROR: WEALTHFOLIO_BACKUP_S3_BUCKET is not set (see $CONFIG) -- no off-host copy for this run." >&2
elif [[ -n "$S3_BUCKET" ]]; then
  echo "[$STAMP] Syncing to s3://$S3_BUCKET/$S3_PREFIX/$STAMP/..."
  # A stale AWS_CA_BUNDLE in the environment (a path that doesn't exist) breaks
  # the CLI's SSL validation -- unset it just for this call.
  if env -u AWS_CA_BUNDLE aws s3 sync "$DEST" "s3://$S3_BUCKET/$S3_PREFIX/$STAMP/" --profile "$S3_PROFILE"; then
    echo "[$STAMP] Off-host copy complete."
  else
    SYNC_OK=0
    echo "[$STAMP] ERROR: S3 sync failed -- local backup is still good, but this run has no off-host copy." >&2
  fi
fi

find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -mtime "+${RETENTION_DAYS}" -print -exec rm -rf {} \;
echo "[$STAMP] Done."
# Fail the unit (after the local backup and pruning finished) so a missing
# off-host copy shows up in `systemctl --user --failed`, not only in the log.
[[ $SYNC_OK == 1 ]] || exit 1
