-- The phases every target goes through:
--
--   eval -> lock -> build -> verify -> activate -> health -> commit
--
-- Up to verify, nothing outside the store changes. Activation starts by
-- writing an intent record {from, to}; any failure from there on rolls
-- back to `from`, and the record is removed only at commit or after a
-- clean rollback. A record found at startup means a switch was
-- interrupted, so it is rolled back before anything else runs.

lfs = require("lfs")
data = require("data")
shell = require("shell")
hash = require("hash")
store = require("store")
lock = require("lock")
version = require("version")

lifecycle = {}

lifecycle.targets = {
    home = require("targets.home"),
}

-- Exit codes (see doc/design.md, CLI).
lifecycle.FAILED = 1
lifecycle.DRIFT = 2
lifecycle.STUCK = 3

function target_of(env)
    return lifecycle.targets[env.target]
end

function without_where(items)
    result = {}
    for _, item in ipairs(items) do
        copy = {}
        for key, value in pairs(item) do
            if key != "where" then
                copy[key] = value
            end
        end
        table.insert(result, copy)
    end
    return result
end

-- The generation id: everything that decides what is built, and
-- nothing else. Source pins and fetched-file digests stand in for their
-- contents; spec files copied in by `files` are hashed directly.
function lifecycle.generation_id(env, pins)
    sources = {}
    for name, source in pairs(env.sources) do
        sources[name] = {git = source.git, commit = pins.sources[name].commit}
    end
    fetch = {}
    for _, item in ipairs(env.fetch) do
        table.insert(fetch, {url = item.url, path = item.path, mode = item.mode, sha256 = pins.fetch[item.url]})
    end
    files = without_where(env.files)
    for _, item in ipairs(files) do
        if item.source != nil then
            item.sha256 = hash.file(env.spec_dir .. "/" .. item.source)
            item.source = nil
        end
    end
    return hash.id({
        teken = version.number, target = env.target, env = env.name,
        sources = sources, build = without_where(env.build), fetch = fetch,
        files = files, links = without_where(env.links), vars = env.env, verify = env.verify,
    })
end

-- Rolls back a switch that was interrupted (a crash, a killed tkn).
function lifecycle.recover(env)
    intent = store.intent(env.name)
    if intent == nil then
        return
    end
    from = intent.from
    if from == nil then
        from = "nothing"
    end
    print("an interrupted switch of " .. env.name .. " to " .. intent.to .. " was found; rolling back to " .. from)
    target_of(env).rollback(env.name, intent)
    store.set_intent(env.name, nil)
end

-- Everything `tkn plan` and `tkn status` report, without changing
-- anything. `missing` lists unpinned inputs; when there are any, the
-- generation id can't be computed yet.
function lifecycle.plan(env)
    pins = lock.read(env.spec_dir)
    result = {env = env, active = store.active(env.name), missing = lock.missing(env, pins)}
    if #result.missing > 0 then
        return result
    end
    result.id = lifecycle.generation_id(env, pins)
    result.built = store.has_gen(env.name, result.id)
    result.steps = target_of(env).steps(env, pins)
    result.links = target_of(env).link_changes(env, result.active)
    return result
end

function lifecycle.print_plan(plan)
    env = plan.env
    print("env " .. env.name .. " (target " .. env.target .. ")")
    active = plan.active
    if active == nil then
        active = "none"
    end
    print("  active: " .. active)
    if #plan.missing > 0 then
        print("  not pinned: " .. table.concat(plan.missing, ", ") .. " (run tkn lock)")
        return
    end
    state = "to build"
    if plan.built == true then
        state = "built"
    end
    if plan.id == plan.active then
        state = "active"
    end
    print("  spec:   " .. plan.id .. " (" .. state .. ")")
    if plan.id == plan.active then
        return
    end
    for _, entry in ipairs(plan.steps) do
        mark = "+"
        if entry.cached == true then
            mark = "="
        end
        print("    " .. mark .. " build " .. entry.step.name)
    end
    for _, change in ipairs(plan.links) do
        print("    " .. change .. " (link)")
    end
end

