-- Running commands. Probes capture output and exit status; builds and
-- verify commands stream to the terminal. Every command teken runs goes
-- through here, so tests only need stub binaries on PATH.

lfs = require("lfs")

shell = {}

function shell.quote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- Runs `cmd` and returns its combined stdout+stderr and whether it
-- exited 0. io.popen's close gives no exit status in luam, so the
-- status is echoed as a marker on the last line and stripped again.
function shell.capture(cmd)
    handle = io.popen("{ " .. cmd .. "\n} 2>&1; echo \"__rc=$?\"")
    out = io.read(handle, "*a")
    io.close(handle)
    rc = string.match(out, "__rc=(%d+)%s*$")
    out = string.gsub(out, "__rc=%d+%s*$", "")
    return out, rc == "0"
end

function shell.ok(cmd)
    _, ok = shell.capture(cmd)
    return ok
end

-- Like capture, but fails with the command's output when it exits
-- non-zero. For steps whose failure ends the run.
function shell.must(cmd, what)
    out, ok = shell.capture(cmd)
    if ok != true then
        error(what .. " failed:\n" .. out, 0)
    end
    return out
end

function shell.trim(text)
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
end

function shell.lines(text)
    result = {}
    for line in string.gmatch(text, "[^\n]+") do
        table.insert(result, line)
    end
    return result
end

-- Runs `cmd` with its output going straight to the terminal.
function shell.run(cmd)
    status = os.execute(cmd)
    return status == 0 or status == true
end

function shell.home()
    return os.getenv("HOME")
end

function shell.parent(path)
    parent = string.match(path, "^(.*)/[^/]+/?$")
    if parent == nil then
        return "."
    end
    if parent == "" then
        return "/"
    end
    return parent
end

function shell.basename(path)
    return string.match(path, "([^/]+)/?$")
end

function shell.exists(path)
    return lfs.symlinkattributes(path) != nil
end

function shell.mkdir(path)
    shell.must("mkdir -p " .. shell.quote(path), "mkdir " .. path)
end

function shell.remove(path)
    shell.must("rm -rf " .. shell.quote(path), "remove " .. path)
end

return shell
