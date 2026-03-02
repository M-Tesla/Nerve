const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");
const types = @import("../core/types.zig");
const page = @import("../page/page.zig");

test "Spill to Disk: Large Transaction" {
    const path = "test_spill.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};

    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();

    // Pre-allocate to avoid MapFull
    try environment.resize(1024 * 1024 * 10); // 10MB

    // 1. Start Write Transaction
    var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
    defer tx.abort(); // cleanup if fail

    // 2. Set Dirty Limit
    tx.dirty_limit = 10;
    
    // 3. Write many pages (e.g., 100)
    const Cursor = @import("../cursor.zig").Cursor;
    
    var buf: [32]u8 = undefined;
    for (0..100) |i| {
        const key = try std.fmt.bufPrint(&buf, "key{d:0>5}", .{i});
        const val = "val";
        
        var cursor = Cursor.open(&tx, &tx.meta.trees.main);
        try cursor.put(key, val, 0);
    }

    // 4. Commit
    _ = try tx.commit();

    // 5. Verify Data (New Read Txn)
    var rx = try txn.Transaction.begin(&environment, null, .{ .rdonly = true });
    defer rx.abort();

    for (0..100) |i| {
        const key = try std.fmt.bufPrint(&buf, "key{d:0>5}", .{i});
        var cursor = Cursor.open(&rx, &rx.meta.trees.main);
        
        var val_out: []const u8 = undefined;
        const res = try cursor.get(key, &val_out);
        if (!res) {
            std.debug.print("FAIL: Key {s} not found\n", .{key});
            return error.KeyNotFound;
        }
    }
}
