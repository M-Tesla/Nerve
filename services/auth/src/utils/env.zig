//! Cross-platform environment variable reader (Linux + Windows).
//! On Linux/POSIX uses std.posix.getenv (zero-allocation).
//! On Windows returns null (WTF-16 env vars not supported in dev).

const builtin = @import("builtin");
const std = @import("std");

/// Read an environment variable.
/// Returns null if not set or if the OS is Windows.
pub fn get(key: [:0]const u8) ?[:0]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    return std.posix.getenv(key);
}
