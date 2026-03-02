//! Minimal HTTP client for inter-service calls (DICT, STR, PSPs).
//! HTTP/1.0 blocking — no TLS, no redirects, localhost only.
//! All services run on 127.0.0.1 with configurable ports.

const std     = @import("std");
const net     = std.net;
const builtin = @import("builtin");

pub const HttpError = error{
    ConnectionFailed,
    SendFailed,
    ReadFailed,
    InvalidResponse,
};

/// HTTP Response. Caller must call .deinit() to free body memory.
pub const Response = struct {
    status: u16,
    body:   []u8,
    _alloc: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self._alloc.free(self.body);
    }
};

/// HTTP POST to 127.0.0.1:port/path with JSON body.
pub fn post(
    allocator: std.mem.Allocator,
    port: u16,
    path: []const u8,
    body: []const u8,
) !Response {
    const stream = connect(allocator, port) catch return HttpError.ConnectionFailed;
    defer stream.close();

    const req = try std.fmt.allocPrint(allocator,
        "POST {s} HTTP/1.0\r\nHost: 127.0.0.1\r\n" ++
        "Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ path, body.len, body });
    defer allocator.free(req);

    socketWriteAll(stream, req) catch return HttpError.SendFailed;
    return readResponse(allocator, stream);
}

/// HTTP GET to 127.0.0.1:port/path.
pub fn get(
    allocator: std.mem.Allocator,
    port: u16,
    path: []const u8,
) !Response {
    const stream = connect(allocator, port) catch return HttpError.ConnectionFailed;
    defer stream.close();

    const req = try std.fmt.allocPrint(allocator,
        "GET {s} HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n",
        .{path});
    defer allocator.free(req);

    socketWriteAll(stream, req) catch return HttpError.SendFailed;
    return readResponse(allocator, stream);
}

// ---------------------------------------------------------------------------
// Windows socket helpers — ws2_32.recv/send instead of ReadFile/WriteFile
// ---------------------------------------------------------------------------

fn socketRead(stream: net.Stream, buf: []u8) !usize {
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        const n = ws2.recv(stream.handle, buf.ptr, @intCast(buf.len), 0);
        if (n < 0) return error.Unexpected;
        return @as(usize, @intCast(n));
    }
    return stream.read(buf);
}

fn socketWriteAll(stream: net.Stream, buf: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        var pos: usize = 0;
        while (pos < buf.len) {
            const n = ws2.send(stream.handle, buf[pos..].ptr, @intCast(buf.len - pos), 0);
            if (n < 0) return error.Unexpected;
            pos += @as(usize, @intCast(n));
        }
        return;
    }
    return stream.writeAll(buf);
}

// ---------------------------------------------------------------------------
// Private
// ---------------------------------------------------------------------------

fn connect(allocator: std.mem.Allocator, port: u16) !net.Stream {
    return net.tcpConnectToHost(allocator, "127.0.0.1", port);
}

fn readResponse(allocator: std.mem.Allocator, stream: net.Stream) !Response {
    // Read until EOF (HTTP/1.0 closes connection when response is complete)
    var raw: std.ArrayListUnmanaged(u8) = .{};
    defer raw.deinit(allocator);

    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = socketRead(stream, &tmp) catch break;
        if (n == 0) break;
        raw.appendSlice(allocator, tmp[0..n]) catch return HttpError.ReadFailed;
        if (raw.items.len > 1024 * 1024) break; // 1 MB limit
    }

    const data = raw.items;
    if (data.len == 0) return HttpError.InvalidResponse;

    // Parse status line: "HTTP/1.0 200 OK\r\n"
    const line_end = std.mem.indexOfScalar(u8, data, '\r') orelse
        return HttpError.InvalidResponse;
    var parts = std.mem.splitScalar(u8, data[0..line_end], ' ');
    _ = parts.next(); // "HTTP/1.0"
    const status_str = parts.next() orelse return HttpError.InvalidResponse;
    const status = std.fmt.parseInt(u16, status_str, 10) catch
        return HttpError.InvalidResponse;

    // Find body (after \r\n\r\n)
    const sep = std.mem.indexOf(u8, data, "\r\n\r\n") orelse
        return HttpError.InvalidResponse;
    const body_raw = data[sep + 4..];
    const body = allocator.dupe(u8, body_raw) catch return HttpError.ReadFailed;

    return .{ .status = status, .body = body, ._alloc = allocator };
}

// ---------------------------------------------------------------------------
// Utility: extract JSON string field from a response
// ---------------------------------------------------------------------------

/// Extracts the string value of a JSON field: "key":"value" → value
/// Returns null if the field is not found.
pub fn jsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    var i = val_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"') break;
        if (json[i] == '\\') i += 1;
    }
    if (i >= json.len) return null;
    return json[val_start..i];
}
