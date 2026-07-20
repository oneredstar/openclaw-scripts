#!/usr/bin/env bash

# upgrade-openclaw.sh — back up data + repo + node version, then pull the
# latest changes and restart the Docker compose stack and the standalone
# OpenClaw node. Destructive only in the sense that it restarts the
# running stack/node and overwrites the repo working tree; everything is
# backed up first so rollback can restore any of it.

set -Eeuo pipefail
trap 'fail "Command failed at line $LINENO: $BASH_COMMAND"' ERR

export OPENCLAW_DATA_DIR="$HOME/.openclaw-data"
export OPENCLAW_CONFIG_DIR="$OPENCLAW_DATA_DIR/config"
export OPENCLAW_WORKSPACE_DIR="$OPENCLAW_DATA_DIR/workspace"
export OPENCLAW_AUTH_PROFILE_SECRET_DIR="$OPENCLAW_DATA_DIR/auth-secrets"
export OPENCLAW_HOME_VOLUME="openclaw_home"

OPENCLAW_REPO_DIR="$HOME/openclaw"
OPENCLAW_BACKUP_ROOT="$HOME/openclaw-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

YES=0

# Resolve this script's directory so we can source the shared node helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  1. Backing up data and the active repo (each gets a timestamped
     name under \$OPENCLAW_BACKUP_ROOT and is verified before anything
     is touched), and recording the currently installed openclaw npm
     package version as a sidecar file under \$OPENCLAW_BACKUP_ROOT
     so rollback can downgrade it later (not "verified": it is just
     the version string captured from npm before the upgrade).
  2. Stopping the current Docker compose stack (volumes preserved).
  3. Stopping the running OpenClaw node (if any).
  4. Pulling the latest changes (or, if detached, the latest stable tag).
  5. Running the Docker setup and bringing the stack back up.
  6. Upgrading the global openclaw npm package (openclaw node).
  7. Restarting the OpenClaw node in the background using
     ~/.openclaw-mac-node/node.env (skipped if that file is missing).

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

# shellcheck source=lib/openclaw-node.sh
source "$SCRIPT_DIR/lib/openclaw-node.sh"

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

# Capture the currently installed openclaw npm package version BEFORE we
# upgrade. The version is written to a sidecar file next to the data/repo
# backups so that rollback-openclaw.sh can downgrade the package back to
# what it was. Soft-fails (returns 0) when npm or openclaw isn't
# installed yet (e.g. on a fresh install) — in that case the rollback
# simply has nothing to downgrade.
backup_existing_node_version() {
    if ! command -v npm >/dev/null 2>&1; then
        log "npm not found in PATH; skipping pre-upgrade node version capture."
        return 0
    fi
    if ! command -v openclaw >/dev/null 2>&1; then
        log "openclaw binary not found in PATH; nothing to capture."
        return 0
    fi
    ensure_dir "$OPENCLAW_BACKUP_ROOT"
    local version_file="$OPENCLAW_BACKUP_ROOT/openclaw-node-$TIMESTAMP.version"
    if [ -e "$version_file" ]; then
        fail "Refusing to overwrite existing node version file: $version_file"
    fi
    # `npm ls -g openclaw --depth=0` prints something like:
    #   /path/to/global/lib
    #   └── openclaw@1.2.3
    # Pull the version token (the part after `@` on the matching line),
    # after stripping any ANSI colour codes.
    local current_version
    current_version="$(
        npm ls -g openclaw --depth=0 2>/dev/null \
            | sed $'s/\x1b\[[0-9;]*m//g' \
            | awk '/openclaw@/ {
                sub(/.*openclaw@/, "")
                sub(/[ \t)].*$/, "")
                print
                exit
            }'
    )"
    if [ -z "$current_version" ]; then
        log "Could not determine the currently installed openclaw npm version; node rollback will not be possible for the package."
        return 0
    fi
    printf '%s\n' "$current_version" > "$version_file"
    log "Saved pre-upgrade openclaw node version $current_version to $version_file"
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
    if git remote get-url origin >/dev/null 2>&1; then
        git fetch origin --tags --prune
    else
        log "Remote 'origin' not found; fetching from all remotes"
        git fetch --all --tags --prune
    fi

    local current_branch
    current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

    if [ -n "$current_branch" ]; then
        local upstream
        upstream="$(git for-each-ref --format='%(upstream:short)' "refs/heads/$current_branch")"

        if [ -n "$upstream" ]; then
            log "Pulling latest changes for branch $current_branch from $upstream"
            git pull --ff-only
            return
        fi

        if git show-ref --verify --quiet "refs/remotes/origin/$current_branch"; then
            log "Branch $current_branch has no upstream; fast-forwarding from origin/$current_branch"
            git merge --ff-only "origin/$current_branch"
            return
        fi

        fail "Branch $current_branch has no upstream and origin/$current_branch does not exist"
        return
    fi

    local latest_tag
    latest_tag="$(git tag --list 'v*' --sort=-version:refname | grep -E '^v[0-9]+(\.[0-9]+)*$' | head -n 1)"

    if [ -z "$latest_tag" ]; then
        fail "Repository is detached and no stable release tag could be determined"
    fi

    log "Repository is detached; checking out latest stable release $latest_tag"
    if git switch --detach "$latest_tag" >/dev/null 2>&1; then
        log "Checked out $latest_tag with git switch --detach"
    else
        git checkout --detach "$latest_tag"
        log "Checked out $latest_tag with git checkout --detach"
    fi
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
    # Soft-fail: if the install fails (EACCES, network, registry hiccup,
    # proxy issue, etc.) we still want the gateway upgrade to succeed.
    # The OpenClaw node will then start with the previously installed
    # npm-global version.
    if ! npm install -g openclaw@latest; then
        log "WARNING: 'npm install -g openclaw@latest' failed; the OpenClaw node will start with the previously installed version."
        log "Try manually:  npm install -g openclaw@latest"
        return 0
    fi
    # Re-hash so a subsequent `command -v openclaw` sees the new binary.
    hash -r 2>/dev/null || true
}

print_rollback_notes() {
    local repo_backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-repo-$TIMESTAMP"
    local data_backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-data-$TIMESTAMP"
    local node_version_file="$OPENCLAW_BACKUP_ROOT/openclaw-node-$TIMESTAMP.version"

    log "Upgrade complete"
    log "Repo backup:        $repo_backup_path"

    if [ -d "$data_backup_path" ]; then
        log "Data backup:        $data_backup_path"
    fi

    if [ -f "$node_version_file" ]; then
        log "Node version file:  $node_version_file"
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
    log "  - back up data to        $OPENCLAW_BACKUP_ROOT/openclaw-data-$TIMESTAMP"
    log "  - back up repo to        $OPENCLAW_BACKUP_ROOT/openclaw-repo-$TIMESTAMP"
    log "  - capture the currently installed openclaw npm version"
    log "  - stop the compose stack (volumes preserved)"
    log "  - stop the running openclaw node (if any)"
    log "  - pull the latest repo changes and run the Docker setup"
    log "  - upgrade the openclaw npm package globally (openclaw node)"
    log "  - start the upgraded stack and the upgraded node"
    confirm "Type 'upgrade' to continue: " "upgrade"

    backup_existing_data
    backup_existing_repo
    backup_existing_node_version
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
