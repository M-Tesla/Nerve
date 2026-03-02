const std = @import("std");
const env_mod = @import("env.zig");
const txn_mod = @import("txn.zig");
const cursor_mod = @import("cursor.zig");
const types = @import("core/types.zig");
const consts = @import("core/consts.zig");

test "Repro Fixed Split" {
    const path = "repro_fixed_split_test.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    
    var env = try env_mod.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer env.deinit();

    {
        var txn = try txn_mod.Transaction.begin(&env, null, .{ .rdonly = false });
        defer txn.abort();

        // DUPSORT (0x04) | DUPFIXED (0x10)
        txn.meta.trees.main.flags |= 0x04 | 0x10;
        
        var cur = cursor_mod.Cursor.open(&txn, &txn.meta.trees.main);
        
        // Page size 4096. 
        // DupFixed items: 20 bytes page header.
        // Item size: 8 bytes (key "data") + 4 bytes? No, DUPFIXED doesn't store keys.
        // It stores VALUES.
        // Our test uses key="key", value="{i}".
        // If monolith_DUPFIXED, values must be same size.
        // Let's use 8 byte values "val{0:0>5}".
        
        // Items per page approx: (4096 - 20) / 8 = 509 items.
        // Insert 600 items to force split.
        
        var buf: [32]u8 = undefined;
        var i: u32 = 0;
        while (i < 600) : (i += 1) {
            const val = try std.fmt.bufPrint(&buf, "val{d:0>5}", .{i});
            // Key is constant for duplicates
            try cur.put("multivalue_key", val, 0);
        }
        
        try txn.commit();
        std.debug.print("Commit successful. Inserted 600 items.\n", .{});
    }
    
    // PRINT THE SIZES FROM THE MAP!
    {
        var read_txn = try @import("txn.zig").Transaction.begin(&env, null, .{ .rdonly = true });
        var temp_cur = cursor_mod.Cursor.open(&read_txn, &read_txn.meta.trees.main);
        var tval: []const u8 = undefined;
        if (try temp_cur.get("multivalue_key", &tval)) {
             const sub_root_pgno = std.mem.readInt(u32, temp_cur.stack[0].node.getData()[0..4], .little);
             const branch = try read_txn.getPage(sub_root_pgno);
             std.debug.print("DEBUG-RO: SubRoot={d}, flags={x}, entries={d}\n", .{sub_root_pgno, branch.flags, branch.getNumEntries()});
             
             if (branch.getNumEntries() == 2) {
                 const indices = @as([*]const u16, @ptrCast(@alignCast(@as([*]const u8, @ptrCast(branch)) + 20)));
                 const offL = indices[0];
                 const offR = indices[1];
                 std.debug.print("DEBUG-RO: Offsets: L={d}, R={d}\n", .{offL, offR});
             }
        }
        
        // Dump root 8193
        var sub_tree = std.mem.zeroInit(types.Tree, .{});
        // The main node points to sub_root. We can get it directly!
        var temp_cur2 = cursor_mod.Cursor.open(&read_txn, &read_txn.meta.trees.main);
        var tval2: []const u8 = undefined;
        if (try temp_cur2.get("multivalue_key", &tval2)) {
            var d = temp_cur2.depth;
            var sub_root: u32 = 0;
            while (d > 0) : (d -= 1) {
                const entry = &temp_cur2.stack[d - 1];
                if ((entry.page.flags & @import("page/page.zig").P_LEAF2) == 0) {
                    if ((entry.node.flags & @import("page/page.zig").Node.F_DUPDATA) != 0) {
                        sub_root = std.mem.readInt(u32, entry.node.getData()[0..4], .little);
                        break;
                    }
                }
            }
            sub_tree.root = sub_root;
            sub_tree.flags = 0x10;
            var subt_cur = cursor_mod.Cursor.open(&read_txn, &sub_tree);
            std.debug.print("\n=== SUBTREE DUMP ===\n", .{});
            subt_cur.dump();
            std.debug.print("====================\n\n", .{});
        }
        read_txn.abort();
    }
    
    // 2. Verify all items present
    {
        var txn = try txn_mod.Transaction.begin(&env, null, .{ .rdonly = true });
        defer txn.abort();

        var cur = cursor_mod.Cursor.open(&txn, &txn.meta.trees.main);
        
        cur.dump();
        
        var i: u32 = 0;
        // Position at first duplicate
        var val: []const u8 = undefined;
        const found = try cur.get("multivalue_key", &val);
        if (!found) {
             std.debug.print("TEST: 'multivalue_key' lost! cursor depth={d}\n", .{cur.depth});
             @panic("Key not found!");
        }
        
        // Iterate duplicates
        // get returns the FIRST duplicate.
        // Verify it matches val00000
        // Wait, DUPFIXED are sorted. "val00000" < "val00001".
        
        // Loop 600 times calling nextDup? 
        // Or just next()?
        // next() moves to next key/value pair. For dups, it moves to next dup.
        
        while (i < 600) : (i += 1) {
            var buf: [32]u8 = undefined;
            const expected = try std.fmt.bufPrint(&buf, "val{d:0>5}", .{i});
            
            if (!std.mem.eql(u8, val, expected)) {
                std.debug.print("Mismatch at index {d}: Expected '{s}', Got '{s}'\n", .{i, expected, val});
                @panic("Data Mismatch");
            }
            
            // Move to next
            if (i < 599) {
                // We are already at current (from previous loop or init).
                // Wait, logic:
                // 1. get("key", &val) -> gets first. (i=0)
                // 2. loop check logic.
                // 3. next().
                
                // If i < 599, try next.
                const has_next = try cur.next();
                if (!has_next) {
                     std.debug.print("\n[TEST-LOOP] i={d}: cur.next() returned FALSE! Cursor depth={d}. cur.stack[0].index={d}\n", .{i, cur.depth, cur.stack[0].index});
                     if (cur.depth > 1) {
                         std.debug.print("Stack[1].index={d}, leaf entries={d}\n", .{cur.stack[1].index, cur.stack[1].page.getNumEntries()});
                     }
                     std.debug.print("Premature end of data at index {d}\n", .{i});
                     @panic("Missing Data");
                }
                const kv = try cur.current();
                val = kv.value; // Update val
            }
        }
        
        std.debug.print("Verification successful. All 600 items found.\n", .{});
    }
}
