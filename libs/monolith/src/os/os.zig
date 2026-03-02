//! OS Abstraction Layer
//! Focused on Windows (primary target), prepared for POSIX.

const std = @import("std");
const consts = @import("../core/consts.zig");
const windows = std.os.windows;
const builtin = @import("builtin");
const WINAPI: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86) .stdcall else .c;

pub const FileHandle = std.fs.File;

pub const MmapError = error{
    MappingFailed,
    UnmappingFailed,
    ResizeFailed,
    LockFailed,
    UnlockFailed,
};

pub fn lockFile(file: FileHandle, exclusive: bool, wait: bool) !void {
    var overlapped = std.mem.zeroes(MmapRegion.OVERLAPPED);
    overlapped.Offset = 0;
    overlapped.OffsetHigh = 0;

    var flags: u32 = 0;
    if (exclusive) flags |= MmapRegion.LOCKFILE_EXCLUSIVE_LOCK;
    if (!wait) flags |= MmapRegion.LOCKFILE_FAIL_IMMEDIATELY;

    // Lock 1 byte at position 0 for simple file exclusivity
    const len: u64 = 1;

    const rc = MmapRegion.LockFileEx(
        file.handle,
        flags,
        0,
        @as(u32, @truncate(len)),
        @as(u32, @truncate(len >> 32)),
        &overlapped,
    );

    if (rc == 0) return MmapError.LockFailed;
}

pub fn unlockFile(file: FileHandle) !void {
    var overlapped = std.mem.zeroes(MmapRegion.OVERLAPPED);
    overlapped.Offset = 0;
    overlapped.OffsetHigh = 0;
    const len: u64 = 1;
    const rc = MmapRegion.UnlockFileEx(
        file.handle,
        0,
        @as(u32, @truncate(len)),
        @as(u32, @truncate(len >> 32)),
        &overlapped,
    );
    if (rc == 0) return MmapError.UnlockFailed;
}

