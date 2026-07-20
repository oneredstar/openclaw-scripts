#!/usr/bin/env bash

# rollback-openclaw.sh — restore a previous repo (and optional data)
# backup, and downgrade the npm-global openclaw package to the version
# captured by upgrade-openclaw.sh before that upgrade. Always backs up
# the current state to a pre-rollback-* name first, so the rollback is
# itself reversible.

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
BACKUP_ID=""
SKIP_NODE=0

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
Usage: $(basename "$0") [--yes] [--skip-node] [backup_id]

Restores a previous OpenClaw repo backup. If backup_id is omitted, the
most recent repo backup is selected.

The current state is always preserved first as a pre-rollback-* backup,
so the rollback is itself reversible.

The matching data backup (openclaw-data-<backup_id>) is restored if it
exists; if no matching data backup is found, the current data directory
is left in place.

If the matching node version file (openclaw-node-<backup_id>.version) is
present, the global openclaw npm package is also downgraded to that
version (unless --skip-node is given), and the OpenClaw node is
restarted in the background using ~/.openclaw-mac-node/node.env.

Options:
  -y, --yes       Skip the interactive confirmation prompt
      --skip-node Do not touch the OpenClaw node (npm package or process)
  -h, --help      Show this help and exit
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

latest_repo_backup() {
    local latest_path
    latest_path="$(find "$OPENCLAW_BACKUP_ROOT" -maxdepth 1 -type d -name 'openclaw-repo-*' -print | sort | tail -n 1)"
    [ -n "$latest_path" ] || fail "No repo backups were found in $OPENCLAW_BACKUP_ROOT"
    printf '%s\n' "${latest_path##*/openclaw-repo-}"
}

resolve_backup_id() {
    if [ -n "$BACKUP_ID" ]; then
        printf '%s\n' "$BACKUP_ID"
        return
    fi

    latest_repo_backup
}

backup_current_state() {
    ensure_dir "$OPENCLAW_BACKUP_ROOT"

    if [ -d "$OPENCLAW_REPO_DIR" ]; then
        local repo_backup_path="$OPENCLAW_BACKUP_ROOT/pre-rollback-repo-$TIMESTAMP"
        if [ -e "$repo_backup_path" ]; then
            fail "Refusing to overwrite existing backup path: $repo_backup_path"
        fi
        log "Backing up current repo to $repo_backup_path"
        cp -a "$OPENCLAW_REPO_DIR" "$repo_backup_path"
        verify_backup "$OPENCLAW_REPO_DIR" "$repo_backup_path"
    else
        log "No current repo found at $OPENCLAW_REPO_DIR; skipping current repo backup"
    fi

    if [ -d "$OPENCLAW_DATA_DIR" ]; then
        local data_backup_path="$OPENCLAW_BACKUP_ROOT/pre-rollback-data-$TIMESTAMP"
        if [ -e "$data_backup_path" ]; then
            fail "Refusing to overwrite existing backup path: $data_backup_path"
        fi
        log "Backing up current data to $data_backup_path"
        cp -a "$OPENCLAW_DATA_DIR" "$data_backup_path"
        verify_backup "$OPENCLAW_DATA_DIR" "$data_backup_path"
    else
        log "No current data directory found at $OPENCLAW_DATA_DIR; skipping current data backup"
    fi
}

stop_current_stack() {
    if [ ! -d "$OPENCLAW_REPO_DIR" ]; then
        log "No current repo found at $OPENCLAW_REPO_DIR; skipping docker compose down"
        return
    fi

    cd "$OPENCLAW_REPO_DIR"

    if docker compose config >/dev/null 2>&1; then
        log "Stopping current OpenClaw Docker compose stack (volumes preserved)"
        # No --volumes: rollback should not destroy the openclaw_home
        # volume or any other named volumes the compose file references.
        docker compose down --remove-orphans
    else
        log "No usable docker compose configuration found in $OPENCLAW_REPO_DIR; skipping docker compose down"
    fi
}

