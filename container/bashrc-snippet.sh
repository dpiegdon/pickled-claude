
# --- claude-container ---------------------------------------------------------
export HISTFILE=/commandhistory/.bash_history
export HISTSIZE=50000 HISTFILESIZE=100000
export PROMPT_COMMAND='history -a'
export CLAUDE_CONFIG_DIR=/home/claude/.claude

alias ".."="cd .."
alias "..."="cd ../.."
alias "...."="cd ../../.."
[[ -z $BASH_VERSION ]] && alias "/"="cd /"
alias -- "-"="cd -"
alias j="jobs"
alias l="ls -la"
alias ll="ls -l"
alias ls="ls --color=auto"
alias lt="ls -la --sort=time -r"
alias ltr="ls -la --sort=time"

alias g="git"
alias t="tig"
alias v="vim"
alias vp="vim -p"

case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
