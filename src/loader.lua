-- Loads an env file and its units into one resolved env the targets
-- build from. Files are data, not code: each runs in luam's data-only
-- sandbox and must return a table. Every field is checked (unknown
-- keys, wrong types, fields the env's target can't use, duplicates
-- across units) before anything runs.

data = require("data")
shell = require("shell")
version = require("version")

loader = {}

ENV_KEYS = {
    requires_teken = "string", target = "string", vars = "table",
    units = "table", state = "table", keep = "number",
}

-- Unit fields and the targets that can use them.
UNIT_FIELDS = {
    sources = {home = true},
    build = {home = true},
    fetch = {home = true},
    files = {home = true},
    links = {home = true},
    env = {home = true},
    verify = {home = true},
}

-- Targets this teken implements. The container target is designed
-- (doc/design.md) but not built yet.
TARGETS = {home = true}

ITEM_FIELDS = {
    sources = {git = "string", ref = "string"},
    build = {
        name = "string", from = "string", cmd = "string", needs = "table",
        env = "table", install = "table",
    },
    fetch = {url = "string", path = "string", mode = "string"},
    files = {path = "string", source = "string", content = "string", mode = "string"},
    links = {path = "string", target = "string"},
}

REQUIRED = {
    sources = {"git"},
    build = {"name", "from", "cmd"},
    fetch = {"url", "path"},
    files = {"path"},
    links = {"path", "target"},
}

function fail(where, message)
    error(where .. ": " .. message, 0)
end

-- type() with booleans named "boolean" (luam calls them "flag").
function type_name(value)
    name = type(value)
    if name == "flag" then
        return "boolean"
    end
    return name
end

function key_list(tbl)
    keys = {}
    for _, key in ipairs(data.sorted_keys(tbl)) do
        table.insert(keys, tostring(key))
    end
    return table.concat(keys, ", ")
end

function load_table(path)
    value = data.load(path)
    if value == nil then
        fail(path, "file not found")
    end
    return value
end

-- ${name} -> vars[name]; a leading ~/ -> $HOME/. ${build.<step>} is
-- left for the build, which alone knows where a step's tree is.
function expand_string(value, vars, where)
    missing = nil
    value = string.gsub(value, "%${([%w_%.]+)}", function(name)
        if string.sub(name, 1, 6) == "build." then
            return nil
        end
        if vars[name] == nil then
            missing = name
            return nil
        end
        return vars[name]
    end)
    if missing != nil then
        fail(where, "unknown variable ${" .. missing .. "}")
    end
    if value == "~" then
        return shell.home()
    end
    if string.sub(value, 1, 2) == "~/" then
        return shell.home() .. string.sub(value, 2)
    end
    return value
end

function expand_value(value, vars, where)
    if type(value) == "string" then
        return expand_string(value, vars, where)
    end
    if type(value) == "table" then
        result = {}
        for key, inner in pairs(value) do
            result[key] = expand_value(inner, vars, where)
        end
        return result
    end
    return value
end

function check_fields(item, fields, required, where)
    if type(item) != "table" then
        fail(where, "expected a table, got " .. type_name(item))
    end
    for field, value in pairs(item) do
        expected = fields[field]
        if expected == nil then
            fail(where, "unknown field '" .. tostring(field) .. "' (allowed: " .. key_list(fields) .. ")")
        end
        if type_name(value) != expected then
            fail(where, "field '" .. field .. "' must be a " .. expected .. ", got " .. type_name(value))
        end
    end
    for _, field in ipairs(required) do
        if item[field] == nil then
            fail(where, "missing required field '" .. field .. "'")
        end
    end
end

function check_string_map(tbl, where)
    for key, value in pairs(tbl) do
        if type(key) != "string" or type(value) != "string" then
            fail(where, "must map names to strings")
        end
    end
end

function check_string_list(tbl, where)
    if data.is_list(tbl) == false then
        fail(where, "must be a list")
    end
    for _, value in ipairs(tbl) do
        if type(value) != "string" then
            fail(where, "must be a list of strings")
        end
    end
end

-- A path inside a generation: relative, no "..".
function check_relative(path, where)
    if string.sub(path, 1, 1) == "/" or string.find(path, "%.%.") != nil then
        fail(where, "'" .. path .. "' must be a relative path inside the generation")
    end
