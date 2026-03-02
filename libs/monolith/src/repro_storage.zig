const std = @import("std");
const env = @import("env.zig");
const txn = @import("txn.zig");
const cursor = @import("cursor.zig");
const chk = @import("chk.zig");

test "Fixed Size Dups Storage Optimization" {
    const path_std = "test_dup_std.monolith";
    const path_fix = "test_dup_fix.monolith";
    defer std.fs.cwd().deleteFile(path_std) catch {};
    defer std.fs.cwd().deleteFile(path_fix) catch {};
    
    const count = 10000;
       
    // 2. Optimized DUPFIXED
    {
        var env_fix = try env.Environment.open(path_fix, .{}, .{}, std.testing.allocator);
        defer env_fix.deinit();
        var tx = try txn.Transaction.begin(&env_fix, null, .{ .rdonly = false });
        defer tx.abort();
        
        tx.meta.trees.main.flags |= 0x04 | 0x10; // DUPSORT | DUPFIXED
        var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
        
        for (0..count) |i| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @intCast(i), .little);
            cur.put("key_fix", &buf, 0) catch |err| {
                std.debug.print("FAILURE at i={d}: {s}\n", .{i, @errorName(err)});
                return err;
            };
        }
        try tx.commit();
        
        // Validation Check
        var tx_chk = try txn.Transaction.begin(&env_fix, null, .{ .rdonly = true });
        defer tx_chk.abort();
        
        var checker = chk.Checker.init(std.testing.allocator, &tx_chk);
        defer checker.deinit();
        try checker.check();
    }
}
