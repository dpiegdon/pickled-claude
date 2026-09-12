# Design concept: Claude Code in tmux inside Docker

Status: agreed 2026-09-10, implemented. Decisions: skip-permissions on by default (`CLAUDE_SKIP_PERMISSIONS=0` disables), ports configurable with host SSH default 2222, no egress firewall, Debian 13 trixie.

## Goals

- Run Claude Code (`claude`) inside a long-lived tmux session in a Debian container.
- Claude can install software on demand (passwordless `sudo apt-get ...`, pip, npm, ...).
- Attach to the live session from outside (SSH), see exactly what Claude sees, and type into it.
- Inject prompts without attaching: via SSH command (`ssh ... inject "text"`) and via HTTP
  (`PUT /prompt`) protected by a bearer token.
- Survive container restarts: login, settings, per-project trust, shell history and SSH host
  keys are persisted. The workspace is a bind mount from the host.

Non-goals (for now): multiple parallel Claude sessions, a web terminal, a network egress
firewall (see "Optional add-ons").

## Architecture

```
 host / LAN                          container "pickled-claude" (debian:trixie-slim)
 ------------                        ------------------------------------------------
                                     tini (init) -> entrypoint.sh (root)
 ssh -p 2222 claude@host  ------->   sshd :22 (key auth only, user "claude")
   plain login = tmux attach            |  login shell -> auto `tmux attach -t claude`
   ssh ... inject "text"                |  remote cmd  -> /usr/local/bin/inject
   ssh ... peek                         |
                                        v
                                     tmux server (uid claude)  session "claude"
                                        window 0: login bash -> `claude $CLAUDE_ARGS`
                                        cwd /workspace
                                        ^
 curl -X PUT :8080/prompt  ------->  inject-server.py :8080 (uid claude, python3 stdlib)
   Authorization: Bearer <token>       PUT/POST /prompt, POST /keys, GET /screen, GET /health

 volumes: claude-config -> /home/claude/.claude   (+ CLAUDE_CONFIG_DIR, keeps .claude.json)
          claude-history -> /commandhistory       (bash history, as in Anthropic's reference)
          ssh-hostkeys   -> /etc/ssh/hostkeys     (stable host key across recreates)
          ./workspace    -> /workspace            (bind mount, the project Claude works on)
          ./authorized_keys -> /config/authorized_keys (ro, copied in at start)
```

## Components

### Image (Dockerfile)

- Base `debian:trixie-slim`. Packages: `tmux ncurses-term openssh-server sudo git curl wget
  ca-certificates gnupg python3 procps psmisc less nano jq unzip zip xz-utils iproute2 tzdata`.
- User `claude` with build-time `UID`/`GID` args (default 1000) so files in `/workspace` are
  owned by the host user. `/etc/sudoers.d/claude`: `claude ALL=(ALL) NOPASSWD:ALL`.
  This is what makes "install stuff on demand" work.
- Claude Code via the native installer (`curl -fsSL https://claude.ai/install.sh | bash`) as
  user `claude`, plus a symlink `/usr/local/bin/claude` so non-login shells find it.
  No Node.js needed. Auto-update stays on by default (`DISABLE_AUTOUPDATER` overridable).
- `CLAUDE_CONFIG_DIR=/home/claude/.claude` so the OAuth account and per-project trust in
  `.claude.json` land inside the persisted volume (documented pattern from the devcontainer docs).
- sshd: `PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers claude`, host keys read
  from `/etc/ssh/hostkeys`; the keys baked in by the Debian package are deleted at build time.
  `pam_loginuid` set to optional (fails inside containers otherwise).
- `/etc/tmux.conf`: `tmux-256color`, truecolor, `escape-time 10` (Esc must be instant for
  Claude Code), big scrollback, extended keys (Shift+Enter passthrough).
- `LANG=C.UTF-8` for both docker-started and ssh-started processes (`/etc/default/locale`).

### Process model (entrypoint.sh, runs as root)

0. Write `/etc/claude-container.conf` (tmux target, expected command, Enter delay, and the
   `CLAUDE_*` settings that shape the claude command) so the SSH helper scripts and the HTTP
   server share one configuration. sshd gives a login shell a clean environment, so a session
   restarted by `attach` over SSH would otherwise use different flags than the entrypoint's.