end

function check_absolute(path, where)
    if string.sub(path, 1, 1) != "/" then
        fail(where, "'" .. path .. "' must be absolute (or start with ~/)")
    end
end

function inside(path, dir)
    return path == dir or string.sub(path, 1, string.len(dir) + 1) == dir .. "/"
end

function new_env(name, path, spec_dir, target)
    return {
        name = name, path = path, spec_dir = spec_dir, target = target,
        sources = {}, build = {}, fetch = {}, files = {}, links = {},
        env = {}, verify = {}, state = {}, origin = {},
    }
end

-- Adds one unit's items to the env, checking each and refusing a name
-- or path two units both claim.
function merge_unit(env, unit, unit_path, vars)
    for field, value in pairs(unit) do
        targets = UNIT_FIELDS[field]
        if targets == nil then
            fail(unit_path, "unknown field '" .. tostring(field) .. "' (allowed: " .. key_list(UNIT_FIELDS) .. ")")
        end
        if targets[env.target] != true then
            fail(unit_path, "'" .. field .. "' is not available for target '" .. env.target .. "'")
        end
        if type(value) != "table" then
            fail(unit_path, "'" .. field .. "' must be a table")
        end
    end
    if unit.sources != nil then
        for name, source in pairs(unit.sources) do
            where = unit_path .. ": sources." .. tostring(name)
            check_fields(source, ITEM_FIELDS.sources, REQUIRED.sources, where)
            if env.sources[name] != nil then
                fail(where, "already declared in " .. env.origin["sources." .. name])
            end
            env.sources[name] = expand_value(source, vars, where)
            env.origin["sources." .. name] = unit_path
        end
    end
    for _, field in ipairs({"build", "fetch", "files", "links"}) do
        if unit[field] != nil then
            if data.is_list(unit[field]) == false then
                fail(unit_path, "'" .. field .. "' must be a list")
            end
            key = "path"
            if field == "build" then
                key = "name"
            end
            for index, item in ipairs(unit[field]) do
                where = unit_path .. ": " .. field .. "[" .. index .. "]"
                check_fields(item, ITEM_FIELDS[field], REQUIRED[field], where)
                item = expand_value(item, vars, where)
                id = field .. "." .. item[key]
                if env.origin[id] != nil then
                    fail(where, "'" .. item[key] .. "' already declared in " .. env.origin[id])
                end
                env.origin[id] = where
                item.where = where
                table.insert(env[field], item)
            end
        end
    end
    if unit.env != nil then
        check_string_map(unit.env, unit_path .. ": env")
        for name, value in pairs(unit.env) do
            if env.origin["env." .. name] != nil then
                fail(unit_path, "env " .. name .. " already set in " .. env.origin["env." .. name])
            end
            env.origin["env." .. name] = unit_path
            env.env[name] = expand_string(value, vars, unit_path .. ": env." .. name)
        end
    end
    if unit.verify != nil then
        check_string_list(unit.verify, unit_path .. ": verify")
        for _, cmd in ipairs(unit.verify) do
            table.insert(env.verify, expand_string(cmd, vars, unit_path .. ": verify"))
        end
    end
end

