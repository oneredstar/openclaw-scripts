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
    log "  - pull the latest changes and run the Docker setup"
    log "  - start the upgraded stack"
    confirm "Type 'upgrade' to continue: " "upgrade"

    backup_existing_data
    backup_existing_repo
    stop_current_stack
    update_repo
    run_docker_setup
    start_updated_stack
    print_rollback_notes
}

main "$@"
