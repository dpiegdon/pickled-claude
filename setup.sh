#!/bin/bash
# One-time setup: .env with a random token and your uid/gid, ./authorized_keys, ./workspace.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
    cp .env.example .env
    token=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    sed -i -e "s|^INJECT_TOKEN=.*|INJECT_TOKEN=$token|" \
           -e "s|^UID=.*|UID=$(id -u)|" \
           -e "s|^GID=.*|GID=$(id -g)|" .env
    echo "created .env: random INJECT_TOKEN, UID/GID $(id -u)/$(id -g)"
else
    echo ".env exists, left unchanged"
fi

if [ ! -s authorized_keys ]; then
    : > authorized_keys
    for key in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
        if [ -f "$key" ]; then cat "$key" >> authorized_keys; fi
    done
    if [ -s authorized_keys ]; then
        echo "authorized_keys: $(wc -l < authorized_keys) public key(s) copied from ~/.ssh"
    else
        echo "WARNING: no public key found in ~/.ssh. Put one into ./authorized_keys before starting."
    fi
else
    echo "authorized_keys exists, left unchanged"
fi

mkdir -p workspace

# shellcheck disable=SC1091
SSH_PORT=$(sed -n 's/^SSH_PORT=//p' .env); SSH_PORT=${SSH_PORT:-2222}
cat <<MSG

Next:
  docker compose up -d --build        # build the image and start the container
  docker compose logs -f              # watch until "tmux session 'claude' started"
  ssh -p $SSH_PORT claude@localhost          # attach to the Claude session (Ctrl-b d to detach)
MSG
