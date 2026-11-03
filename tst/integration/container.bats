load test_helper

# The container target against tst/integration/fake-podman: images and
# containers are files under $PODMAN_STATE, so a test can read what
# each container runs and whether it is running.

setup() {
    setup_env
    export PODMAN_STATE="$WORK/podman"
    export LOG="$WORK/log"
    mkdir -p "$WORK/bin"
    cp "$BATS_TEST_DIRNAME/fake-podman" "$WORK/bin/podman"
    chmod +x "$WORK/bin/podman"
    export PATH="$WORK/bin:$PATH"
    tools_unit
    container_env
}
teardown() { teardown_env; }

# container_env [extra env fields]
container_env() {
    cat > envs/test.lua <<LUA
return {
    target = "container",
    units = {"tools"},
    container = {name = "box", base = "ubuntu:24.04", health_wait = 0, tty = true, ports = {"8000:8000"}},
    state = {{path = "/data", volume = "box-data"}, {path = "/root/rnd", bind = "~/rnd"}},
    ${1:-}
}
LUA
}

# tools_unit [verify command] [EDITOR value]
tools_unit() {
    verify="${1:-}"
    [ -n "$verify" ] || verify='"true"'
    unit tools <<LUA
return {
    apt = {"jq", "build-essential"},
    sources = {hello = {git = "$WORK/src/hello"}},
    build = {{name = "hello", from = "hello", cmd = "sh build.sh", install = {["out/hello"] = "bin/hello"}}},
    files = {{path = "files/rc", content = "one"}},
    links = {{path = "~/.rc", target = "files/rc"}},
    env = {EDITOR = "${2:-micro}"},
    verify = {$verify},
}
LUA
}

box() {
    cat "$PODMAN_STATE/containers/$1"
}

image_of() {
    sed -n 's/^image=.*://p' "$PODMAN_STATE/containers/$1"
}

running() {
    sed -n 's/^running=//p' "$PODMAN_STATE/containers/$1"
}

containers() {
    ls "$PODMAN_STATE/containers" | grep -v '\.diff$\|\.status$' | tr '\n' ' '
}

@test "the base image must be pinned" {
    run "$TKN" plan envs/test.lua
    [[ "$output" == *"not pinned: image ubuntu:24.04, source hello"* ]]
    "$TKN" lock envs/test.lua
    grep -q '\["ubuntu:24.04"\] = "sha256:' lock.lua
}

@test "switch builds the image and starts the container" {
    "$TKN" lock envs/test.lua
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 0 ]
    id=$(active)
    file="$TEKEN_STATE/envs/test/gens/$id/Containerfile"
    grep -q "^FROM ubuntu:24.04@sha256:" "$file"
    grep -q "apt-get install -y --no-install-recommends 'jq' 'build-essential'" "$file"
    grep -qF 'COPY ["sources/hello", "/opt/teken-build/hello"]' "$file"
    grep -qF "ln -s '/opt/teken/files/rc' '/root/.rc'" "$file"
    grep -qF 'ENV PATH=/opt/teken/bin:${PATH}' "$file"
    grep -qF 'ENV EDITOR="micro"' "$file"
    grep -qF "teken.id=\"$id\"" "$file"
    [ "$(containers)" = "box " ]
    [ "$(image_of box)" = "$id" ]
    [ "$(running box)" = "true" ]
    box box | grep -qF -- "--volume box-data:/data"
    box box | grep -qF -- "--volume $HOME/rnd:/root/rnd"
    box box | grep -qF -- "--publish 8000:8000"
    run "$TKN" status envs/test.lua
    [ "$status" -eq 0 ]
}

@test "a second switch replaces the container and removes the old one" {
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    tools_unit '"true"' nano
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 0 ]
    [ "$(containers)" = "box " ]
    [ "$(image_of box)" = "$(active)" ]
    [ "$(running box)" = "true" ]
    [ "$(wc -l < "$TEKEN_STATE/envs/test/history.lua")" -gt 3 ]
}

@test "a failed image build leaves the running container alone" {
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    before=$(active)
    tools_unit '"true"' FAIL_BUILD
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"podman build of teken/test:"*"failed"* ]]
    [ "$(containers)" = "box " ]
    [ "$(image_of box)" = "$before" ]
    [ "$(running box)" = "true" ]
}

