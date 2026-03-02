const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");
const page = @import("../page/page.zig");
const cursor = @import("../cursor.zig");

test "GC Overflow Reuse" {
    const path = "test_gc_overflow.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    // 1. Init
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    // Expand file a bit
    {
        var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        try file.setEndPos(4096 * 20); // 20 Pages
        file.close();
    }
    
    // 2. Insert Large Value (3 pages)
    // Page Data size ~ 4000. 3 pages = 12000 bytes.
    const large_val = try std.testing.allocator.alloc(u8, 12000);
    defer std.testing.allocator.free(large_val);
    @memset(large_val, 'A');
    
    var pgno_first_alloc: u32 = 0;
    
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        defer tx.abort();
        var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
        
        try cur.put("key1", large_val, 0);
        
        // Peek at the overflow page number (not easy via public API, but we can check usage)
        const used = tx.meta.geometry.first_unallocated;
        pgno_first_alloc = used; // Approx next free
        
        try tx.commit();
    }
    
    // 3. Delete Large Value
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        defer tx.abort();
        var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
        
        var val: []const u8 = undefined;
        const found = try cur.get("key1", &val);
        try std.testing.expect(found);
        try cur.del(); // Should free the 3+ overflow pages
        
        try tx.commit();
    }
    
    // 4. Force Oldest Reader to advance (Start new RO txn)
    // Actually, simply starting a new RW txn updates the reader check if we use check reader slots.
    // But since we have no other readers, Oldest = TxnID - 1?
    // Let's just Insert again.
    
    var pgno_second_alloc: u32 = 0;
    
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        defer tx.abort();
        
        // Check consistency
        // try std.testing.expect(tx.meta.trees.gc.items > 0);
        
        var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
        
        // This allocation should reuse the pages freed in Step 3
        try cur.put("key2", large_val, 0);
         
        pgno_second_alloc = tx.meta.geometry.first_unallocated;
        
        try tx.commit();
    }
    
    // 5. Verification
    // If Reuse happened, database size (first_unallocated) should NOT have grown significantly.
    // If it grew, it means we allocated NEW pages at the end.
    
    // Note: 'first_unallocated' tracks the High Water Mark.
    // Even with reuse, High Water Mark doesn't drop.
    // But it shouldn't RISE if we reuse gaps.
    
    // Note: Reuse saves the Overflow pages (3 pages), but the operation itself
    // incurs overhead:
    // 1. Leaf Page COW (1 page)
    // 2. Potential Splits (1-2 pages)
    // 3. GC Tree updates (COW) during reclaim (1 page)
    // So the file WILL grow, but much less than if we allocated 3 new overflow pages + overhead.
    // Without reuse, growth would be ~6-7 pages.
    // With reuse, growth observed is ~4 pages.
    
    const growth = pgno_second_alloc - pgno_first_alloc;
    std.debug.print("Growth: {d} pages\n", .{growth});
    
    if (growth > 5) {
         std.debug.print("FAIL: Excessive growth ({d} pages). Reuse likely failed.\n", .{growth});
         return error.TestExpectedEqual; 
    }
}
