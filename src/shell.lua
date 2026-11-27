-- Command and atomic-path wrapper over `external_tool` and `paths`.

const ext = require("external_tool")
const paths = require("paths")

const shell = {}

shell.quote = ext.shell_quote
shell.capture = ext.exec
shell.ok = ext.ok
shell.must = ext.must

function shell.trim(text)
    return string.trim(text)
end

function shell.lines(text)
    result = {}
    for line in string.gmatch(text, "[^\n]+") do
        table.insert(result, line)
    end
    return result
end

function shell.run(cmd)
    ok = ext.run(cmd)
    return ok == true
end

function shell.home()
    return os.getenv("HOME")
end

shell.parent = paths.get_parent_dir
shell.basename = paths.get_file_name
shell.exists = paths.exists

function shell.mkdir(path)
    ok, err = paths.ensure_dir(path)
    if not ok then
        error("mkdir " .. path .. " failed:\n" .. tostring(err), 0)
    end
end

function shell.write_file(path, text)
    ok, err = paths.write_atomic(path, text)
    if not ok then
        error(tostring(err), 0)
    end
end

function shell.remove(path)
    ext.must("rm -rf " .. ext.shell_quote(path), "remove " .. path)
end

return shell
