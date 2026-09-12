# pickled-claude

<img src="pickled-claude.jpg" align="right" width="300">

Claude Code in tmux, inside Docker. Only REAL if its 100% vibe coded.

A Debian container that runs [Claude Code](https://code.claude.com) inside a tmux session.
Attach to the live session over SSH, or push prompts into it from outside via SSH command or
HTTP. Claude can install whatever it needs (`sudo apt-get ...`) because the container is its
sandbox. Design notes are in [DESIGN.md](DESIGN.md).

```
ssh -p 2222 claude@host                 -> attached to the tmux session (Ctrl-b d detaches)
ssh -p 2222 claude@host inject "text"   -> pastes "text" into Claude and presses Enter
curl -X PUT -H "Authorization: Bearer $TOKEN" --data-binary @prompt.md http://host:8080/prompt
```

## Quick start

```bash
./setup.sh                      # .env with random token + your uid/gid, authorized_keys, workspace/
docker compose up -d --build    # build (downloads Claude Code) and start
docker compose logs -f          # wait for "tmux session 'claude' started"
ssh -p 2222 claude@localhost    # attach; on first start finish onboarding and /login here
```

`setup.sh` copies your `~/.ssh/*.pub` into `./authorized_keys`. Without it, put at least one
public key there yourself; the file must exist before `docker compose up`.

Login: either attach once and run `/login` (the browser flow prints a URL; paste the code back
into the terminal), or set `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` (from
`claude setup-token`) in `.env`. Login and settings survive container recreation.

## Connecting

| what | command |
| --- | --- |
| attach to Claude | `ssh -p 2222 claude@host` (an interactive login auto-attaches) |
| detach | `Ctrl-b d` |
| plain shell in the container | `ssh -t -p 2222 claude@host bash` |
| scroll back | `Ctrl-b [`, then arrows / PageUp, `q` to leave |

Several terminals can be attached at the same time. Detaching leaves Claude running.

## Injecting prompts

### Via SSH

```bash
ssh -p 2222 claude@host inject "run the test suite and fix what fails"
ssh -p 2222 claude@host inject < prompt.md          # multi-line text from a file
ssh -p 2222 claude@host inject -n "typed but not submitted"
ssh -p 2222 claude@host inject -k Escape            # raw keys: Escape, C-c, y, Down Enter, ...
ssh -p 2222 claude@host peek 100                    # screen contents + 100 lines scrollback
```

Prefer stdin for anything with quotes or special characters, because the argument form goes
through the remote shell once more. `inject -h` prints the usage.

### Via HTTP

All endpoints except `/health` need `Authorization: Bearer <INJECT_TOKEN>` (or `?token=`).

| method + path | body | effect |
| --- | --- | --- |
| `PUT` or `POST /prompt` | plain text, or JSON `{"text": "...", "submit": true}` | paste + Enter. `?submit=0` pastes without Enter |
| `POST /keys` | tmux key names, e.g. `Escape` or `y Enter` | send raw keys |
| `GET /screen?lines=N` | | current screen as text, plus N lines of scrollback |
| `GET /health` | | `{"ok": true, "session": true}` |

```bash
TOKEN=$(sed -n 's/^INJECT_TOKEN=//p' .env)
curl -X PUT -H "Authorization: Bearer $TOKEN" --data-binary 'summarize the git log of today' http://localhost:8080/prompt
curl -X PUT -H "Authorization: Bearer $TOKEN" --data-binary @prompt.md http://localhost:8080/prompt
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     --data '{"text": "line one\nline two", "submit": false}' http://localhost:8080/prompt
curl -H "Authorization: Bearer $TOKEN" 'http://localhost:8080/screen?lines=50'
```

Responses are JSON: `{"ok": true, "chars": 30, "lines": 1, "submitted": true}` or
`{"ok": false, "error": "..."}` with status 400/401/404/409/413/503.

### How injection works, and its limits

- Text goes into a tmux buffer and is pasted with bracketed paste, so multi-line prompts arrive
  as one paste (Claude shows `[Pasted text +N lines]`). After `INJECT_ENTER_DELAY` seconds
  Enter is sent.
- **Refused unless Claude is in the foreground.** If Claude exited and the pane shows a bash
  prompt, injected text would run as a shell command, so `inject` exits with code 3 and HTTP
  answers 409. Override with `inject -f` or `?force=1`. `inject "claude"` with `-f` restarts
  Claude in that case, or just attach and type `claude`.
- Injections from SSH and HTTP are serialised with a lock, so two prompts never interleave.
- If Claude is busy, Claude Code queues the text as the next message. If it is sitting in a
  permission or menu prompt, Enter picks the highlighted option. Look first with `peek` or
  `GET /screen` and answer prompts with `inject -k` / `POST /keys`.

## Configuration (.env)

| variable | default | meaning |
| --- | --- | --- |
| `INJECT_TOKEN` | empty | bearer token for HTTP. Empty disables the HTTP injector; SSH `inject` still works |
| `SSH_PORT` | 2222 | host port for SSH (22 stays with the host's own sshd) |
| `INJECT_PORT` | 8080 | host port for the HTTP API |
| `BIND_ADDR` | 0.0.0.0 | `127.0.0.1` to expose both ports only on the host |
| `CLAUDE_SKIP_PERMISSIONS` | 1 | start Claude with `--dangerously-skip-permissions`. `0` for normal prompts |
| `CLAUDE_CONTINUE` | 1 | after a restart, continue the conversation the container was running before. `0` always starts a new one |
| `CLAUDE_ARGS` | empty | extra `claude` arguments, e.g. `--model opus`. An explicit `--continue`/`--resume` overrides `CLAUDE_CONTINUE` |
| `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` | empty | non-interactive login |
| `DISABLE_AUTOUPDATER` | empty | `1` pins the version baked into the image |
| `UID`, `GID` | 1000 | in-container user; build args, rebuild after changing |
| `AUTHORIZED_KEYS` | empty | one extra public key; several go into `./authorized_keys` |
| `INJECT_ENTER_DELAY` | 0.5 | seconds between paste and Enter |
| `TZ` | UTC | container time zone |

Changes to `.env` take effect with `docker compose up -d`, which recreates the container.
The running `claude` process does not survive that, but the conversation does: the new
container starts `claude --continue` and picks it up where it stopped (`CLAUDE_CONTINUE=0`
if you would rather start fresh every time). If you ran several conversations in `/workspace`,
the one you used last is the one that comes back; `/resume` inside Claude switches to another.

## What persists where

| data | location | survives |
| --- | --- | --- |
| login, settings, per-project trust | volume `claude-config` at `/home/claude/.claude` (`CLAUDE_CONFIG_DIR`) | recreate and image rebuild |
| conversations (what `--continue` and `/resume` read) | volume `claude-sessions` at `/home/claude/.claude/projects` | recreate and image rebuild |
| bash history | volume `claude-history` | recreate and image rebuild |
| SSH host key | volume `ssh-hostkeys` | recreate and image rebuild |
| your project | bind mount `./workspace` at `/workspace` | everything |
| packages Claude installed with apt/pip/npm | container layer | `restart`, but not recreate |

Put tools you always want into the `Dockerfile` (the apt line) and rebuild.
`docker compose down -v` removes all four volumes, login included.

### Clearing old sessions

The conversations live in a volume of their own, so they can go without taking the login,
the settings or the per-project trust with them. All of them at once:

```bash
docker compose down
docker volume rm pickled-claude_claude-sessions
docker compose up -d                     # next start has no conversation to continue
```

Or only the conversations of one working directory, with the container running. `/workspace`
is stored as `-workspace`, every character that is not a letter or digit becomes a `-`:

```bash
docker compose exec claude ls /home/claude/.claude/projects
docker compose exec claude rm -rf /home/claude/.claude/projects/-workspace
```

Deleting the transcript of the conversation that is open right now confuses the running
`claude`, so exit it first, or leave that one file alone.

## Updating Claude Code

Claude Code auto-updates itself inside the container (into the container layer). A rebuild
(`docker compose build --pull --no-cache && docker compose up -d`) installs the current version
into the image. Set `DISABLE_AUTOUPDATER=1` if you want the image to be the only source of truth.

## Security notes

- SSH accepts keys only, no passwords, no root login. The HTTP token travels in clear text:
  keep `INJECT_PORT` on `127.0.0.1` or a trusted network, or put a TLS reverse proxy in front.
- Skipping permission prompts is the default because Claude runs as a non-root user inside the
  container and prompts would block remote injection. It also means Claude can do anything the
  container can: modify `./workspace`, reach the network, install packages. Do not mount
  `~/.ssh`, cloud credentials or other host secrets into the container, and use repository
  scoped tokens for git remotes. `CLAUDE_SKIP_PERMISSIONS=0` restores the prompts.
- `INJECT_TOKEN` is stripped from the environment of the Claude session.

## Troubleshooting

- **Injected text appears in the input box but is not submitted**: raise `INJECT_ENTER_DELAY`.
- **`inject` says the pane is running `bash`**: Claude exited. Attach and type `claude`
  (`claude --continue` picks up the conversation), or `ssh ... inject -f claude`.
- **A restart began a new conversation instead of continuing the old one**: conversations belong
  to a working directory, so the transcript has to be there. Check with
  `docker compose exec claude ls /home/claude/.claude/projects/-workspace`. An empty or missing
  directory means there was nothing to continue, most likely because the volume `claude-sessions`
  was removed.
- **`inject` refuses with an unexpected program name** (for example after a Claude Code update
  changes how the process is named): set `INJECT_EXPECT_CMD=<that name>` in the container
  environment, or `INJECT_EXPECT_CMD=` to disable the check.
- **"bind source path does not exist" on `docker compose up`**: create `./authorized_keys`.
- **SSH host key warning after `docker compose down -v`**: the volume with the host key was
  removed; delete the old line from `~/.ssh/known_hosts`.
- **Permission denied in `/workspace`**: the directory is owned by another uid. Set `UID`/`GID`
  in `.env` to the owner and rebuild, or `chown` it.
- **Claude complains about running as root / refuses skip-permissions**: it is not started via
  the entrypoint. Use `attach` or `start-claude-session`, both run as user `claude`.

## Layout

```
Dockerfile, compose.yaml, .env.example, setup.sh
authorized_keys          your public keys (gitignored)
workspace/               bind-mounted project dir (gitignored)
container/
  entrypoint.sh          sshd + tmux session + HTTP injector, writes /etc/claude-container.conf
  inject-server.py       HTTP API (python3 stdlib only)
  bin/inject, peek, attach, start-claude-session
  sshd.conf, tmux.conf, profile.d/, bashrc-snippet.sh
tests/                   shell tests, run them with ./tests/start-claude-session.test.sh
```
