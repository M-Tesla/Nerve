const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");
const cursor = @import("../cursor.zig");

test "Nested Transaction - Commit Path" {
    const path = "test_nested_commit.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    var parent = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
    defer parent.abort();
    
    var cur = cursor.Cursor.open(&parent, &parent.meta.trees.main);
    try cur.put("key_A", "val_A", 0);
    
    // Child Txn
    {
        var child = try txn.Transaction.begin(&environment, &parent, .{ .rdonly = false });
        // Child shares lock/txnid
        try std.testing.expectEqual(child.txnid, parent.txnid);
        
        var child_cur = cursor.Cursor.open(&child, &child.meta.trees.main);
        
        // Read parent data
        var val: []const u8 = undefined;
        try std.testing.expect(try child_cur.get("key_A", &val));
        try std.testing.expectEqualStrings("val_A", val);
        
        // Write child data
        try child_cur.put("key_B", "val_B", 0);
        
        // Commit Child -> Merge to Parent
        try child.commit();
    }
    
    // Back in Parent
    // Verify "key_B" is visible
    {
        var val: []const u8 = undefined;
        try std.testing.expect(try cur.get("key_B", &val));
        try std.testing.expectEqualStrings("val_B", val);
    }
    
    // Commit Parent
    try parent.commit();
    
    // Check Persisted
    var rxn = try txn.Transaction.begin(&environment, null, .{ .rdonly = true });
    defer rxn.abort();
    var rcur = cursor.Cursor.open(&rxn, &rxn.meta.trees.main);
    
    var val: []const u8 = undefined;
    try std.testing.expect(try rcur.get("key_A", &val));
    try std.testing.expect(try rcur.get("key_B", &val));
}

test "Nested Transaction - Abort Path" {
    const path = "test_nested_abort.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    var parent = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
    defer parent.abort();
    
    var cur = cursor.Cursor.open(&parent, &parent.meta.trees.main);
    try cur.put("key_A", "val_A", 0);
    
    // Child Txn
    {
        var child = try txn.Transaction.begin(&environment, &parent, .{ .rdonly = false });
        var child_cur = cursor.Cursor.open(&child, &child.meta.trees.main);
        
        // Write child data
        try child_cur.put("key_B", "val_B_child", 0);
        
        // Overwrite parent data (Shadowing)
        try child_cur.put("key_A", "val_A_child", 0);
        
        // Verify in Child
        var val: []const u8 = undefined;
        try std.testing.expect(try child_cur.get("key_A", &val));
        try std.testing.expectEqualStrings("val_A_child", val);
        
        // Verify Parent NOT changed yet (Shadowing)
        // Note: Parent Cursor might point to old page, but if lookups happen, logic should be robust.
        // Actually, Parent Cursor is technically separate, but "parent" transaction object?
        // Parent transaction object is NOT modified by child yet.
        // But parent.getPage(pgno) might return what? 
        // Parent.getPage only checks parent.dirty_list.
        // Child put updates child.dirty_list.
        // So Parent.getPage does NOT see child changes.
        
        // Abort Child
        child.abort();
    }
    
    // Back in Parent
    // Verify "key_B" is NOT visible
    {
        var val: []const u8 = undefined;
        try std.testing.expect(! (try cur.get("key_B", &val)));
        
        // Verify "key_A" is still "val_A"
        try std.testing.expect(try cur.get("key_A", &val));
        try std.testing.expectEqualStrings("val_A", val);
    }
    
    try parent.commit();
}
