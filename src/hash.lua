-- Content hashes: generation ids, step ids, fetched files. Backed by
-- Luam's in-process OpenSSL `crypto` binding and canonical `data.serialize`.

const crypto = require("crypto")
const data = require("data")

const hash = {}

const ID_LENGTH = 16

function hash.file(path)
    digest, err = crypto.sha256_file(path)
    if digest == nil then
        error("sha256 " .. path .. " failed: " .. tostring(err), 0)
    end
    return digest
end

function hash.text(text)
    return crypto.sha256(text)
end

function hash.id(value)
    return string.sub(crypto.sha256(data.serialize(value)), 1, ID_LENGTH)
end

return hash
