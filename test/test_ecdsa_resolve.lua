-- Test: ECDSA backend resolution (OpenSSL preferred, pure-Lua fallback)
-- Run: luajit test/test_ecdsa_resolve.lua

package.path = "runtime/?.lua;runtime/?/init.lua;" .. package.path

local bigint = require("smithy.crypto.bigint")
local sha256 = require("smithy.crypto.sha256")

local pass, fail = 0, 0

local function test(name, fn)
    io.write("RUN:  " .. name .. " ... ")
    io.flush()
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print("PASS")
    else
        fail = fail + 1
        print("FAIL\n  " .. tostring(err))
    end
end

-- ============================================================
-- Resolution tests
-- ============================================================

test("ecdsa resolver: backend() returns openssl or lua", function()
    local ecdsa = require("smithy.crypto.ecdsa")
    local b = ecdsa.backend()
    assert(b == "openssl" or b == "lua", "unexpected backend: " .. b)
    print("(" .. b .. ") ", "")
end)

test("ecdsa resolver: sign() produces valid DER via resolved backend", function()
    local ecdsa = require("smithy.crypto.ecdsa")
    local d = bigint.from_int(42)
    local hash = sha256.digest("resolver test")
    local sig = ecdsa.sign(d, hash)
    assert(string.byte(sig, 1) == 0x30, "expected DER SEQUENCE tag")
    local total_len = string.byte(sig, 2)
    assert(#sig == total_len + 2, "DER length mismatch")
end)

test("ecdsa_openssl: available() returns boolean", function()
    local openssl = require("smithy.crypto.ecdsa_openssl")
    local avail = openssl.available()
    assert(type(avail) == "boolean", "expected boolean, got " .. type(avail))
end)

test("ecdsa_openssl: sign() produces valid DER when available", function()
    local openssl = require("smithy.crypto.ecdsa_openssl")
    if not openssl.available() then
        print("(skipped - no OpenSSL) ", "")
        return
    end
    local d = bigint.from_int(7)
    local hash = sha256.digest("openssl direct test")
    local sig = openssl.sign(d, hash)
    assert(string.byte(sig, 1) == 0x30, "expected DER SEQUENCE tag")
end)

test("ecdsa_lua: sign() produces valid DER", function()
    local lua_ecdsa = require("smithy.crypto.ecdsa_lua")
    local d = bigint.from_int(7)
    local hash = sha256.digest("lua direct test")
    local sig = lua_ecdsa.sign(d, hash)
    assert(string.byte(sig, 1) == 0x30, "expected DER SEQUENCE tag")
end)

test("ecdsa resolver: resolution is stable (same backend on repeated calls)", function()
    local ecdsa = require("smithy.crypto.ecdsa")
    local b1 = ecdsa.backend()
    local b2 = ecdsa.backend()
    assert(b1 == b2, "backend changed between calls: " .. b1 .. " vs " .. b2)
end)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