-- Checks that need the whole env: build steps name known sources and
-- earlier steps, ${build.x} only refers to a step listed in needs,
-- and nothing teken writes lands inside declared state.
function check_env(env)
    built = {}
    for _, step in ipairs(env.build) do
        if env.sources[step.from] == nil then
            fail(step.where, "from '" .. step.from .. "' is not a declared source")
        end
        needs = {}
        if step.needs != nil then
            check_string_list(step.needs, step.where .. ": needs")
            for _, need in ipairs(step.needs) do
                if built[need] != true then
                    fail(step.where, "needs '" .. need .. "', which is not a build step declared before it")
                end
                needs[need] = true
            end
        end
        text = step.cmd
        if step.env != nil then
            check_string_map(step.env, step.where .. ": env")
            for _, value in pairs(step.env) do
                text = text .. "\n" .. value
            end
        end
        for ref in string.gmatch(text, "%${build%.([%w_]+)}") do
            if needs[ref] != true then
                fail(step.where, "${build." .. ref .. "} needs '" .. ref .. "' in needs")
            end
        end
        if step.install == nil or next(step.install) == nil then
            fail(step.where, "'install' must map at least one built path to a generation path")
        end
        check_string_map(step.install, step.where .. ": install")
        for from, to in pairs(step.install) do
            check_relative(from, step.where .. ": install")
            check_relative(to, step.where .. ": install")
        end
        built[step.name] = true
    end
    for _, item in ipairs(env.fetch) do
        check_relative(item.path, item.where)
    end
    for _, item in ipairs(env.files) do
        check_relative(item.path, item.where)
        if (item.source == nil) == (item.content == nil) then
            fail(item.where, "needs exactly one of 'source' and 'content'")
        end
    end
    for _, item in ipairs(env.links) do
        check_absolute(item.path, item.where)
        check_relative(item.target, item.where)
        for _, state in ipairs(env.state) do
            if inside(item.path, state.path) or inside(state.path, item.path) then
                fail(item.where, "link " .. item.path .. " overlaps state path " .. state.path)
            end
        end
    end
end

function load_state(raw, env, vars)
    if data.is_list(raw) == false then
        fail(env.path, "'state' must be a list")
    end
    for index, item in ipairs(raw) do
        where = env.path .. ": state[" .. index .. "]"
        check_fields(item, {path = "string"}, {"path"}, where)
        item = expand_value(item, vars, where)
        check_absolute(item.path, where)
        table.insert(env.state, item)
    end
end

function builtin_vars(name)
    uid = shell.trim(shell.must("id -u", "id -u"))
    return {home = shell.home(), user = os.getenv("USER"), uid = uid, env = name}
end

-- Loads envs/<name>.lua and the units it lists from units/ beside
-- envs/. Returns the resolved env.
function loader.load(env_path)
    raw = load_table(env_path)
    for key, value in pairs(raw) do
        if ENV_KEYS[key] == nil then
            fail(env_path, "unknown key '" .. tostring(key) .. "' (allowed: " .. key_list(ENV_KEYS) .. ")")
        end
        if type_name(value) != ENV_KEYS[key] then
            fail(env_path, "'" .. key .. "' must be a " .. ENV_KEYS[key])
        end
    end
    -- Checked first: a spec written for a newer teken would otherwise
    -- fail on whatever new feature it uses, with a less helpful message.
    if raw.requires_teken != nil then
        if version.parse(raw.requires_teken) == nil then
            fail(env_path, "requires_teken must look like 0.1.0")
        end
        if version.satisfies(raw.requires_teken) == false then
            fail(env_path, "needs teken " .. raw.requires_teken .. " or newer, this is " .. version.describe())
        end
    end
    if raw.target == nil then
        fail(env_path, "'target' is required (home)")
    end
    if TARGETS[raw.target] != true then
        fail(env_path, "unknown target '" .. raw.target .. "' (this teken builds: " .. key_list(TARGETS) .. ")")
    end
    if raw.units == nil or #raw.units == 0 then
        fail(env_path, "'units' must list at least one unit")
    end
    name = string.gsub(shell.basename(env_path), "%.lua$", "")
    spec_dir = shell.parent(shell.parent(env_path))
    env = new_env(name, env_path, spec_dir, raw.target)
    env.keep = raw.keep
    if env.keep == nil then
        env.keep = 3
    end
    if env.keep < 2 then
        fail(env_path, "'keep' must be at least 2, so there is a generation to roll back to")
    end
    vars = builtin_vars(name)
    if raw.vars != nil then
        check_string_map(raw.vars, env_path .. ": vars")
        for key, value in pairs(raw.vars) do
            vars[key] = value
        end
    end
    -- Vars may refer to each other and to ~ (projects = "~/Projects").
    for key, value in pairs(vars) do
        vars[key] = expand_string(value, vars, env_path .. ": var " .. key)
    end
    if raw.state != nil then
        load_state(raw.state, env, vars)
    end
    env.units = raw.units
    for _, unit_name in ipairs(raw.units) do
        unit_path = spec_dir .. "/units/" .. unit_name .. ".lua"
        merge_unit(env, load_table(unit_path), unit_path, vars)
    end
    check_env(env)
    return env
end

return loader
