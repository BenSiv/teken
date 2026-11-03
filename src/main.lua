-- tkn: builds environments from a spec and switches to them all at once
-- or not at all. See doc/design.md.

if package.preload["lifecycle"] == nil then
    script_dir = string.match(arg[0], "^(.*/)")
    if script_dir == nil then
        script_dir = "./"
    end
    package.path = script_dir .. "?.lua;" .. package.path
end

shell = require("shell")
store = require("store")
loader = require("loader")
lock = require("lock")
lifecycle = require("lifecycle")
version = require("version")

USAGE = """usage: tkn <command> [env.lua] [options]

  plan     [env]          what switch would build and change; nothing runs
  build    [env]          build and verify the spec's generation, no activation
  switch   [env] [-y]     build, verify, activate, health check; roll back on failure
           --discard-undeclared   (container) replace it even when its own
                                  layer has changes outside declared state
  rollback [env] [-y]     activate the previous generation
  gens     [env]          list generations; * marks the active one
  status   [env]          exit 2 when the active generation is not the spec's
  lock     [env]          pin inputs not yet in lock.lua
  update   [env] [name..] move pins forward (all, or the named sources/URLs)
  gc                      remove generations and build steps nothing keeps
  --version

env defaults to envs/<hostname>.lua. Exit codes: 0 done, 1 failed (rolled
back cleanly), 2 drift (status), 3 failed and could not roll back."""

ENV_COMMANDS = {
    plan = true, build = true, switch = true, rollback = true,
    gens = true, status = true, lock = true, update = true,
}

function parse_args(args)
    options = {yes = false, names = {}, discard_undeclared = false}
    for _, value in ipairs(args) do
        if value == "-y" or value == "--yes" then
            options.yes = true
        elseif value == "-h" or value == "--help" then
            options.help = true
        elseif value == "--discard-undeclared" then
            options.discard_undeclared = true
        elseif value == "--version" then
            options.version = true
        elseif string.sub(value, 1, 1) == "-" then
            error("unknown option " .. value, 0)
        elseif options.command == nil then
            options.command = value
        elseif options.env == nil and string.match(value, "%.lua$") != nil then
            options.env = value
        elseif options.command == "update" then
            table.insert(options.names, value)
        else
            error("unexpected argument " .. value, 0)
        end
    end
    return options
end

-- uname -n rather than hostname: every distribution has uname.
function default_env()
    out, _ = shell.capture("uname -n")
    return "envs/" .. shell.trim(out) .. ".lua"
end

function confirm(question)
    if shell.ok("test -t 0") == false then
        error("this needs -y when not run from a terminal", 0)
    end
    io.write(question .. " [y/N] ")
    answer = io.read("*l")
    return answer == "y" or answer == "Y" or answer == "yes"
end

function print_gens(env)
    history = store.history(env.name)
    active = store.active(env.name)
    listed = {}
    for index = #history, 1, -1 do
        id = history[index]
        listed[id] = true
        mark = " "
        if id == active then
            mark = "*"
        end
        meta = store.meta(env.name, id)
        created = "?"
        if meta != nil then
            created = meta.created
        end
        print(mark .. " " .. id .. "  " .. created)
    end
    for _, id in ipairs(store.gens(env.name)) do
        if listed[id] != true then
            print("  " .. id .. "  (built, never activated)")
        end
    end
    return 0
end

function run_lock(env, update, names)
    pins = lock.read(env.spec_dir)
    changes = lock.pin(env, pins, update, names)
    if #changes == 0 then
        print("lock.lua is up to date")
        return 0
    end
    lock.write(env.spec_dir, pins)
    for _, change in ipairs(changes) do
        print("  " .. change)
    end
    return 0
end

function run_env_command(command, env, options)
    if command == "lock" then
        return run_lock(env, false, {})
    end
    if command == "update" then
        return run_lock(env, true, options.names)
    end
    if command == "gens" then
        return print_gens(env)
    end
    if command == "rollback" then
        if options.yes == false and confirm("Roll " .. env.name .. " back?") == false then
            print("Not rolled back.")
            return 1
        end
        return lifecycle.rollback(env, options)
    end
    plan = lifecycle.plan(env)
    lifecycle.print_plan(plan)
    if command == "plan" then
        return 0
    end
    if command == "status" then
        if #plan.missing > 0 or plan.id != plan.active then
            return lifecycle.DRIFT
        end
        return 0
    end
    if command == "build" then
        lifecycle.build(env)
        return 0
    end
    -- Before comparing ids: with unpinned inputs there is no spec id.
    lock.require_pinned(env, lock.read(env.spec_dir))
    if plan.id == plan.active then
        print("Nothing to do.")
        return 0
    end
    if options.yes == false and confirm("Switch " .. env.name .. "?") == false then
        print("Not switched.")
        return 1
    end
    id = lifecycle.build(env)
    return lifecycle.switch(env, id, options)
end

function main(args)
    options = parse_args(args)
    if options.version == true then
        print(version.describe())
        return 0
    end
    if options.help == true or options.command == nil then
        print(USAGE)
        if options.help == true then
            return 0
        end
        return 1
    end
    command = options.command
    if command == "gc" then
        return lifecycle.gc()
    end
    if ENV_COMMANDS[command] != true then
        error("unknown command " .. command .. "\n\n" .. USAGE, 0)
    end
    env_path = options.env
    if env_path == nil then
        env_path = default_env()
    end
    env = loader.load(env_path)
    -- Every env command holds the env's run lock and first finishes off
    -- an interrupted switch, so it always sees a consistent env.
    store.lock(env.name)
    ok, result = pcall(function()
        lifecycle.recover(env)
        return run_env_command(command, env, options)
    end)
    store.unlock(env.name)
    if ok != true then
        error(result, 0)
    end
    return result
end

ok, result = pcall(main, arg)
if ok != true then
    io.write(io.stderr, "tkn: " .. tostring(result) .. "\n")
    os.exit(1)
end
os.exit(result)
