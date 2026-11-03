load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "unknown unit fields are rejected before anything runs" {
    unit bad <<'LUA'
return {pakages = {"jq"}}
LUA
    env_file '"bad"'
    run "$TKN" plan envs/test.lua
    [ "$status" -eq 1 ]
    [[ "$output" == *"units/bad.lua: unknown field 'pakages'"* ]]
}

@test "a field the target can't use names the target" {
    unit bad <<'LUA'
return {apt = {"jq"}}
LUA
    env_file '"bad"'
    run "$TKN" plan envs/test.lua
    [ "$status" -eq 1 ]
    [[ "$output" == *"'apt' is not available for target 'home'"* ]]
}

@test "a container env needs its container section" {
    printf 'return {target = "container", units = {"x"}}\n' > envs/test.lua
    run "$TKN" plan envs/test.lua
    [ "$status" -eq 1 ]
    [[ "$output" == *"a container env needs a 'container' section"* ]]
}

@test "container state needs a volume or a bind mount" {
    unit a <<'LUA'
return {verify = {"true"}}
LUA
    printf 'return {target = "container", units = {"a"}, container = {name = "c", base = "ubuntu:24.04"}, state = {{path = "/data"}}}\n' > envs/test.lua
    run "$TKN" plan envs/test.lua
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs exactly one of 'volume' and 'bind'"* ]]
}

@test "two units claiming the same link fail with both places" {
    unit a <<'LUA'
return {files = {{path = "files/a", content = "a"}}, links = {{path = "~/.x", target = "files/a"}}}
LUA
    unit b <<'LUA'
return {files = {{path = "files/b", content = "b"}}, links = {{path = "~/.x", target = "files/b"}}}
LUA
    env_file '"a", "b"'
    run "$TKN" plan envs/test.lua
    [ "$status" -eq 1 ]
    [[ "$output" == *"units/b.lua: links[1]"*"already declared in"*"units/a.lua"* ]]
}

@test "a build step may only use steps it needs" {
    unit bad <<LUA
return {
    sources = {hello = {git = "$WORK/src/hello"}},
    build = {
        {name = "a", from = "hello", cmd = "true", install = {["build.sh"] = "a"}},
        {name = "b", from = "hello", cmd = "ls \${build.a}", install = {["build.sh"] = "b"}},
    },
}
LUA
    env_file '"bad"'
    run "$TKN" plan envs/test.lua
    [ "$status" -eq 1 ]
    [[ "$output" == *"\${build.a} needs 'a' in needs"* ]]
}

@test "links may not overlap declared state" {
    unit a <<'LUA'
return {files = {{path = "files/a", content = "a"}}, links = {{path = "~/src/x", target = "files/a"}}}
LUA
    env_file '"a"' 'state = {{path = "~/src"}}'
    run "$TKN" plan envs/test.lua
    [ "$status" -eq 1 ]
    [[ "$output" == *"overlaps state path"* ]]
}

@test "unknown variables are an error" {
    unit a <<'LUA'
return {env = {X = "${nope}"}}
LUA
    env_file '"a"'
    run "$TKN" plan envs/test.lua
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown variable \${nope}"* ]]
}
