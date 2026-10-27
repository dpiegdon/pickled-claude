#!/bin/bash
# Tests for the pickled-claude wrapper: instance setup and the commands it hands to docker/ssh.
# Runs on the host without a Docker daemon: docker, ss and ssh are stubbed. If "docker compose"
# is installed, the real one also renders the config of two instances (needs no daemon either).
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
WRAPPER=$REPO/pickled-claude
pass=0; fail=0

check() {   # check <name> <command...>: passes when the command succeeds
    local name=$1; shift
    if "$@"; then
        pass=$((pass+1)); echo "ok   - $name"
    else
        fail=$((fail+1)); echo "FAIL - $name"
    fi
}

# A fresh fake host: HOME with one public key, stubbed tools, empty registry.
# STUB_LISTEN: ports something listens on. STUB_PROJECTS: compose project names that exist.
setup() {
    T=$(mktemp -d)
    mkdir -p "$T/bin" "$T/home/.ssh" "$T/work"
    echo "ssh-ed25519 AAAATEST test@host" > "$T/home/.ssh/id_ed25519.pub"
    cat > "$T/bin/docker" <<'STUB'
#!/bin/bash
printf 'PICKLED_CLAUDE_SRC=%s docker %s\n' "${PICKLED_CLAUDE_SRC:-}" "$*" >> "$STUB_LOG"
printf 'env GID=%s SSH_PORT=%s\n' "${GID-unset}" "${SSH_PORT-unset}" >> "$STUB_LOG"
if [ "$1 $2" = "compose ls" ]; then
    for p in ${STUB_PROJECTS:-}; do printf '{"Name":"%s","Status":"exited(1)"}' "$p"; done; echo
fi
exit 0
STUB
    cat > "$T/bin/ss" <<'STUB'
#!/bin/bash
for p in ${STUB_LISTEN:-}; do echo "LISTEN 0 128 0.0.0.0:$p 0.0.0.0:*"; done
STUB
    cat > "$T/bin/ssh" <<'STUB'
#!/bin/bash
printf 'ssh %s\n' "$*" >> "$STUB_LOG"
STUB
    chmod +x "$T/bin/"*
    : > "$T/log"
}

