# Copilot Instructions for openclaw-scripts

When editing this repo:

- Keep the scripts bash-first and reliably defensive: `set -Eeuo pipefail` should remain the default.
- Prefer the existing helper patterns: `log`, `fail`, `require_command`, `ensure_dir`, and backup helpers.
- Do not change the default path constants unless every script that depends on them is updated together.
- Keep destructive order safe: back up before removing data, repos, or volumes.
- When changing a workflow, update the README and any relevant docs in the same PR.
- Prefer small, explicit changes over broad refactors so the maintenance flow stays easy to audit.

Commit messages and PR descriptions should call out user-facing behavior changes, backup implications, or recovery steps.
