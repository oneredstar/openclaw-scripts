#!/usr/bin/env bash

# upgrade-openclaw.sh — back up data + repo, then pull the latest changes
# and restart the Docker compose stack. Destructive only in the sense that
# it restarts the running stack and overwrites the repo working tree; both
# are backed up first.

set -Eeuo pipefail
trap 'fail "Command failed at line $LINENO: $BASH_COMMAND"' ERR

export OPENCLAW_DATA_DIR="$HOME/openclaw-data"
export OPENCLAW_CONFIG_DIR="$OPENCLAW_DATA_DIR/config"
export OPENCLAW_WORKSPACE_DIR="$OPENCLAW_DATA_DIR/workspace"
export OPENCLAW_AUTH_PROFILE_SECRET_DIR="$OPENCLAW_DATA_DIR/auth-secrets"
export OPENCLAW_HOME_VOLUME="openclaw_home"

OPENCLAW_REPO_DIR="$HOME/openclaw"
OPENCLAW_BACKUP_ROOT="$HOME/openclaw-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Mac-side OpenClaw node (run via `openclaw node run`, configured by
# ~/.openclaw-mac-node/node.env). The upgrade script stops the running
# node, upgrades the npm package globally, and restarts the node.
OPENCLAW_NODE_ENV_FILE="$HOME/.openclaw-mac-node/node.env"
OPENCLAW_NODE_LOG="$HOME/.openclaw-mac-node/node.log"
OPENCLAW_NODE_DISPLAY_NAME="MacNode"
OPENCLAW_NODE_HOST="127.0.0.1"
OPENCLAW_NODE_PORT="18789"

YES=0

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

ensure_dir() {
    if [ ! -d "$1" ]; then
        log "Creating directory $1"
        mkdir -p "$1"
    fi
}

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--yes]

Upgrades the existing OpenClaw install by:
  1. Backing up data and the active repo to timestamped names under
     \$OPENCLAW_BACKUP_ROOT and verifying them.
  2. Stopping the current Docker compose stack (volumes preserved).
  3. Pulling the latest changes (or, if detached, the latest stable tag).
  4. Running the Docker setup and bringing the stack back up.
  5. Stopping the running OpenClaw node (if any), upgrading the global
     openclaw npm package, and restarting the node in the background
     (skipped if ~/.openclaw-mac-node/node.env is missing).

Options:
  -y, --yes    Skip the interactive confirmation prompt
  -h, --help   Show this help and exit
USAGE
}

entry_count() {
    find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ' | sed 's/^0$/0/'
}

verify_backup() {
    local src="$1"
    local backup="$2"

    [ -d "$backup" ] || fail "Backup verification failed: $backup was not created"

    local src_count backup_count
    src_count="$(entry_count "$src")"
    backup_count="$(entry_count "$backup")"

    if [ "$src_count" -ne "$backup_count" ]; then
        fail "Backup verification failed: $src has $src_count top-level entries but $backup has $backup_count"
    fi

    log "Backup verified: $backup_count top-level entries match $src"
}

confirm() {
    local prompt="$1"
    local expected="${2:-yes}"
    if [ "$YES" = "1" ]; then
        log "Confirmation skipped (--yes): $prompt"
        return 0
    fi
    if [ ! -t 0 ]; then
        fail "Refusing to proceed without an interactive terminal. Re-run with --yes to skip the confirmation prompt."
    fi
    printf '%s' "$prompt"
    local response
    read -r response
    if [ "$response" != "$expected" ]; then
        log "Aborted by user (expected '$expected', got '$response')"
        exit 1
    fi
}

backup_existing_data() {
    if [ -d "$OPENCLAW_DATA_DIR" ]; then
        ensure_dir "$OPENCLAW_BACKUP_ROOT"
        local backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-data-$TIMESTAMP"
        if [ -e "$backup_path" ]; then
            fail "Refusing to overwrite existing backup path: $backup_path"
        fi
        log "Backing up OpenClaw data to $backup_path"
        cp -a "$OPENCLAW_DATA_DIR" "$backup_path"
        verify_backup "$OPENCLAW_DATA_DIR" "$backup_path"
    else
        log "No OpenClaw data directory found at $OPENCLAW_DATA_DIR; skipping data backup"
    fi
}

