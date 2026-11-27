-- Spec/engine version checked by `requires_teken` (see doc/design.md).
version = {number = "0.3.0"}

-- Keep literal `require("build_commit")` so Luam's static bundler embeds it.
ok, commit = pcall(function() return require("build_commit") end)
if ok == true and type(commit) == "string" then
    version.commit = commit
end

function version.parse(text)
    major, minor, patch = string.match(text, "^(%d+)%.(%d+)%.(%d+)$")
    if major == nil then
        return nil
    end
    return {tonumber(major), tonumber(minor), tonumber(patch)}
end

function version.satisfies(wanted)
    have = version.parse(version.number)
    want = version.parse(wanted)
    for index = 1, 3 do
        if have[index] != want[index] then
            return have[index] > want[index]
        end
    end
    return true
end

function version.describe()
    if version.commit == nil then
        return "teken " .. version.number
    end
    return "teken " .. version.number .. " (" .. version.commit .. ")"
end

return version
