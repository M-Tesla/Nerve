//! Minimal NATS client — raw TCP publisher (no TLS, no cgo).
//! Best-effort: if NATS is unavailable, publishes are silently dropped.
//! Protocol: https://docs.nats.io/reference/reference-protocols/nats

const std = @import("std");
const net = std.net;

pub const Client = struct {
    stream: ?net.Stream = null,

    /// Try to connect to NATS. Never fails — returns a disconnected Client if
    /// NATS is not available. Subsequent publishes will be no-ops.
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) Client {
        const stream = net.tcpConnectToHost(allocator, host, port) catch |err| {
            std.log.warn("NATS: not connected to {s}:{d} ({}) — publishes dropped", .{ host, port, err });
            return .{ .stream = null };
        };

        // Read INFO from server
        var info_buf: [512]u8 = undefined;
        const n = stream.read(&info_buf) catch {
            stream.close();
            std.log.warn("NATS: failed to read INFO — disconnected", .{});
            return .{ .stream = null };
        };
        _ = n;

        // Send CONNECT
        const connect_msg = "CONNECT {\"verbose\":false,\"name\":\"spi\",\"lang\":\"zig\"}\r\n";
        stream.writeAll(connect_msg) catch {
            stream.close();
            std.log.warn("NATS: failed to send CONNECT", .{});
            return .{ .stream = null };
        };

        std.log.info("NATS: connected to {s}:{d}", .{ host, port });
        return .{ .stream = stream };
    }

    /// Publish a message to the given subject.
    /// Silent no-op if the client is disconnected.
    pub fn publish(self: *Client, subject: []const u8, payload: []const u8) void {
        if (self.stream == null) return;

        // NATS protocol: PUB <subject> <#bytes>\r\n<payload>\r\n
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf, "PUB {s} {d}\r\n", .{ subject, payload.len },
        ) catch return;

        self.stream.?.writeAll(header) catch {
            self.stream.?.close();
            self.stream = null;
            return;
        };
        self.stream.?.writeAll(payload) catch {};
        self.stream.?.writeAll("\r\n") catch {};
    }

    pub fn deinit(self: *Client) void {
        if (self.stream) |s| s.close();
        self.stream = null;
    }
};
