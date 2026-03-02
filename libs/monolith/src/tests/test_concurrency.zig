const std = @import("std");
const env = @import("../env.zig");
const txn = @import("../txn.zig");

test "Concurrency Basic" {
    const path = "test_concurrency.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path ++ "-lck") catch {};
    
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    // 1. Start Reader A
    var txn_a = try txn.Transaction.begin(&environment, null, .{ .rdonly = true });
    try std.testing.expect(txn_a.reader_slot != null);
    try std.testing.expect(txn_a.locked_writer == false);
    
    // Check slot in table
    const slot_idx = txn_a.reader_slot.?;
    const table = environment.lock_mgr.table;
    const slot = table.slots[slot_idx];
    const txn_a_id = txn_a.txnid;
    try std.testing.expectEqual(txn_a_id, slot.txnid);
    
    // 2. Start Writer B
    // In our implementation, Writer locks file but doesn't check Reader Table for *starting*.
    // It only checks when Freeing pages (which we haven't implemented usage of properly yet).
    // So Writer B should start fine.
    var txn_b = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
    try std.testing.expect(txn_b.locked_writer == true);
    try std.testing.expect(txn_b.reader_slot == null);
    
    // 3. Commit B
    try txn_b.commit();
    try std.testing.expect(txn_b.locked_writer == false);
    
    // 4. Reader A Abort
    txn_a.abort();
    try std.testing.expect(txn_a.reader_slot == null);
    
    // Check slot cleared
    const slot_after = table.slots[slot_idx];
    try std.testing.expectEqual(@as(u64, 0), slot_after.txnid);
}

test "Concurrency Threads" {
    const path = "test_concurrency_threads.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path ++ "-lck") catch {};
    
    var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
    defer environment.deinit();
    
    // Main thread takes Writer Lock
    var txn_main = try txn.Transaction.begin(&environment, null, .{ .rdonly = false });
    
    // Spawn thread that tries to take Writer Lock
    const ThreadContext = struct {
        env: *env.Environment,
        done: bool = false,
    };
    var ctx = ThreadContext{ .env = &environment };
    
    const thread_fn = struct {
        fn run(c: *ThreadContext) !void {
            var t = try txn.Transaction.begin(c.env, null, .{ .rdonly = false });
            defer t.abort();
            c.done = true;
        }
    }.run;
    
    var thread = try std.Thread.spawn(.{}, thread_fn, .{&ctx});
    
    // Sleep a bit. Thread should be blocked in begin()
    std.os.windows.kernel32.Sleep(100);
    try std.testing.expect(ctx.done == false);
    
    // Release Lock
    txn_main.abort();
    
    // Wait for thread
    thread.join();
    try std.testing.expect(ctx.done == true);
}
