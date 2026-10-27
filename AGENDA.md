# Agenda

Open work, roughly in the order it should be done. Items 1-8 come from the review on 2026-10-27.
`[x]` = done (not yet verified against a running Docker daemon, see item 10, step 7).

## Fixes from the review

1. [x] **Volumes:** replace the bind-backed named volumes in `compose.yaml` with plain bind mounts
   (`./.volume_config:/home/claude/.claude`, ...). Compose resolves relative paths for those and
   creates missing directories; `driver_opts.device: ./...` is handed to dockerd verbatim and the
   source must already exist. Prerequisite for item 10.
2. [x] **GID collision:** the entrypoint runs `chown claude:claude`, but group `claude` does not exist
   when the host GID is already taken in the image (macOS GID 20 = `dialout`), so the container
   dies under `set -e`. Use `chown claude:` or numeric ids.
3. [x] **Docs after the volume move:** `docker volume rm ...` / `down -v` no longer delete data,
   it lives in `./.volume_*`. README says "four volumes" and `ssh-hostkeys`.
4. [x] **setup.sh vs build.sh:** docs say `./setup.sh`, the file is `build.sh`. Its `docker build .`
   is untagged and without `UID`/`GID` build args, so compose never uses that image.
5. [x] **Token in logs:** `?token=` ends up in journald via the logged request line.
   Strip the query in `log_message` or drop query-string auth.
6. [x] **Default bind:** `BIND_ADDR=0.0.0.0` exposes an unencrypted RCE-capable API to the LAN.
   Default to `127.0.0.1`.
7. [x] **Token "hidden" from Claude:** the inject-server runs as the same user, so
   `/proc/<pid>/environ` shows it. Fix the comment (or run the server as another user).
8. Small stuff. Done: journald tag comment (`ledger`), "Window 0" comment vs `base-index 1`.
   Open: unpinned installer and non-persisted autoupdates, `env | sed` parsing in the
   entrypoint, loose ` -c ` match in `start-claude-session`.

## Features

10. [ ] **Multiple instances.** Steps 1-6 done, step 7 (manual check with Docker) open.
    Several containers side by side, each started from its own
    directory, with that directory's `.env`, `authorized_keys`, `workspace/` and `.volume_*`.
    See the plan below.

---

## Plan: multiple instances

### Model

An *instance* is a directory. The repository is the code; it is never copied into an instance.

```
~/claude/projA/              <- instance directory (any location)
  .env                       COMPOSE_PROJECT_NAME, ports, token, UID/GID, ...
  authorized_keys
  workspace/
  .volume_config/ .volume_sessions/ .volume_commandhistory/ .volume_ssh_hostkeys/
```

The repository directory itself stays a valid instance, so `docker compose up -d` in the repo
keeps working exactly as today.

### What collides today

| Item | Today | Change |
|---|---|---|
| Compose project | `name: pickled-claude` | remove; take `COMPOSE_PROJECT_NAME` from the instance `.env` |
| Container | `container_name: pickled-claude` | remove; compose names it `<project>-claude-1` |
| Host ports | `SSH_PORT` / `INJECT_PORT` from `.env` | already configurable; init picks free ones |
| Log tag | `tag: pickled-claude` | `tag: "{{.Name}}"` |
| Volume paths | relative to the compose file's directory | relative to `--project-directory` (the instance) |
| Build context | `.` | `${PICKLED_CLAUDE_SRC:-.}` so it still points at the repo |
| Image tag | `pickled-claude:local` | `pickled-claude:${UID}-${GID}`, so instances with different users don't overwrite each other's image |

Things already per-container and fine: SSH host keys (in the instance's volume), the inject lock
file in `/tmp`, the tmux socket, `/etc/claude-container.conf`.

### Wrapper: `pickled-claude` (repo root, symlink it into `~/bin`)

Resolves the repo from its own (symlink-followed) path and the instance from `$PWD`
(or `-C DIR`), then runs

```
PICKLED_CLAUDE_SRC=$REPO docker compose \
    -f "$REPO/compose.yaml" --project-directory "$INSTANCE" --env-file "$INSTANCE/.env" "$@"
```

Subcommands:

- `pickled-claude init [DIR]`: replaces `build.sh`. Creates DIR, `.env` from
  `$REPO/.env.example` with a random token, `UID`/`GID`,
  `COMPOSE_PROJECT_NAME=pickled-claude-<basename>` (with a numeric suffix if that project
  already exists in `docker compose ls -a`), and the first free `SSH_PORT` >= 2222 and
  `INJECT_PORT` >= 8080. A port counts as taken if something listens on it (`ss -ltn`) or
  another instance's `.env` claims it. Instances are found through `docker compose ls -a` (its
  config-file and working-dir columns). Also creates `authorized_keys`, `workspace/` and the
  `.volume_*` directories. Leaves an existing `.env` alone.
- `pickled-claude ssh [ARGS]`: `ssh -p $SSH_PORT claude@localhost` using the instance's `.env`.
- `pickled-claude ls`: instances with project name, directory, ports and state.
- Everything else goes straight to `docker compose`: `pickled-claude up -d`, `logs -f`, `down`,
  `build`, `exec claude peek`, ...

The wrapper refuses to run without `$INSTANCE/.env`, except for `init` and `ls`, so a typo'd
directory never starts a container with default ports and fresh state.

### Steps

1. Review fixes 1 (bind mounts), 2 (chown) and 4 (drop `build.sh`). The instance work builds on them.
2. `compose.yaml`: drop `name` / `container_name`, templated log tag, build context, image tag.
3. `.env.example`: add `COMPOSE_PROJECT_NAME`; `BIND_ADDR=127.0.0.1` (review item 6).
4. Write the `pickled-claude` wrapper with `init`, `ssh`, `ls` and passthrough.
5. Tests (no Docker daemon needed):
   - `tests/pickled-claude.test.sh`: `init` into temp dirs with `docker` / `ss` stubbed. Checks
     the generated `.env` (unique project name, ports skipping taken and already-claimed ones,
     token, uid/gid), the created directories, that an existing `.env` is left alone, and the
     exact `docker compose` argv of the passthrough.
   - `docker compose config` for two instance dirs: distinct project names, ports and absolute
     bind sources under each instance, and a build context pointing at the repo.
6. Docs: README gets an "Several instances" section and the wrapper replaces raw compose
   commands in the quick start. Update DESIGN.md (file layout, decisions). Migration note for the
   existing instance: `docker compose down`, then `docker volume rm pickled-claude_claude-*`
   (the data is in `./.volume_*` and stays), then `up -d`.
7. Manual check on a host with Docker: two instances up at once, SSH into both, inject into one
   and peek at both, `down` one while the other keeps running.