backup_existing_repo() {
    if [ -d "$OPENCLAW_REPO_DIR" ]; then
        ensure_dir "$OPENCLAW_BACKUP_ROOT"
        local backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-repo-$TIMESTAMP"
        if [ -e "$backup_path" ]; then
            fail "Refusing to overwrite existing backup path: $backup_path"
        fi
        log "Backing up OpenClaw repo to $backup_path"
        cp -a "$OPENCLAW_REPO_DIR" "$backup_path"
        verify_backup "$OPENCLAW_REPO_DIR" "$backup_path"
    else
        fail "Expected OpenClaw repo at $OPENCLAW_REPO_DIR, but it was not found"
    fi
}

stop_current_stack() {
    if [ ! -d "$OPENCLAW_REPO_DIR" ]; then
        fail "Expected OpenClaw repo at $OPENCLAW_REPO_DIR, but it was not found"
    fi

    cd "$OPENCLAW_REPO_DIR"

    if docker compose config >/dev/null 2>&1; then
        log "Stopping current OpenClaw Docker compose stack (volumes preserved)"
        # No --volumes: the upgrade should not destroy the openclaw_home
        # volume or any other named volumes defined in the compose file.
        docker compose down --remove-orphans
    else
        fail "Could not find a usable docker compose configuration in $OPENCLAW_REPO_DIR"
    fi
}

update_repo() {
    cd "$OPENCLAW_REPO_DIR"

    log "Fetching latest changes"
    git fetch --all --tags --prune

    local current_branch
    current_branch="$(git branch --show-current)"

    if [ -n "$current_branch" ]; then
        log "Pulling latest changes for branch $current_branch"
        git pull --ff-only
        return
    fi

    local latest_tag
    latest_tag="$(git tag --list 'v*' --sort=-version:refname | grep -E '^v[0-9]+(\.[0-9]+)*$' | head -n 1)"

    if [ -z "$latest_tag" ]; then
        fail "Repository is detached and no stable release tag could be determined"
    fi

    log "Repository is detached; checking out latest stable release $latest_tag"
    git switch --detach "$latest_tag"
}

run_docker_setup() {
    cd "$OPENCLAW_REPO_DIR"
    log "Running Docker setup from the OpenClaw repo"
    ./scripts/docker/setup.sh
}

start_updated_stack() {
    cd "$OPENCLAW_REPO_DIR"
    log "Starting upgraded OpenClaw Docker compose stack"
    docker compose up -d
}

# Send SIGTERM to the running openclaw node (if any), wait briefly,
# and escalate to SIGKILL only if the process is still alive. Matches
# the `pkill -f "openclaw node"` pattern Nizam uses in his launch script.
stop_openclaw_node() {
    local pids
    # `pgrep -f` matches against the full command line. "openclaw node"
    # is the same pattern Nizam uses in his launch script.
    pids="$(pgrep -f "openclaw node" || true)"
    if [ -z "$pids" ]; then
        log "No running openclaw node found"
        return 0
    fi
    log "Stopping openclaw node (PIDs: $pids)"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 1
    if pgrep -f "openclaw node" >/dev/null 2>&1; then
        log "openclaw node did not exit after SIGTERM; sending SIGKILL"
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
        sleep 1
    fi
    if pgrep -f "openclaw node" >/dev/null 2>&1; then
        log "WARNING: openclaw node is still running; continuing anyway"
    fi
}

