# OpenClaw Script Operations

This repository contains a small set of macOS shell utilities for maintaining an OpenClaw installation.

## Common flows

### 1. First-time or full reinstall

- Use `reinstall-openclaw.sh` when the local installation needs to be replaced entirely.
- The script backs up both the data directory and the local repo (with verification), then cleans up the OpenClaw Docker containers, images, networks, and volumes, removes the local clone and `~/.openclaw`, and clones the latest stable release before running the Docker setup.
- It requires an interactive login keychain unlock.
- By default the script prints what it is about to do and asks for typed confirmation before any destructive step. Pass `--yes` to skip the prompt for automation.

### 2. Normal upgrade

- Use `upgrade-openclaw.sh` when the existing installation should be updated and restarted.
- The script backs up the data directory and the active repo (with verification), stops the current Docker compose stack without removing volumes, fetches the latest changes, runs the Docker setup, and brings the stack back up.
- If the repo is detached, the script resets to the latest stable tag.
- **The standalone OpenClaw node is also upgraded.** The script stops the running `openclaw node` process (matched by `pgrep -f "openclaw node"`), runs `npm install -g openclaw@latest`, and restarts the node in the background with environment from `~/.openclaw-mac-node/node.env` and the same argv Nizam uses in his launch script (`--host 127.0.0.1 --port 18789 --display-name "MacNode"`). The node log is written to `~/.openclaw-mac-node/node.log`. If `node.env` is missing, the node upgrade is skipped with a clear log message and the gateway upgrade proceeds.
- `npm install -g` may need `sudo` if the npm global prefix is under `/usr/...`; the script logs a heads-up when it detects that path.
- The script asks for typed confirmation before destructive steps; pass `--yes` to skip.

### 3. Data reset

- Use `reset-data.sh` when you only need a fresh `config`, `workspace`, and `auth-secrets` structure at `~/openclaw-data`.
- The script backs up the existing data (and verifies it) before removing the source and recreating the standard subdirectories.
- The script asks for typed confirmation before destructive steps; pass `--yes` to skip.

### 4. Data backup

- Use `backup-data.sh` when you only need the backup without touching the original directory.
- **This script is non-destructive.** It copies the data directory to a timestamped folder under `~/openclaw-backups` and verifies the copy; the source is left untouched.
- Safe to run as often as you want. Each run writes a new timestamped backup; existing backup paths are never overwritten.

### 5. Rollback

- Use `rollback-openclaw.sh` to restore a previous repo and optional data backup.
- Pass a backup ID (the timestamp suffix of `openclaw-repo-<id>`) explicitly or leave it empty to pick the latest repo backup.
- Before restoring, the script always writes a `pre-rollback-repo-<timestamp>` and (if data exists) `pre-rollback-data-<timestamp>` snapshot of the current state. The rollback is itself reversible.
- The restore is atomic-style: the current directory is moved aside before the backup is copied in. If the copy fails, the original is moved back into place.
- The script asks for typed confirmation before destructive steps; pass `--yes` to skip.

## Backup file naming

- `openclaw-data-*` — data backups written by `backup-data.sh`, `reset-data.sh`, `upgrade-openclaw.sh`, and `reinstall-openclaw.sh`.
- `openclaw-repo-*` — repo backups written by `upgrade-openclaw.sh` and `reinstall-openclaw.sh`.
- `pre-rollback-*` — temporary snapshots of the current state taken at the start of a rollback. The rollback flow itself is reversible by running `rollback-openclaw.sh` again with the `pre-rollback-*` timestamp.

## Defensive patterns to preserve

- **Back up before destruction.** Every script that removes a directory copies it to `~/openclaw-backups` first.
- **Verify the backup before destroying the source.** Each backup is checked against the source (top-level entry count match) before any `rm -rf` runs.
- **Never overwrite a backup path.** If the target path already exists, the script fails rather than clobbering an earlier copy.
- **Destructive steps are gated on a typed confirmation** that names the exact backup path being written and what will be removed. `--yes`/`-y` skips the prompt for automation.
- **Destructive steps without `--yes` require a TTY.** Non-interactive invocations must opt in explicitly with `--yes`.
- **Do not pass `--volumes` to `docker compose down`.** Named volumes defined in the compose file are removed only by the explicit volume cleanup in `reinstall-openclaw.sh`, which uses a narrow name filter.
- **Do not use `-f` on `docker rmi` or `docker volume rm`.** Unexpected "image in use" or "volume in use" errors should surface so the operator can investigate.
- **Narrow the Docker resource filter** to images/networks/volumes whose name is exactly `openclaw` or starts with `openclaw-`, `openclaw/`, or `openclaw:` (or namespaced equivalents like `.../openclaw-...`). Third-party images that merely contain the substring "openclaw" elsewhere are left alone.
- **Update the README and these docs** when behavior changes.
