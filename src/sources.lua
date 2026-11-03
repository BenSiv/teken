-- Git sources: a bare mirror per source in the store's cache, and
-- checkouts of it at a pinned commit. Both targets build from these;
-- the container target copies the checkout into the image's build
-- context, so private repos are cloned with the host's credentials and
-- no token ever reaches the image.

lfs = require("lfs")
shell = require("shell")
hash = require("hash")
store = require("store")

sources = {}

-- A bare mirror of `source` holding `commit`, fetched only when the
-- commit is not there yet. --no-local: git refuses hardlinked clones of
-- local paths across some directories, and a mirror must not share
-- objects with the repo it mirrors anyway.
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

-- A fresh checkout of source `name` at `commit` in `dir`, with its own
-- .git so builds that ask git about themselves (git describe) work.
function sources.checkout(name, source, commit, dir)
    mirror = sources.mirror(name, source, commit)
    shell.must("git clone --quiet --no-hardlinks --no-checkout " .. shell.quote(mirror) .. " " .. shell.quote(dir)
        .. " && git -C " .. shell.quote(dir) .. " checkout --quiet --detach " .. commit,
        "checkout of " .. name)
end

return sources
