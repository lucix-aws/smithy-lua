-- Test: P-256 ECDSA and SigV4a
-- Run: luajit test/test_sigv4a.lua

package.path = "runtime/?.lua;runtime/?/init.lua;" .. package.path

local bigint = require("smithy.crypto.bigint")
local field = require("smithy.crypto.field")
local p256 = require("smithy.crypto.p256")
local ecdsa = require("smithy.crypto.ecdsa")
local sigv4a = require("smithy.sigv4a")
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

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "assert_eq") .. ":\n  expected: " .. tostring(b) .. "\n  got:      " .. tostring(a), 2)
    end
end

-- ============================================================
-- bigint tests
-- ============================================================

test("bigint: from_int and to_hex", function()
    local a = bigint.from_int(1)
    local h = bigint.to_hex(a)
    assert_eq(h, "0000000000000000000000000000000000000000000000000000000000000001")
end)

test("bigint: from_hex roundtrip", function()
    local hex = "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF"
    local a = bigint.from_hex(hex)
    assert_eq(bigint.to_hex(a), hex)
end)

test("bigint: add", function()
    local a = bigint.from_int(0xFFFFFF)
    local b = bigint.from_int(1)
    local c = bigint.add(a, b)
    assert_eq(bigint.to_hex(c), "0000000000000000000000000000000000000000000000000000000001000000")
end)

test("bigint: sub", function()
    local a = bigint.from_hex("0000000000000000000000000000000000000000000000000000000001000000")
    local b = bigint.from_int(1)
    local c = bigint.sub(a, b)
    assert_eq(bigint.to_hex(c), "0000000000000000000000000000000000000000000000000000000000FFFFFF")
end)

test("bigint: cmp", function()
    local a = bigint.from_int(100)
    local b = bigint.from_int(200)
    assert_eq(bigint.cmp(a, b), -1)
    assert_eq(bigint.cmp(b, a), 1)
    assert_eq(bigint.cmp(a, a), 0)
end)

-- ============================================================
-- field arithmetic tests
-- ============================================================

test("field: P-256 prime roundtrip", function()
    assert_eq(bigint.to_hex(field.P), "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF")
end)

test("field: fadd basic", function()
    local a = bigint.from_int(3)
    local b = bigint.from_int(5)
    local c = field.fadd(a, b)
    assert_eq(bigint.to_hex(c), "0000000000000000000000000000000000000000000000000000000000000008")
end)

test("field: fadd wraps mod p", function()
    local pm1 = bigint.sub(field.P, bigint.from_int(1))
    local c = field.fadd(pm1, bigint.from_int(2))
    assert_eq(bigint.to_hex(c), "0000000000000000000000000000000000000000000000000000000000000001")
end)

test("field: fmul basic", function()
    local a = bigint.from_int(7)
    local b = bigint.from_int(6)
    local c = field.fmul(a, b)
    assert_eq(bigint.to_hex(c), "000000000000000000000000000000000000000000000000000000000000002A")
end)

test("field: fmul large values", function()
    -- Test that multiplication of two large field elements stays in field
    local a = bigint.from_hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFE")
    local b = bigint.from_int(2)
    local c = field.fmul(a, b)
    -- (p-1) * 2 mod p = p - 2
    assert_eq(bigint.to_hex(c), "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFD")
end)

-- ============================================================
-- P-256 point arithmetic tests
-- ============================================================

test("p256: generator point on curve", function()
    -- Verify y^2 = x^3 - 3x + b mod p
    local x = p256.Gx
    local y = p256.Gy
    local y2 = field.fsqr(y)
    local x3 = field.fmul(x, field.fsqr(x))
    local ax = field.fmul(bigint.from_int(3), x)
    local b = bigint.from_hex("5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B")
    local rhs = field.fadd(field.fsub(x3, ax), b)
    assert_eq(bigint.to_hex(y2), bigint.to_hex(rhs), "G not on curve")
end)

test("p256: scalar mult by 1 gives G", function()
    local R = p256.scalar_base_mult(bigint.from_int(1))
    local rx, ry = p256.to_affine(R)
    assert_eq(bigint.to_hex(rx), bigint.to_hex(p256.Gx))
    assert_eq(bigint.to_hex(ry), bigint.to_hex(p256.Gy))
end)

