-- teken's version. Bump the minor number whenever spec files gain
-- something an older teken can't read (a field, a target, a built-in
-- var), so env files can require it with `requires_teken`.
--
--   0.1.0  home target: sources, build, fetch, files, links, env, verify

version = {number = "0.1.0"}

-- The commit the binary was built from; bld/build.sh writes
-- src/build_commit.lua (untracked). A run from source has none. The
-- require stays literal so luam's static bundler finds the module.
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

-- True when this teken is at least `wanted` ("major.minor.patch").
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
