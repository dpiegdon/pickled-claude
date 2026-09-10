
# --- claude-container ---------------------------------------------------------
export HISTFILE=/commandhistory/.bash_history
export HISTSIZE=50000 HISTFILESIZE=100000
export PROMPT_COMMAND='history -a'
export CLAUDE_CONFIG_DIR=/home/claude/.claude
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
