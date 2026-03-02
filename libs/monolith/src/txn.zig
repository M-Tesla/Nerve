//! Zig wrapper for MDBX_txn.
//! A Transaction represents an MVCC snapshot of the database.
//!
//! Usage:
//!   var txn = try Transaction.begin(&env, null, .{});
//!   defer txn.abort(); // no-op if already committed
//!   const dbi = try txn.openDbi("users", .{ .create = true });
//!   try txn.put(dbi, "cpf_key", value_bytes, .{});
//!   try txn.commit();

const std = @import("std");
const c = @import("c.zig").mdbx;
const types = @import("types.zig");
const env_mod = @import("env.zig");
const cursor_mod = @import("cursor.zig");

pub const Transaction = struct {
    ptr: *c.MDBX_txn,
    committed: bool = false,

    /// Starts a transaction.
    ///
    /// parent  — parent transaction for nested transactions (null = top-level)
    /// flags   — TxnFlags (.rdonly = true for read-only transactions)
    pub fn begin(
        env: *env_mod.Environment,
        parent: ?*Transaction,
        flags: types.TxnFlags,
    ) types.Error!Transaction {
        var txn_ptr: ?*c.MDBX_txn = null;
        const parent_ptr: ?*c.MDBX_txn = if (parent) |p| p.ptr else null;
        try types.checkError(c.mdbx_txn_begin(env.ptr, parent_ptr, flags.toC(), &txn_ptr));
        return .{ .ptr = txn_ptr.?, .committed = false };
    }

    /// Commits the transaction. After commit() the pointer is invalid.
    pub fn commit(self: *Transaction) types.Error!void {
        try types.checkError(c.mdbx_txn_commit(self.ptr));
        self.committed = true;
    }

    /// Aborts the transaction (discards all changes).
    /// Safe to call even if already committed (no-op in that case).
    pub fn abort(self: *Transaction) void {
        if (!self.committed) {
            _ = c.mdbx_txn_abort(self.ptr);
        }
        self.committed = true; // marks as "closed"
    }

    // -----------------------------------------------------------------------
    // DBI management
    // -----------------------------------------------------------------------

    /// Opens (or creates) a named DBI within this transaction.
    /// Must be in a write txn if flags.create = true.
    pub fn openDbi(self: *Transaction, name: [:0]const u8, flags: types.DbFlags) types.Error!types.Dbi {
        var dbi: types.Dbi = 0;
        try types.checkError(c.mdbx_dbi_open(self.ptr, name.ptr, flags.toC(), &dbi));
        return dbi;
    }

    /// Opens the "default" DBI (unnamed, always available).
    pub fn openDefaultDbi(self: *Transaction) types.Error!types.Dbi {
        var dbi: types.Dbi = 0;
        try types.checkError(c.mdbx_dbi_open(self.ptr, null, c.MDBX_DB_DEFAULTS, &dbi));
        return dbi;
    }

    // -----------------------------------------------------------------------
    // Direct read/write operations (without cursor)
    // -----------------------------------------------------------------------

    /// Reads a value by key. Returns null if not found.
    /// The returned slice points to memory managed by libmdbx —
    /// do not modify and do not use after the transaction closes.
    pub fn get(self: *Transaction, dbi: types.Dbi, key: []const u8) types.Error!?[]const u8 {
        var k = c.MDBX_val{
            .iov_base = @ptrCast(@constCast(key.ptr)),
            .iov_len  = key.len,
        };
        var v: c.MDBX_val = undefined;
        const rc = c.mdbx_get(self.ptr, dbi, &k, &v);
        if (rc == c.MDBX_NOTFOUND) return null;
        try types.checkError(rc);
        return @as([*]u8, @ptrCast(v.iov_base))[0..v.iov_len];
    }

    /// Inserts or updates a key/value pair.
    pub fn put(
        self: *Transaction,
        dbi: types.Dbi,
        key: []const u8,
        val: []const u8,
        flags: types.PutFlags,
    ) types.Error!void {
        var k = c.MDBX_val{
            .iov_base = @ptrCast(@constCast(key.ptr)),
            .iov_len  = key.len,
        };
        var v = c.MDBX_val{
            .iov_base = @ptrCast(@constCast(val.ptr)),
            .iov_len  = val.len,
        };
        try types.checkError(c.mdbx_put(self.ptr, dbi, &k, &v, flags.toC()));
    }

    /// Deletes a key (and all its values in dupsort DBIs).
    /// To delete only a specific value in dupsort, use cursor.del().
    pub fn del(self: *Transaction, dbi: types.Dbi, key: []const u8, val: ?[]const u8) types.Error!void {
        var k = c.MDBX_val{
            .iov_base = @ptrCast(@constCast(key.ptr)),
            .iov_len  = key.len,
        };
        if (val) |v_slice| {
            var v = c.MDBX_val{
                .iov_base = @ptrCast(@constCast(v_slice.ptr)),
                .iov_len  = v_slice.len,
            };
            try types.checkError(c.mdbx_del(self.ptr, dbi, &k, &v));
        } else {
            try types.checkError(c.mdbx_del(self.ptr, dbi, &k, null));
        }
    }

    // -----------------------------------------------------------------------
    // Cursor
    // -----------------------------------------------------------------------

    /// Opens a cursor on this DBI. The cursor must be closed before commit/abort.
    pub fn cursor(self: *Transaction, dbi: types.Dbi) types.Error!cursor_mod.Cursor {
        return cursor_mod.Cursor.open(self, dbi);
    }
};