1. Generate SSH host keys into the volume if missing.
2. Assemble `~claude/.ssh/authorized_keys` from `/config/authorized_keys` and the optional
   `AUTHORIZED_KEYS` env var, fix permissions.
3. Start `sshd -D -e` in the background.
4. As user `claude` (with `INJECT_TOKEN` stripped from the environment so it is not visible to
   the Claude session): `start-claude-session` creates tmux session `claude`, window 0 with a
   login bash in `/workspace`, then types `claude $CLAUDE_ARGS` + Enter into it.
   When `claude` exits you get the shell back instead of a dead session; `attach` restarts
   the session if it is gone.
   The tmux server dies with the container, so a restart always builds a new session. The
   conversation is restored instead: if `$CLAUDE_CONFIG_DIR/projects/<workdir slug>/` already
   holds a transcript, the typed command is `claude --continue`. The slug is the working
   directory with every non-alphanumeric character replaced by `-`, e.g. `-workspace`, and the
   directory sits in the `claude-config` volume. A first start finds no transcript and begins a
   new conversation; `CLAUDE_CONTINUE=0`, or an explicit `--continue`/`--resume` in
   `CLAUDE_ARGS`, takes the decision away from the script.
5. As user `claude`: `inject-server.py` on `0.0.0.0:8080` (skipped with a loud warning when
   `INJECT_TOKEN` is empty).
6. `wait -n`; if sshd or the injector dies the container exits and compose restarts it.
   Compose uses `init: true` for zombie reaping and a `tmux has-session` healthcheck.

### Attaching

- `ssh -p 2222 claude@host`: an interactive login runs `/etc/profile.d/99-tmux-autoattach.sh`,
  which `exec`s `tmux attach -t claude`. Detach with the usual `Ctrl-b d`.
- `ssh -t -p 2222 claude@host bash`: plain shell without attaching (non-login shell skips
  profile.d).
- Several people/terminals can attach at once; tmux resizes to the smallest client.

### Injection mechanics (shared by SSH and HTTP)

```
tmux load-buffer -b inject -            # text via stdin: any size, any characters
tmux paste-buffer -p -d -b inject -t claude:claude.0   # -p = bracketed paste
sleep 0.5                               # Claude Code drops Enter if it comes too early
tmux send-keys -t claude:claude.0 Enter
```

- Bracketed paste means multi-line prompts arrive as one paste (Claude shows
  `[Pasted text +N lines]`) instead of each newline submitting a message.
- Safety check before injecting: the pane's foreground command must be `claude`
  (`#{pane_current_command}`). If Claude has exited and the pane shows a bash prompt, the
  text would otherwise be executed as a shell command. Override with `-f` / `?force=1`.
- A lock serialises concurrent injections so text and Enter never interleave.
- If Claude is busy, Claude Code queues the typed text as the next message. If it is sitting
  in a permission prompt, the Enter confirms the highlighted option; use `peek` /
  `GET /screen` to look first, and `inject -k` / `POST /keys` to answer prompts
  (`Escape`, `C-c`, `y`, `Down Enter`, ...).

### SSH command surface (in /usr/local/bin)

| command | purpose |
| --- | --- |
| `inject [-n] [-f] TEXT...` / `... \| inject` | paste text and press Enter (`-n`: no Enter, `-f`: skip the "is claude running" check) |
| `inject -k KEY...` | send raw tmux key names |
| `peek [N]` | print the current screen plus N lines of scrollback |
| `attach` | (re)create the session if needed and attach |
| `start-claude-session` | idempotent session creation, used by entrypoint and `attach` |

Examples: `ssh -p 2222 claude@host inject "run the tests and fix failures"`,
`ssh -p 2222 claude@host inject < prompt.md`, `ssh -p 2222 claude@host peek 200`.

### HTTP API (inject-server.py, python3 stdlib, no dependencies)

Auth: `Authorization: Bearer $INJECT_TOKEN` or `?token=`. Constant-time comparison.
Body limit 1 MiB.

| method + path | body | effect |
| --- | --- | --- |
| `PUT`/`POST /prompt[?submit=0][&force=1]` | raw text, or JSON `{"text": "...", "submit": true}` | paste + Enter |
| `POST /keys[?force=1]` | `Escape`, `C-c`, `y Enter`, ... | `tmux send-keys` |
| `GET /screen[?lines=N]` | | `tmux capture-pane`, text/plain |
| `GET /health` | | `{"ok":true,"session":true}`, no auth |

