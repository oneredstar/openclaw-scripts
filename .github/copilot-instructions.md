# Copilot Instructions for openclaw-scripts

When editing this repo:

- Keep the scripts bash-first and reliably defensive: `set -Eeuo pipefail` should remain the default.
- Prefer the existing helper patterns: `log`, `fail`, `require_command`, `ensure_dir`, `confirm`, `verify_backup`, and `replace_with_backup` (the latter only in `rollback-openclaw.sh`).
- Do not change the default path constants unless every script that depends on them is updated together.
- Keep destructive order safe: back up before removing data, repos, or volumes.
- Every backup is verified against the source (top-level entry count) before the source is touched.
- Backups are never overwritten: if the target backup path already exists, the script must fail rather than clobber it.
- Destructive operations are gated on a typed confirmation that names the exact backup path. Scripts must accept `--yes`/`-y` to skip the prompt, and must refuse to run without a TTY when `--yes` is not set.
- Do not pass `--volumes` to `docker compose down`. Named volumes defined in the compose file are removed only by the explicit volume cleanup in `reinstall-openclaw.sh`.
- Do not use `-f` on `docker rmi` or `docker volume rm`. Unexpected "image in use" or "volume in use" errors must surface.
- The Docker resource filter (images, networks, volumes) must be narrow: only `openclaw`, `openclaw-...`, `openclaw/...`, or `.../openclaw[-/:]...`. Third-party resources that merely contain the substring "openclaw" must be left alone.
- `backup-data.sh` is non-destructive. It must never remove or modify the source data directory.
- When changing a workflow, update the README and `docs/operations.md` in the same PR.
- Prefer small, explicit changes over broad refactors so the maintenance flow stays easy to audit.

Commit messages and PR descriptions should call out user-facing behavior changes, backup implications, or recovery steps.
