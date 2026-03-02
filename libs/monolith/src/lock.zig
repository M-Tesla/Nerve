const std = @import("std");
const os = @import("os/os.zig");
const types = @import("core/types.zig");

pub const ReaderSlot = extern struct {
    txnid: u64 align(8),
    pid: u32,
    tid: u32,
};

pub const ReaderTable = extern struct {
    magic: u64,
    num_slots: u32,
    padding: u32,
    slots: [126]ReaderSlot, // Fit in 4KB roughly? 126 * 16 = 2016. Plenty of space.
};

pub const LockManager = struct {
    file: std.fs.File,
    map: os.MmapRegion,
    table: *ReaderTable,
    allocator: std.mem.Allocator,

    pub fn init(path: []const u8, allocator: std.mem.Allocator) !LockManager {
        // Create/Open .lck file
        // Append .lck to path? User passes full db path?
        // Let's assume user passes "db.monolith", we make "db.monolith.lck"?
        // Or user passes the lock path directly.
        // Let's assume strict naming convention for now: path + "-lck"
        
        const key_path = try std.fmt.allocPrint(allocator, "{s}-lck", .{path});
        defer allocator.free(key_path);
        
        var file = try std.fs.cwd().createFile(key_path, .{
            .read = true,
            .truncate = false,
            .exclusive = false, // Open if exists
        });
        errdefer file.close();
        
        const size = try file.getEndPos();
        const min_size = 4096;
        
        if (size < min_size) {
            try file.setEndPos(min_size);
            // If new, init header?
            // Need to map first to write header in memory? or write to file?
            // Map is easier.
        }
        
        // Map as Read-Write
        var region = try os.MmapRegion.init(file, min_size, false);
        errdefer region.deinit();
        
        const table = @as(*ReaderTable, @ptrCast(@alignCast(region.ptr)));
        
        // Ensure magic (if new file, magic is 0)
        // Simple init if magic == 0
        if (table.magic == 0) {
            table.magic = 0xBEEFDEAD;
            table.num_slots = 126;
            // Clear slots
            @memset(@as([*]u8, @ptrCast(&table.slots[0]))[0..@sizeOf(@TypeOf(table.slots))], 0);
        }
        
        return LockManager{
            .file = file,
            .map = region,
            .table = table,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LockManager) void {
        self.map.deinit();
        self.file.close();
    }

    pub fn lockWriter(self: *LockManager) !void {
        // Lock byte 0..1 exclusively, Wait=true
        try os.lockFile(self.file, true, true);
    }
    
    pub fn unlockWriter(self: *LockManager) !void {
        try os.unlockFile(self.file);
    }
    
    // Returns slot index
    pub fn registerReader(self: *LockManager, txnid: u64) !usize {
        // Attempt 1: Fast path
        if (try self.tryClaimSlot(txnid)) |idx| return idx;
        
        // Slots Full? Try to recover dead slots
        self.recoverDeadSlots();
        
        // Attempt 2: Retry after recovery
        if (try self.tryClaimSlot(txnid)) |idx| return idx;

        return error.ReaderSlotsFull;
    }
    
    fn tryClaimSlot(self: *LockManager, txnid: u64) !?usize {
        var i: usize = 0;
        while (i < self.table.num_slots) : (i += 1) {
             const slot = &self.table.slots[i];
             const current_txnid = @atomicLoad(u64, &slot.txnid, .acquire);
             if (current_txnid == 0) {
                 const res = @atomicRmw(u64, &slot.txnid, .Xchg, txnid, .acq_rel);
                 if (res == 0) {
                     slot.pid = os.GetCurrentProcessId();
                     slot.tid = os.GetCurrentThreadId();
                     return i;
                 }
             }
        }
        return null;
    }
    
    pub fn recoverDeadSlots(self: *LockManager) void {
        var i: usize = 0;
        while (i < self.table.num_slots) : (i += 1) {
            const slot = &self.table.slots[i];
            const txnid = @atomicLoad(u64, &slot.txnid, .acquire);
            const pid = slot.pid;
            
            if (txnid != 0 and pid != 0) {
                if (!os.isProcessAlive(pid)) {
                    // Process is dead. Clear slot.
                    // Release lock.
                    slot.pid = 0;
                    slot.tid = 0;
                    @atomicStore(u64, &slot.txnid, 0, .release);
                }
            }
        }
    }

    pub fn unregisterReader(self: *LockManager, slot_idx: usize) void {
        if (slot_idx >= self.table.num_slots) return;
        const slot = &self.table.slots[slot_idx];
        @atomicStore(u64, &slot.txnid, 0, .release);
    }
    
    pub fn getOldestReader(self: *LockManager, limit_txnid: u64) u64 {
        var min_txnid = limit_txnid;
        var i: usize = 0;
        
        while (i < self.table.num_slots) : (i += 1) {
             const slot = &self.table.slots[i];
             const txnid = @atomicLoad(u64, &slot.txnid, .acquire);
             
             if (txnid != 0 and txnid < min_txnid) {
                 min_txnid = txnid;
             }
        }
        return min_txnid;
    }
};
