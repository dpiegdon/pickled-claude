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
run "$T/work" projA init
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
check "image overlay builds on the base image" grep -qx 'FROM ${BASE}' "$A/image/Dockerfile"
check "instance is invisible to a surrounding git repository" grep -qx '\*' "$A/.gitignore"

run "$T/work" "Proj B" init
B="$T/work/Proj B"
check "second instance: next free ports" \
    test "$(envval SSH_PORT "$B/.env"):$(envval INJECT_PORT "$B/.env")" = 2223:8081
check "second instance: sanitized name" test "$(envval COMPOSE_PROJECT_NAME "$B/.env")" = pickled-claude-proj-b

cp "$A/.env" "$T/env.before"
run "$T/work" projA init
check "re-init leaves .env alone" cmp -s "$A/.env" "$T/env.before"
echo "RUN true" >> "$A/image/Dockerfile"; cp "$A/image/Dockerfile" "$T/df.before"
run "$T/work" projA init
check "re-init leaves image/Dockerfile alone" cmp -s "$A/image/Dockerfile" "$T/df.before"

run "$T/work" ls
check "ls lists both instances" grep -q 'pickled-claude-proj-b *2223 *8081' "$T/out"
rm -rf "$T"

setup
STUB_LISTEN="2222 2223 8080" run "$T/work" projA init
check "ports in use are skipped" \
    test "$(envval SSH_PORT "$T/work/projA/.env"):$(envval INJECT_PORT "$T/work/projA/.env")" = 2224:8081
STUB_PROJECTS="pickled-claude-projb pickled-claude-projb-2" run "$T/work" projB init
check "taken project names get a suffix" \
    test "$(envval COMPOSE_PROJECT_NAME "$T/work/projB/.env")" = pickled-claude-projb-3
mkdir -p "$T/work/pickled-claude"
run "$T/work" pickled-claude init
check "no doubled prefix" \
    test "$(envval COMPOSE_PROJECT_NAME "$T/work/pickled-claude/.env")" = pickled-claude
rm -rf "$T"

echo "# pickled-claude commands"
setup
run "$T/work" projA init
A=$T/work/projA
check "init says how to go on" grep -q "pickled-claude projA up" "$T/out"
: > "$T/log"
run "$T/work" projA up
C="PICKLED_CLAUDE_SRC=$REPO docker compose -f $REPO/compose.yaml --project-directory $A --env-file $A/.env -p pickled-claude-proja"
check "up builds the base, then the overlay, then starts" test \
    "$(grep -F "$C" "$T/log")" = "$C build base
$C build claude
$C up -d"
check "up shows the info afterwards" grep -q 'SSH   127.0.0.1:2222 -> 22' "$T/out"
: > "$T/log"
run "$T/work" projA build --pull --no-cache
check "build options go to the base image only" test \
    "$(grep -F "$C" "$T/log")" = "$C build --pull --no-cache base
$C build claude"
: > "$T/log"
RUN_ENV=(GID=4242 SSH_PORT=1)
run "$T/work" projA up
RUN_ENV=()
check "variables of the .env do not leak in from the shell" grep -qxF "env GID=unset SSH_PORT=unset" "$T/log"
: > "$T/log"
run "$T" "$A" logs -f
check "an absolute instance path works, other commands go to compose" \
    grep -qF -- "--project-directory $A --env-file $A/.env -p pickled-claude-proja logs -f" "$T/log"
run "$T/work" projA info
check "info: SSH port mapping" grep -q 'SSH   127.0.0.1:2222 -> 22 .*ssh -p 2222 claude@127.0.0.1' "$T/out"
check "info: HTTP port mapping" grep -q 'HTTP  127.0.0.1:8080 -> 8080 .*http://127.0.0.1:8080/' "$T/out"
check "info: own images" grep -q 'pickled-claude-proja-base, pickled-claude-proja-claude' "$T/out"
: > "$T/log"
run "$T/work" projA ssh peek 10
check "ssh uses the instance port and host key alias" \
    grep -qxF "ssh -p 2222 -o HostKeyAlias=pickled-claude-proja claude@127.0.0.1 peek 10" "$T/log"
