load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "rollback returns to the previous generation and its links" {
    hello_unit one
    env_file '"hello"'
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    first=$(active)
    unit extra <<'LUA'
return {files = {{path = "files/extra", content = "x"}}, links = {{path = "~/.extra", target = "files/extra"}}}
LUA
    hello_unit two
    env_file '"hello", "extra"'
    "$TKN" switch envs/test.lua -y
    [ -L "$HOME/.extra" ]
    run "$TKN" rollback envs/test.lua -y
    [ "$status" -eq 0 ]
    [ "$(active)" = "$first" ]
    [ "$(cat "$HOME/.rc")" = "one" ]
    [ ! -L "$HOME/.extra" ]
    run "$TKN" rollback envs/test.lua -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"no previous generation"* ]]
}

@test "a file where a link goes is adopted, and restored when the link goes" {
    echo mine > "$HOME/.rc"
    hello_unit
    env_file '"hello"'
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    [ "$(cat "$HOME/.rc")" = "one" ]
    unit other <<'LUA'
return {files = {{path = "files/other", content = "x"}}}
LUA
    env_file '"other"'
    "$TKN" switch envs/test.lua -y
    [ ! -L "$HOME/.rc" ]
    [ "$(cat "$HOME/.rc")" = "mine" ]
}

@test "the first switch rolled back leaves nothing behind" {
    echo mine > "$HOME/.rc"
    unit hello <<LUA
return {
    files = {{path = "files/rc", content = "one"}},
    links = {{path = "~/.rc", target = "files/rc"}},
    verify = {"case \"\$TEKEN_GEN\" in */current) exit 1;; esac"},
}
LUA
    env_file '"hello"'
    run "$TKN" switch envs/test.lua -y
    [ "$status" -eq 1 ]
    [ ! -e "$CURRENT" ] && [ ! -L "$CURRENT" ]
    [ ! -L "$HOME/.rc" ]
    [ "$(cat "$HOME/.rc")" = "mine" ]
}

@test "an interrupted switch is rolled back by the next command" {
    hello_unit one
    env_file '"hello"'
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    first=$(active)
    hello_unit two
    "$TKN" build envs/test.lua
    second=$(ls "$TEKEN_STATE/envs/test/gens" | grep -v "$first")
    # What a crash right after the rename of current leaves behind.
    printf 'return {from = "%s", to = "%s"}\n' "$first" "$second" > "$TEKEN_STATE/envs/test/intent.lua"
    ln -sfn "gens/$second" "$CURRENT"
    run "$TKN" status envs/test.lua
    [[ "$output" == *"interrupted switch"* ]]
    [ "$(active)" = "$first" ]
    [ "$(cat "$HOME/.rc")" = "one" ]
    [ ! -e "$TEKEN_STATE/envs/test/intent.lua" ]
}

@test "history keeps 'keep' generations and gc removes the rest" {
    env_file '"hello"' 'keep = 2'
    for n in one two three; do
        hello_unit "$n"
        [ -f lock.lua ] || "$TKN" lock envs/test.lua
        "$TKN" switch envs/test.lua -y
    done
    [ "$(ls "$TEKEN_STATE/envs/test/gens" | wc -l)" -eq 2 ]
    hello_unit four
    "$TKN" build envs/test.lua
    [ "$(ls "$TEKEN_STATE/envs/test/gens" | wc -l)" -eq 3 ]
    run "$TKN" gc
    [ "$status" -eq 0 ]
    [[ "$output" == *"removed 1 generation(s)"* ]]
    [ "$(ls "$TEKEN_STATE/envs/test/gens" | wc -l)" -eq 2 ]
}

@test "two tkn runs cannot change one env at once" {
    hello_unit
    env_file '"hello"'
    mkdir -p "$TEKEN_STATE/envs/test/run.lock"
    run "$TKN" plan envs/test.lua
    [ "$status" -eq 1 ]
    [[ "$output" == *"another tkn is changing env 'test'"* ]]
}

@test "rollback checks the old generation with its own verify, not the spec's" {
    hello_unit one
    env_file '"hello"'
    "$TKN" lock envs/test.lua
    "$TKN" switch envs/test.lua -y
    first=$(active)
    hello_unit two
    "$TKN" switch envs/test.lua -y
    # The spec moves on; what generation one was built to pass does not.
    sed -i 's/verify = {"hello"}/verify = {"hello", "false"}/' units/hello.lua
    run "$TKN" rollback envs/test.lua -y
    [ "$status" -eq 0 ]
    [ "$(active)" = "$first" ]
    [ "$(cat "$HOME/.rc")" = "one" ]
}
