# openclaw-scripts

Compact Mac shell utilities for installing, upgrading, resetting, backing up, and rolling back OpenClaw on local development machines.

The scripts assume the OpenClaw repository lives at `~/openclaw` and that OpenClaw data lives at `~/openclaw-data`.

Available scripts:

- `reinstall-openclaw.sh`: first-time or full reinstall flow
- `upgrade-openclaw.sh`: pulls the latest changes and restarts the Docker stack
- `reset-data.sh`: removes and reinitializes local OpenClaw data
- `backup-data.sh`: backs up and removes the data directory
- `rollback-openclaw.sh`: restores a previous repo/data backup

Every script writes backups under `~/openclaw-backups` before destructive actions.

Common prerequisites:

- macOS
- `git`
- `docker`
- a login keychain that can be unlocked
- access to the OpenClaw Docker setup flow in the main repo

Usage examples:

```bash
cd ~/openclaw-scripts
./reinstall-openclaw.sh
./upgrade-openclaw.sh
```

More detail on the recovery and maintenance flows lives in [docs/operations.md](docs/operations.md).
