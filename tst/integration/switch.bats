load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "switch builds, verifies and activates a generation" {
    hello_unit
    env_file '"hello"'
    "$TKN" lock envs/test.lua
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.rc")" = "one" ]
    [ "$(readlink "$HOME/.rc")" = "$CURRENT/files/rc" ]
    [ "$("$CURRENT/bin/hello")" = "hi" ]
    grep -q "export PATH='$CURRENT/bin'" "$CURRENT/env.sh"
    run "$TKN" status envs/test.lua
    [ "$status" -eq 0 ]
    [[ "$output" == *"(active)"* ]]
}

@test "an unchanged spec switches to nothing" {
    hello_unit
    env_file '"hello"'
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to do."* ]]
}

@test "inputs must be pinned before anything is built" {
    hello_unit
    env_file '"hello"'
    run "$TKN" plan envs/test.lua
    [ "$status" -eq 0 ]
    [[ "$output" == *"not pinned: source hello"* ]]
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"run: tkn lock"* ]]
    [ ! -e "$CURRENT" ]
}

@test "the lock pins the commit, and only update moves it" {
    hello_unit
    env_file '"hello"'
    "$TKN" lock envs/test.lua
    first=$(git -C "$WORK/src/hello" rev-parse HEAD)
    grep -q "$first" lock.lua
    echo '# change' >> "$WORK/src/hello/build.sh"
    git_test -C "$WORK/src/hello" commit -q -am change
    run "$TKN" lock envs/test.lua
    [[ "$output" == *"up to date"* ]]
    grep -q "$first" lock.lua
    run "$TKN" update envs/test.lua
    [ "$status" -eq 0 ]
    grep -q "$(git -C "$WORK/src/hello" rev-parse HEAD)" lock.lua
}

@test "a failed build leaves the active generation untouched" {
    hello_unit
    env_file '"hello"'
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    before=$(active)
    sed -i 's/cmd = "sh build.sh"/cmd = "exit 1"/' units/hello.lua
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"build step 'hello' failed"* ]]
    [ "$(active)" = "$before" ]
    [ "$(cat "$HOME/.rc")" = "one" ]
    [ -z "$(ls "$TEKEN_STATE/envs/test/gens" | grep tmp)" ]
}

@test "a failed verify keeps the candidate and leaves the active one" {
    hello_unit
    env_file '"hello"'
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    before=$(active)
    sed -i 's/verify = {"hello"}/verify = {"hello", "false"}/' units/hello.lua
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"verify failed: false"* ]]
    [[ "$output" == *"candidate is kept"* ]]
    [ "$(active)" = "$before" ]
}

@test "a failed health check rolls back the switch and its links" {
    hello_unit
    env_file '"hello"'
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    before=$(active)
    # Passes in the candidate, fails once it is live behind current.
    unit extra <<'LUA'
return {
    files = {{path = "files/extra", content = "x"}},
    links = {{path = "~/.extra", target = "files/extra"}},
    verify = {"case \"$TEKEN_GEN\" in */current) exit 1;; esac"},
}
LUA
    env_file '"hello", "extra"'
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"health check failed"* ]]
    [[ "$output" == *"rolling back to $before"* ]]
    [ "$(active)" = "$before" ]
    [ ! -e "$HOME/.extra" ] && [ ! -L "$HOME/.extra" ]
    [ ! -e "$TEKEN_STATE/envs/test/intent.lua" ]
}

@test "build steps are reused when only other inputs change" {
    hello_unit one
    env_file '"hello"'
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    hello_unit two
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"= hello (cached)"* ]]
    [ "$(cat "$HOME/.rc")" = "two" ]
}

@test "build steps can use an earlier step's tree" {
    unit chain <<LUA
return {
    sources = {hello = {git = "$WORK/src/hello"}},
    build = {
        {name = "base", from = "hello", cmd = "sh build.sh", install = {["out/hello"] = "bin/hello"}},
        {name = "copy", from = "hello", needs = {"base"}, env = {BASE = "\${build.base}"},
         cmd = "mkdir -p out && cp \"\$BASE/out/hello\" out/again", install = {["out/again"] = "bin/again"}},
    },
    verify = {"again"},
}
LUA
    env_file '"chain"'
    "$TKN" lock envs/test.lua
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 0 ]
    [ "$("$CURRENT/bin/again")" = "hi" ]
}
