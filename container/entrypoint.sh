#!/bin/bash
# Container entrypoint (root): sshd + tmux session running Claude Code + HTTP injector.
set -euo pipefail

USER_NAME=claude
HOME_DIR=/home/claude
HOSTKEY_DIR=/etc/ssh/hostkeys

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# Empty optional variables must not look "configured" to claude or the scripts.
while IFS= read -r name; do
    unset "$name"
done < <(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=$/\1/p')

# ---- shared config for inject/peek/attach and inject-server -------------------------------
cat > /etc/claude-container.conf <<CONF
TMUX_SESSION=claude
TMUX_TARGET=claude:claude.0
INJECT_EXPECT_CMD=${INJECT_EXPECT_CMD-claude}
INJECT_ENTER_DELAY=${INJECT_ENTER_DELAY:-0.5}
CONF

# sshd hands a login shell a clean environment, so the settings that shape the claude command
# must travel through this file too: otherwise a session restarted by "attach" over SSH would
# use different flags than the one the entrypoint starts.
{
    printf 'CLAUDE_WORKDIR=%q\n'          "${CLAUDE_WORKDIR:-/workspace}"
    printf 'CLAUDE_CONFIG_DIR=%q\n'       "${CLAUDE_CONFIG_DIR:-$HOME_DIR/.claude}"
    printf 'CLAUDE_SKIP_PERMISSIONS=%q\n' "${CLAUDE_SKIP_PERMISSIONS:-1}"
    printf 'CLAUDE_CONTINUE=%q\n'         "${CLAUDE_CONTINUE:-1}"
    printf 'CLAUDE_ARGS=%q\n'             "${CLAUDE_ARGS:-}"
} >> /etc/claude-container.conf

# ---- timezone -----------------------------------------------------------------------------
if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
fi

# ---- SSH host keys (persisted in a volume) ------------------------------------------------
mkdir -p "$HOSTKEY_DIR"
for type in ed25519 rsa; do
    key="$HOSTKEY_DIR/ssh_host_${type}_key"
    if [ ! -f "$key" ]; then
        log "generating $type SSH host key"
        ssh-keygen -q -t "$type" -N '' -f "$key"
    fi
done
chmod 600 "$HOSTKEY_DIR"/ssh_host_*_key
log "SSH host key: $(ssh-keygen -lf "$HOSTKEY_DIR/ssh_host_ed25519_key.pub")"

# ---- authorized_keys ------------------------------------------------------------------------
mkdir -p "$HOME_DIR/.ssh"
{
    if [ -f /config/authorized_keys ]; then cat /config/authorized_keys; fi
    if [ -n "${AUTHORIZED_KEYS:-}" ]; then printf '%s\n' "$AUTHORIZED_KEYS"; fi
} | grep -v '^[[:space:]]*$' > "$HOME_DIR/.ssh/authorized_keys" || true
chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
if [ -s "$HOME_DIR/.ssh/authorized_keys" ]; then
    log "$(wc -l < "$HOME_DIR/.ssh/authorized_keys") SSH public key(s) installed for user $USER_NAME"
else
    log "WARNING: no SSH public keys (./authorized_keys or AUTHORIZED_KEYS) -> SSH login impossible"
fi

# ---- writable volumes ---------------------------------------------------------------------------
for dir in "$HOME_DIR/.claude" /commandhistory /workspace; do
    if ! runuser -u "$USER_NAME" -- test -w "$dir"; then
        log "making $dir writable for $USER_NAME"
        chown "$USER_NAME:$USER_NAME" "$dir"
    fi
done

# ---- sshd ------------------------------------------------------------------------------------
mkdir -p /run/sshd
/usr/sbin/sshd -t
/usr/sbin/sshd -D -e &
SSHD_PID=$!
log "sshd listening on :22"

# Runs a command as the unprivileged user. The HTTP token is deliberately not passed on,
# so the Claude session never sees it.
as_user() {
    runuser -u "$USER_NAME" -- env -u INJECT_TOKEN \
        HOME="$HOME_DIR" USER="$USER_NAME" LOGNAME="$USER_NAME" SHELL=/bin/bash \
        PATH="$HOME_DIR/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        TERM="${TERM:-xterm-256color}" "$@"
}

# ---- tmux session with Claude Code -------------------------------------------------------------
log "$(as_user start-claude-session)"

# ---- HTTP injector -------------------------------------------------------------------------------
INJECT_PID=""
if [ -n "${INJECT_TOKEN:-}" ]; then
    runuser -u "$USER_NAME" -- env HOME="$HOME_DIR" INJECT_TOKEN="$INJECT_TOKEN" \
        INJECT_BIND=0.0.0.0 INJECT_PORT=8080 python3 /usr/local/bin/inject-server.py &
    INJECT_PID=$!
else
    log "WARNING: INJECT_TOKEN is empty -> HTTP injector disabled ('ssh ... inject' still works)"
fi

# ---- supervise ----------------------------------------------------------------------------------
shutdown() {
    trap - TERM INT
    log "shutting down"
    as_user tmux kill-server 2>/dev/null || true
    kill "$SSHD_PID" ${INJECT_PID:-} 2>/dev/null || true
    wait 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

# Returns as soon as one of the services exits; compose then restarts the container.
# shellcheck disable=SC2086
wait -n $SSHD_PID $INJECT_PID || true
log "a service exited unexpectedly, stopping container"
shutdown
