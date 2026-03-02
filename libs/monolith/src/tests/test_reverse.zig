const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");
const cursor = @import("../cursor.zig");
const types = @import("../core/types.zig");

test "Reverse Keys (monolith_REVERSEKEY)" {
    const path = "test_reverse_keys.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    // Create DB with REVERSEKEY (0x02)
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        defer tx.abort();
        
        // Create table with flag
        // We simulate this by modifying the flags of the main tree directly for this test,
        // as we don't have a full DBI open/create API yet that takes flags.
        // We use the root tree which we can modify in the meta.
        tx.meta.trees.main.flags |= 0x02; // monolith_REVERSEKEY
        
        var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
        
        try cur.put("A", "valA", 0);
        try cur.put("B", "valB", 0);
        try cur.put("C", "valC", 0);
        
        try tx.commit();
    }
    
    // Verify Order
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = true });
        defer tx.abort();
        var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
        
        // First should be C
        try cur.bind();
        var v: []const u8 = undefined;
        
        // Current implementation of 'bind' goes to index 0.
        // For standard B-Tree, index 0 is smallest key.
        // But 'cmp' verifies order.
        // The tree construction (put) should have placed them in reverse order?
        // Wait, monolith_REVERSEKEY affects comparison.
        // If "A" CMP "B" -> .gt (because .lt inverted).
        // So "A" > "B".
        // So "C" should be "smallest" (if C < B < A).
        // "C" CMP "B" -> "C" > "B"? No. "C" vs "B" -> .gt normally. Inverted -> .lt.
        // So C < B < A.
        // So C is smallest.
        
        // Let's verify what `cur.current()` returns at index 0.
        _ = try cur.get("C", &v); // Should find C
        
        // Iteration from start (Index 0 to N)
        // Should yield C, B, A
        
        // Reset to first
        // As we don't have 'first', we just bind() which goes to index 0 of first leaf.
        try cur.bind();
        
        // Item 1: C
        var kv = try cur.current();
        try std.testing.expectEqualStrings("C", kv.key);
        
        // Item 2: B
        var has_next = try cur.next();
        try std.testing.expect(has_next);
        kv = try cur.current();
        try std.testing.expectEqualStrings("B", kv.key);
        
        // Item 3: A
        has_next = try cur.next();
        try std.testing.expect(has_next);
        kv = try cur.current();
        try std.testing.expectEqualStrings("A", kv.key);
    }
}

test "Reverse Dups (monolith_REVERSEDUP)" {
    const path = "test_reverse_dups.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        defer tx.abort();
        
        // DUPSORT (0x04) | REVERSEDUP (0x40)
        tx.meta.trees.main.flags |= 0x04 | 0x40;
        
        var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
        
        // Insert: 1, 2, 3
        try cur.put("key", "1", 0);
        try cur.put("key", "2", 0);
        try cur.put("key", "3", 0); 
        
        // "3" CMP "2" -> .gt -> Inverted .lt -> "3" < "2" < "1".
        // So order should be 3, 2, 1.
        
        try tx.commit();
    }
    
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = true });
        defer tx.abort();
        var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
        
        var v: []const u8 = undefined;
        _ = try cur.get("key", &v); // Finds key, positions at first dup?
        
        // get matches the first item (smallest).
        // Since 3 < 2 < 1, "3" is smallest.
        
        var kv = try cur.current();
        try std.testing.expectEqualStrings("3", kv.value);
        
        var has_next = try cur.nextDup();
        try std.testing.expect(has_next);
        kv = try cur.current();
        try std.testing.expectEqualStrings("2", kv.value);
        
        has_next = try cur.nextDup();
        try std.testing.expect(has_next);
        kv = try cur.current();
        try std.testing.expectEqualStrings("1", kv.value);
        
        // Verify getBoth
        const found = try cur.getBoth("key", "2");
        try std.testing.expect(found);
        kv = try cur.current();
        try std.testing.expectEqualStrings("2", kv.value);
    }
}