Example: `curl -X PUT -H "Authorization: Bearer $TOKEN" --data-binary @prompt.txt http://host:8080/prompt`

### Configuration (.env)

| variable | default | meaning |
| --- | --- | --- |
| `INJECT_TOKEN` | (required for HTTP) | bearer token; `setup.sh` generates one |
| `CLAUDE_SKIP_PERMISSIONS` | 1 | start with `--dangerously-skip-permissions`; `0` = normal permission prompts |
| `CLAUDE_ARGS` | empty | extra args, e.g. `--continue`, `--model ...` |
| `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` | empty | non-interactive auth; otherwise attach once and `/login` |
| `SSH_PORT` / `INJECT_PORT` | 2222 / 8080 | host ports |
| `BIND_ADDR` | 0.0.0.0 | set `127.0.0.1` to expose only on the host |
| `UID` / `GID` | 1000 / 1000 | in-container user, build args |
| `TZ` | UTC | |
| `DISABLE_AUTOUPDATER` | empty | set `1` to pin the image's version |

Helper `setup.sh`: creates `.env` with a random token and your uid/gid, copies your public
key into `./authorized_keys`, creates `./workspace`. Then `docker compose up -d --build`.

## Security notes

- SSH is key-only, root login disabled. The HTTP token travels in plaintext; keep 8080 on
  localhost or a trusted network, or put a TLS reverse proxy in front.
- Do not mount `~/.ssh` or cloud credentials into the container (Anthropic's warning applies:
  a bypassed session can exfiltrate anything inside the container, including `~/.claude`).
- `--dangerously-skip-permissions` is the default because Claude runs as non-root inside the
  container and prompts would block remote injection. Set `CLAUDE_SKIP_PERMISSIONS=0` to get
  normal prompts (answer them via `ssh` attach or `inject -k`).
- Anything installed with apt/pip lives in the container layer: survives `restart`, is lost
  on `docker compose up` after an image rebuild. Put permanent tools in the Dockerfile.

## Optional add-ons (not in the first version)

- Egress firewall as in Anthropic's `init-firewall.sh` (needs `NET_ADMIN`/`NET_RAW`). It
  conflicts with "install anything on demand" unless Debian/PyPI/npm mirrors are added to the
  allowlist, so it is left out initially. Could be a compose profile later.
- `POST /prompt` fan-out to several sessions, or a `/restart` endpoint.
- Web terminal (ttyd) instead of / in addition to SSH.

## File layout

```
claude-container/
  Dockerfile
  compose.yaml
  .env.example            -> .env (gitignored)
  authorized_keys         (gitignored, created by setup.sh)
  setup.sh
  README.md
  DESIGN.md
  workspace/              (gitignored, bind-mounted to /workspace)
  container/
    entrypoint.sh
    inject-server.py
    sshd.conf             -> /etc/ssh/sshd_config.d/10-claude.conf
    tmux.conf             -> /etc/tmux.conf
    profile.d/10-claude-env.sh, 99-tmux-autoattach.sh
    bashrc-snippet.sh     (history + env, appended to ~claude/.bashrc)
    bin/inject, peek, attach, start-claude-session
  tests/
    start-claude-session.test.sh   which claude command lands in the tmux window
```

## Decisions (2026-09-10)

1. Permission mode: `--dangerously-skip-permissions` on by default, `CLAUDE_SKIP_PERMISSIONS=0` disables.
2. Ports: all interfaces, `SSH_PORT` (default 2222, host port 22 belongs to the host's sshd) and
   `INJECT_PORT` (default 8080) configurable, `BIND_ADDR` to restrict.
3. No egress firewall.
4. Debian 13 trixie.
5. A restart continues the last conversation of the working directory (`claude --continue`)
   rather than resuming a session id pinned at first start. If somebody exits `claude` and
   starts a new conversation by hand in the tmux window, that newer one is the one a restart
   should come back to; a pinned id would keep dragging the original session along.
   With several conversations in one directory, `--continue` takes the one with the most recent
   activity (not the oldest, and not the one the tmux window happened to run), and it keeps the
   session id, so after the first restart that choice stays stable.
