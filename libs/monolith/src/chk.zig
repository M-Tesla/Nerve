const std = @import("std");
const txn = @import("txn.zig");
const page = @import("page/page.zig");
const types = @import("core/types.zig");

pub const Checker = struct {
    txn: *txn.Transaction,
    allocator: std.mem.Allocator,
    visited: std.AutoHashMap(types.pgno_t, void),
    
    pub fn init(allocator: std.mem.Allocator, transaction: *txn.Transaction) Checker {
        return .{
            .txn = transaction,
            .allocator = allocator,
            .visited = std.AutoHashMap(types.pgno_t, void).init(allocator),
        };
    }

    pub fn deinit(self: *Checker) void {
        self.visited.deinit();
    }

    pub fn check(self: *Checker) !void {
        // 1. Check Main Tree
        try self.checkTree(&self.txn.meta.trees.main);
        
        // 2. Check GC Tree
        try self.checkTree(&self.txn.meta.trees.gc);
        
        // 3. Verify Reachability (Optional: Check free list + visited == total pages?)
        // For now, simpler check: Visited should not exceed file size.
    }

    fn checkTree(self: *Checker, tree: *align(4) types.Tree) !void {
        if (tree.root == 0) return;
        try self.checkPage(tree.root);
    }

    fn checkPage(self: *Checker, pgno: types.pgno_t) !void {
        // Cycle Detection
        if (self.visited.contains(pgno)) {
             std.debug.print("Checker: Cycle Detected at Pgno {d}!\n", .{pgno});
             return error.CycleDetected;
        }
        try self.visited.put(pgno, {});

        // Fetch Page
        const p = try self.txn.getPage(pgno);
        
        // 1. Basic Integrity
        if (p.pgno != pgno) return error.PageWrongPgno;

        const num = p.getNumEntries();
        const flags = p.getFlags();
        
        // 2. Validate Flags
        if ((flags & page.P_BRANCH) == 0 and (flags & page.P_LEAF) == 0 and (flags & page.P_META) == 0 and (flags & page.P_OVERFLOW) == 0) {
             return error.InvalidPageFlags;
        }

        // 3. Structure Validation
        if ((flags & page.P_BRANCH) != 0) {
            // Branch Page: Validate children pointers
            // Branch nodes: [Key | Pgno]
            // We should ideally check that keys are sorted.
            
            for (0..num) |i| {
                const node = p.getNode(@intCast(i));
                const child_pgno = node.getChildPgno();
                
                std.debug.print("Checker: Branch Pgno {d}, Node {d}, Child {d}\n", .{pgno, i, child_pgno});
                
                // Recursively check children
                try self.checkPage(child_pgno);
            }
        } else if ((p.flags & page.P_LEAF2) != 0) {
             // P_DUPFIXED Leaf
             // Validate items? Arrays.
             // Ensure count matches size?
             // Simply check items are within page bounds?
             const ksize = p.dupfix_ksize;
             if (ksize == 0) return error.CorruptedDB;
             const used_space = @as(u32, num) * ksize + 20;
             if (used_space > 4096) return error.CorruptedDB;
        } else if ((flags & page.P_LEAF) != 0) {
             // Standard Leaf
             // Validate nodes: [Key | Data]
             for (0..num) |i| {
                 const node = p.getNode(@intCast(i));
                 
                 // Check if it's a Sub-Tree (DUPSORT)
                 if ((node.flags & page.Node.F_DUPDATA) != 0) {
                     const data = node.getData();
                     if (data.len != 4) return error.CorruptedDB; // Sub-tree root pgno is u32
                     
                     const sub_root = std.mem.readInt(u32, data[0..4], .little);
                     try self.checkPage(sub_root);
                 }
             }
        }
    }
};
