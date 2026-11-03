-- Where teken keeps what it builds. The root is $TEKEN_STATE, or
-- ~/.local/state/teken:
--
--   cache/git/<name>-<id>/   bare mirrors of git sources
--   cache/fetch/<sha256>     fetched files, by content
--   steps/<id>/tree/         a build step's finished tree (done marker: steps/<id>/done)
--   envs/<env>/gens/<id>/    generations; <id>.tmp while one is built
--   envs/<env>/current       symlink to the active generation
--   envs/<env>/history.lua   activated generations, oldest first; last is active
--   envs/<env>/intent.lua    present only while a switch is in progress
--   envs/<env>/adopted/      files that stood where a link now is
--   envs/<env>/run.lock      held while a tkn command changes this env

lfs = require("lfs")
data = require("data")
shell = require("shell")

store = {}

function store.root()
    root = os.getenv("TEKEN_STATE")
    if root == nil or root == "" then
        root = shell.home() .. "/.local/state/teken"
    end
    return root
end

function store.cache_dir(kind)
    dir = store.root() .. "/cache/" .. kind
    shell.mkdir(dir)
    return dir
end

function store.steps_dir()
    dir = store.root() .. "/steps"
    shell.mkdir(dir)
    return dir
end

function store.env_dir(name)
    return store.root() .. "/envs/" .. name
end

function store.gens_dir(name)
    return store.env_dir(name) .. "/gens"
end

function store.gen_path(name, id)
    return store.gens_dir(name) .. "/" .. id
end

function store.current_path(name)
    return store.env_dir(name) .. "/current"
end

function store.has_gen(name, id)
    return lfs.attributes(store.gen_path(name, id) .. "/meta.lua") != nil
end

function store.meta(name, id)
    return data.load(store.gen_path(name, id) .. "/meta.lua")
end

-- The active generation's id, from the current symlink; nil before
-- the first switch.
function store.active(name)
    target = lfs.symlinkattributes(store.current_path(name), "target")
    if target == nil then
        return nil
    end
    return shell.basename(target)
end

-- Points current at generation `id` (nil removes it) in one rename(2):
-- the new link is made beside it and renamed over it.
function store.set_current(name, id)
    current = store.current_path(name)
    if id == nil then
        os.remove(current)
        return
    end
    tmp = current .. ".new"
    os.remove(tmp)
    ok, err = lfs.link("gens/" .. id, tmp, true)
    if ok == nil then
        error("cannot link " .. tmp .. ": " .. tostring(err), 0)
    end
    ok, err = os.rename(tmp, current)
    if ok == nil then
        error("cannot switch " .. current .. ": " .. tostring(err), 0)
    end
end

function store.history(name)
    history = data.load(store.env_dir(name) .. "/history.lua")
    if history == nil then
        history = {}
    end
    return history
end

function store.set_history(name, history)
    data.save(store.env_dir(name) .. "/history.lua", history)
end

function store.intent(name)
    return data.load(store.env_dir(name) .. "/intent.lua")
end

function store.set_intent(name, intent)
    path = store.env_dir(name) .. "/intent.lua"
    if intent == nil then
        os.remove(path)
        return
    end
    data.save(path, intent)
end

-- Held while a command changes the env, so two tkn runs never switch
-- the same env at once. mkdir is atomic: it fails when the lock exists.
function store.lock(name)
    shell.mkdir(store.env_dir(name))
    path = store.env_dir(name) .. "/run.lock"
    ok, _ = lfs.mkdir(path)
    if ok == nil then
        error("another tkn is changing env '" .. name .. "' (or one was killed and left "
            .. path .. "; remove it if no tkn is running)", 0)
    end
end

function store.unlock(name)
    lfs.rmdir(store.env_dir(name) .. "/run.lock")
end

-- Generations of `name` on disk, by id.
function store.gens(name)
    result = {}
    dir = store.gens_dir(name)
    if lfs.attributes(dir) == nil then
        return result
    end
    for entry in lfs.dir(dir) do
        if entry != "." and entry != ".." and string.match(entry, "%.tmp$") == nil then
            table.insert(result, entry)
        end
    end
    table.sort(result)
    return result
end

-- Trims history to the last `keep` entries and removes the generations
-- that drop out of it. The active generation is always the last entry.
function store.prune(name, keep)
    history = store.history(name)
    removed = {}
    while #history > keep do
        id = table.remove(history, 1)
        table.insert(removed, id)
    end
    store.set_history(name, history)
    kept = {}
    for _, id in ipairs(history) do
        kept[id] = true
    end
    for _, id in ipairs(removed) do
        if kept[id] != true then
            shell.remove(store.gen_path(name, id))
        end
    end
    return removed
end

return store