# Replace $1 (current path) with a copy of $2 (backup path). To minimize the
# window where neither the old nor the new state is in place, move the old
# state out of the way first, then copy the backup in. If the copy fails,
# move the old state back into place.
replace_with_backup() {
    local current="$1"
    local source="$2"
    local safenest

    safenest="${current}.pre-restore.$$.$(date +%s)"

    if [ -e "$current" ] || [ -L "$current" ]; then
        if ! mv "$current" "$safenest"; then
            fail "Could not move $current aside to $safenest; aborting before any changes are made"
        fi
    fi

    if ! cp -a "$source" "$current"; then
        log "Restore from $source failed"
        if [ -e "$safenest" ]; then
            mv "$safenest" "$current"
            log "Restored original $current from safenest"
            fail "Aborted; original $current has been put back in place"
        fi
        fail "Aborted; $current could not be created from $source"
    fi

    if [ -e "$safenest" ]; then
        rm -rf "$safenest"
    fi
}

restore_repo_backup() {
    local backup_id="$1"
    local repo_backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-repo-$backup_id"

    [ -d "$repo_backup_path" ] || fail "Repo backup not found: $repo_backup_path"
    [ -n "$(ls -A "$repo_backup_path" 2>/dev/null)" ] || fail "Repo backup is empty: $repo_backup_path"

    log "Restoring repo backup from $repo_backup_path (current state is in pre-rollback-*)"
    replace_with_backup "$OPENCLAW_REPO_DIR" "$repo_backup_path"
}

restore_data_backup() {
    local backup_id="$1"
    local data_backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-data-$backup_id"

    if [ ! -d "$data_backup_path" ]; then
        log "No matching data backup found at $data_backup_path; leaving current data directory unchanged"
        return
    fi

    log "Restoring data backup from $data_backup_path (current state is in pre-rollback-data-*)"
    replace_with_backup "$OPENCLAW_DATA_DIR" "$data_backup_path"
}

