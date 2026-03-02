//! JWT Verifier — validates Ed25519 signature + claims (exp, iss, jti revocation)
//! Verifies tokens issued by signer.zig using the Auth service public key.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const claims_mod = @import("claims.zig");
const db_mod = @import("../store/db.zig");

pub const VerifyError = error{
    MalformedToken,
    InvalidSignature,
    TokenExpired,
    TokenRevoked,
    MissingField,
    InvalidKeyLength,
};

/// Result of a successful verification.
pub const VerifyResult = struct {
    psp_id: []const u8, // sub from JWT (points into internal json_buf)
    jti: []const u8,    // jti from JWT (points into internal json_buf)
    expires_at: i64,
    /// Internal buffer holding the decoded payload JSON.
    /// Kept in VerifyResult so the strings above remain valid.
    _json_buf: []u8,
    _allocator: std.mem.Allocator,

    pub fn deinit(self: *VerifyResult) void {
        self._allocator.free(self._json_buf);
    }
};

/// Verify a complete JWT.
/// pubkey: 32-byte Ed25519 public key of the Auth service.
/// db: Auth DB for checking revoked JTIs.
/// Returns VerifyResult that must be .deinit() by caller.
pub fn verify(
    allocator: std.mem.Allocator,
    token: []const u8,
    pubkey: Ed25519.PublicKey,
    db: *db_mod.DB,
) (VerifyError || std.mem.Allocator.Error || error{
    KeyTooLong, InvalidKeyLength, InvalidEncoding, InvalidCharacter, NoSpaceLeft, InvalidPadding,
})!VerifyResult {
    // 1. Split into 3 parts: header.payload.signature
    var parts: [3][]const u8 = undefined;
    var iter = std.mem.splitScalar(u8, token, '.');
    var idx: usize = 0;
    while (iter.next()) |part| {
        if (idx >= 3) return VerifyError.MalformedToken;
        parts[idx] = part;
        idx += 1;
    }
    if (idx != 3) return VerifyError.MalformedToken;

    const enc_header = parts[0];
    const enc_payload = parts[1];
    const enc_sig = parts[2];

    // 2. Verify Ed25519 signature
    // Signed message = "header.payload" (excluding the signature part)
    const message = token[0 .. enc_header.len + 1 + enc_payload.len];

    const sig_bytes = try claims_mod.decode(allocator, enc_sig);
    defer allocator.free(sig_bytes);
    if (sig_bytes.len != Ed25519.Signature.encoded_length) return VerifyError.MalformedToken;

    const sig = Ed25519.Signature.fromBytes(sig_bytes[0..Ed25519.Signature.encoded_length].*);
    sig.verify(message, pubkey) catch return VerifyError.InvalidSignature;

    // 3. Decode and parse payload
    const payload_json = try claims_mod.decode(allocator, enc_payload);
    errdefer allocator.free(payload_json);

    var parsed_claims: claims_mod.Claims = undefined;
    claims_mod.Claims.parse(payload_json, &parsed_claims) catch return VerifyError.MissingField;

    // 4. Check expiration
    const now: i64 = std.time.timestamp();
    if (now >= parsed_claims.exp) return VerifyError.TokenExpired;

    // 5. Check JTI revocation
    const revoked = db.isJtiRevoked(parsed_claims.jti) catch return VerifyError.TokenRevoked;
    if (revoked) return VerifyError.TokenRevoked;

    return VerifyResult{
        .psp_id = parsed_claims.sub,
        .jti = parsed_claims.jti,
        .expires_at = parsed_claims.exp,
        ._json_buf = payload_json,
        ._allocator = allocator,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "verify valid token sign→verify round-trip" {
    const signer_mod = @import("signer.zig");
    const ally = std.testing.allocator;

    const kp = Ed25519.KeyPair.generate();

    const tmp_path = "test_auth_verify.monolith";
    std.fs.cwd().deleteFile(tmp_path) catch {};
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var db = try db_mod.DB.open(tmp_path);
    defer db.deinit();

    const signed = try signer_mod.sign(ally, "psp-alpha", kp, 900);
    defer ally.free(signed.token);

    var result = try verify(ally, signed.token, kp.public_key, &db);
    defer result.deinit();

    try std.testing.expectEqualStrings("psp-alpha", result.psp_id);
    try std.testing.expect(result.expires_at > std.time.timestamp());
}

test "verify fails with expired token" {
    const signer_mod = @import("signer.zig");
    const ally = std.testing.allocator;

    const kp = Ed25519.KeyPair.generate();

    const tmp_path = "test_auth_expired.monolith";
    std.fs.cwd().deleteFile(tmp_path) catch {};
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var db = try db_mod.DB.open(tmp_path);
    defer db.deinit();

    // TTL of -1 second → already expired
    const signed = try signer_mod.sign(ally, "psp-alpha", kp, -1);
    defer ally.free(signed.token);

    const result = verify(ally, signed.token, kp.public_key, &db);
    try std.testing.expectError(VerifyError.TokenExpired, result);
}

test "verify fails with revoked JTI" {
    const signer_mod = @import("signer.zig");
    const ally = std.testing.allocator;

    const kp = Ed25519.KeyPair.generate();

    const tmp_path = "test_auth_revoked.monolith";
    std.fs.cwd().deleteFile(tmp_path) catch {};
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var db = try db_mod.DB.open(tmp_path);
    defer db.deinit();

    const signed = try signer_mod.sign(ally, "psp-alpha", kp, 900);
    defer ally.free(signed.token);

    // Revoke the JTI before verifying
    try db.revokeJti(&signed.jti);

    const result = verify(ally, signed.token, kp.public_key, &db);
    try std.testing.expectError(VerifyError.TokenRevoked, result);
}
