-- P-256 elliptic curve point arithmetic and ECDSA signing
-- Uses Jacobian coordinates: (X, Y, Z) represents affine (X/Z^2, Y/Z^3)

local bigint = require("smithy.crypto.bigint")
local field = require("smithy.crypto.field")

local M = {}

-- P-256 generator point G
local Gx = bigint.from_hex("6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296")
local Gy = bigint.from_hex("4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5")

M.Gx = Gx
M.Gy = Gy

-- Point at infinity (Jacobian: Z=0)
function M.point_inf()
    return {bigint.from_int(0), bigint.from_int(1), bigint.from_int(0)}
end

function M.is_inf(P)
    return bigint.is_zero(P[3])
end

-- Point doubling in Jacobian coordinates
-- Reference: https://hyperelliptic.org/EFD/g1p/auto-shortw-jacobian-3.html#doubling-dbl-2001-b
-- P-256 has a = -3
function M.point_double(P)
    local X1, Y1, Z1 = P[1], P[2], P[3]
    if bigint.is_zero(Z1) then return M.point_inf() end

    local Z1sq = field.fsqr(Z1)
    local Y1sq = field.fsqr(Y1)
    local S = field.fmul(bigint.from_int(4), field.fmul(X1, Y1sq))
    -- M = 3*X1^2 + a*Z1^4, a=-3 for P-256
    local X1sq = field.fsqr(X1)
    local Z1_4 = field.fsqr(Z1sq)
    local three_x1sq = field.fadd(X1sq, field.fadd(X1sq, X1sq))
    local a_z1_4 = field.fmul(bigint.from_int(3), Z1_4)
    local MM = field.fsub(three_x1sq, a_z1_4)  -- 3*X1^2 - 3*Z1^4

    local X3 = field.fsub(field.fsqr(MM), field.fadd(S, S))
    local Y1_4 = field.fsqr(Y1sq)
    local eight_y1_4 = field.fmul(bigint.from_int(8), Y1_4)
    local Y3 = field.fsub(field.fmul(MM, field.fsub(S, X3)), eight_y1_4)
    local Z3 = field.fmul(bigint.from_int(2), field.fmul(Y1, Z1))

    return {X3, Y3, Z3}
end

-- Point addition in Jacobian coordinates
-- Mixed addition when Q is affine (Qz=1) for efficiency
function M.point_add(P, Q)
    local X1, Y1, Z1 = P[1], P[2], P[3]
    local X2, Y2, Z2 = Q[1], Q[2], Q[3]

    if bigint.is_zero(Z1) then return {bigint.copy(X2), bigint.copy(Y2), bigint.copy(Z2)} end
    if bigint.is_zero(Z2) then return {bigint.copy(X1), bigint.copy(Y1), bigint.copy(Z1)} end

    local Z1sq = field.fsqr(Z1)
    local Z2sq = field.fsqr(Z2)
    local U1 = field.fmul(X1, Z2sq)
    local U2 = field.fmul(X2, Z1sq)
    local S1 = field.fmul(Y1, field.fmul(Z2, Z2sq))
    local S2 = field.fmul(Y2, field.fmul(Z1, Z1sq))

    if bigint.cmp(U1, U2) == 0 then
        if bigint.cmp(S1, S2) == 0 then
            return M.point_double(P)
        else
            return M.point_inf()
        end
    end

    local H = field.fsub(U2, U1)
    local R = field.fsub(S2, S1)
    local Hsq = field.fsqr(H)
    local Hcu = field.fmul(H, Hsq)
    local U1Hsq = field.fmul(U1, Hsq)

    local X3 = field.fsub(field.fsub(field.fsqr(R), Hcu), field.fadd(U1Hsq, U1Hsq))
    local Y3 = field.fsub(field.fmul(R, field.fsub(U1Hsq, X3)), field.fmul(S1, Hcu))
    local Z3 = field.fmul(H, field.fmul(Z1, Z2))

    return {X3, Y3, Z3}
end

-- Convert Jacobian to affine coordinates
function M.to_affine(P)
    if bigint.is_zero(P[3]) then
        return nil, nil -- point at infinity
    end
    local Z_inv = field.finv(P[3])
    local Z_inv2 = field.fsqr(Z_inv)
    local Z_inv3 = field.fmul(Z_inv2, Z_inv)
    local x = field.fmul(P[1], Z_inv2)
    local y = field.fmul(P[2], Z_inv3)
    return x, y
end

-- Scalar multiplication: k * G (base point multiplication)
-- Uses double-and-add, scanning bits from MSB to LSB
function M.scalar_base_mult(k)
    local G = {Gx, Gy, bigint.from_int(1)}
    return M.scalar_mult(k, G)
end

-- Scalar multiplication: k * P
function M.scalar_mult(k, P)
    local R = M.point_inf()
    local k_bytes = bigint.to_bytes(k)
    for i = 1, 32 do
        local byte = string.byte(k_bytes, i)
        for j = 7, 0, -1 do
            R = M.point_double(R)
            if math.floor(byte / (2^j)) % 2 == 1 then
                R = M.point_add(R, P)
            end
        end
    end
    return R
end

return M
