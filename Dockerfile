# syntax=docker/dockerfile:1
# Claude Code inside a tmux session, reachable via SSH and a small HTTP injection API.
FROM debian:trixie-slim

ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg git sudo \
        tmux ncurses-term openssh-server \
        python3 procps psmisc less nano jq unzip zip xz-utils file iproute2 tzdata \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Unprivileged user "claude" with passwordless sudo, so Claude can install packages on demand.
RUN if ! getent group "$GID" >/dev/null; then groupadd -g "$GID" claude; fi \
    && useradd -m -u "$UID" -g "$GID" -s /bin/bash claude \
    && echo 'claude ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude

# sshd: host keys are generated per instance into a volume, never baked into the image.
# pam_loginuid fails inside containers, so make it optional.
RUN rm -f /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd /etc/ssh/hostkeys \
    && sed -i 's/^session\s\+required\s\+pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/sshd \
    && printf 'LANG=C.UTF-8\n' > /etc/default/locale \
    && printf 'LANG=C.UTF-8\nCLAUDE_CONFIG_DIR=/home/claude/.claude\n' >> /etc/environment

COPY container/sshd.conf /etc/ssh/sshd_config.d/10-claude.conf
COPY container/tmux.conf /etc/tmux.conf
COPY container/profile.d/ /etc/profile.d/
COPY container/bin/ container/entrypoint.sh container/inject-server.py /usr/local/bin/
COPY container/bashrc-snippet.sh /tmp/bashrc-snippet.sh
RUN chmod 0755 /usr/local/bin/* \
    && chmod 0644 /etc/tmux.conf /etc/ssh/sshd_config.d/10-claude.conf \
                  /etc/profile.d/10-claude-env.sh /etc/profile.d/99-tmux-autoattach.sh \
    && cat /tmp/bashrc-snippet.sh >> /home/claude/.bashrc && rm /tmp/bashrc-snippet.sh

# Persistent bash history (same approach as Anthropic's reference devcontainer),
# workspace, and the Claude config dir that becomes a named volume.
# /home/claude/.claude/projects is a mount point of its own (volume claude-sessions); creating
# it here with the right owner means a freshly created volume starts out writable for claude.
RUN mkdir -p /commandhistory /workspace /home/claude/.claude/projects \
    && touch /commandhistory/.bash_history \
    && chown -R "$UID:$GID" /commandhistory /workspace /home/claude/.claude

# .claude.json (OAuth account, per-project trust) must live inside the persisted volume.
ENV CLAUDE_CONFIG_DIR=/home/claude/.claude

# Claude Code via the native installer, as the unprivileged user. No Node.js required.
RUN runuser -l claude -c 'curl -fsSL https://claude.ai/install.sh | bash' \
    && test -x /home/claude/.local/bin/claude \
    && ln -s /home/claude/.local/bin/claude /usr/local/bin/claude

WORKDIR /workspace
EXPOSE 22 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD runuser -u claude -- tmux has-session -t =claude

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
