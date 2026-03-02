const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");
const cursor = @import("../cursor.zig");
const chk = @import("../chk.zig");
const page = @import("../page/page.zig");

test "Database Validation (monolith_chk)" {
    const path = "test_chk.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    // 1. Create a Valid DB
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        defer tx.abort();
        
        var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
        
        // Insert enough items to create branches (lower than 80 to avoid MapFull on 16 pages limit with GC overhead)
        for (0..15) |i| {
            var buf: [16]u8 = undefined;
            const key = try std.fmt.bufPrint(&buf, "key{d}", .{i});
            try cur.put(key, "val", 0);
        }
        
        try tx.commit();
    }
    
    // 2. Check Valid DB
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = true });
        defer tx.abort();
        
        var checker = chk.Checker.init(std.testing.allocator, &tx);
        defer checker.deinit();
        
        try checker.check();
    }
    
    
}
