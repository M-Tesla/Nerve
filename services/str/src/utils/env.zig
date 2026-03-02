//! Environment variable utility — cross-platform (Linux + Windows)

const std     = @import("std");
const builtin = @import("builtin");

/// Returns the value of environment variable `key`, or null if not defined.
/// On Windows, std.posix is not available — returns null.
pub fn get(key: [:0]const u8) ?[:0]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    return std.posix.getenv(key);
}
