-- Test: runtime/crypto/sha256.lua and runtime/crypto/hmac.lua
-- Run: luajit test/test_crypto.lua

package.path = "runtime/?.lua;runtime/?/init.lua;" .. package.path

local sha256 = require("smithy.crypto.sha256")
local hmac = require("smithy.crypto.hmac")

local pass, fail = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print("PASS: " .. name)
    else
        fail = fail + 1
        print("FAIL: " .. name .. "\n  " .. tostring(err))
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "assert_eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end

-- SHA-256 test vectors (NIST FIPS 180-4)
test("sha256: empty string", function()
    assert_eq(sha256.hex_digest(""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
end)

test("sha256: abc", function()
    assert_eq(sha256.hex_digest("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
end)

test("sha256: 448-bit message", function()
    assert_eq(sha256.hex_digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
end)

test("sha256: 896-bit message", function()
    assert_eq(sha256.hex_digest("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"),
        "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
end)

test("sha256: digest returns 32 bytes", function()
    local raw = sha256.digest("abc")
    assert_eq(#raw, 32)
end)

-- HMAC-SHA-256 test vectors (RFC 4231)
test("hmac: RFC 4231 test case 1", function()
    local key = string.rep("\x0b", 20)
    assert_eq(hmac.hex_digest(key, "Hi There"),
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
end)

test("hmac: RFC 4231 test case 2", function()
    assert_eq(hmac.hex_digest("Jefe", "what do ya want for nothing?"),
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
end)

test("hmac: RFC 4231 test case 3", function()
    local key = string.rep("\xaa", 20)
    local data = string.rep("\xdd", 50)
    assert_eq(hmac.hex_digest(key, data),
        "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
end)

test("hmac: RFC 4231 test case 4", function()
    local key = ""
    for i = 1, 25 do key = key .. string.char(i) end
    local data = string.rep("\xcd", 50)
    assert_eq(hmac.hex_digest(key, data),
        "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b")
end)

test("hmac: digest returns 32 bytes", function()
    local raw = hmac.digest("key", "msg")
    assert_eq(#raw, 32)
end)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
