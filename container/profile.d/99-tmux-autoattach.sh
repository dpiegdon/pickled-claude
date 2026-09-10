# Interactive SSH logins attach to the Claude tmux session (detach with Ctrl-b d).
# For a plain shell instead:  ssh -t -p <port> claude@<host> bash
case "$-" in *i*) ;; *) return ;; esac
if [ -n "${SSH_TTY:-}" ] && [ -z "${TMUX:-}" ] && [ "$(id -un)" = "claude" ] \
   && command -v attach >/dev/null 2>&1; then
    exec attach
fi
