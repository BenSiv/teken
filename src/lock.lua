-- lock.lua pins every input that can change under the same spec: the
-- digest of each base image, the commit of each git source and the
-- sha256 of each fetched URL. Only
-- `tkn lock` (pin what is missing) and `tkn update` (move pins
-- forward) write it; every other command refuses to build from an
-- input that is not pinned.

data = require("data")
shell = require("shell")
hash = require("hash")
store = require("store")

lock = {}

HEADER = "-- Written by tkn lock / tkn update. Commit it with the spec."

function lock.path(spec_dir)
    return spec_dir .. "/lock.lua"
end

function lock.read(spec_dir)
    pins = data.load(lock.path(spec_dir))
    if pins == nil then
        pins = {}
    end
    if pins.sources == nil then
        pins.sources = {}
    end
    if pins.fetch == nil then
        pins.fetch = {}
    end
    if pins.images == nil then
        pins.images = {}
    end
    return pins
end

function lock.write(spec_dir, pins)
    data.save(lock.path(spec_dir), pins, HEADER)
end

-- A source's pin still holds when it names the same repo and ref.
function source_pinned(pin, source)
    return pin != nil and pin.git == source.git and pin.ref == source.ref
end

-- Inputs of `env` that `pins` does not cover, as "kind name" strings.
function lock.missing(env, pins)
    result = {}
    if env.container != nil and pins.images[env.container.base] == nil then
        table.insert(result, "image " .. env.container.base)
    end
    for _, name in ipairs(data.sorted_keys(env.sources)) do
        if source_pinned(pins.sources[name], env.sources[name]) == false then
            table.insert(result, "source " .. name)
        end
    end
    for _, item in ipairs(env.fetch) do
        if pins.fetch[item.url] == nil then
            table.insert(result, "fetch " .. item.url)
        end
    end
    return result
end

function lock.require_pinned(env, pins)
    missing = lock.missing(env, pins)
    if #missing > 0 then
        error("not pinned in " .. lock.path(env.spec_dir) .. ": " .. table.concat(missing, ", ")
            .. "\nrun: tkn lock " .. env.path, 0)
    end
end

-- The commit `ref` (default HEAD) points at in the remote. A ref that
-- already is a full commit hash pins to itself.
function resolve_commit(source)
    ref = source.ref
    if ref == nil then
        ref = "HEAD"
    end
    if string.match(ref, "^%x+$") != nil and string.len(ref) == 40 then
        return ref
    end
    out = shell.must("git ls-remote " .. shell.quote(source.git) .. " " .. shell.quote(ref),
        "git ls-remote " .. source.git)
    commit = string.match(out, "^(%x+)%s")
    if commit == nil then
        error("no ref '" .. ref .. "' in " .. source.git, 0)
    end
    return commit
end

-- The digest `image` (a name:tag) points at in its registry now.
function resolve_digest(image)
    shell.must("podman pull --quiet " .. shell.quote(image), "podman pull " .. image)
    out = shell.must("podman image inspect --format '{{.Digest}}' " .. shell.quote(image), "podman image inspect " .. image)
    digest = string.match(out, "(sha256:%x+)")
    if digest == nil then
        error("no digest for " .. image .. " in: " .. out, 0)
    end
    return digest
end

-- Downloads `url` into the fetch cache and returns its sha256.
function lock.download(url)
    dir = store.cache_dir("fetch")
    tmp = dir .. "/download.tmp"
    shell.must("curl -fsSL -o " .. shell.quote(tmp) .. " " .. shell.quote(url), "download " .. url)
    digest = hash.file(tmp)
    os.rename(tmp, dir .. "/" .. digest)
    return digest
end

-- Pins `env`'s inputs into `pins`. Without `update`, only inputs not yet
-- pinned are resolved; with it, the inputs named in `names` (all when
-- empty) move to what their ref and URL point at now. Returns the list
-- of changes, "name: old -> new".
function lock.pin(env, pins, update, names)
    wanted = {}
    for _, name in ipairs(names) do
        wanted[name] = true
    end
    changes = {}
    if env.container != nil then
        base = env.container.base
        old = pins.images[base]
        selected = #names == 0 or wanted[base] == true
        if old == nil or (update == true and selected == true) then
            digest = resolve_digest(base)
            if old != digest then
                pins.images[base] = digest
                if old == nil then
                    old = "none"
                end
                table.insert(changes, base .. ": " .. string.sub(old, 1, 19) .. " -> " .. string.sub(digest, 1, 19))
            end
        end
    end
    for _, name in ipairs(data.sorted_keys(env.sources)) do
        source = env.sources[name]
        pin = pins.sources[name]
        selected = #names == 0 or wanted[name] == true
        if source_pinned(pin, source) == false or (update == true and selected == true) then
            commit = resolve_commit(source)
            old = "none"
            if pin != nil then
                old = string.sub(pin.commit, 1, 12)
            end
            if pin == nil or pin.commit != commit or source_pinned(pin, source) == false then
                pins.sources[name] = {git = source.git, ref = source.ref, commit = commit}
                table.insert(changes, name .. ": " .. old .. " -> " .. string.sub(commit, 1, 12))
            end
        end
    end
    for _, item in ipairs(env.fetch) do
        selected = #names == 0 or wanted[item.url] == true
        old = pins.fetch[item.url]
        if old == nil or (update == true and selected == true) then
            digest = lock.download(item.url)
            if old != digest then
                pins.fetch[item.url] = digest
                if old == nil then
                    old = "none"
                end
                table.insert(changes, item.url .. ": " .. string.sub(old, 1, 12) .. " -> " .. string.sub(digest, 1, 12))
            end
        end
    end
    return changes
end

return lock
