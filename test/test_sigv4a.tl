local assert = require("luassert") as any
-- Test: P-256 ECDSA and SigV4a

local bigint = require("smithy.crypto.bigint")
local field = require("smithy.crypto.field")
local p256 = require("smithy.crypto.p256")
local ecdsa = require("smithy.crypto.ecdsa")
local sigv4a = require("smithy.sigv4a")
local sha256 = require("smithy.crypto.sha256")

describe("sigv4a", function()

-- ============================================================
-- bigint tests
-- ============================================================

it("bigint: from_int and to_hex", function()
    local a = bigint.from_int(1)
    local h = bigint.to_hex(a)
    assert.are.equal("0000000000000000000000000000000000000000000000000000000000000001", h)
end)

it("bigint: from_hex roundtrip", function()
    local hex = "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF"
    local a = bigint.from_hex(hex)
    assert.are.equal(hex, bigint.to_hex(a))
end)

it("bigint: add", function()
    local a = bigint.from_int(0xFFFFFF)
    local b = bigint.from_int(1)
    local c = bigint.add(a, b)
    assert.are.equal("0000000000000000000000000000000000000000000000000000000001000000", bigint.to_hex(c))
end)

it("bigint: sub", function()
    local a = bigint.from_hex("0000000000000000000000000000000000000000000000000000000001000000")
    local b = bigint.from_int(1)
    local c = bigint.sub(a, b)
    assert.are.equal("0000000000000000000000000000000000000000000000000000000000FFFFFF", bigint.to_hex(c))
end)

it("bigint: cmp", function()
    local a = bigint.from_int(100)
    local b = bigint.from_int(200)
    assert.are.equal(-1, bigint.cmp(a, b))
    assert.are.equal(1, bigint.cmp(b, a))
    assert.are.equal(0, bigint.cmp(a, a))
end)

-- ============================================================
-- field arithmetic tests
-- ============================================================

it("field: P-256 prime roundtrip", function()
    assert.are.equal("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF", bigint.to_hex(field.P))
end)

it("field: fadd basic", function()
    local a = bigint.from_int(3)
    local b = bigint.from_int(5)
    local c = field.fadd(a, b)
    assert.are.equal("0000000000000000000000000000000000000000000000000000000000000008", bigint.to_hex(c))
end)

it("field: fadd wraps mod p", function()
    local pm1 = bigint.sub(field.P, bigint.from_int(1))
    local c = field.fadd(pm1, bigint.from_int(2))
    assert.are.equal("0000000000000000000000000000000000000000000000000000000000000001", bigint.to_hex(c))
end)

it("field: fmul basic", function()
    local a = bigint.from_int(7)
    local b = bigint.from_int(6)
    local c = field.fmul(a, b)
    assert.are.equal("000000000000000000000000000000000000000000000000000000000000002A", bigint.to_hex(c))
end)

it("field: fmul large values", function()
    local a = bigint.from_hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFE")
    local b = bigint.from_int(2)
    local c = field.fmul(a, b)
    assert.are.equal("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFD", bigint.to_hex(c))
end)

-- ============================================================
-- P-256 point arithmetic tests
-- ============================================================

it("p256: generator point on curve", function()
    local x = p256.Gx
    local y = p256.Gy
    local y2 = field.fsqr(y)
    local x3 = field.fmul(x, field.fsqr(x))
    local ax = field.fmul(bigint.from_int(3), x)
    local b = bigint.from_hex("5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B")
    local rhs = field.fadd(field.fsub(x3, ax), b)
    assert.are.equal(bigint.to_hex(rhs), bigint.to_hex(y2))
end)

it("p256: scalar mult by 1 gives G", function()
    local R = p256.scalar_base_mult(bigint.from_int(1))
    local rx, ry = p256.to_affine(R)
    assert.are.equal(bigint.to_hex(p256.Gx), bigint.to_hex(rx))
    assert.are.equal(bigint.to_hex(p256.Gy), bigint.to_hex(ry))
end)

it("p256: scalar mult by 2 (point doubling)", function()
    local R = p256.scalar_base_mult(bigint.from_int(2))
    local rx, ry = p256.to_affine(R)
    assert.are.equal("7CF27B188D034F7E8A52380304B51AC3C08969E277F21B35A60B48FC47669978", bigint.to_hex(rx))
    assert.are.equal("07775510DB8ED040293D9AC69F7430DBBA7DADE63CE982299E04B79D227873D1", bigint.to_hex(ry))
end)

it("p256: scalar mult by 3", function()
    local R = p256.scalar_base_mult(bigint.from_int(3))
    local rx, ry = p256.to_affine(R)
    assert.are.equal("5ECBE4D1A6330A44C8F7EF951D4BF165E6C6B721EFADA985FB41661BC6E7FD6C", bigint.to_hex(rx))
    assert.are.equal("8734640C4998FF7E374B06CE1A64A2ECD82AB036384FB83D9A79B127A27D5032", bigint.to_hex(ry))
end)

-- ============================================================
-- Key derivation test (from Go SDK test vectors)
-- ============================================================

it("sigv4a: key derivation matches Go SDK test vector", function()
    local akid = "AKISORANDOMAASORANDOM"
    local secret = "q+jcrXGc+0zWN6uzclKVhvMmUsIfRPa4rlRandom"

    local d, qx, qy = sigv4a.derive_key(akid, secret)

    local expected_x = "15D242CEEBF8D8169FD6A8B5A746C41140414C3B07579038DA06AF89190FFFCB"
    local expected_y = "0515242CEDD82E94799482E4C0514B505AFCCF2C0C98D6A553BF539F424C5EC0"

    assert.are.equal(expected_x, bigint.to_hex(qx))
    assert.are.equal(expected_y, bigint.to_hex(qy))
end)

-- ============================================================
-- ECDSA sign/verify roundtrip
-- ============================================================

it("ecdsa: sign produces valid DER", function()
    local d = bigint.from_int(1)
    local hash = sha256.digest("test message")
    local sig = ecdsa.sign(d, hash)

    assert.are.equal(0x30, string.byte(sig, 1))
    local total_len = string.byte(sig, 2)
    assert.are.equal(total_len + 2, #sig)
    assert.are.equal(0x02, string.byte(sig, 3))
end)

-- ============================================================
-- SigV4a signer integration test
-- ============================================================

it("sigv4a: sign produces valid Authorization header", function()
    local request = {
        method = "POST",
        url = "https://service.region.amazonaws.com",
        headers = {
            ["X-Amz-Date"] = "19700101T000000Z",
        } as {string:string},
        body = nil as string,
    }
    local identity = {
        access_key = "AKID",
        secret_key = "SECRET",
        session_token = "SESSION",
    }
    local props = {
        signing_name = "dynamodb",
        region_set = {"us-east-1", "us-west-1"} as {string},
    }

    local signed, err = sigv4a.sign(request, identity, props)
    assert(signed, "sign failed: " .. tostring(err and (err as {string:string}).message))

    local auth = (signed as {string:any}).headers["Authorization"] as string
    assert(auth, "no Authorization header")

    local preamble = auth:match("^(AWS4%-ECDSA%-P256%-SHA256 Credential=AKID/19700101/dynamodb/aws4_request)")
    assert(preamble, "preamble mismatch: " .. auth)

    assert(auth:find("x%-amz%-region%-set"), "missing x-amz-region-set in signed headers")

    assert.are.equal("us-east-1,us-west-1", (signed as {string:any}).headers["X-Amz-Region-Set"])
end)

end)
