-- Content hashes: generation ids, step ids, fetched files. sha256sum
-- does the hashing; ids are its first 16 hex digits, enough to be
-- unique within one store and short enough to read.

shell = require("shell")
data = require("data")

hash = {}

ID_LENGTH = 16

function hash.file(path)
    out = shell.must("sha256sum " .. shell.quote(path), "sha256sum " .. path)
    return string.match(out, "^(%x+)")
end

function hash.text(text)
    path = os.tmpname()
    file = io.open(path, "w")
    io.write(file, text)
    io.close(file)
    digest = hash.file(path)
    os.remove(path)
    return digest
end

-- The id of a table: its canonical serialization, hashed.
function hash.id(value)
    return string.sub(hash.text(data.serialize(value)), 1, ID_LENGTH)
end

return hash
