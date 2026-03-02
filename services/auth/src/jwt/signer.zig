//! JWT Signer — signs tokens with Ed25519 (std.crypto.sign.Ed25519)
//! The Auth service has its own keypair and signs all issued JWTs.
//! Any service can verify using the Auth public key.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const claims_mod = @import("claims.zig");

/// Result of signing — the complete JWT token.
pub const SignedToken = struct {
    /// Token in format header.payload.signature (Base64url)
    /// Heap-allocated — caller must free with allocator.free().
    token: []u8,
    /// JTI generated for this token (UUID v4)
    jti: [36]u8,
    /// Expiration timestamp (unix seconds)
    expires_at: i64,
};

/// Sign a JWT for the PSP identified by psp_id.
/// keypair: Ed25519 keypair (seed[32] ++ pubkey[32]).
/// ttl_seconds: token lifetime in seconds (e.g. 900 for 15 min).
/// Returns SignedToken with heap-allocated token — caller frees .token.
pub fn sign(
    allocator: std.mem.Allocator,
    psp_id: []const u8,
    keypair: Ed25519.KeyPair,
    ttl_seconds: i64,
) !SignedToken {
    const now: i64 = std.time.timestamp();
    const exp: i64 = now + ttl_seconds;

    // Generate unique JTI
    var jti: [36]u8 = undefined;
    claims_mod.generateUuidV4(&jti);

    // Build header.payload (the message to sign)
    const enc_header = try claims_mod.encodedHeader(allocator);
    defer allocator.free(enc_header);

    const enc_payload = try claims_mod.encodedPayload(allocator, psp_id, now, exp, &jti);
    defer allocator.free(enc_payload);

    // Message = "base64url(header).base64url(payload)"
    const message = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ enc_header, enc_payload });
    defer allocator.free(message);

    // Sign with Ed25519
    const sig = try keypair.sign(message, null);
    const sig_bytes = sig.toBytes();

    // Base64url encode the signature (64 bytes)
    const enc_sig = try claims_mod.encode(allocator, &sig_bytes);
    defer allocator.free(enc_sig);

    // Final token: header.payload.signature
    const token = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{
        enc_header,
        enc_payload,
        enc_sig,
    });

    return .{
        .token = token,
        .jti = jti,
        .expires_at = exp,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "sign produces valid 3-part token" {
    const ally = std.testing.allocator;

    const kp = Ed25519.KeyPair.generate();

    const result = try sign(ally, "psp-test", kp, 900);
    defer ally.free(result.token);

    // Token must have exactly 2 dots (3 parts)
    var dot_count: usize = 0;
    for (result.token) |c| {
        if (c == '.') dot_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), dot_count);

    // JTI must be 36 chars (UUID v4)
    try std.testing.expectEqual(@as(usize, 36), result.jti.len);

    // expires_at must be in the future
    try std.testing.expect(result.expires_at > std.time.timestamp());
}
