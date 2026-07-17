# shellcheck shell=bash
# lib/openclaw-node.sh — shared helpers for the standalone OpenClaw node
# (the `openclaw node run` process started by Nizam's launch script under
# ~/.openclaw-mac-node/). Sourced by both upgrade-openclaw.sh and
# rollback-openclaw.sh.
#
# Sourced scripts must define `log` and `ensure_dir` BEFORE sourcing this
# file. The OPENCLAW_NODE_* constants can be overridden by setting them in
# the environment before sourcing.

# Mac-side OpenClaw node config (matches Nizam's launch script).
: "${OPENCLAW_NODE_ENV_FILE:=$HOME/.openclaw-mac-node/node.env}"
: "${OPENCLAW_NODE_LOG:=$HOME/.openclaw-mac-node/node.log}"
: "${OPENCLAW_NODE_DISPLAY_NAME:=MacNode}"
: "${OPENCLAW_NODE_HOST:=127.0.0.1}"
: "${OPENCLAW_NODE_PORT:=18789}"
export OPENCLAW_NODE_ENV_FILE OPENCLAW_NODE_LOG OPENCLAW_NODE_DISPLAY_NAME OPENCLAW_NODE_HOST OPENCLAW_NODE_PORT

# Send SIGTERM to the running openclaw node (if any), wait briefly, and
# escalate to SIGKILL only if the process is still alive. Matches the
# `pkill -f "openclaw node"` pattern Nizam uses in his launch script.
stop_openclaw_node() {
    local pids
    pids="$(pgrep -f "openclaw node" || true)"
    if [ -z "$pids" ]; then
        log "No running openclaw node found"
        return 0
    fi
    log "Stopping openclaw node (PIDs: $pids)"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 1
    # Re-grep for any survivors (the PID set may have changed since the
    # first check: a respawn, a child we missed, etc.). Use the FRESH
    # PID list for the SIGKILL escalation rather than the stale one,
    # so we don't leave a still-running node that could collide on
    # port when we try to start the upgraded one.
    local survivors
    survivors="$(pgrep -f "openclaw node" || true)"
    if [ -n "$survivors" ]; then
        log "openclaw node did not exit after SIGTERM; sending SIGKILL (PIDs: $survivors)"
        # shellcheck disable=SC2086
        kill -9 $survivors 2>/dev/null || true
        sleep 1
    fi
    if pgrep -f "openclaw node" >/dev/null 2>&1; then
        log "WARNING: openclaw node is still running after SIGKILL; continuing anyway"
    fi
}

# Start the openclaw node in the background using ~/.openclaw-mac-node/node.env
# for its environment. The env file is sourced inside a subshell so
# OPENCLAW_GATEWAY_TOKEN (and any other secrets) stay scoped to the launched
# process and are never echoed into the calling script's log.
#
# Returns 0 even on soft failures (missing env file / missing binary), so a
# caller whose primary job is the gateway upgrade isn't aborted by node
# setup problems.
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
        log "Run 'npm install -g openclaw@<version>' (or fix PATH) and re-run your node command manually."
        return 0
    fi

    ensure_dir "$(dirname "$OPENCLAW_NODE_LOG")"
    log "Starting openclaw node in the background (display-name=$OPENCLAW_NODE_DISPLAY_NAME, log=$OPENCLAW_NODE_LOG)"
    # Disable errexit/pipefail/errexit-trace inside the subshell so that
    # any failure while sourcing node.env, or a `disown` returning
    # non-zero in a non-interactive shell (no job control), does not
    # abort the parent upgrade/rollback. Node steps are soft-fail by
    # contract; the post-launch pgrep below reports whether it actually
    # came up.
    (
        set +e
        set +o pipefail
        set +E
        set -a
        # shellcheck disable=SC1090
        . "$OPENCLAW_NODE_ENV_FILE"
        set +a
        nohup openclaw node run \
            --host "$OPENCLAW_NODE_HOST" \
            --port "$OPENCLAW_NODE_PORT" \
            --display-name "$OPENCLAW_NODE_DISPLAY_NAME" \
            >> "$OPENCLAW_NODE_LOG" 2>&1 &
        # Best-effort: disown may fail when job control is disabled
        # (non-interactive shells); the background `&` is enough to
        # detach either way.
        disown 2>/dev/null || true
    ) || true
    sleep 1
    if pgrep -f "openclaw node" >/dev/null 2>&1; then
        log "OpenClaw node is running; tail $OPENCLAW_NODE_LOG to confirm startup."
    else
        log "WARNING: openclaw node did not appear in pgrep after launch; check $OPENCLAW_NODE_LOG"
    fi
}
