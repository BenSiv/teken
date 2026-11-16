-- tst/unit/help.lua
-- Unit tests for src/help.lua: every CLI command has a dedented help
-- entry, and unknown keys return nil.

help = require("help")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

COMMANDS = {"plan", "build", "switch", "rollback", "gens", "status", "lock", "update", "gc"}

function test_root_help()
    print("Testing top-level tkn help")
    text = help.get_help_string("tkn")
    check(text != nil, "tkn help exists")
    check(string.starts_with(text, "Usage: tkn "), "tkn help starts with Usage: tkn")
    check(string.contains(text, "tkn <command> -h or --help"), "tkn help points to per-command help")
    for _, cmd in ipairs(COMMANDS) do
        check(string.match(text, "%s+" .. cmd .. "%s+") != nil, "tkn help lists " .. cmd)
    end
end

function test_per_command_help()
    print("Testing per-command help strings")
    for _, cmd in ipairs(COMMANDS) do
        key = "tkn " .. cmd
        text = help.get_help_string(key)
        check(text != nil, key .. " help exists")
        if text != nil then
            check(string.starts_with(text, "Usage: tkn " .. cmd), key .. " starts with Usage")
            check(string.contains(text, "\nDescription:\n"), key .. " has Description section")
            check(string.contains(text, "\nOptions:\n"), key .. " has Options section")
            check(string.contains(text, "\nExamples:\n"), key .. " has Examples section")
        end
    end
end

function test_unknown_command()
    print("Testing unknown command returns nil")
    check(help.get_help_string("tkn unknown") == nil, "unknown subcommand is nil")
    check(help.get_help_string("unknown") == nil, "unknown root is nil")
end

test_root_help()
test_per_command_help()
test_unknown_command()

if FAILURES > 0 then
    print(FAILURES .. " failure(s)")
    os.exit(1)
end
print("ok")
