const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");
const cursor = @import("../cursor.zig");

test "Cursor Overflow" {
    const path = "test_cursor_overflow.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    // 1. Write Large Value
    var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
    defer tx.abort();
    
    var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
    
    const large_val = try std.testing.allocator.alloc(u8, 10000); // 10KB
    defer std.testing.allocator.free(large_val);
    @memset(large_val, 'X');
    large_val[9999] = 'Y';
    
    try cur.put("large_key", large_val, 0);
    
    // Verify Allocations
    try std.testing.expect(tx.meta.geometry.first_unallocated > 5);
    
    // 2. Read Back
    var val: []const u8 = undefined;
    const found = try cur.get("large_key", &val);
    try std.testing.expect(found);
    try std.testing.expectEqual(large_val.len, val.len);
    try std.testing.expectEqual(@as(u8, 'X'), val[0]);
    try std.testing.expectEqual(@as(u8, 'Y'), val[9999]);
    
    // 3. Delete
    try cur.del();
    
    // Verify Gone
    val = undefined;
    const found_after = try cur.get("large_key", &val);
    try std.testing.expect(!found_after);
    
    // Verify Freed
    try std.testing.expect(tx.freed_pages.items.len >= 3);
    
    try tx.commit();
}
