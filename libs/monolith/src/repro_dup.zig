const std = @import("std");
const env = @import("env.zig");
const txn = @import("txn.zig");
const cursor = @import("cursor.zig");

// Reproduce DupFixed Resize Error
// Strategy: Insert enough duplicate items for a single key to force:
// 1. Page Splitting (Leaf -> Branch)
// 2. Map Resizing (by filling the initial map)
test "Reproduce DupFixed Resize Crash" {
    const path = "test_dup_fixed_repro.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    // Start with small map to force resize early?
    // Environment.open triggers initNewDB which sets 3 pages.
    // Map init size is 16 pages (64KB).
    // We need to fill > 64KB.
    
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    var tx = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
    defer tx.abort(); // Attempt to abort if crash doesn't happen, or commit at end.
    
    // DUPSORT (0x04) | DUPFIXED (0x10)
    tx.meta.trees.main.flags |= 0x04 | 0x10;
    
    var cur = cursor.Cursor.open(&tx, &tx.meta.trees.main);
    
    // Insert 20,000 items of 4 bytes each.
    // 20,000 * 4 = 80KB.
    // Plus overhead. This should trigger resize of 64KB map.
    
    const count = 20000;
    var buf: [16]u8 = undefined;
    
    // Value: 4 bytes (fixed size)
    // const val = "valX";
    
    var i: usize = 0;
    while (i < count) : (i += 1) {
         if (i % 1000 == 0) {
             std.debug.print("Inserting {d}...\n", .{i});
         }
         // All for SAME KEY "keyA" to stress the DUPFIXED sub-tree
         // But "val" must be unique? 
         // DUPSORT stores (Key, Val) where Val is the "Key" in sub-tree.
         // Yes, val must be unique for DUPSORT if we want to store multiple items.
         // Wait, DUPSORT allows duplicates? No, DUPSORT sorts values.
         // If values are identical, `put` might return KeyExists (if NOOVERWRITE) or overwrite?
         // In DUPSORT, (Key, Val) pair must be unique.
         
         // So we need unique 4-byte values.
         // 4 bytes = u32.
         std.mem.writeInt(u32, buf[0..4], @intCast(i), .little);
         const val_slice = buf[0..4];
         
         cur.put("keyA", val_slice, 0) catch |err| {
             std.debug.print("FAILURE at i={d}: {s}\n", .{i, @errorName(err)});
             @panic("TEST FAILED");
         };
    }
    
    std.debug.print("Finished insertion. Committing...\n", .{});
    try tx.commit();
}