test("p256: scalar mult by 2 (point doubling)", function()
    -- 2*G is a known point
    local R = p256.scalar_base_mult(bigint.from_int(2))
    local rx, ry = p256.to_affine(R)
    -- Known 2*G for P-256:
    assert_eq(bigint.to_hex(rx), "7CF27B188D034F7E8A52380304B51AC3C08969E277F21B35A60B48FC47669978")
    assert_eq(bigint.to_hex(ry), "07775510DB8ED040293D9AC69F7430DBBA7DADE63CE982299E04B79D227873D1")
end)

test("p256: scalar mult by 3", function()
    local R = p256.scalar_base_mult(bigint.from_int(3))
    local rx, ry = p256.to_affine(R)
    -- Known 3*G for P-256:
    assert_eq(bigint.to_hex(rx), "5ECBE4D1A6330A44C8F7EF951D4BF165E6C6B721EFADA985FB41661BC6E7FD6C")
    assert_eq(bigint.to_hex(ry), "8734640C4998FF7E374B06CE1A64A2ECD82AB036384FB83D9A79B127A27D5032")
end)

-- ============================================================
-- Key derivation test (from Go SDK test vectors)
-- ============================================================

test("sigv4a: key derivation matches Go SDK test vector", function()
    local akid = "AKISORANDOMAASORANDOM"
    local secret = "q+jcrXGc+0zWN6uzclKVhvMmUsIfRPa4rlRandom"

    local d, qx, qy = sigv4a.derive_key(akid, secret)

    local expected_x = "15D242CEEBF8D8169FD6A8B5A746C41140414C3B07579038DA06AF89190FFFCB"
    local expected_y = "0515242CEDD82E94799482E4C0514B505AFCCF2C0C98D6A553BF539F424C5EC0"

    assert_eq(bigint.to_hex(qx), expected_x, "public key X mismatch")
    assert_eq(bigint.to_hex(qy), expected_y, "public key Y mismatch")
end)

-- ============================================================
-- ECDSA sign/verify roundtrip
-- ============================================================

test("ecdsa: sign produces valid DER", function()
    -- Use a known private key (just 1 for simplicity)
    local d = bigint.from_int(1)
    local hash = sha256.digest("test message")
    local sig = ecdsa.sign(d, hash)

    -- Check DER structure: 0x30 <len> 0x02 <len> <r> 0x02 <len> <s>
    assert_eq(string.byte(sig, 1), 0x30, "DER: expected SEQUENCE tag")
    local total_len = string.byte(sig, 2)
    assert_eq(#sig, total_len + 2, "DER: length mismatch")
    assert_eq(string.byte(sig, 3), 0x02, "DER: expected INTEGER tag for r")
end)

-- ============================================================
-- SigV4a signer integration test
-- ============================================================

test("sigv4a: sign produces valid Authorization header", function()
    local request = {
        method = "POST",
        url = "https://service.region.amazonaws.com",
        headers = {
            ["X-Amz-Date"] = "19700101T000000Z",
        },
        body = nil,
    }
    local identity = {
        access_key = "AKID",
        secret_key = "SECRET",
        session_token = "SESSION",
    }
    local props = {
        signing_name = "dynamodb",
        region_set = {"us-east-1", "us-west-1"},
    }

    local signed, err = sigv4a.sign(request, identity, props)
    assert(signed, "sign failed: " .. tostring(err and err.message))

    local auth = signed.headers["Authorization"]
    assert(auth, "no Authorization header")

    -- Check preamble
    local preamble = auth:match("^(AWS4%-ECDSA%-P256%-SHA256 Credential=AKID/19700101/dynamodb/aws4_request)")
    assert(preamble, "preamble mismatch: " .. auth)

    -- Check signed headers include region-set
    assert(auth:find("x%-amz%-region%-set"), "missing x-amz-region-set in signed headers")

    -- Check region set header
    assert_eq(signed.headers["X-Amz-Region-Set"], "us-east-1,us-west-1")
end)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
