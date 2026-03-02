//! Monolith — Embedded B-tree storage engine (libmdbx via Zig FFI)
//!
//! Public API:
//!   const monolith = @import("monolith");
//!
//!   var env = try monolith.Environment.open("/data/dict.monolith", .{}, 16, 1 << 30);
//!   defer env.close();
//!
//!   var txn = try monolith.Transaction.begin(&env, null, .{});
//!   defer txn.abort();
//!   const dbi = try txn.openDbi("users", .{ .create = true });
//!   try txn.put(dbi, key_bytes, val_bytes, .{});
//!   try txn.commit();

pub const Environment  = @import("env.zig").Environment;
pub const Transaction  = @import("txn.zig").Transaction;
pub const Cursor       = @import("cursor.zig").Cursor;
pub const types        = @import("types.zig");

// Convenience re-exports (avoids `monolith.types.EnvFlags`)
pub const EnvFlags  = types.EnvFlags;
pub const DbFlags   = types.DbFlags;
pub const TxnFlags  = types.TxnFlags;
pub const PutFlags  = types.PutFlags;
pub const Dbi       = types.Dbi;
pub const KV        = types.KV;
pub const Error     = types.Error;

// -------------------------------------------------------------------------
// Integration tests
// -------------------------------------------------------------------------
test {
    _ = @import("tests/test_basic.zig");
    _ = @import("tests/test_dupsort.zig");
    _ = @import("tests/test_integerkey.zig");
    _ = @import("tests/test_multi_dbi.zig");
}
