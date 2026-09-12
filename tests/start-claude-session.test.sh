#!/bin/bash
# Tests for start-claude-session: which claude command ends up in the tmux window.
# Runs on the host, no container needed: tmux, the workdir and the config dir are stubbed.
set -uo pipefail
cd "$(dirname "$0")/.."
SCRIPT=$PWD/container/bin/start-claude-session
pass=0; fail=0

# case <name> <VAR=VAL ...> -- <expected substring | !unexpected substring ...>
# WITH_HISTORY=1 creates a transcript for the workdir, i.e. "a session existed before".
case_() {
    local name=$1; shift
    local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift

    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/bin" "$tmp/workspace"
    cat > "$tmp/bin/tmux" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TMUX_LOG"
[ "$1" = has-session ] && exit "${TMUX_HAS_SESSION:-1}"
exit 0
STUB
    chmod +x "$tmp/bin/tmux"

    local with_history=0 e
    for e in "${envs[@]}"; do [ "$e" = WITH_HISTORY=1 ] && with_history=1; done
    if [ "$with_history" = 1 ]; then
        # Claude Code: <config>/projects/<cwd with non-alphanumerics replaced by ->/<uuid>.jsonl
        local slug; slug=$(printf '%s' "$tmp/workspace" | sed 's/[^a-zA-Z0-9]/-/g')
        mkdir -p "$tmp/config/projects/$slug"
        echo '{}' > "$tmp/config/projects/$slug/11111111-2222-3333-4444-555555555555.jsonl"
    fi

    : > "$tmp/tmux.log"
    env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" TMUX_LOG="$tmp/tmux.log" \
        CLAUDE_CONTAINER_CONF=/nonexistent \
        CLAUDE_WORKDIR="$tmp/workspace" CLAUDE_CONFIG_DIR="$tmp/config" \
        "${envs[@]}" "$SCRIPT" > "$tmp/out" 2>&1
    local rc=$? sent; sent=$(grep '^send-keys' "$tmp/tmux.log" || true)

    local ok=1 why= want
    [ "$rc" -ne 0 ] && { ok=0; why="exit $rc: $(head -2 "$tmp/out")"; }
    for want in "$@"; do
        if [ "${want#!}" != "$want" ]; then
            case $sent in *"${want#!}"*) ok=0; why="unexpected: ${want#!}";; esac
        else
            case $sent in *"$want"*) ;; *) ok=0; why="missing: $want";; esac
        fi
    done
    if [ "$ok" = 1 ]; then
        pass=$((pass+1)); echo "ok   - $name"
    else
        fail=$((fail+1)); echo "FAIL - $name: $why"; echo "       sent: ${sent:-<nothing>}"
    fi
    rm -rf "$tmp"
}

echo "# start-claude-session"
case_ "first start: no previous conversation -> plain claude" \
    WITH_HISTORY=0 -- "claude" '!--continue'
case_ "restart: previous conversation -> --continue" \
    WITH_HISTORY=1 -- "claude" "--continue"
case_ "CLAUDE_CONTINUE=0 disables resuming" \
    WITH_HISTORY=1 CLAUDE_CONTINUE=0 -- '!--continue'
case_ "explicit --resume in CLAUDE_ARGS wins" \
    WITH_HISTORY=1 "CLAUDE_ARGS=--resume 1234" -- "--resume 1234" '!--continue'
case_ "--continue in CLAUDE_ARGS is not doubled" \
    WITH_HISTORY=1 "CLAUDE_ARGS=--continue" -- '!--continue --continue'
case_ "permission flag still honoured" \
    WITH_HISTORY=1 CLAUDE_SKIP_PERMISSIONS=0 -- "--continue" '!--dangerously-skip-permissions'
case_ "running session is left alone" \
    WITH_HISTORY=1 TMUX_HAS_SESSION=0 -- '!claude'
echo "# $pass passed, $fail failed"
[ "$fail" -eq 0 ]