# Downgrade the npm-global openclaw package to the version captured by
# upgrade-openclaw.sh at backup_id. Reads openclaw-node-<backup_id>.version.
# Soft-fails when the version file is missing or empty (e.g. the upgrade
# was performed manually or the version could not be captured) so the
# gateway rollback still proceeds.
rollback_openclaw_node() {
    if [ "$SKIP_NODE" = "1" ]; then
        log "Skipping OpenClaw node rollback (--skip-node)"
        return 0
    fi

    local backup_id="$1"
    local version_file="$OPENCLAW_BACKUP_ROOT/openclaw-node-$backup_id.version"

    if [ ! -f "$version_file" ]; then
        log "No saved pre-upgrade node version at $version_file; cannot downgrade the npm-global openclaw package automatically."
        log "If you know the previous version, run:  npm install -g openclaw@<version>"
        return 0
    fi

    if ! command -v npm >/dev/null 2>&1; then
        # Soft-fail: node rollback is optional. The gateway rollback has
        # already succeeded at this point; failing it because npm is
        # missing would be too strict. Leave a clear hint to either
        # downgrade manually or re-run with --skip-node to skip this.
        log "WARNING: npm not found in PATH; cannot downgrade the openclaw npm package automatically."
        log "Re-run with --skip-node to skip the node side, or downgrade manually:  npm install -g openclaw@$previous_version"
        return 0
    fi

    local previous_version
    previous_version="$(tr -d '[:space:]' < "$version_file")"
    if [ -z "$previous_version" ]; then
        log "Version file $version_file is empty; cannot roll back the npm-global openclaw package."
        return 0
    fi

    local npm_prefix
    npm_prefix="$(npm config get prefix 2>/dev/null || echo "unknown")"
    case "$npm_prefix" in
        /usr/*)
            log "npm global prefix is $npm_prefix (system location); sudo may be required for the downgrade."
            ;;
    esac

    log "Rolling back openclaw npm package to $previous_version (from $version_file)"
    # Soft-fail the downgrade for the same reasons as upgrade_openclaw_node:
    # EACCES, network, registry hiccup, etc. must not undo a successful
    # gateway rollback.
    if ! npm install -g "openclaw@$previous_version"; then
        log "WARNING: 'npm install -g openclaw@$previous_version' failed; the OpenClaw node may start with the previous package version."
        log "Try manually:  npm install -g openclaw@$previous_version"
        return 0
    fi
    hash -r 2>/dev/null || true
    log "Downgraded openclaw npm package to $previous_version"
}

start_restored_stack() {
    cd "$OPENCLAW_REPO_DIR"

    if docker compose config >/dev/null 2>&1; then
        log "Starting restored OpenClaw Docker compose stack"
        docker compose up -d
    else
        fail "Could not find a usable docker compose configuration in restored repo $OPENCLAW_REPO_DIR"
    fi
}

print_summary() {
    local backup_id="$1"

    log "Rollback complete"
    log "Restored repo backup:    $OPENCLAW_BACKUP_ROOT/openclaw-repo-$backup_id"
    if [ -d "$OPENCLAW_BACKUP_ROOT/openclaw-data-$backup_id" ]; then
        log "Restored data backup:    $OPENCLAW_BACKUP_ROOT/openclaw-data-$backup_id"
    fi
    log "Pre-rollback repo:       $OPENCLAW_BACKUP_ROOT/pre-rollback-repo-$TIMESTAMP"
    if [ -d "$OPENCLAW_BACKUP_ROOT/pre-rollback-data-$TIMESTAMP" ]; then
        log "Pre-rollback data:       $OPENCLAW_BACKUP_ROOT/pre-rollback-data-$TIMESTAMP"
    fi
    if [ "$SKIP_NODE" = "0" ] && [ -f "$OPENCLAW_BACKUP_ROOT/openclaw-node-$backup_id.version" ]; then
        log "Restored node version:   $(tr -d '[:space:]' < "$OPENCLAW_BACKUP_ROOT/openclaw-node-$backup_id.version")"
    fi
    log "To undo this rollback, run:  $(basename "$0") --yes $TIMESTAMP"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)
                YES=1
                shift
                ;;
            --skip-node)
                SKIP_NODE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                fail "Unknown argument: $1 (use --help for usage)"
                ;;
            *)
                if [ -n "$BACKUP_ID" ]; then
                    fail "Only one backup_id may be provided"
                fi
                BACKUP_ID="$1"
                shift
                ;;
        esac
    done

    require_command docker
    require_command cp
    require_command find
    docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"

    BACKUP_ID="$(resolve_backup_id)"

    log "Rollback will restore:"
    log "  repo backup:   $OPENCLAW_BACKUP_ROOT/openclaw-repo-$BACKUP_ID"
    if [ -d "$OPENCLAW_BACKUP_ROOT/openclaw-data-$BACKUP_ID" ]; then
        log "  data backup:   $OPENCLAW_BACKUP_ROOT/openclaw-data-$BACKUP_ID"
    else
        log "  data backup:   (no matching data backup; current data left in place)"
    fi
    if [ "$SKIP_NODE" = "0" ]; then
        if [ -f "$OPENCLAW_BACKUP_ROOT/openclaw-node-$BACKUP_ID.version" ]; then
            local_version="$(tr -d '[:space:]' < "$OPENCLAW_BACKUP_ROOT/openclaw-node-$BACKUP_ID.version")"
            log "  node version:  downgrade npm-global openclaw to $local_version"
        else
            log "  node version:  (no matching node version file; node rollback will be skipped)"
        fi
    else
        log "  node version:  (--skip-node; node side untouched)"
    fi
    log "Pre-rollback backups will be written as pre-rollback-*-$TIMESTAMP."
    confirm "Type 'rollback' to continue: " "rollback"

    backup_current_state
    stop_current_stack
    restore_repo_backup "$BACKUP_ID"
    restore_data_backup "$BACKUP_ID"
    if [ "$SKIP_NODE" = "0" ]; then
        stop_openclaw_node
        rollback_openclaw_node "$BACKUP_ID"
    fi
    start_restored_stack
    if [ "$SKIP_NODE" = "0" ]; then
        start_openclaw_node
    fi
    print_summary "$BACKUP_ID"
}

main "$@"
