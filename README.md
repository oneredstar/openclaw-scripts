# openclaw-scripts

Compact Mac shell utilities for installing, upgrading, resetting, backing up, and rolling back OpenClaw on local development machines.

The scripts assume the OpenClaw repository lives at `~/openclaw` and that OpenClaw data lives at `~/openclaw-data`.

## Available scripts

- `backup-data.sh` — copies `~/openclaw-data` to a timestamped folder under `~/openclaw-backups`. **Non-destructive**: it never removes or modifies the source data directory. Safe to run as often as you want.
- `reset-data.sh` — backs up, then removes, the data directory and re-creates an empty `config`/`workspace`/`auth-secrets` structure. Destructive (requires interactive confirmation unless `--yes` is passed).
- `upgrade-openclaw.sh` — backs up the active repo and data, pulls the latest changes (or the latest stable tag if detached), runs the Docker setup, restarts the stack, **and also upgrades the standalone OpenClaw node (`openclaw node run`) via `npm install -g openclaw@latest`**. The node is restarted in the background using `~/.openclaw-mac-node/node.env` for its environment; if that file is missing, only the gateway upgrade happens. Destructive (requires interactive confirmation unless `--yes` is passed).
- `reinstall-openclaw.sh` — backs up data and repo, tears down OpenClaw Docker containers/images/networks/volumes, removes `~/openclaw` and `~/.openclaw`, then clones the latest stable release and runs the Docker setup. Destructive (requires interactive confirmation unless `--yes` is passed).
- `rollback-openclaw.sh` — restores a previous repo backup (and matching data backup if present). Always snapshots the current state to a `pre-rollback-*` folder first, so a rollback is itself reversible. Destructive (requires interactive confirmation unless `--yes` is passed).

Every script writes its backups under `~/openclaw-backups` with timestamped names and verifies the backup against the source before touching the source.

## Common prerequisites

- macOS
- `git`
- `docker`
- access to the OpenClaw Docker setup flow in the main repo
- a login keychain that can be unlocked (only required for `reinstall-openclaw.sh`)

`upgrade-openclaw.sh` additionally expects `npm` (for the OpenClaw node upgrade) and a working OpenClaw node setup under `~/.openclaw-mac-node/` (created when the node was first launched); if the env file is missing, the node upgrade is skipped with a clear log message.

## Usage

```bash
cd ~/openclaw-scripts
./backup-data.sh                              # safe; no confirmation needed
./upgrade-openclaw.sh                         # prompts before destructive actions
./upgrade-openclaw.sh --yes                   # non-interactive (use from CI / automation)
./rollback-openclaw.sh 20260717-004530        # restore a specific backup
```

More detail on the recovery and maintenance flows lives in [docs/operations.md](docs/operations.md).

## Safety notes

- **Backups are never overwritten.** If a target backup path already exists, the script fails rather than clobbering it.
- **Destructive steps are gated on an interactive confirmation** that names the specific backup path being written and what will be removed. Pass `--yes` (or `-y`) to skip in automation.
- **The Docker compose `down` step never passes `--volumes`**, so named volumes defined in the compose file are preserved across upgrade/rollback. The install/uninstall flows remove only the explicit `openclaw_home` volume and any other volumes that match the OpenClaw naming filter.
- **`docker rmi` and `docker volume rm` are run without `-f`**, so unexpected "image in use" or "volume in use" errors surface instead of being silently forced.
- **Restore is atomic-style.** `rollback-openclaw.sh` moves the current directory aside before copying the backup in. If the copy fails, the original is moved back into place.
- **Node upgrades source `node.env` inside a subshell** so secrets like `OPENCLAW_GATEWAY_TOKEN` are scoped to the launched process and never written to the upgrade log. The node log is appended to `~/.openclaw-mac-node/node.log`.
