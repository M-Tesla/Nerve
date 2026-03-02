//! Cross-platform environment variable utility (Linux + Windows).

const std     = @import("std");
const builtin = @import("builtin");

/// Return the value of environment variable `key`, or null if not set.
/// On Windows, std.posix is unavailable — returns null.
pub fn get(key: [:0]const u8) ?[:0]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    return std.posix.getenv(key);
}
