const std = @import("std");
const env_mod = @import("../env.zig");
const txn_mod = @import("../txn.zig");
const cursor_mod = @import("../cursor.zig");

test "Simple Delete Node on P_LEAF" {
    const path = "test_delete_simple.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    
    var env = try env_mod.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer env.deinit();

    // 1. Inserir 5 itens
    {
        var txn = try txn_mod.Transaction.begin(&env, null, .{ .rdonly = false });
        var cur = cursor_mod.Cursor.open(&txn, &txn.meta.trees.main);
        
        var i: u32 = 0;
        var key_buf: [32]u8 = undefined;
        while (i < 3) : (i += 1) {
            const key = try std.fmt.bufPrint(&key_buf, "key_{d:0>4}", .{i});
            try cur.put(key, "data", 0);
        }
        try txn.commit();
    }
    
    // 2. Verificar Inserções e Tamanho da Página e Deleção
    {
        var txn = try txn_mod.Transaction.begin(&env, null, .{ .rdonly = false });
        defer txn.abort(); // Rollback pra não poluir, ou commit the pois

        var cur = cursor_mod.Cursor.open(&txn, &txn.meta.trees.main);
        
        // Pega tamanho antes
        try cur.bind();
        const root_page = cur.stack[0].page;
        const initial_entries = root_page.getNumEntries();
        const initial_free = root_page.getFreeSpace();
        
        try std.testing.expectEqual(@as(u16, 3), initial_entries);
        
        // Cursar e Deletar "key_0001"
        var val: []const u8 = undefined;
        const found = try cur.get("key_0001", &val);
        try std.testing.expect(found);
        
        // Cur is pointing at key_0001. Let's Delete!
        try cur.del();
        
        // Pega tamanho DEPOIS
        const after_entries = cur.stack[0].page.getNumEntries();
        const after_free = cur.stack[0].page.getFreeSpace();
        
        try std.testing.expectEqual(@as(u16, 2), after_entries);
        try std.testing.expect(after_free > initial_free); // Free space must increase! Compaction worked.
        
        // Next key should be 'key_0002' because the items shifted to the left taking the deleted spot
        const next_stat = try cur.current();
        std.debug.print("\n[DEBUG-TEST] Current key after deletion is: {s}\n", .{next_stat.key});
        try std.testing.expectEqualStrings("key_0002", next_stat.key);
        
        try txn.commit();
    }
}
