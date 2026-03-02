const std = @import("std");
const env = @import("../env.zig");
const page = @import("../page/page.zig");
const txn = @import("../txn.zig");

test "Env Resize Persistence" {
    const path = "test_resize_p.monolith";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    // 1. Create Env
    {
        var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
        // Write pattern to Page 2 (Main Root)
        // Access via map directly to simulate "dirty" write in memory
        const ptr = environment.map.ptr + 4096 * 2;
        const slice = ptr[0..4096];
        @memset(slice, 0xAA); // Fill with AA
        
        // Sync explicitly once
        environment.map.sync();
        
        environment.deinit();
    }
    
    // 2. Reopen and Resize
    {
        var environment = try env.Environment.open(path, .{}, .{}, std.testing.allocator);
        defer environment.deinit();
        
        const ptr = environment.map.ptr + 4096 * 2;
        try std.testing.expectEqual(@as(u8, 0xAA), ptr[0]);
        
        // Resize DOUBLE
        // Current size: 16 * 4096 (default init) = 65536
        const new_size = 65536 * 2;
        try environment.resize(new_size);
        
        // Check if data persisted
        const new_ptr = environment.map.ptr + 4096 * 2;
        std.debug.print("Checking byte at 0: {x}\n", .{new_ptr[0]});
        try std.testing.expectEqual(@as(u8, 0xAA), new_ptr[0]);
        try std.testing.expectEqual(@as(u8, 0xAA), new_ptr[4095]);
    }
}
