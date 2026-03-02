//! Zig wrapper for MDBX_env.
//! An Environment represents an open .monolith file.
//! Each service opens its own file — not shared.

const std = @import("std");
const c = @import("c.zig").mdbx;
const types = @import("types.zig");

pub const Environment = struct {
    ptr: *c.MDBX_env,

    /// Opens (or creates) a .monolith file.
    ///
    /// Parameters:
    ///   path      — file path (e.g. "/data/dict.monolith")
    ///   flags     — EnvFlags (nosubdir=true by default)
    ///   max_dbs   — how many named DBIs the env supports (e.g. 16)
    ///   map_size  — maximum mmap size in bytes (e.g. 1 GiB)
    pub fn open(
        path: [:0]const u8,
        flags: types.EnvFlags,
        max_dbs: u32,
        map_size: usize,
    ) types.Error!Environment {
        var env_ptr: ?*c.MDBX_env = null;

        try types.checkError(c.mdbx_env_create(&env_ptr));
        errdefer _ = c.mdbx_env_close_ex(env_ptr, false);

        // Maximum number of named DBIs
        try types.checkError(c.mdbx_env_set_maxdbs(env_ptr, @intCast(max_dbs)));

        // Geometry: lower=256KiB, upper=map_size, grow_step=4MiB
        // Fixed grow_step avoids frequent remaps as the file grows;
        // high shrink_threshold avoids unnecessary truncations and re-mmaps.
        try types.checkError(c.mdbx_env_set_geometry(
            env_ptr,
            256 * 1024,          // lower — minimum file size
            -1,                  // now  — current size (−1 = do not change)
            @intCast(map_size),  // upper — maximum limit
            4 * 1024 * 1024,     // grow_step — 4 MiB at a time (reduces remaps)
            -1,                  // shrink_threshold (−1 = do not shrink automatically)
            0,                   // pagesize (0 = default = 4096)
        ));

        // Open the file
        const rc = c.mdbx_env_open(env_ptr, path.ptr, flags.toC(), 0o644);
        try types.checkError(rc);

        return .{ .ptr = env_ptr.? };
    }

    /// Closes the environment and releases resources.
    /// After close() the pointer is invalid — do not use anymore.
    pub fn close(self: *Environment) void {
        _ = c.mdbx_env_close_ex(self.ptr, false);
        self.ptr = undefined;
    }

    /// Forces a flush of the page cache to disk.
    /// Should be called periodically when the env uses MDBX_SAFE_NOSYNC.
    /// Errors are ignored (best-effort); mdbx detects and recovers on the next open.
    pub fn sync(self: *Environment) void {
        _ = c.mdbx_env_sync_ex(self.ptr, false, false);
    }

    /// Returns environment statistics (number of readers, etc.)
    pub fn stat(self: *Environment, txn_ptr: ?*c.MDBX_txn) types.Error!c.MDBX_stat {
        var s: c.MDBX_stat = undefined;
        try types.checkError(c.mdbx_env_stat_ex(self.ptr, txn_ptr, &s, @sizeOf(c.MDBX_stat)));
        return s;
    }
};
