# Copilot Instructions for openclaw-scripts

When editing this repo:

- Never run the OpenClaw maintenance scripts as a test (`backup-data.sh`, `reset-data.sh`, `upgrade-openclaw.sh`, `rollback-openclaw.sh`, `reinstall-openclaw.sh`), because they can affect a live local OpenClaw install. Validate changes by static review and shell linting only.
- Keep the scripts bash-first and reliably defensive: `set -Eeuo pipefail` should remain the default.
- Prefer the existing helper patterns: `log`, `fail`, `require_command`, `ensure_dir`, `confirm`, `verify_backup`, and `replace_with_backup` (the latter only in `rollback-openclaw.sh`).
- Keep default paths aligned across scripts: gateway data at `~/.openclaw-data`, standalone node at `~/.openclaw-mac-node`, and repo at `~/openclaw`.
- In `reinstall-openclaw.sh`, back up both gateway data (`~/.openclaw-data`) and standalone node data (`~/.openclaw-mac-node`) before destructive cleanup.
- In `reinstall-openclaw.sh`, destructive cleanup must remove `~/.openclaw-mac-node`, `~/openclaw`, and `~/.openclaw-data` for a true fresh install.
- Keep destructive order safe: back up before removing data, repos, or volumes.
- Every backup is verified against the source (top-level entry count) before the source is touched.
- Backups are never overwritten: if the target backup path already exists, the script must fail rather than clobber it.
- Destructive operations are gated on a typed confirmation that names the exact backup path. Scripts must accept `--yes`/`-y` to skip the prompt, and must refuse to run without a TTY when `--yes` is not set.
- Do not pass `--volumes` to `docker compose down`. Named volumes defined in the compose file are removed only by the explicit volume cleanup in `reinstall-openclaw.sh`.
- Do not use `-f` on `docker rmi` or `docker volume rm`. Unexpected "image in use" or "volume in use" errors must surface.
- The Docker resource filter (images, networks, volumes) must be narrow: only `openclaw`, `openclaw-...`, `openclaw/...`, or `.../openclaw[-/:]...`. Third-party resources that merely contain the substring "openclaw" must be left alone.
- `backup-data.sh` is non-destructive. It must never remove or modify the source data directory.
- `upgrade-openclaw.sh` upgrades both the Docker-side gateway and the standalone OpenClaw node. The node side: stop running `openclaw node` processes by `pgrep -f`, then `npm install -g openclaw@latest`, then restart the node in the background using `~/.openclaw-mac-node/node.env` and the argv from Nizam's launch script (`--host 127.0.0.1 --port 18789 --display-name "MacNode"`). The env file must be sourced inside a subshell so `OPENCLAW_GATEWAY_TOKEN` and similar secrets are never echoed or written to the upgrade log. The node log goes to `~/.openclaw-mac-node/node.log`. Node-upgrade steps must be soft-fail (log + return 0) so a missing `node.env` or missing `npm` does not abort an otherwise-successful gateway upgrade.
- When changing a workflow, update the README and `docs/operations.md` in the same PR.
- Prefer small, explicit changes over broad refactors so the maintenance flow stays easy to audit.

Commit messages and PR descriptions should call out user-facing behavior changes, backup implications, or recovery steps.