upgrade_openclaw_node() {
    if ! command -v npm >/dev/null 2>&1; then
        log "npm not found in PATH; skipping the OpenClaw node npm upgrade."
        log "Install Node.js / npm and re-run, or upgrade manually with: npm install -g openclaw@latest"
        return 0
    fi
    local npm_prefix
    npm_prefix="$(npm config get prefix 2>/dev/null || echo "unknown")"
    case "$npm_prefix" in
        /usr/*)
            log "npm global prefix is $npm_prefix (system location); sudo may be required."
            ;;
    esac
    log "Upgrading openclaw via 'npm install -g openclaw@latest'"
    # Inherit the existing PATH so npm can find its global bin dir.
    npm install -g openclaw@latest
    # Re-hash so a subsequent `command -v openclaw` sees the new binary.
    hash -r 2>/dev/null || true
}

start_openclaw_node() {
    if [ ! -f "$OPENCLAW_NODE_ENV_FILE" ]; then
        log "No node env file at $OPENCLAW_NODE_ENV_FILE; skipping node restart."
        log "Re-run your node command manually when ready, e.g.:"
        log "  pkill -f 'openclaw node' || true"
        log "  source ~/.openclaw-mac-node/node.env"
        log "  openclaw node run --host $OPENCLAW_NODE_HOST --port $OPENCLAW_NODE_PORT --display-name '$OPENCLAW_NODE_DISPLAY_NAME'"
        return 0
    fi
    if ! command -v openclaw >/dev/null 2>&1; then
        log "openclaw binary not found in PATH; cannot restart node."
        log "Run 'npm install -g openclaw@latest' (or fix PATH) and re-run your node command manually."
        return 0
    fi

    ensure_dir "$(dirname "$OPENCLAW_NODE_LOG")"
    log "Starting openclaw node in the background (display-name=$OPENCLAW_NODE_DISPLAY_NAME, log=$OPENCLAW_NODE_LOG)"
    # Source the env file inside a subshell so OPENCLAW_GATEWAY_TOKEN (and
    # any other secrets) stay scoped to the launched process. The values
    # are never echoed or written to the upgrade log.
    (
        set -a
        # shellcheck disable=SC1090
        . "$OPENCLAW_NODE_ENV_FILE"
        set +a
        nohup openclaw node run \
            --host "$OPENCLAW_NODE_HOST" \
            --port "$OPENCLAW_NODE_PORT" \
            --display-name "$OPENCLAW_NODE_DISPLAY_NAME" \
            >> "$OPENCLAW_NODE_LOG" 2>&1 &
        disown
    )
    sleep 1
    if pgrep -f "openclaw node" >/dev/null 2>&1; then
        log "OpenClaw node is running; tail $OPENCLAW_NODE_LOG to confirm startup."
    else
        log "WARNING: openclaw node did not appear in pgrep after launch; check $OPENCLAW_NODE_LOG"
    fi
}

print_rollback_notes() {
    local repo_backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-repo-$TIMESTAMP"
    local data_backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-data-$TIMESTAMP"

    log "Upgrade complete"
    log "Repo backup: $repo_backup_path"

    if [ -d "$data_backup_path" ]; then
        log "Data backup: $data_backup_path"
    fi

    log "To roll back, run:  $(basename "$0" | sed 's/upgrade/rollback/') --yes $TIMESTAMP"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)
                YES=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1 (use --help for usage)"
                ;;
        esac
    done

    require_command git
    require_command docker
    require_command cp

    [ -d "$OPENCLAW_REPO_DIR" ] || fail "Expected OpenClaw repo at $OPENCLAW_REPO_DIR, but it was not found"
    docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"

    log "Upgrade will:"
    log "  - back up data to   $OPENCLAW_BACKUP_ROOT/openclaw-data-$TIMESTAMP"
    log "  - back up repo to   $OPENCLAW_BACKUP_ROOT/openclaw-repo-$TIMESTAMP"
    log "  - stop the compose stack (volumes preserved)"
    log "  - stop the running openclaw node (if any)"
    log "  - pull the latest repo changes and run the Docker setup"
    log "  - upgrade the openclaw npm package globally (openclaw node)"
    log "  - start the upgraded stack and the upgraded node"
    confirm "Type 'upgrade' to continue: " "upgrade"

    backup_existing_data
    backup_existing_repo
    stop_current_stack
    stop_openclaw_node
    update_repo
    run_docker_setup
    upgrade_openclaw_node
    start_updated_stack
    start_openclaw_node
    print_rollback_notes
}

main "$@"
