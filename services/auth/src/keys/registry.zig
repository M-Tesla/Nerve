//! PSP Key Registry — CRUD for Ed25519 public keys in Monolith DB
//! Manages the registry of public keys for PSPs participating in RSFN.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const db_mod  = @import("../store/db.zig");
const env_util = @import("../utils/env.zig");

/// Register a PSP public key in the DB.
/// pubkey_bytes: 32 bytes of the Ed25519 public key.
pub fn registerPspKey(
    db: *db_mod.DB,
    psp_id: []const u8,
    pubkey_bytes: [32]u8,
) !void {
    try db.putPspKey(psp_id, pubkey_bytes);
    std.log.info("PSP '{s}' registered in key registry", .{psp_id});
}

/// Return the Ed25519 public key for a PSP, or null if not registered.
pub fn lookupPspKey(
    db: *db_mod.DB,
    psp_id: []const u8,
) !?[32]u8 {
    return db.getPspKey(psp_id);
}

/// Return true if the PSP is registered.
pub fn isPspRegistered(
    db: *db_mod.DB,
    psp_id: []const u8,
) !bool {
    return db.pspExists(psp_id);
}

/// Seed PSPs from environment variables.
/// Env var format: AUTH_PSP_{ID_UPPERCASE}_PUBKEY_HEX=<64 hex chars>
/// Example: AUTH_PSP_ALPHA_PUBKEY_HEX=aabb...ccdd
pub fn seedFromEnv(db: *db_mod.DB) !void {
    const psps = [_]struct { env_var: [:0]const u8, psp_id: []const u8 }{
        .{ .env_var = "AUTH_PSP_ALPHA_PUBKEY_HEX", .psp_id = "psp-alpha" },
        .{ .env_var = "AUTH_PSP_BETA_PUBKEY_HEX", .psp_id = "psp-beta" },
    };

    for (psps) |entry| {
        const hex = env_util.get(entry.env_var) orelse {
            std.log.warn("Env var '{s}' not set — PSP '{s}' not seeded", .{
                entry.env_var,
                entry.psp_id,
            });
            continue;
        };

        if (hex.len != 64) {
            std.log.err("Env var '{s}' must be 64 hex chars (32 bytes). Skipping.", .{entry.env_var});
            continue;
        }

        var pubkey_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&pubkey_bytes, hex) catch |err| {
            std.log.err("Failed to decode hex from '{s}': {}", .{ entry.env_var, err });
            continue;
        };

        try registerPspKey(db, entry.psp_id, pubkey_bytes);
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "register and lookup PSP key" {
    const tmp_path = "test_key_registry.monolith";
    std.fs.cwd().deleteFile(tmp_path) catch {};
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var db = try db_mod.DB.open(tmp_path);
    defer db.deinit();

    const kp = try Ed25519.KeyPair.generate();
    const pubkey_bytes = kp.public_key.bytes;

    // Register
    try registerPspKey(&db, "psp-test", pubkey_bytes);

    // Verify registration
    try std.testing.expect(try isPspRegistered(&db, "psp-test"));
    try std.testing.expect(!try isPspRegistered(&db, "psp-unknown"));

    // Lookup the key
    const retrieved = try lookupPspKey(&db, "psp-test");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualSlices(u8, &pubkey_bytes, &retrieved.?);
}