RUN_ENV=()  # extra VAR=VALUE for the next run, as if exported in your shell
run() {     # run in DIR with ARGS; output in $T/out
    local dir=$1; shift
    (cd "$dir" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" STUB_LOG="$T/log" \
        PICKLED_CLAUDE_REGISTRY="$T/registry" STUB_LISTEN="${STUB_LISTEN:-}" \
        STUB_PROJECTS="${STUB_PROJECTS:-}" "${RUN_ENV[@]}" "$WRAPPER" "$@") > "$T/out" 2>&1
}

envval() { sed -n "s/^$1=//p" "$2"; }

echo "# pickled-claude init"
setup
run "$T/work" init projA
A=$T/work/projA
check "init creates the instance files" \
    test -f "$A/.env" -a -s "$A/authorized_keys" -a -d "$A/workspace" -a -d "$A/.volume_config" \
         -a -d "$A/.volume_sessions" -a -d "$A/.volume_commandhistory" -a -d "$A/.volume_ssh_hostkeys"
check "project name from the directory" test "$(envval COMPOSE_PROJECT_NAME "$A/.env")" = pickled-claude-proja
check "default ports" test "$(envval SSH_PORT "$A/.env"):$(envval INJECT_PORT "$A/.env")" = 2222:8080
check "random token" test "$(envval INJECT_TOKEN "$A/.env" | wc -c)" -ge 32
check "uid/gid of the caller" test "$(envval UID "$A/.env"):$(envval GID "$A/.env")" = "$(id -u):$(id -g)"
check "localhost bind by default" test "$(envval BIND_ADDR "$A/.env")" = 127.0.0.1
check ".env readable only by the owner" test "$(stat -c %a "$A/.env")" = 600
check "public key copied" grep -q AAAATEST "$A/authorized_keys"
check "image overlay builds on the base image" grep -qx 'FROM base' "$A/image/Dockerfile"

run "$T/work" init "Proj B"
B="$T/work/Proj B"
check "second instance: next free ports" \
    test "$(envval SSH_PORT "$B/.env"):$(envval INJECT_PORT "$B/.env")" = 2223:8081
check "second instance: sanitized name" test "$(envval COMPOSE_PROJECT_NAME "$B/.env")" = pickled-claude-proj-b

cp "$A/.env" "$T/env.before"
run "$T/work" init projA
check "re-init leaves .env alone" cmp -s "$A/.env" "$T/env.before"
echo "RUN true" >> "$A/image/Dockerfile"; cp "$A/image/Dockerfile" "$T/df.before"
run "$T/work" init projA
check "re-init leaves image/Dockerfile alone" cmp -s "$A/image/Dockerfile" "$T/df.before"

run "$T/work" ls
check "ls lists both instances" grep -q 'pickled-claude-proj-b *2223 *8081' "$T/out"
rm -rf "$T"

setup
STUB_LISTEN="2222 2223 8080" run "$T/work" init projA
check "ports in use are skipped" \
    test "$(envval SSH_PORT "$T/work/projA/.env"):$(envval INJECT_PORT "$T/work/projA/.env")" = 2224:8081
STUB_PROJECTS="pickled-claude-projb pickled-claude-projb-2" run "$T/work" init projB
check "taken project names get a suffix" \
    test "$(envval COMPOSE_PROJECT_NAME "$T/work/projB/.env")" = pickled-claude-projb-3
mkdir -p "$T/work/pickled-claude"
run "$T/work" init pickled-claude
check "no doubled prefix" \
    test "$(envval COMPOSE_PROJECT_NAME "$T/work/pickled-claude/.env")" = pickled-claude
rm -rf "$T"

echo "# pickled-claude commands"
setup
run "$T/work" init projA
A=$T/work/projA
: > "$T/log"
run "$A" up -d
check "compose command for the current directory" grep -qxF \
    "PICKLED_CLAUDE_SRC=$REPO docker compose -f $REPO/compose.yaml --project-directory $A --env-file $A/.env -p pickled-claude-proja up -d" "$T/log"
: > "$T/log"
RUN_ENV=(GID=4242 SSH_PORT=1)
run "$A" up -d
RUN_ENV=()
check "variables of the .env do not leak in from the shell" grep -qxF "env GID=unset SSH_PORT=unset" "$T/log"
: > "$T/log"
run "$T" -C work/projA logs -f
check "-C selects the instance" grep -qF -- "--project-directory $A --env-file $A/.env -p pickled-claude-proja logs -f" "$T/log"
: > "$T/log"
run "$A" ssh peek 10
check "ssh uses the instance port and host key alias" \
    grep -qxF "ssh -p 2222 -o HostKeyAlias=pickled-claude-proja claude@127.0.0.1 peek 10" "$T/log"
: > "$T/log"
run "$T/work" up -d; rc=$?
check "refuses a directory without .env" test "$rc" = 1 -a ! -s "$T/log"
check "and says how to create it" grep -q 'pickled-claude init' "$T/out"
rm -rf "$T"

if docker compose version >/dev/null 2>&1; then
    echo "# docker compose config of two instances"
    T=$(mktemp -d)
    export PICKLED_CLAUDE_REGISTRY=$T/registry
    (cd "$T" && "$WRAPPER" init one && "$WRAPPER" init two) > /dev/null 2>&1
    (cd "$T/one" && "$WRAPPER" config) > "$T/one.yaml" 2>&1
    (cd "$T/two" && "$WRAPPER" config) > "$T/two.yaml" 2>&1
    check "instance one: own project" \
        grep -q "^name: pickled-claude-one" "$T/one.yaml"
    check "instance one: bind sources in its directory" grep -q "source: $T/one/.volume_sessions" "$T/one.yaml"
    check "instance one: base image from the repository" grep -q "context: $REPO\$" "$T/one.yaml"
    check "instance one: overlay from its own image/" grep -q "context: $T/one/image\$" "$T/one.yaml"
    check "instance one: overlay builds FROM its base" grep -q "base: service:base" "$T/one.yaml"
    (cd "$T/one" && "$WRAPPER" config --images) > "$T/one.images" 2>&1
    (cd "$T/two" && "$WRAPPER" config --images) > "$T/two.images" 2>&1
    check "instance one: images named after the instance" \
        test "$(sort "$T/one.images" | tr '\n' ' ')" = "pickled-claude-one-base pickled-claude-one-claude "
    check "instances share no image" test -z "$(comm -12 <(sort "$T/one.images") <(sort "$T/two.images"))"
    (cd "$T/one" && GID=4242 "$WRAPPER" config) > "$T/one-env.yaml" 2>&1
    check "an exported GID does not override the instance's" grep -q "GID: \"$(id -g)\"" "$T/one-env.yaml"
    check "instance two: own project" grep -q "^name: pickled-claude-two" "$T/two.yaml"
    check "instance two: bind sources in its directory" grep -q "source: $T/two/workspace" "$T/two.yaml"
    check "instances publish different ports" \
        test "$(grep published "$T/one.yaml")" != "$(grep published "$T/two.yaml")"
    rm -rf "$T"
fi

echo "# $pass passed, $fail failed"
[ "$fail" -eq 0 ]
