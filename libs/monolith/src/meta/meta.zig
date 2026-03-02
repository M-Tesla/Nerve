//! Meta pages and control headers

const std = @import("std");
const types = @import("../core/types.zig");
const consts = @import("../core/consts.zig");
const page = @import("../page/page.zig");

/// Meta page header.
/// Stores critical information at the start of the database file.
/// There are always 2 meta pages (0 and 1) used in ping-pong to guarantee atomicity.
pub const Meta = extern struct {
    /// Magic number and version (monolith_magic_and_version)
    magic_and_version: u64 align(4),

    /// TxnID A (committed) - union with atomic and unsafe
    txnid_a: u64 align(4),

    /// Reserve16
    reserve16: u16,

    /// Validator ID
    validator_id: u8,

    /// Extra page header
    extra_pagehdr: i8,

    /// Database geometry
    geometry: types.Geo,

    /// Trees (GC and Main)
    trees: extern struct {
        gc: types.Tree,
        main: types.Tree,
    } align(4),

    /// Canary
    canary: types.Canary align(4),

    /// Signatures
    sign: u64 align(4),

    /// TxnID B
    txnid_b: u64 align(4),

    /// Retired pages
    pages_retired: [2]u32,

    /// Boot ID
    bootid: types.Bin128 align(4),

    /// DXB ID
    dxbid: types.Bin128 align(4),

    pub fn validate(self: *const Meta) bool {
        return self.magic_and_version == consts.MAGIC;
    }
};

test "Meta size fits in minimum page" {
    try std.testing.expect(@sizeOf(Meta) < consts.MIN_PAGESIZE);
}
