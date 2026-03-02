//! Zig wrapper for MDBX_cursor.
//! Cursors allow efficient iteration over keys/values,
//! essential for traversing secondary indices (dupsort).
//!
//! Basic usage:
//!   var cur = try txn.cursor(dbi);
//!   defer cur.close();
//!   if (try cur.first()) |kv| { ... }
//!   while (try cur.next()) |kv| { ... }
//!
//! Dupsort (secondary index):
//!   try cur.find(key);        // position at key
//!   while (try cur.nextDup()) |val| { ... }  // iterate values

const std = @import("std");
const c = @import("c.zig").mdbx;
const types = @import("types.zig");

// forward declaration — txn.zig imports cursor.zig, so cursor.zig
// cannot import txn.zig (cycle). Use the C pointer directly.

pub const Cursor = struct {
    ptr: *c.MDBX_cursor,

    /// Opens a cursor for the DBI in the given transaction.
    pub fn open(txn_ptr: anytype, dbi: types.Dbi) types.Error!Cursor {
        // txn_ptr can be *Transaction (from txn.zig) or *c.MDBX_txn
        const raw: *c.MDBX_txn = if (@TypeOf(txn_ptr) == *c.MDBX_txn)
            txn_ptr
        else
            txn_ptr.ptr;

        var cur_ptr: ?*c.MDBX_cursor = null;
        try types.checkError(c.mdbx_cursor_open(raw, dbi, &cur_ptr));
        return .{ .ptr = cur_ptr.? };
    }

    /// Closes the cursor and releases resources.
    pub fn close(self: *Cursor) void {
        c.mdbx_cursor_close(self.ptr);
        self.ptr = undefined;
    }

    // -----------------------------------------------------------------------
    // Basic navigation
    // -----------------------------------------------------------------------

    /// Positions at the first key/value pair. Returns null if DB is empty.
    pub fn first(self: *Cursor) types.Error!?types.KV {
        return self.op(c.MDBX_FIRST);
    }

    /// Advances to the next key/value pair.
    /// Returns null when the end is reached.
    pub fn next(self: *Cursor) types.Error!?types.KV {
        return self.op(c.MDBX_NEXT);
    }

    /// Positions at the last key/value pair.
    pub fn last(self: *Cursor) types.Error!?types.KV {
        return self.op(c.MDBX_LAST);
    }

    /// Returns the current pair (without moving the cursor).
    pub fn current(self: *Cursor) types.Error!?types.KV {
        return self.op(c.MDBX_GET_CURRENT);
    }

    // -----------------------------------------------------------------------
    // Search
    // -----------------------------------------------------------------------

    /// Positions the cursor at the exact key. Returns false if not found.
    pub fn find(self: *Cursor, key: []const u8) types.Error!bool {
        var k = c.MDBX_val{
            .iov_base = @ptrCast(@constCast(key.ptr)),
            .iov_len  = key.len,
        };
        var v: c.MDBX_val = undefined;
        const rc = c.mdbx_cursor_get(self.ptr, &k, &v, c.MDBX_SET);
        if (rc == c.MDBX_NOTFOUND) return false;
        try types.checkError(rc);
        return true;
    }

    /// Positions the cursor at key >= key (lower bound).
    /// Useful for range scans. Returns null if no key >= key exists.
    pub fn findGe(self: *Cursor, key: []const u8) types.Error!?types.KV {
        var k = c.MDBX_val{
            .iov_base = @ptrCast(@constCast(key.ptr)),
            .iov_len  = key.len,
        };
        var v: c.MDBX_val = undefined;
        const rc = c.mdbx_cursor_get(self.ptr, &k, &v, c.MDBX_SET_RANGE);
        if (rc == c.MDBX_NOTFOUND) return null;
        try types.checkError(rc);
        return .{
            .key = @as([*]u8, @ptrCast(k.iov_base))[0..k.iov_len],
            .val = @as([*]u8, @ptrCast(v.iov_base))[0..v.iov_len],
        };
    }

    // -----------------------------------------------------------------------
    // Dupsort navigation (secondary indices)
    // -----------------------------------------------------------------------

    /// Advances to the next value of the same key in a dupsort DBI.
    /// Returns null when there are no more dups for the current key.
    pub fn nextDup(self: *Cursor) types.Error!?[]const u8 {
        var k: c.MDBX_val = undefined;
        var v: c.MDBX_val = undefined;
        const rc = c.mdbx_cursor_get(self.ptr, &k, &v, c.MDBX_NEXT_DUP);
        if (rc == c.MDBX_NOTFOUND) return null;
        try types.checkError(rc);
        return @as([*]u8, @ptrCast(v.iov_base))[0..v.iov_len];
    }

    /// Positions at the exact (key, val) pair in a dupsort DBI.
    pub fn findDup(self: *Cursor, key: []const u8, val: []const u8) types.Error!bool {
        var k = c.MDBX_val{
            .iov_base = @ptrCast(@constCast(key.ptr)),
            .iov_len  = key.len,
        };
        var v = c.MDBX_val{
            .iov_base = @ptrCast(@constCast(val.ptr)),
            .iov_len  = val.len,
        };
        const rc = c.mdbx_cursor_get(self.ptr, &k, &v, c.MDBX_GET_BOTH);
        if (rc == c.MDBX_NOTFOUND) return false;
        try types.checkError(rc);
        return true;
    }

    /// Counts how many values the current key has in a dupsort DBI.
    pub fn countDups(self: *Cursor) types.Error!usize {
        var count: usize = 0;
        try types.checkError(c.mdbx_cursor_count(self.ptr, &count));
        return count;
    }

    // -----------------------------------------------------------------------
    // Write via cursor
    // -----------------------------------------------------------------------

    /// Inserts/updates a key/value pair at the cursor position.
    pub fn put(
        self: *Cursor,
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
        try types.checkError(c.mdbx_cursor_put(self.ptr, &k, &v, flags.toC()));
    }

    /// Deletes the current element at the cursor.
    pub fn del(self: *Cursor) types.Error!void {
        try types.checkError(c.mdbx_cursor_del(self.ptr, c.MDBX_CURRENT));
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    fn op(self: *Cursor, op_code: c.MDBX_cursor_op) types.Error!?types.KV {
        var k: c.MDBX_val = undefined;
        var v: c.MDBX_val = undefined;
        const rc = c.mdbx_cursor_get(self.ptr, &k, &v, op_code);
        if (rc == c.MDBX_NOTFOUND) return null;
        try types.checkError(rc);
        return .{
            .key = @as([*]u8, @ptrCast(k.iov_base))[0..k.iov_len],
            .val = @as([*]u8, @ptrCast(v.iov_base))[0..v.iov_len],
        };
    }
};