/// Represents a memory-mapped region
pub const MmapRegion = struct {
    ptr: [*]align(4096) u8,
    len: usize,
    handle: ?windows.HANDLE, // Windows mapping handle

    const builtin = @import("builtin");

    // Protection flags
    const PAGE_READONLY: u32 = 0x02;
    const PAGE_READWRITE: u32 = 0x04;

    // Access flags
    const FILE_MAP_WRITE: u32 = 0x02;
    const FILE_MAP_READ: u32 = 0x04;
    const FILE_MAP_ALL_ACCESS: u32 = 0xF001F; // SECTION_ALL_ACCESS

    // Local definition to avoid std lib version issues
    const OVERLAPPED = extern struct {
        Internal: usize,
        InternalHigh: usize,
        Offset: u32,
        OffsetHigh: u32,
        hEvent: ?windows.HANDLE,
    };

    extern "kernel32" fn CreateFileMappingW(
        hFile: windows.HANDLE,
        lpFileMappingAttributes: ?*anyopaque,
        flProtect: u32,
        dwMaximumSizeHigh: u32,
        dwMaximumSizeLow: u32,
        lpName: ?[*:0]const u16,
    ) callconv(WINAPI) ?windows.HANDLE;

    extern "kernel32" fn MapViewOfFile(
        hFileMappingObject: windows.HANDLE,
        dwDesiredAccess: u32,
        dwFileOffsetHigh: u32,
        dwFileOffsetLow: u32,
        dwNumberOfBytesToMap: usize,
    ) callconv(WINAPI) ?*anyopaque;

    extern "kernel32" fn UnmapViewOfFile(
        lpBaseAddress: ?*anyopaque,
    ) callconv(WINAPI) i32;

    extern "kernel32" fn FlushViewOfFile(
        lpBaseAddress: ?*const anyopaque,
        dwNumberOfBytesToFlush: usize,
    ) callconv(WINAPI) i32;

    extern "kernel32" fn LockFileEx(
        hFile: windows.HANDLE,
        dwFlags: u32,
        dwReserved: u32,
        nNumberOfBytesToLockLow: u32,
        nNumberOfBytesToLockHigh: u32,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(WINAPI) i32;

    extern "kernel32" fn UnlockFileEx(
        hFile: windows.HANDLE,
        dwReserved: u32,
        nNumberOfBytesToUnlockLow: u32,
        nNumberOfBytesToUnlockHigh: u32,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(WINAPI) i32;

    const LOCKFILE_FAIL_IMMEDIATELY: u32 = 0x00000001;
    const LOCKFILE_EXCLUSIVE_LOCK: u32 = 0x00000002;

    pub fn init(file: FileHandle, size: usize, read_only: bool) !MmapRegion {
        const protect = if (read_only) PAGE_READONLY else PAGE_READWRITE;
        const access = if (read_only) FILE_MAP_READ else FILE_MAP_ALL_ACCESS;

        const size_low: u32 = @truncate(size);
        const size_high: u32 = @truncate(size >> 32);

        const mapping_handle = CreateFileMappingW(
            file.handle,
            null,
            protect,
            size_high,
            size_low,
            null,
        );

        if (mapping_handle == null) {
            return MmapError.MappingFailed;
        }

        const ptr = MapViewOfFile(
            mapping_handle.?,
            access,
            0,
            0,
            size,
        );

        if (ptr == null) {
            windows.CloseHandle(mapping_handle.?);
            return MmapError.MappingFailed;
        }

        return MmapRegion{
            .ptr = @alignCast(@ptrCast(ptr)),
            .len = size,
            .handle = mapping_handle,
        };
    }

    pub fn deinit(self: *MmapRegion) void {
        _ = UnmapViewOfFile(self.ptr);
        if (self.handle) |h| {
            windows.CloseHandle(h);
        }
    }

    pub fn sync(self: *MmapRegion) void {
        _ = FlushViewOfFile(self.ptr, self.len);
    }
};

// --- Process Management (Windows) ---

pub const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
pub const SYNCHRONIZE = 0x00100000;
pub const STILL_ACTIVE = 259;

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: u32,
    bInheritHandle: i32,
    dwProcessId: u32,
) callconv(WINAPI) ?windows.HANDLE;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: windows.HANDLE,
    lpExitCode: *u32,
) callconv(WINAPI) i32;

pub extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
pub extern "kernel32" fn GetCurrentThreadId() callconv(WINAPI) u32;

/// Checks if a process with the given PID is still alive.
/// Returns true if alive, false if dead or invalid.
pub fn isProcessAlive(pid: u32) bool {
    if (pid == 0) return false;

    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);

    if (handle) |h| {
        defer windows.CloseHandle(h);

        var exit_code: u32 = 0;
        const rc = GetExitCodeProcess(h, &exit_code);

        if (rc != 0) {
            if (exit_code == STILL_ACTIVE) {
                return true;
            } else {
                return false;
            }
        }
        return false;
    } else {
        const err = windows.kernel32.GetLastError();
        // ACCESS_DENIED (5) → process exists but we can't open it (Admin/System). Assume alive.
        if (@intFromEnum(err) == 5) return true;
        return false;
    }
}

test "Mmap basic" {
    const tmp_path = "test_mmap.dat";
    var file = try std.fs.cwd().createFile(tmp_path, .{ .read = true, .truncate = true });
    defer {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    try file.setEndPos(4096);

    var region = try MmapRegion.init(file, 4096, false);
    defer region.deinit();

    const slice = region.ptr[0..region.len];
    slice[0] = 0xAA;
    slice[4095] = 0xBB;

    region.sync();

    try file.seekTo(0);
    var buf: [1]u8 = undefined;
    _ = try file.read(&buf);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[0]);
}

test "isProcessAlive" {
    const pid = GetCurrentProcessId();
    try std.testing.expect(isProcessAlive(pid));
    try std.testing.expect(!isProcessAlive(0xfffffffc));
    try std.testing.expect(!isProcessAlive(0));
}
