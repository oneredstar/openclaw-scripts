# OpenClaw Script Operations

This repository contains a small set of macOS shell utilities for maintaining an OpenClaw installation.

Common flows:

1. First-time or full reinstall

- Use `reinstall-openclaw.sh` when the local installation needs to be replaced entirely.
- The script backs up the existing data directory, cleans up leftover Docker containers, images, networks, and volumes, clones the latest stable OpenClaw release, then runs the Docker setup.
- It requires an interactive login keychain unlock.

2. Normal upgrade

- Use `upgrade-openclaw.sh` when the existing installation should be updated and restarted.
- The script backs up both the data directory and the active repo, fetches the latest changes, runs the Docker setup, and brings the stack back up.
- If the repo is detached, the script resets to the latest stable tag.

3. Data reset

- Use `reset-data.sh` when you only need a fresh `config`, `workspace`, and `auth-secrets` structure at `~/openclaw-data`.
- The script backs up any existing data before removing it and recreates the directories.

4. Data backup

- Use `backup-data.sh` when you only need the backup without touching the original directory.
- The backup is stored under `~/openclaw-backups` with a timestamped name.

5. Rollback

- Use `rollback-openclaw.sh` to restore a previous repo and optional data backup.
- Pass a backup ID explicitly or leave it empty to pick the latest repo backup.
- The script stops the current Docker compose stack, restores the backup, and starts the restored stack.

Backup file naming:

- `openclaw-data-*` for data backups
- `openclaw-repo-*` for repo backups
- `pre-rollback-*` for the temporary copies created during rollback

Defensive patterns to preserve:

- Back up before destruction.
- Do not remove the user's current data until the backup has been verified.
- Clean up Docker artifacts only when the OpenClaw repo is the active target.
- Update the README and Copilot instructions when behavior changes.
