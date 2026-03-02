const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");
const cursor = @import("../cursor.zig");

test "Map Resizing" {
    const path = "test_resize.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    // 1. Init Small Environment (Let Open handle it)
    // Just ensure file doesn't exist or is empty
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    file.close();
    
    // Open with small map (just enough for init)
    // Environment.open calculates map size based on file size.
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    // 2. Fill it up
    var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
    
    var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
    
    // Insert typical items until full
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key_{d}", .{i}) catch unreachable;
        
        // Use allocPages indirectly via put (splitPage -> allocPage)
        // One page can hold approx 4096 / (node_overhead + key + val) items.
        // Say 20 bytes/item -> 200 items. 
        // But we start with 3 pages. Page 0,1 Meta. Page 2 Root.
        // Root is Leaf.
        // Inserting few items fits.
        // Splitting needs new page.
        // Next pgno is 4.
        // File size is 12KB (3 pages). 0, 1, 2.
        // Next alloc is Page 3.
        // Wait, initNewDB sets first_unallocated = 4. (Pages 0,1,2,3 used??)
        // initNewDB uses Page 0 (Meta0), 1 (Meta1), 2 (Main), 3 (GC).
        // Total 4 pages. 
        // So file must be 16KB initially.
        // Env.open says "current_size = 4096 * 3" if new?
        // Let's check env.zig initNewDB.
        
        // env.zig:94: try file.setEndPos(4096 * 3); 
        // env.zig:127: meta_ptr.geometry.first_unallocated = 4;
        // env.zig:175: try file.seekTo(4096 * 3); writeAll.
        // Writes Page 3 at offset 12288 (4096*3). 
        // So file size becomes 4096*4 = 16384.
        
        // So if we open existing, size is 16384.
        // first_unallocated = 4.
        // Next alloc needs Page 4 (offset 16384).
        // Map len is 16384. 
        // 4 * 4096 = 16384. Accessing index 16384 is Out of Bounds.
        // So FIRST allocation should fail if we don't resize?
        // Yes.
        
        // map resizing should happen automatically now.
        try cur.put(key, "val", 0);
    }
    
    // Verify success
    try tx.commit();
    
    // Check size increased
    try std.testing.expect(environment.map.len > 4096 * 4);
    
    // Verify data
    var rx = try txn.Transaction.begin(&environment, null, .{ .rdonly = true });
    defer rx.abort();
    var rcur = cursor.Cursor.open(&rx, &rx.meta.trees.main);
    
    var val: []const u8 = undefined;
    try std.testing.expect(try rcur.get("key_50", &val));
    try std.testing.expectEqualStrings("val", val);
}

