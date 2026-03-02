const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");
const cursor = @import("../cursor.zig");

test "Fixed Size Dups (monolith_DUPFIXED)" {
    const path = "test_dup_fixed.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    // 1. Setup DB with DUPFIXED
    {
        var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
        defer tx.abort();
        
        // DUPSORT (0x04) | DUPFIXED (0x10)
        tx.meta.trees.main.flags |= 0x04 | 0x10;
        
        var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
        
        // Insert first item (Reference Size: 4)
        try cur.put("keyA", "val1", 0);
        
        // Insert second item (Size: 4) - Should succeed
        try cur.put("keyA", "val2", 0);
        
        // Insert third item (Size: 5) - Should fail
        const err = cur.put("keyA", "val33", 0);
        try std.testing.expectEqual(error.BadValueSize, err);
        
        // Insert new key (Size: 6)
        // monolith documentation says DUPFIXED applies per database, so all dups in the DB must be same size?
        // OR is it per-key?
        // "monolith_DUPFIXED: ... data items for all keys in this database must be the same size."
        // So if I insert "keyB" -> "val444", it should check against global dupfix_size.
        
        const err2 = cur.put("keyB", "val444", 0); // "val444" is 6 bytes. dupfix_size is 4.
        try std.testing.expectEqual(error.BadValueSize, err2);
        
        // Insert matching size for different key
        try cur.put("keyC", "valX", 0); // 4 bytes. OK.
        
        try tx.commit();
    }
}
