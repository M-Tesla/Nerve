//! Cross-platform helper for reading environment variables.
//! std.posix.getenv does not work on Windows — guarded with comptime.

const std     = @import("std");
const builtin = @import("builtin");

pub fn get(key: [:0]const u8) ?[:0]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    return std.posix.getenv(key);
}
