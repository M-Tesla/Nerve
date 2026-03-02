//! Auth Store — Monolith DB wrapper (libmdbx via FFI)
//!
//! Two named DBIs:
//!   "psp_keys"     — Key: psp_id (string), Value: [32]u8 (Ed25519 pubkey)
//!   "revoked_jtis" — Key: jti (string UUID), Value: [8]u8 (revoked_at_ns u64 LE)

const std = @import("std");
const m = @import("monolith");

pub const DB = struct {
    env: m.Environment,

    /// Open (or create) the Auth service .monolith file.
    /// path must be null-terminated ([:0]const u8).
    pub fn open(path: [:0]const u8) !DB {
        var env = try m.Environment.open(path, .{ .liforeclaim = true }, 4, 64 * 1024 * 1024);
        errdefer env.close();

        // Create both DBIs in an init write transaction
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        _ = try txn.openDbi("psp_keys",     .{ .create = true });
        _ = try txn.openDbi("revoked_jtis", .{ .create = true });
        try txn.commit();

        return .{ .env = env };
    }

    pub fn deinit(self: *DB) void {
        self.env.close();
    }

    // -------------------------------------------------------------------------
    // psp_keys API
    // -------------------------------------------------------------------------

    /// Register the Ed25519 public key (32 bytes) for a PSP.
    pub fn putPspKey(self: *DB, psp_id: []const u8, pubkey: [32]u8) !void {
        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("psp_keys", .{});
        try txn.put(dbi, psp_id, &pubkey, .{});
        try txn.commit();
    }

    /// Return the Ed25519 public key (32 bytes) for a PSP, or null if not found.
    pub fn getPspKey(self: *DB, psp_id: []const u8) !?[32]u8 {
        var txn = try m.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("psp_keys", .{});
        const val = try txn.get(dbi, psp_id) orelse return null;
        if (val.len != 32) return error.InvalidKeyLength;
        var result: [32]u8 = undefined;
        @memcpy(&result, val[0..32]);
        return result;
    }

    /// Return true if the PSP is registered.
    pub fn pspExists(self: *DB, psp_id: []const u8) !bool {
        var txn = try m.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("psp_keys", .{});
        return (try txn.get(dbi, psp_id)) != null;
    }

    // -------------------------------------------------------------------------
    // revoked_jtis API
    // -------------------------------------------------------------------------

    /// Revoke a JTI by recording the revocation timestamp (nanoseconds).
    pub fn revokeJti(self: *DB, jti: []const u8) !void {
        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        var ts_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &ts_buf, now_ns, .little);

        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("revoked_jtis", .{});
        try txn.put(dbi, jti, &ts_buf, .{});
        try txn.commit();
    }

    /// Return true if the JTI has been revoked.
    pub fn isJtiRevoked(self: *DB, jti: []const u8) !bool {
        var txn = try m.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("revoked_jtis", .{});
        return (try txn.get(dbi, jti)) != null;
    }
};