function lifecycle.build(env)
    pins = lock.read(env.spec_dir)
    lock.require_pinned(env, pins)
    id = lifecycle.generation_id(env, pins)
    target_of(env).build(env, pins, id)
    return id
end

-- Activates generation `to`, rolling back on any failure. Returns 0,
-- FAILED (rolled back cleanly) or STUCK (rollback failed too; the
-- intent record stays so the next run tries again).
function activate(env, from, to)
    target = target_of(env)
    store.set_intent(env.name, {from = from, to = to})
    print("switching " .. env.name .. " to " .. to)
    ok, err = pcall(target.activate, env, from, to)
    if ok == true then
        return 0
    end
    io.write(io.stderr, "tkn: " .. tostring(err) .. "\n")
    back = from
    if back == nil then
        back = "nothing"
    end
    print("rolling back to " .. back)
    rolled, rollback_err = pcall(target.rollback, env.name, {from = from, to = to})
    if rolled != true then
        io.write(io.stderr, "tkn: rollback failed: " .. tostring(rollback_err) .. "\n"
            .. "the intent record in " .. store.env_dir(env.name) .. " is kept; the next tkn run retries the rollback\n")
        return lifecycle.STUCK
    end
    store.set_intent(env.name, nil)
    return lifecycle.FAILED
end

-- The full lifecycle. `id` is what lifecycle.build returned.
function lifecycle.switch(env, id)
    from = store.active(env.name)
    if from == id then
        print(env.name .. " is already at " .. id)
        return 0
    end
    code = activate(env, from, id)
    if code != 0 then
        return code
    end
    history = store.history(env.name)
    table.insert(history, id)
    store.set_history(env.name, history)
    store.set_intent(env.name, nil)
    store.prune(env.name, env.keep)
    print("done: " .. env.name .. " is at " .. id)
    return 0
end

-- Activates the generation before the active one in history.
function lifecycle.rollback(env)
    history = store.history(env.name)
    active = store.active(env.name)
    if #history < 2 or history[#history] != active then
        error("no previous generation of " .. env.name .. " to roll back to", 0)
    end
    previous = history[#history - 1]
    if store.has_gen(env.name, previous) == false then
        error("generation " .. previous .. " is no longer in the store", 0)
    end
    code = activate(env, active, previous)
    if code != 0 then
        return code
    end
    table.remove(history)
    store.set_history(env.name, history)
    store.set_intent(env.name, nil)
    print("done: " .. env.name .. " is back at " .. previous)
    return 0
end

function list_dir(dir)
    result = {}
    if lfs.attributes(dir) == nil then
        return result
    end
    for entry in lfs.dir(dir) do
        if entry != "." and entry != ".." then
            table.insert(result, entry)
        end
    end
    table.sort(result)
    return result
end

-- Across the whole store: removes generations no longer in their env's
-- history (built but never activated, or pruned) and build steps no kept
-- generation uses. Fetch and git caches stay: they are inputs, and
-- cheap to keep compared with fetching again.
function lifecycle.gc()
    used_steps = {}
    gens = 0
    for _, name in ipairs(list_dir(store.root() .. "/envs")) do
        if store.intent(name) != nil then
            error("env " .. name .. " has an interrupted switch; run any tkn command on it first", 0)
        end
        kept = {}
        for _, id in ipairs(store.history(name)) do
            kept[id] = true
        end
        for _, id in ipairs(list_dir(store.gens_dir(name))) do
            if kept[string.gsub(id, "%.tmp$", "")] != true or string.match(id, "%.tmp$") != nil then
                shell.remove(store.gen_path(name, id))
                gens = gens + 1
            else
                meta = store.meta(name, id)
                for _, step in ipairs(meta.steps) do
                    used_steps[step] = true
                end
            end
        end
    end
    steps = 0
    for _, id in ipairs(list_dir(store.root() .. "/steps")) do
        if used_steps[id] != true then
            shell.remove(store.root() .. "/steps/" .. id)
            steps = steps + 1
        end
    end
    print("removed " .. gens .. " generation(s) and " .. steps .. " build step(s)")
    return 0
end

return lifecycle
