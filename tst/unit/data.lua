-- tst/unit/data.lua
-- Unit tests for src/data.lua: the serializer is the canonical form ids
-- are hashed from, so equal tables must give equal text, and the text
-- must load back to an equal table.

data = require("data")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function test_order_independent()
    print("Testing serialization ignores insertion order")
    a = {}
    a.zeta = 1
    a.alpha = {2, 3}
    b = {}
    b.alpha = {2, 3}
    b.zeta = 1
    check(data.serialize(a) == data.serialize(b), "same text for the same table")
end

function test_round_trip()
    print("Testing serialized text loads back")
    value = {name = "x", list = {"a", "b"}, nested = {["with space"] = "q\"uote\n"}, n = 3, flag = true}
    path = os.tmpname()
    data.save(path, value)
    loaded = data.load(path)
    os.remove(path)
    check(data.serialize(loaded) == data.serialize(value), "round trip keeps the table")
end

function test_missing_file()
    print("Testing a missing file loads as nil")
    check(data.load("/nonexistent/teken-test.lua") == nil, "missing file is nil")
end

test_order_independent()
test_round_trip()
test_missing_file()

if FAILURES > 0 then
    print(FAILURES .. " failure(s)")
    os.exit(1)
end
print("ok")
