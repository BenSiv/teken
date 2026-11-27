-- Generation store layout, atomic `current` symlink swap, intent records, and `run.lock` (see doc/design.md).

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

function store.active(name)
    target = lfs.symlinkattributes(store.current_path(name), "target")
    if target == nil then
        return nil
    end
    return shell.basename(target)
end

-- Atomically swap `current` symlink via `rename(2)` over `current.new`.
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

-- Atomic per-env exclusion lock via `mkdir`.
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

-- Trim `history` to the last `keep` entries and return IDs no longer referenced.
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
    dropped = {}
    for _, id in ipairs(removed) do
        if kept[id] != true then
            table.insert(dropped, id)
        end
    end
    return dropped
end

return store
