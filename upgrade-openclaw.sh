#!/usr/bin/env bash

set -Eeuo pipefail
trap 'fail "Command failed at line $LINENO: $BASH_COMMAND"' ERR

export OPENCLAW_DATA_DIR="$HOME/openclaw-data"
export OPENCLAW_CONFIG_DIR="$OPENCLAW_DATA_DIR/config"
export OPENCLAW_WORKSPACE_DIR="$OPENCLAW_DATA_DIR/workspace"
export OPENCLAW_AUTH_PROFILE_SECRET_DIR="$OPENCLAW_DATA_DIR/auth-secrets"
export OPENCLAW_HOME_VOLUME="openclaw_home"

OPENCLAW_REPO_DIR="$HOME/openclaw"
OPENCLAW_REPO_URL="https://github.com/openclaw/openclaw.git"
OPENCLAW_BACKUP_ROOT="$HOME/openclaw-backups"
OPENCLAW_TEST_DATA_DIR="$HOME/openclaw-test-data"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

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

backup_existing_data() {
    if [ -d "$OPENCLAW_DATA_DIR" ]; then
        ensure_dir "$OPENCLAW_BACKUP_ROOT"
        local backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-data-$TIMESTAMP"
        log "Backing up OpenClaw data to $backup_path"
        cp -R "$OPENCLAW_DATA_DIR" "$backup_path"
    else
        log "No OpenClaw data directory found at $OPENCLAW_DATA_DIR; skipping data backup"
    fi
}

backup_existing_repo() {
    if [ -d "$OPENCLAW_REPO_DIR" ]; then
        ensure_dir "$OPENCLAW_BACKUP_ROOT"
        local backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-repo-$TIMESTAMP"
        log "Backing up OpenClaw repo to $backup_path"
        cp -R "$OPENCLAW_REPO_DIR" "$backup_path"
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
        log "Stopping current OpenClaw Docker compose stack"
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

    log "If you need to roll back, stop the upgraded stack, switch to the repo backup, and run docker compose up there."
}

main() {
    require_command git
    require_command docker
    require_command cp

    [ -d "$OPENCLAW_REPO_DIR" ] || fail "Expected OpenClaw repo at $OPENCLAW_REPO_DIR, but it was not found"
    docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"

    backup_existing_data
    backup_existing_repo
    stop_current_stack
    update_repo
    run_docker_setup
    start_updated_stack
    print_rollback_notes
}

main "$@"
