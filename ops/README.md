# Wealthfolio backup/restore

Backup and restore tooling for a self-hosted Wealthfolio deployment, kept
under `ops/` so it stays separate from upstream's own files. It assumes the
compose overlay in `compose.deploy.yml` and an untracked `.env.docker`.

## What gets backed up

- **The data volume** (`wealthfolio_wealthfolio-data`): the SQLite database,
  `profiles.json` and the encrypted secrets store.
- **`.env.docker` and `compose.deploy.yml`**, copied with the backup. The
  `WF_SECRET_KEY` in `.env.docker` is what decrypts the secrets store, so
  losing it makes the stored credentials unrecoverable.

The container is stopped for the copy so the SQLite file and its WAL are
consistent, and restarted even if the copy fails. Downtime is a few seconds.

## Where backups go

`$WEALTHFOLIO_BACKUP_ROOT`, default `${XDG_DATA_HOME:-~/.local/share}/backups/wealthfolio`,
one timestamped subdirectory per run. Anything older than
`$WEALTHFOLIO_BACKUP_RETENTION_DAYS` (default 7) is pruned.

Each run also syncs to `s3://$WEALTHFOLIO_BACKUP_S3_BUCKET/<timestamp>/` with
the AWS profile in `$WEALTHFOLIO_BACKUP_S3_PROFILE` (default `s3-backup`), which
should be an IAM user with only `PutObject`/`GetObject`/`ListBucket` on that
bucket and no `DeleteObject`, so a leaked key cannot wipe existing backups. Give
the bucket its own lifecycle rule; remote retention is independent of the local
one. The bucket name is personal config, so it is read from
`${XDG_CONFIG_HOME:-~/.config}/wealthfolio/backup.env`
(`WEALTHFOLIO_BACKUP_S3_BUCKET=...`); an empty value skips the sync and an unset
one fails the run. A sync failure logs an ERROR and the script exits 1 after the
local backup and pruning finish, so the unit shows up in
`systemctl --user --failed`.

## Scheduling

A systemd `--user` timer runs it daily at 03:30 (with jitter and
`Persistent=true`, so a missed run fires on next login). Enable lingering
(`loginctl enable-linger`) to have it run while logged out. Edit
`WorkingDirectory` and `ExecStart` in the service file to point at your clone,
and check that `aws` is on the unit's `PATH`, before installing:

```
cp ops/systemd/wealthfolio-backup.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now wealthfolio-backup.timer
```

Run it by hand, and always before bumping the pinned release, with
`ops/backup.sh`.

## Restoring

```
ops/restore.sh ~/.local/share/backups/wealthfolio/<timestamp>
```

This is destructive: it replaces the data volume's contents after a typed
confirmation. The backed-up config is left for a manual diff against the live
files. To test a backup without touching the live stack, extract the tarball
into a scratch volume in a separate compose project instead.