: > "$T/log"
mkdir -p "$T/work/plain"
run "$T/work" plain up; rc=$?
check "refuses a directory without .env" test "$rc" = 1 -a ! -s "$T/log"
check "and says how to create it" grep -q 'plain init' "$T/out"
run "$T/work" projA; rc=$?
check "an instance without a command is an error" test "$rc" = 1

: > "$T/log"
run "$T/work" projA delete < /dev/null; rc=$?
check "delete without confirmation deletes nothing" test "$rc" = 1 -a -f "$A/.env" -a ! -s "$T/log"
run "$T/work" projA delete <<< "wrong"; rc=$?
check "delete with the wrong name deletes nothing" test "$rc" = 1 -a -f "$A/.env"
run "$T/work" projA delete <<< "pickled-claude-proja"; rc=$?
check "delete with the name typed removes the directory" test "$rc" = 0 -a ! -e "$A"
check "delete stops the instance" \
    grep -q -- "-p pickled-claude-proja down --remove-orphans" "$T/log"
check "delete removes the images" grep -q "docker image rm pickled-claude-proja-claude pickled-claude-proja-base" "$T/log"
check "delete unregisters the instance" test -z "$(grep -xF "$A" "$T/registry")"
run "$T/work" projB init
run "$T/work" projB delete --yes
check "delete --yes needs no confirmation" test ! -e "$T/work/projB"
run "$T/work" plain delete --yes; rc=$?
check "delete refuses a directory that is not an instance" test "$rc" = 1 -a -d "$T/work/plain"
rm -rf "$T"

if docker compose version >/dev/null 2>&1; then
    echo "# docker compose config of two instances"
    T=$(mktemp -d)
    export PICKLED_CLAUDE_REGISTRY=$T/registry
    (cd "$T" && "$WRAPPER" one init && "$WRAPPER" two init) > /dev/null 2>&1
    (cd "$T" && "$WRAPPER" one config) > "$T/one.yaml" 2>&1
    (cd "$T" && "$WRAPPER" two config) > "$T/two.yaml" 2>&1
    check "instance one: own project" \
        grep -q "^name: pickled-claude-one" "$T/one.yaml"
    check "instance one: bind sources in its directory" grep -q "source: $T/one/.volume_sessions" "$T/one.yaml"
    check "instance one: base image from the repository" grep -q "context: $REPO\$" "$T/one.yaml"
    check "instance one: overlay from its own image/" grep -q "context: $T/one/image\$" "$T/one.yaml"
    check "instance one: overlay builds FROM its own base" grep -q "BASE: pickled-claude-one-base" "$T/one.yaml"
    (cd "$T" && "$WRAPPER" one config --images) > "$T/one.images" 2>&1
    (cd "$T" && "$WRAPPER" two config --images) > "$T/two.images" 2>&1
    check "instance one: images named after the instance" \
        test "$(sort "$T/one.images" | tr '\n' ' ')" = "pickled-claude-one-base pickled-claude-one-claude "
    check "instances share no image" test -z "$(comm -12 <(sort "$T/one.images") <(sort "$T/two.images"))"
    (cd "$T" && GID=4242 "$WRAPPER" one config) > "$T/one-env.yaml" 2>&1
    check "an exported GID does not override the instance's" grep -q "GID: \"$(id -g)\"" "$T/one-env.yaml"
    check "instance two: own project" grep -q "^name: pickled-claude-two" "$T/two.yaml"
    check "instance two: bind sources in its directory" grep -q "source: $T/two/workspace" "$T/two.yaml"
    check "instances publish different ports" \
        test "$(grep published "$T/one.yaml")" != "$(grep published "$T/two.yaml")"
    rm -rf "$T"
fi

echo "# $pass passed, $fail failed"
[ "$fail" -eq 0 ]
