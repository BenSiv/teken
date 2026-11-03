load test_helper

# Runtime start (0.3.0): repos cloned into state, links into state, the
# generated /opt/teken/start entrypoint, and the health check waiting
# for it. The start script is run for real with sh, with every path it
# touches under $WORK.

setup() {
    setup_env
    export PODMAN_STATE="$WORK/podman"
    export LOG="$WORK/log"
    mkdir -p "$WORK/bin"
    cp "$BATS_TEST_DIRNAME/fake-podman" "$WORK/bin/podman"
    chmod +x "$WORK/bin/podman"
    export PATH="$WORK/bin:$PATH"
    export TEKEN_RUN="$WORK/run"
    export TEKEN_LOGS="$WORK/logs"
}
teardown() { teardown_env; }

# box_env [extra container fields] -> a container env using unit "box"
# with its state, a volume, at $WORK/vol.
box_env() {
    cat > envs/test.lua <<LUA
return {
    target = "container",
    units = {"box"},
    container = {name = "box", base = "ubuntu:24.04", health_wait = 0, home = "$WORK/chome", start_timeout = 3, ${1:-}},
    state = {{path = "$WORK/vol", volume = "box-data"}},
}
LUA
    # Rejection tests expect this to fail; their own run shows why.
    "$TKN" lock envs/test.lua > /dev/null 2>&1 || true
}

# box_unit < lua fields -> units/box.lua (inside `return {...}`)
box_unit() {
    { echo "return {"; cat; echo "}"; } > units/box.lua
}

