-- teken's own data files (lock.lua, meta.lua, history.lua, intent.lua)
-- are plain table literals: read in the data-only sandbox like spec
-- files, and written atomically (temp file, then rename) so a crash
-- never leaves half a file. The same serializer, with sorted keys, is
-- the canonical form generation and step ids are hashed from.

sandbox = require("sandbox")
shell = require("shell")

data = {}

function key_order(a, b)
    ta = type(a)
    tb = type(b)
    if ta != tb then
        return ta < tb
    end
    return a < b
end

function data.sorted_keys(tbl)
    keys = {}
    for key, _ in pairs(tbl) do
        table.insert(keys, key)
    end
    table.sort(keys, key_order)
    return keys
end

function data.is_list(tbl)
    count = 0
    for _, _ in pairs(tbl) do
        count = count + 1
    end
    return count == #tbl
end

function key_literal(key)
    if type(key) == "string" and string.match(key, "^[%a_][%w_]*$") != nil then
        return key
    end
    return "[" .. data.serialize(key, "") .. "]"
end

-- A Lua literal for `value`, keys sorted, so equal tables always give
-- the same text.
function data.serialize(value, indent)
    if indent == nil then
        indent = ""
    end
    kind = type(value)
    if kind == "string" then
        return string.format("%q", value)
    end
    if kind == "number" then
        return tostring(value)
    end
    if kind == "flag" or kind == "boolean" then
        return tostring(value)
    end
    if kind != "table" then
        error("cannot serialize a " .. kind, 0)
    end
    if next(value) == nil then
        return "{}"
    end
    inner = indent .. "    "
    parts = {}
    if data.is_list(value) then
        for _, item in ipairs(value) do
            table.insert(parts, inner .. data.serialize(item, inner))
        end
    else
        for _, key in ipairs(data.sorted_keys(value)) do
            table.insert(parts, inner .. key_literal(key) .. " = " .. data.serialize(value[key], inner))
        end
    end
    return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
end

function data.read_file(path)
    file = io.open(path, "r")
    if file == nil then
        return nil
    end
    text = io.read(file, "*a")
    io.close(file)
    return text
end

function data.write_file(path, text)
    tmp = path .. ".tmp"
    file = io.open(tmp, "w")
    if file == nil then
        error("cannot write " .. tmp, 0)
    end
    io.write(file, text)
    io.close(file)
    ok, err = os.rename(tmp, path)
    if ok == nil then
        error("cannot rename " .. tmp .. ": " .. tostring(err), 0)
    end
end

-- Loads a table literal file in the data-only sandbox. Nil when the
-- file does not exist; an error when it is not a table.
function data.load(path)
    source = data.read_file(path)
    if source == nil then
        return nil
    end
    ok, value = sandbox.run(source, "@" .. path, sandbox.data_env())
    if ok != true then
        error(path .. ": " .. tostring(value), 0)
    end
    if type(value) != "table" then
        error(path .. ": must return a table, got " .. type(value), 0)
    end
    return value
end

function data.save(path, value, header)
    text = "return " .. data.serialize(value) .. "\n"
    if header != nil then
        text = header .. "\n" .. text
    end
    data.write_file(path, text)
end

return data
