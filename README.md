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

Everything goes through `pickled-claude INSTANCE COMMAND`, where `INSTANCE` is the instance's
directory (relative to where you are, or absolute). From the repository:

```bash
./pickled-claude claude1 init      # create ./claude1: .env (free ports, random token, uid/gid),
                                   #   authorized_keys, image/Dockerfile, workspace/, .volume_*/
./pickled-claude claude1 up        # build its images (downloads Claude Code), start, show info
./pickled-claude claude1 logs -f   # wait for "tmux session 'claude' started"
./pickled-claude claude1 ssh       # attach; on first start finish onboarding and /login here
```

| command | effect |
| --- | --- |
| `init` | create the instance directory and its settings; leaves existing files alone |
| `up [ARGS]` | build the instance's images and (re)start it (`docker compose up -d --build`), then `info` |
| `info` | instance name, state, port mapping with the matching `ssh` command and URL, images |
| `ssh [ARGS]` | ssh into the instance; without ARGS that attaches to Claude |
| `delete [--yes]` | remove the container, both images and the whole directory, after you type the instance name |
| anything else | a `docker compose` command for this instance: `logs -f`, `down`, `ps`, `exec claude bash`, ... |

`pickled-claude ls` lists all instances. To call it from anywhere, link it into your PATH:
`ln -s "$PWD/pickled-claude" ~/bin/`.

`init` copies your `~/.ssh/*.pub` into the instance's `authorized_keys`. Without one, put at
least one public key there yourself; the file must exist before `up`.

### Several instances

Each instance is a directory with its own `.env`, `authorized_keys`, `workspace/`, state and
images, so several run side by side without sharing anything:

```bash
pickled-claude ~/claude/projA init       # SSH 2222, HTTP 8080
pickled-claude ~/claude/projB init       # next free ports: 2223, 8081
pickled-claude ~/claude/projB up
pickled-claude ls                        # name, ports, state and directory of every instance
```

`init` names the instance `pickled-claude-<directory>` (`COMPOSE_PROJECT_NAME`, the container
is `<name>-claude-1`) and picks ports that nothing listens on and no other instance claims.
Instances are remembered in `~/.config/pickled-claude/instances`. Moving an instance
directory is fine while it is stopped; the next command from the new place registers it.

Login: either attach once and run `/login` (the browser flow prints a URL; paste the code back
into the terminal), or set `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` (from
`claude setup-token`) in `.env`. Login and settings survive container recreation.

## Connecting

| what | command |
| --- | --- |
| attach to Claude | `ssh -p 2222 claude@host` (an interactive login auto-attaches) |
| same, by instance | `pickled-claude INSTANCE ssh` (`... ssh inject "text"` etc. work too) |
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
| `COMPOSE_PROJECT_NAME` | directory name | instance name, unique per host; `init` sets it |
| `BIND_ADDR` | 127.0.0.1 | `0.0.0.0` to expose both ports to the network |
| `CONTAINER_HOSTNAME` | pickle | hostname inside the container |
| `CLAUDE_SKIP_PERMISSIONS` | 1 | start Claude with `--dangerously-skip-permissions`. `0` for normal prompts |
| `CLAUDE_CONTINUE` | 1 | after a restart, continue the conversation the container was running before. `0` always starts a new one |
| `CLAUDE_ARGS` | empty | extra `claude` arguments, e.g. `--model opus`. An explicit `--continue`/`--resume` overrides `CLAUDE_CONTINUE` |
| `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` | empty | non-interactive login |
| `DISABLE_AUTOUPDATER` | empty | `1` pins the version baked into the image |
| `UID`, `GID` | 1000 | in-container user; build args, rebuild after changing |
| `AUTHORIZED_KEYS` | empty | one extra public key; several go into `./authorized_keys` |
| `INJECT_ENTER_DELAY` | 0.5 | seconds between paste and Enter |
| `TZ` | UTC | container time zone |

Changes to `.env` take effect with `pickled-claude INSTANCE up`, which recreates the container.
The running `claude` process does not survive that, but the conversation does: the new
container starts `claude --continue` and picks it up where it stopped (`CLAUDE_CONTINUE=0`
if you would rather start fresh every time). If you ran several conversations in `/workspace`,
the one you used last is the one that comes back; `/resume` inside Claude switches to another.

## What persists where

| data | location | survives |
| --- | --- | --- |
All of it lives in the instance directory, bind-mounted into the container:

| data | instance directory | in the container | survives |
| --- | --- | --- | --- |
| login, settings, per-project trust | `.volume_config/` | `/home/claude/.claude` (`CLAUDE_CONFIG_DIR`) | until you delete it |
| conversations (what `--continue` and `/resume` read) | `.volume_sessions/` | `/home/claude/.claude/projects` | until you delete it |
| bash history | `.volume_commandhistory/` | `/commandhistory` | until you delete it |
| SSH host key | `.volume_ssh_hostkeys/` | `/etc/ssh/hostkeys` | until you delete it |
| your project | `workspace/` | `/workspace` | until you delete it |
| this instance's image additions | `image/Dockerfile` (and files next to it) | the image | until you delete it |
| packages Claude installed with apt/pip/npm | | container layer | `restart`, but not recreate |

Put tools you always want into the instance's `image/Dockerfile` and rebuild (see below).
`pickled-claude INSTANCE down -v` does not touch any of these directories; to reset an
instance, stop it and delete them, or remove it entirely with `pickled-claude INSTANCE delete`. Files the container wrote there may belong to root or the container's uid,
so `sudo rm -rf` may be needed.

### Clearing old sessions

The conversations have a directory of their own, so they can go without taking the login,
the settings or the per-project trust with them. All of them at once:

```bash
pickled-claude INSTANCE down
rm -rf INSTANCE/.volume_sessions/*
pickled-claude INSTANCE up               # next start has no conversation to continue
```

Or only the conversations of one working directory, with the container running. `/workspace`
is stored as `-workspace`, every character that is not a letter or digit becomes a `-`:

```bash
pickled-claude INSTANCE exec claude ls /home/claude/.claude/projects
pickled-claude INSTANCE exec claude rm -rf /home/claude/.claude/projects/-workspace
```

Deleting the transcript of the conversation that is open right now confuses the running
`claude`, so exit it first, or leave that one file alone.

## Status line

A new instance shows the model, context window use and the plan's 5-hour and weekly usage
limits (with their reset times) below Claude's input, but no cost figure:

```
Opus 5.5 │ ctx 23% (46k/200k) │ 5h 12% ↻14:40 │ 7d 85% ↻Mon 08:00
```

On its first start, the entrypoint writes `.volume_config/settings.json` pointing `statusLine`
at `/usr/local/bin/claude-statusline`. It does that only while there is no `settings.json`, so
an instance that already has one (older instances included) keeps it as it is; add the
`statusLine` block there by hand, or remove the `statusLine` block to get rid of it.

## The instance's image

Every instance builds its own two images, and nothing else uses them:

| image | built from |
| --- | --- |
| `<instance>-base` | the repository's `Dockerfile`, with the instance's `UID`/`GID` |
| `<instance>-claude` | the instance's `image/Dockerfile` (`FROM base`), which the container runs |

`init` creates `image/Dockerfile` with commented examples. Add what this instance needs:

```dockerfile
FROM base
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY my-tool /usr/local/bin/          # files next to image/Dockerfile
```

Then `pickled-claude INSTANCE up`, which rebuilds before it starts. A rebuild picks up the repository as it is
at that moment, and only for this instance: the others keep running what they were built with
until they are rebuilt themselves. (Docker's build cache is shared by all builds on the host;
it only skips steps that are identical, so it does not tie the instances together.)

## Updating Claude Code

Claude Code auto-updates itself inside the container (into the container layer). A rebuild
(`pickled-claude INSTANCE build --pull --no-cache && pickled-claude INSTANCE up`) installs the current version
into the instance's image. Set `DISABLE_AUTOUPDATER=1` if you want the image to be the only source of truth.

## Security notes

- SSH accepts keys only, no passwords, no root login. Both ports bind to `127.0.0.1` by default.
  The HTTP token travels in clear text and gets anyone root in the container: before setting
  `BIND_ADDR=0.0.0.0`, make sure the network is trusted, or put a TLS reverse proxy in front.
- Skipping permission prompts is the default because Claude runs as a non-root user inside the
  container and prompts would block remote injection. It also means Claude can do anything the
  container can: modify `./workspace`, reach the network, install packages. Do not mount
  `~/.ssh`, cloud credentials or other host secrets into the container, and use repository
  scoped tokens for git remotes. `CLAUDE_SKIP_PERMISSIONS=0` restores the prompts.
- `INJECT_TOKEN` is stripped from the environment of the Claude session. That keeps it out of
  casual sight only: the injector runs as the same user, so Claude could read it from `/proc`.

## Troubleshooting

- **Injected text appears in the input box but is not submitted**: raise `INJECT_ENTER_DELAY`.
- **`inject` says the pane is running `bash`**: Claude exited. Attach and type `claude`
  (`claude --continue` picks up the conversation), or `ssh ... inject -f claude`.
- **A restart began a new conversation instead of continuing the old one**: conversations belong
  to a working directory, so the transcript has to be there. Check with
  `ls .volume_sessions/-workspace` in the instance directory. An empty or missing directory
  means there was nothing to continue, most likely because it was cleared.
- **`inject` refuses with an unexpected program name** (for example after a Claude Code update
  changes how the process is named): set `INJECT_EXPECT_CMD=<that name>` in the container
  environment, or `INJECT_EXPECT_CMD=` to disable the check.
- **"bind source path does not exist" on `up`**: create `authorized_keys` in the instance
  directory (`pickled-claude INSTANCE init` does).
- **`pickled-claude: ... is not an instance (no .env)`**: the path does not point at an
  instance directory. `pickled-claude ls` shows where they are; `... init` creates one.
- **"port is already allocated" on `up`**: another instance or program has the port. Change
  `SSH_PORT`/`INJECT_PORT` in `.env`; `pickled-claude ls` shows what the instances use.
- **SSH host key warning**: the instance's `.volume_ssh_hostkeys/` was deleted, so it has a new
  key. `pickled-claude INSTANCE ssh` stores host keys under the instance name; remove that line from
  `~/.ssh/known_hosts` (`ssh-keygen -R <name>`).
- **Permission denied in `/workspace`**: the directory is owned by another uid. Set `UID`/`GID`
  in `.env` to the owner and rebuild, or `chown` it.
- **Claude complains about running as root / refuses skip-permissions**: it is not started via
  the entrypoint. Use `attach` or `start-claude-session`, both run as user `claude`.

## Layout

```
Dockerfile, compose.yaml, .env.example
pickled-claude           INSTANCE init|up|info|ssh|delete, else docker compose; ls
container/
  entrypoint.sh          sshd + tmux session + HTTP injector, writes /etc/claude-container.conf
  inject-server.py       HTTP API (python3 stdlib only)
  bin/inject, peek, attach, start-claude-session, claude-statusline
  sshd.conf, tmux.conf, profile.d/, bashrc-snippet.sh
tests/                   shell tests: ./tests/*.test.sh

instance directory (the repository itself, or anywhere else):
  .env  authorized_keys  image/Dockerfile  workspace/
  .volume_config/  .volume_sessions/  .volume_commandhistory/  .volume_ssh_hostkeys/
```
