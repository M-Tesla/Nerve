const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");
const page = @import("../page/page.zig");
const Cursor = @import("../cursor.zig").Cursor;
const types = @import("../core/types.zig");

test "Integer Dups (monolith_INTEGERDUP)" {
    const path = "test_int_dup.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};

    const monolith_INTEGERDUP: u16 = 0x20;
    const monolith_DUPSORT: u16 = 0x04;

    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();

    // 1. Insert Integer Duplicates
    // We expect them to be sorted numerically (Small Endian), not lexicographically.
    // Lex: 10, 2, 30
    // Num: 2, 10, 30
    // Encode as 4-byte integers (Little Endian)
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        defer tx.abort();
        
        // Enable monolith_INTEGERDUP | monolith_DUPSORT
        tx.meta.trees.main.flags |= (monolith_INTEGERDUP | monolith_DUPSORT); // 0x20 | 0x04
        
        var cursor = Cursor.open(&tx, &tx.meta.trees.main);
        
        const key = "keyset";
        
        var val2: [4]u8 = undefined; std.mem.writeInt(u32, &val2, 2, .little);
        var val256: [4]u8 = undefined; std.mem.writeInt(u32, &val256, 256, .little);
        var val65536: [4]u8 = undefined; std.mem.writeInt(u32, &val65536, 65536, .little);
        
        try cursor.put(key, &val256, 0);
        try cursor.put(key, &val2, 0); // Should go before 256
        try cursor.put(key, &val65536, 0); // Should go after 256
        
        _ = try tx.commit();
    }

    // 2. Verify Order
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = true });
        defer tx.abort();
        
        var cursor = Cursor.open(&tx, &tx.meta.trees.main);
        
        var val: []const u8 = undefined;
        // Get first
        const found = try cursor.get("keyset", &val);
        try std.testing.expect(found);
        
        // Should be 2 (first)
        var i = std.mem.readInt(u32, val[0..4], .little);
        // With INTEGERDUP, 2 comes first
        try std.testing.expectEqual(@as(u32, 2), i);
        
        // Next Dup
        var has_next = try cursor.nextDup();
        try std.testing.expect(has_next);
        var kv = try cursor.current();
        i = std.mem.readInt(u32, kv.value[0..4], .little);
        try std.testing.expectEqual(@as(u32, 256), i);
        
        // Next Dup
        has_next = try cursor.nextDup();
        try std.testing.expect(has_next);
        kv = try cursor.current();
        i = std.mem.readInt(u32, kv.value[0..4], .little);
        try std.testing.expectEqual(@as(u32, 65536), i);
    }
}
