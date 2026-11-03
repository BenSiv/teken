-- Nothing to build: a file, a link to it, an env var, and checks that
-- all three arrived.
return {
    files = {{path = "files/smoke-rc", content = "teken smoke test\n"}},
    links = {{path = "~/.teken-smoke/rc", target = "files/smoke-rc"}},
    env = {TEKEN_SMOKE = "1"},
    verify = {
        "grep -q 'teken smoke test' \"$TEKEN_GEN/files/smoke-rc\"",
        "test \"$TEKEN_SMOKE\" = 1",
    },
}
