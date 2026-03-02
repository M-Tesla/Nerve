const std = @import("std");
const lock = @import("../lock.zig");
const os = @import("../os/os.zig");

test "Lock Recovery (Dead Process Cleanup)" {
    const path = "test_lock_recovery";
    defer std.fs.cwd().deleteFile("test_lock_recovery-lck") catch {};
    
    var lock_mgr = try lock.LockManager.init(path, std.testing.allocator);
    defer lock_mgr.deinit();
    
    // 1. Register current process (Alive) at 200
    const slot_idx = try lock_mgr.registerReader(200);
    try std.testing.expect(slot_idx < 126);
    
    // Verify PID is set
    const slot = &lock_mgr.table.slots[slot_idx];
    try std.testing.expectEqual(os.GetCurrentProcessId(), slot.pid);
    try std.testing.expectEqual(@as(u64, 200), slot.txnid);
    
    // 2. Inject "Dead" Process manually at 100
    // Find free slot
    var dead_slot_idx: usize = 0;
    while (dead_slot_idx < 126) : (dead_slot_idx += 1) {
        if (lock_mgr.table.slots[dead_slot_idx].txnid == 0) break;
    }
    
    const dead_slot = &lock_mgr.table.slots[dead_slot_idx];
    dead_slot.pid = 0xfffffffc; // Likely invalid PID (-4)
    dead_slot.tid = 0;
    @atomicStore(u64, &dead_slot.txnid, 100, .release);
    
    // Verify it's there (Oldest blocking reader depends on dead process)
    try std.testing.expectEqual(@as(u64, 100), lock_mgr.getOldestReader(300));
    
    // 3. Trigger Recovery
    lock_mgr.recoverDeadSlots();
    
    // 4. Verify Dead Slot is gone
    const dead_txnid = @atomicLoad(u64, &dead_slot.txnid, .acquire);
    try std.testing.expectEqual(@as(u64, 0), dead_txnid);
    
    // 5. Verify Alive Slot is still there, and Oldest is now 200
    const alive_txnid = @atomicLoad(u64, &slot.txnid, .acquire);
    try std.testing.expectEqual(@as(u64, 200), alive_txnid);
    try std.testing.expectEqual(@as(u64, 200), lock_mgr.getOldestReader(300));
}
