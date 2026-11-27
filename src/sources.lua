-- Host-cached bare git mirrors and detached commit checkouts (see doc/design.md).

lfs = require("lfs")
shell = require("shell")
hash = require("hash")
store = require("store")

sources = {}

-- `--no-local` avoids cross-directory hardlink errors and keeps mirror objects isolated.
function sources.mirror(name, source, commit)
    dir = store.cache_dir("git") .. "/" .. name .. "-" .. hash.id(source.git)
    if lfs.attributes(dir) == nil then
        shell.must("git clone --quiet --no-local --mirror " .. shell.quote(source.git) .. " " .. shell.quote(dir),
            "git clone " .. source.git)
    end
    has_commit = "git -C " .. shell.quote(dir) .. " cat-file -e " .. commit .. "^{commit}"
    if shell.ok(has_commit) == false then
        shell.must("git -C " .. shell.quote(dir) .. " fetch --quiet --prune origin", "git fetch " .. source.git)
        if shell.ok(has_commit) == false then
            error("commit " .. commit .. " is not in " .. source.git .. " any more; run tkn update", 0)
        end
    end
    return dir
end

-- Detached checkout with its own `.git` so build scripts running `git describe` succeed.
function sources.checkout(name, source, commit, dir)
    mirror = sources.mirror(name, source, commit)
    shell.must("git clone --quiet --no-hardlinks --no-checkout " .. shell.quote(mirror) .. " " .. shell.quote(dir)
        .. " && git -C " .. shell.quote(dir) .. " checkout --quiet --detach " .. commit,
        "checkout of " .. name)
end

return sources
