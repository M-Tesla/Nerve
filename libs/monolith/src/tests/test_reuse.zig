const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");
const types = @import("../core/types.zig");

test "Page Reuse" {
    const path = "test_reuse.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path ++ "-lck") catch {};
    
    // 1. Setup DB
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    // 2. Alloc and Free a Page (Txn 1)
    {
        var t1 = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        const p = try t1.allocPage(1);
        const pgno = p.pgno;
        try t1.freePage(pgno);
        try t1.commit();
        // Txn 1 committed. Freed page is timestamped with TxnID 1.
    }
    
    // 3. Block Reuse with Reader (Txn 2)
    // Reader starts. It sees TxnID 1 as latest committed. 
    // Wait, if Reader starts, it registers.
    // If Reader registers, getOldestReader will return Reader's ID.
    // If Reader sees TxnID 1, its ID is 1 (or 0?).
    // In our logic: rdonly txn takes expected txnid.
    // So if T1 committed ID 1.
    // Reader T2 will see 1.
    // getOldestReader will return 1.
    // Page freed in T1 has key [1, pgno].
    // reclaimPage logic: if freed_txnid < oldest.
    // 1 < 1 is FALSE.
    // So Page 1 CANNOT be reclaimed while Reader T2 is active (reading snapshot 1).
    // Correct.
    
    var t2 = try txn.Transaction.begin(&environment, null, .{ .rdonly = true });
    
    // 4. Try Alloc (Txn 3)
    {
        var t3 = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        defer t3.abort();
        
        // Should NOT reuse
        // We can check first_unallocated to see if it grows.
        const first_unalloc_before = t3.meta.geometry.first_unallocated;
        _ = try t3.allocPage(1);
        const first_unalloc_after = t3.meta.geometry.first_unallocated;
        
        try std.testing.expect(first_unalloc_after > first_unalloc_before);
    }
    
    // 5. Finish Reader
    t2.abort();
    
    // 6. Try Alloc Again (Txn 4)
    // No readers. OldestReader returns current_txnid (which will be > 1).
    // Say Txn 4 has ID 2.
    // 1 < 2 is TRUE.
    // Should reuse.
    {
        var t4 = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        defer t4.commit() catch {};
        
        const p = try t4.allocPage(1);

        
        // If reused, verify we got Page 3 back (reclaimed)
        try std.testing.expectEqual(@as(types.pgno_t, 3), p.pgno);
        
        // Note: first_unallocated MAY grow if COW was needed for the GC tree modification.
        // So we don't strictly assert unallocated == before.
        // try std.testing.expectEqual(first_unalloc_before, first_unalloc_after);
     }
}
