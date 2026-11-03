# Each test gets a scratch HOME, a scratch store ($TEKEN_STATE) and a
# spec directory with a local git repo as its only source, so builds
# run for real without touching the network or the real home.

setup_env() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export TKN="$PROJECT_ROOT/bin/tkn"
    export WORK="$BATS_TEST_DIRNAME/.tmp-$BATS_TEST_NUMBER"
    rm -rf "$WORK"
    mkdir -p "$WORK/home" "$WORK/spec/envs" "$WORK/spec/units" "$WORK/src"
    export HOME="$WORK/home"
    export TEKEN_STATE="$WORK/state"
    export CURRENT="$TEKEN_STATE/envs/test/current"
    make_source
    cd "$WORK/spec"
}

teardown_env() {
    rm -rf "$WORK"
}

git_test() {
    git -c user.name=test -c user.email=test@example.com "$@"
}

# A repo whose build writes out/hello, printing $GREETING (default "hi").
make_source() {
    mkdir -p "$WORK/src/hello"
    cat > "$WORK/src/hello/build.sh" <<'SH'
mkdir -p out
printf '#!/bin/sh\necho %s\n' "${GREETING:-hi}" > out/hello
chmod +x out/hello
SH
    git_test -C "$WORK/src/hello" init -q -b main
    git_test -C "$WORK/src/hello" add -A
    git_test -C "$WORK/src/hello" commit -q -m init
}

# env '"a", "b"' [extra fields] -> envs/test.lua using units a and b.
env_file() {
    printf 'return {target = "home", units = {%s}, %s}\n' "$1" "${2:-}" > envs/test.lua
}

# unit name < lua -> units/name.lua
unit() {
    cat > "units/$1.lua"
}

# The standard unit: builds hello into bin/, links a dotfile.
hello_unit() {
    unit hello <<LUA
return {
    sources = {hello = {git = "$WORK/src/hello"}},
    build = {{name = "hello", from = "hello", cmd = "sh build.sh", install = {["out/hello"] = "bin/hello"}}},
    files = {{path = "files/rc", content = "${1:-one}\n"}},
    links = {{path = "~/.rc", target = "files/rc"}},
    verify = {"hello"},
}
LUA
}

active() {
    basename "$(readlink "$CURRENT")"
}
