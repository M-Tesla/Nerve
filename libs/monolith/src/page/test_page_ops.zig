
test "PageHeader Put/Search" {
    var buffer: [4096]u8 align(4) = undefined;
    const ptr = @as(*PageHeader, @ptrCast(&buffer));
    
    // Init
    ptr.init(4096, .{ .leaf = true });
    
    // Check Free Space (4096 - 20 = 4076)
    try std.testing.expectEqual(@as(u32, 4076), ptr.getFreeSpace());
    
    // Insert "key1" -> "val1" at index 0
    _ = ptr.putNode(0, "key1", "val1", 0);
    
    // Verify
    try std.testing.expectEqual(@as(u16, 1), ptr.getNumEntries());
    const n1 = ptr.getNode(0);
    try std.testing.expectEqualStrings("key1", n1.getKey());
    try std.testing.expectEqualStrings("val1", n1.getData());
    
    // Search "key1"
    const res1 = ptr.search("key1");
    try std.testing.expect(res1.match);
    try std.testing.expectEqual(@as(u16, 0), res1.index);
    
    // Search "key2" (should be index 1)
    const res2 = ptr.search("key2");
    try std.testing.expect(!res2.match);
    try std.testing.expectEqual(@as(u16, 1), res2.index);
    
    // Insert "key2" -> "val2" at index 1
    _ = ptr.putNode(1, "key2", "val2", 0);
    
    // Verify order
    try std.testing.expectEqual(@as(u16, 2), ptr.getNumEntries());
    const n2 = ptr.getNode(1);
    try std.testing.expectEqualStrings("key2", n2.getKey());
    
    // Insert "key0" -> "val0" at index 0 (should shift others)
    _ = ptr.putNode(0, "key0", "val0", 0);
    
    // Verify order: key0, key1, key2
    try std.testing.expectEqual(@as(u16, 3), ptr.getNumEntries());
    try std.testing.expectEqualStrings("key0", ptr.getNode(0).getKey());
    try std.testing.expectEqualStrings("key1", ptr.getNode(1).getKey());
    try std.testing.expectEqualStrings("key2", ptr.getNode(2).getKey());
    
    // Verify search finds shifted items
    const res3 = ptr.search("key2");
    try std.testing.expect(res3.match);
    try std.testing.expectEqual(@as(u16, 2), res3.index);
}
