const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");
const cursor = @import("../cursor.zig");
const chk = @import("../chk.zig");

test "Fixed Size Dups Storage Optimization" {
    const path_std = "test_dup_std.monolith";
    const path_fix = "test_dup_fix.monolith";
    defer std.fs.cwd().deleteFile(path_std) catch {};
    defer std.fs.cwd().deleteFile(path_fix) catch {};
    
    const count = 1000;
    
    // 1. Standard DUPSORT (No DUPFIXED)
    {
        var env_std = try env.Environment.open(path_std, .{}, .{}, std.testing.allocator);
        defer env_std.deinit();
        var tx = try txn.Transaction.begin(&env_std, null, .{ .rdonly = false });
        defer tx.abort();
        
        tx.meta.trees.main.flags |= 0x04; // DUPSORT
        var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
        
        for (0..count) |i| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, i, .little);
            try cur.put("key", &buf, 0);
        }
        try tx.commit();
    }
    
    // 2. Optimized DUPFIXED
    std.debug.print("================== START DUPFIXED ==================\n", .{});
    {
        var env_fix = try env.Environment.open(path_fix, .{}, .{}, std.testing.allocator);
        defer env_fix.deinit();
        var tx = try txn.Transaction.begin(&env_fix, null, .{ .rdonly = false });
        defer tx.abort();
        
        tx.meta.trees.main.flags |= 0x04 | 0x10 | 0x20; // DUPSORT | DUPFIXED | INTEGERDUP
        var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
        
        for (0..count) |i| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @intCast(i), .little);
            try cur.put("key_fix", &buf, 0);
        }
        try tx.commit();
        
        // Validation Check
        var tx_chk = try txn.Transaction.begin(&env_fix, null, .{ .rdonly = true });
        defer tx_chk.abort();
        
        var checker = chk.Checker.init(std.testing.allocator, &tx_chk);
        defer checker.deinit();
        try checker.check();
    }
    
    // 3. Compare Size
    const file_std = try std.fs.cwd().openFile(path_std, .{});
    const size_std = (try file_std.stat()).size;
    file_std.close();
    
    const file_fix = try std.fs.cwd().openFile(path_fix, .{});
    const size_fix = (try file_fix.stat()).size;
    file_fix.close();
    
    std.debug.print("\nStandard Size: {d} bytes\n", .{size_std});
    std.debug.print("Fixed Size:    {d} bytes\n", .{size_fix});
    
    // Expect Fixed to be smaller
    try std.testing.expect(size_fix < size_std);
    
    // Verify Items Count
    // Open read-only and count
    {
        var env_fix = try env.Environment.open(path_fix, .{}, .{}, std.testing.allocator);
        defer env_fix.deinit();
        var tx = try txn.Transaction.begin(&env_fix, null, .{ .rdonly = true });
        defer tx.abort();
        // Count duplicate items
        // get("key"), then count.
        // Actually dbi.items tracks total items.
        // If "key" is the only key, then items == count.
        try std.testing.expectEqual(@as(u64, count), tx.meta.trees.main.items);
    }
}
