-- Test: runtime/crypto/sha256.lua and runtime/crypto/hmac.lua

local sha256 = require("smithy.crypto.sha256")
local hmac = require("smithy.crypto.hmac")

describe("crypto", function()
    -- SHA-256 test vectors (NIST FIPS 180-4)
    it("sha256: empty string", function()
        assert.are.equal(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            sha256.hex_digest(""))
    end)

    it("sha256: abc", function()
        assert.are.equal(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            sha256.hex_digest("abc"))
    end)

    it("sha256: 448-bit message", function()
        assert.are.equal(
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            sha256.hex_digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
    end)

    it("sha256: 896-bit message", function()
        assert.are.equal(
            "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
            sha256.hex_digest("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"))
    end)

    it("sha256: digest returns 32 bytes", function()
        local raw = sha256.digest("abc")
        assert.are.equal(32, #raw)
    end)

    -- HMAC-SHA-256 test vectors (RFC 4231)
    it("hmac: RFC 4231 test case 1", function()
        local key = string.rep("\x0b", 20)
        assert.are.equal(
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
            hmac.hex_digest(key, "Hi There"))
    end)

    it("hmac: RFC 4231 test case 2", function()
        assert.are.equal(
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
            hmac.hex_digest("Jefe", "what do ya want for nothing?"))
    end)

    it("hmac: RFC 4231 test case 3", function()
        local key = string.rep("\xaa", 20)
        local data = string.rep("\xdd", 50)
        assert.are.equal(
            "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
            hmac.hex_digest(key, data))
    end)

    it("hmac: RFC 4231 test case 4", function()
        local key = ""
        for i = 1, 25 do key = key .. string.char(i) end
        local data = string.rep("\xcd", 50)
        assert.are.equal(
            "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
            hmac.hex_digest(key, data))
    end)

    it("hmac: digest returns 32 bytes", function()
        local raw = hmac.digest("key", "msg")
        assert.are.equal(32, #raw)
    end)
end)