@test "a failed verify in the candidate leaves the running container alone" {
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    before=$(active)
    tools_unit '"[ \"\$FAKE_IN\" != candidate ]"'
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"verify failed"*"the image is kept"* ]]
    [ "$(image_of box)" = "$before" ]
    [ "$(grep -c '^podman create' "$LOG")" -eq 1 ]
}

@test "a failed health check puts the old container back" {
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    before=$(active)
    tools_unit '"[ \"\$FAKE_IN\" != live ]"'
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"health check failed"* ]]
    [[ "$output" == *"rolling back to $before"* ]]
    [ "$(containers)" = "box " ]
    [ "$(image_of box)" = "$before" ]
    [ "$(running box)" = "true" ]
    [ "$(active)" = "$before" ]
}

@test "changes outside declared state block the switch" {
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    printf 'C /root\nA /root/notes.txt\nC /data\nA /data/db\nA /tmp/x\nC /root/rnd\n' > "$PODMAN_STATE/containers/box.diff"
    tools_unit '"true"' nano
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"changes outside declared state"* ]]
    [[ "$output" == *"  /root/notes.txt"* ]]
    [[ "$output" != *"/data/db"* ]]
    [[ "$output" != *"/tmp/x"* ]]
    [[ "$output" != *"  /root"$'\n'* ]]
    run "$TKN" switch envs/test.lua -y --discard-undeclared
    [ "$status" -eq 0 ]
}

@test "ephemeral paths may change freely" {
    cat > envs/test.lua <<'LUA'
return {
    target = "container",
    units = {"tools"},
    container = {name = "box", base = "ubuntu:24.04", health_wait = 0, ephemeral = {"/root/.cache"}},
}
LUA
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    printf 'C /root\nC /root/.cache\nA /root/.cache/pip\n' > "$PODMAN_STATE/containers/box.diff"
    tools_unit '"true"' nano
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 0 ]
}

@test "a container teken did not create is never replaced" {
    "$TKN" lock envs/test.lua
    mkdir -p "$PODMAN_STATE/containers"
    printf 'image=other:latest\nrunning=true\n' > "$PODMAN_STATE/containers/box"
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"exists that teken did not create"* ]]
    [ "$(sed -n 's/^image=//p' "$PODMAN_STATE/containers/box")" = "other:latest" ]
}

@test "rollback makes a container from the previous image" {
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    first=$(active)
    tools_unit '"true"' nano
    "$TKN" switch envs/test.lua -y
    run "$TKN" rollback envs/test.lua -y
    [ "$status" -eq 0 ]
    [ "$(containers)" = "box " ]
    [ "$(image_of box)" = "$first" ]
    [ "$(running box)" = "true" ]
}

@test "an interrupted swap is rolled back by the next command" {
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    first=$(active)
    tools_unit '"true"' nano
    "$TKN" build envs/test.lua
    second=$(ls "$TEKEN_STATE/envs/test/gens" | grep -v "$first")
    # What a crash right after the new container started leaves behind.
    podman stop box
    podman rename box "box-$first"
    podman create --name box "teken/test:$second"
    podman start box
    printf 'return {from = "%s", to = "%s"}\n' "$first" "$second" > "$TEKEN_STATE/envs/test/intent.lua"
    ln -sfn "gens/$second" "$CURRENT"
    run "$TKN" status envs/test.lua
    [[ "$output" == *"interrupted switch"* ]]
    [ "$(containers)" = "box " ]
    [ "$(image_of box)" = "$first" ]
    [ "$(running box)" = "true" ]
    [ "$(active)" = "$first" ]
}

@test "gc removes images of generations that dropped out" {
    container_env 'keep = 2,'
    "$TKN" lock envs/test.lua
    for editor in a b c; do
        tools_unit '"true"' "$editor"
        "$TKN" switch envs/test.lua -y
    done
    [ "$(ls "$PODMAN_STATE/images" | wc -l)" -eq 2 ]
    grep -q "podman rmi" "$LOG"
}
