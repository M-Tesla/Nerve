const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");
const page = @import("../page/page.zig");
const Cursor = @import("../cursor.zig").Cursor;

test "B-Tree Rebalance (Merge/Redistribute)" {
    const path = "test_rebalance.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};

    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();

    try environment.resize(1024 * 1024 * 10); // 10MB

    // 1. Insert enough items to create a 3-level tree
    // ~200 items per page. 4000 items -> ~20 leaves -> 1 root.
    // Let's go for 5000 items.
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        defer tx.abort();
        
        var cursor = Cursor.open(&tx, &tx.meta.trees.main);
        
        var buf: [32]u8 = undefined;
        for (0..5000) |i| {
            const key = try std.fmt.bufPrint(&buf, "key{d:0>5}", .{i});
            try cursor.put(key, "data", 0);
        }
        _ = try tx.commit();
    }

    // 2. Delete items to cause underflow
    // We want to delete 90% of items, but leaving 1 item per page if possible?
    // Or just delete sequential ranges to force merge.
    // If we delete key00000...key00190, the first leaf becomes almost empty.
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        defer tx.abort();
        var cursor = Cursor.open(&tx, &tx.meta.trees.main);

        // Delete 0..4900. Keeping last 100.
        // This will cause massive underflow in left-most pages.
        // They should merge and effectively free pages.
        var buf: [32]u8 = undefined;
        for (0..4900) |i| {
            const key = try std.fmt.bufPrint(&buf, "key{d:0>5}", .{i});
            var val: []const u8 = undefined;
            const res = try cursor.get(key, &val);
            if (res) {
                 try cursor.del();
            }
        }
        
        _ = try tx.commit();
    }

    // 3. Check Tree Depth and Page Usage
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = true });
        defer tx.abort();
        
        // Depth should decrease or pages should be well-filled?
        // With rebalancing, depth might drop.
        // Without rebalancing, we might have many empty pages.
        
        std.debug.print("Depth: {}\n", .{tx.meta.trees.main.height});
        
        // We can't easily check internal fragmentation without inspecting pages.
        // But we can check if file size/page usage is consistent?
    }
}