start_script() {
    ls -d "$TEKEN_STATE"/envs/test/gens/*/ | head -1 | sed 's|/$||;s|$|/start|'
}

@test "start clones missing repos, runs start entries, then the command" {
    box_unit <<LUA
    repos = {{path = "$WORK/vol/hello", git = "$WORK/src/hello"}},
    start = {
        {name = "mark", cmd = "echo started >> $WORK/vol/marks"},
        {name = "loop", cmd = "echo bg > $WORK/vol/bg", background = true},
    },
LUA
    box_env
    run "$TKN" build envs/test.lua
    [ "$status" -eq 0 ]
    script="$(start_script)"
    [ -f "$script" ]
    run sh "$script" echo the-command
    [ "$status" -eq 0 ]
    [[ "$output" == *"the-command"* ]]
    [ -f "$WORK/vol/hello/build.sh" ]
    [ "$(cat "$TEKEN_RUN/start.status")" = done ]
    [ "$(cat "$WORK/vol/marks")" = started ]
    for i in 1 2 3 4 5; do [ -f "$WORK/vol/bg" ] && break; sleep 0.2; done
    [ "$(cat "$WORK/vol/bg")" = bg ]
}

@test "start never touches an existing checkout and reruns cleanly" {
    box_unit <<LUA
    repos = {{path = "$WORK/vol/hello", git = "$WORK/src/hello"}},
    start = {{name = "mark", cmd = "echo started >> $WORK/vol/marks"}},
LUA
    box_env
    "$TKN" build envs/test.lua
    script="$(start_script)"
    sh "$script" true
    echo local-work > "$WORK/vol/hello/build.sh"
    run sh "$script" true
    [ "$status" -eq 0 ]
    [ "$(cat "$WORK/vol/hello/build.sh")" = local-work ]
    [ "$(wc -l < "$WORK/vol/marks")" -eq 2 ]
}

@test "a failed clone is a warning, not a failed start" {
    box_unit <<LUA
    repos = {{path = "$WORK/vol/gone", git = "$WORK/src/does-not-exist"}},
LUA
    box_env
    "$TKN" build envs/test.lua
    run sh "$(start_script)" true
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not clone"* ]]
    [ "$(cat "$TEKEN_RUN/start.status")" = done ]
}

@test "a failed start entry stops the start before the command" {
    box_unit <<LUA
    start = {{name = "broken", cmd = "exit 3"}, {name = "after", cmd = "touch $WORK/vol/after"}},
LUA
    box_env
    "$TKN" build envs/test.lua
    run sh "$(start_script)" echo the-command
    [ "$status" -ne 0 ]
    [[ "$output" == *"broken failed"* ]]
    [[ "$output" != *"the-command"* ]]
    [ ! -e "$WORK/vol/after" ]
    [ "$(cat "$TEKEN_RUN/start.status")" = failed ]
}

@test "the image runs the start script as its entrypoint" {
    box_unit <<LUA
    start = {{name = "mark", cmd = "true"}},
LUA
    box_env
    "$TKN" build envs/test.lua
    image="$(ls "$PODMAN_STATE/images" | head -1)"
    grep -q 'ENTRYPOINT \["/opt/teken/start"\]' "$PODMAN_STATE/images/$image"
    grep -q 'COPY \["teken-start", "/opt/teken/start"\]' "$PODMAN_STATE/images/$image"
}

@test "a failed start rolls the switch back" {
    box_unit <<LUA
    start = {{name = "mark", cmd = "true"}},
    files = {{path = "files/v", content = "one"}},
LUA
    box_env
    "$TKN" switch envs/test.lua -y
    first="$(active)"
    sed -i 's/"one"/"two"/' units/box.lua
    FAKE_START=failed run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"start of box failed"* ]]
    [ "$(active)" = "$first" ]
    grep -q "running=true" "$PODMAN_STATE/containers/box"
}

@test "links into state are baked into the image" {
    box_unit <<LUA
    links = {{path = "~/.claude/settings.json", target = "$WORK/vol/repo/settings.json"}},
LUA
    box_env
    run "$TKN" build envs/test.lua
    [ "$status" -eq 0 ]
    image="$(ls "$PODMAN_STATE/images" | head -1)"
    grep -q "ln -s '$WORK/vol/repo/settings.json' '$WORK/chome/.claude/settings.json'" "$PODMAN_STATE/images/$image"
}

@test "an absolute link target outside state is rejected" {
    box_unit <<LUA
    links = {{path = "~/.x", target = "/etc/passwd"}},
LUA
    box_env
    run "$TKN" plan envs/test.lua
    [ "$status" -ne 0 ]
    [[ "$output" == *"not inside a state path"* ]]
}

@test "a repo outside state is rejected" {
    box_unit <<LUA
    repos = {{path = "/opt/hello", git = "$WORK/src/hello"}},
LUA
    box_env
    run "$TKN" plan envs/test.lua
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be inside a state path"* ]]
}

@test "start is for containers only" {
    unit hello <<LUA
return {start = {{name = "x", cmd = "true"}}}
LUA
    env_file '"hello"'
    run "$TKN" plan envs/test.lua
    [ "$status" -ne 0 ]
    [[ "$output" == *"'start' is not available for target 'home'"* ]]
}

@test "passenv and present sockets reach podman create" {
    box_unit <<LUA
    files = {{path = "files/v", content = "one"}},
LUA
    touch "$WORK/sock"
    box_env 'passenv = {"FAKE_DISPLAY", "UNSET_VAR"}, sockets = {"$WORK/sock", "\$UNSET_VAR/x"}'
    FAKE_DISPLAY=wayland-9 run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping socket"* ]]
    grep "^podman create" "$LOG" | grep -q -- "--env FAKE_DISPLAY=wayland-9"
    ! grep "^podman create" "$LOG" | grep -q UNSET_VAR
    grep "^podman create" "$LOG" | grep -q -- "--volume $WORK/sock:$WORK/sock"
}

@test "home: switch clones missing repos and links into state" {
    hello_unit
    unit work <<LUA
return {
    repos = {{path = "$WORK/home/Projects/hello", git = "$WORK/src/hello"}},
    links = {{path = "~/.hello-build", target = "$WORK/home/Projects/hello/build.sh"}},
}
LUA
    env_file '"hello", "work"' "state = {{path = \"$WORK/home/Projects\"}},"
    "$TKN" lock envs/test.lua > /dev/null
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 0 ]
    [ -f "$WORK/home/Projects/hello/build.sh" ]
    [ "$(readlink "$HOME/.hello-build")" = "$WORK/home/Projects/hello/build.sh" ]
    # Dropping the link removes it; the checkout stays.
    sed -i '/hello-build/d' units/work.lua
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 0 ]
    [ ! -L "$HOME/.hello-build" ]
    [ -d "$WORK/home/Projects/hello" ]
}
