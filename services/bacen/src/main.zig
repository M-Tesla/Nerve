//! BACEN — Central Bank (PIX Supervisor)
//! NATS subscriber + net settlement ledger + HTTP API
//!
//! Endpoints:
//!   GET /health
//!   GET /position             — net position of all PSPs
//!   GET /position/:psp_id     — position of a specific PSP
//!   GET /audit                — latest entries from the audit ledger
//!
//! Consumes NATS events:
//!   pix.settled   — updates positions + appends to audit_log
//!   pix.reversed  — appends to audit_log (without changing positions)

const std      = @import("std");
const net      = std.net;
const mem      = std.mem;
const builtin  = @import("builtin");

const db_mod   = @import("db.zig");
const env_util = @import("utils/env.zig");

const PORT: u16               = 8083;
const MAX_REQUEST_SIZE: usize = 16384;
const DEFAULT_DB_PATH: [:0]const u8 = "bacen.monolith";

// ---------------------------------------------------------------------------
// Shared context (HTTP thread + NATS thread)
// libmdbx is thread-safe: NATS thread opens write txns, HTTP thread read txns.
// ---------------------------------------------------------------------------

const BacenContext = struct {
    db:        db_mod.DB,
    allocator: std.mem.Allocator,
    nats_port: u16,
};

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port: u16 = blk: {
        const s = env_util.get("BACEN_PORT") orelse break :blk PORT;
        break :blk std.fmt.parseInt(u16, s, 10) catch PORT;
    };
    const db_path: [:0]const u8 = env_util.get("DB_PATH") orelse DEFAULT_DB_PATH;
    const nats_port: u16 = blk: {
        const s = env_util.get("NATS_PORT") orelse break :blk 4222;
        break :blk std.fmt.parseInt(u16, s, 10) catch 4222;
    };

    var db = try db_mod.DB.open(db_path);
    defer db.deinit();

    var ctx = BacenContext{
        .db        = db,
        .allocator = allocator,
        .nats_port = nats_port,
    };

    // Start NATS subscriber thread (daemon — reconnects automatically)
    const nats_t = try std.Thread.spawn(.{}, natsThread, .{&ctx});
    nats_t.detach();

    // HTTP server
    const address = try net.Address.parseIp("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("BACEN listening on :{d}", .{port});

    while (true) {
        const conn = server.accept() catch |err| {
            std.log.err("accept error: {}", .{err});
            continue;
        };
        handleConnection(conn, &ctx) catch |err| {
            std.log.err("handler error: {}", .{err});
        };
        conn.stream.close();
    }
}

// ---------------------------------------------------------------------------
// HTTP dispatcher
// ---------------------------------------------------------------------------

fn handleConnection(conn: net.Server.Connection, ctx: *BacenContext) !void {
    var buf: [MAX_REQUEST_SIZE]u8 = undefined;
    const n = socketRead(conn.stream, &buf) catch return;
    if (n == 0) return;

    const req = buf[0..n];
    const method, const path = parseRequestLine(req) orelse {
        socketWriteAll(conn.stream, badRequestResp()) catch {};
        return;
    };

    if (mem.eql(u8, path, "/health")) {
        socketWriteAll(conn.stream, healthResp()) catch {};
    } else if (mem.eql(u8, method, "GET") and mem.eql(u8, path, "/position")) {
        handlePosition(conn.stream, ctx);
    } else if (mem.eql(u8, method, "GET") and mem.startsWith(u8, path, "/position/")) {
        handlePositionById(conn.stream, ctx, path["/position/".len..]);
    } else if (mem.eql(u8, method, "GET") and mem.eql(u8, path, "/audit")) {
        handleAudit(conn.stream, ctx);
    } else if (mem.eql(u8, method, "GET") and mem.eql(u8, path, "/metrics")) {
        handleMetrics(conn.stream, ctx);
    } else {
        socketWriteAll(conn.stream, notFoundResp()) catch {};
    }
}

// ---------------------------------------------------------------------------
// GET /position — all PSPs
// ---------------------------------------------------------------------------

fn handlePosition(stream: net.Stream, ctx: *BacenContext) void {
    const entries = ctx.db.getAllPositions(ctx.allocator) catch {
        writeJsonError(stream, ctx.allocator, 500, "Internal error");
        return;
    };
    defer {
        for (entries) |e| ctx.allocator.free(e.psp_id);
        ctx.allocator.free(entries);
    }

    var json = std.ArrayListUnmanaged(u8){};
    defer json.deinit(ctx.allocator);

    json.appendSlice(ctx.allocator, "{\"positions\":[") catch return;
    for (entries, 0..) |e, i| {
        if (i > 0) json.appendSlice(ctx.allocator, ",") catch return;
        const net_pos = e.rec.credits_centavos - e.rec.debits_centavos;
        const item = std.fmt.allocPrint(ctx.allocator,
            "{{\"psp_id\":\"{s}\"," ++
            "\"debits_centavos\":{d}," ++
            "\"credits_centavos\":{d}," ++
            "\"net_centavos\":{d}," ++
            "\"tx_count\":{d}}}",
            .{ e.psp_id, e.rec.debits_centavos, e.rec.credits_centavos, net_pos, e.rec.tx_count },
        ) catch return;
        defer ctx.allocator.free(item);
        json.appendSlice(ctx.allocator, item) catch return;
    }
    json.appendSlice(ctx.allocator, "]}") catch return;

    writeJsonResponse(stream, 200, json.items);
}

// ---------------------------------------------------------------------------
// GET /position/:psp_id
// ---------------------------------------------------------------------------

fn handlePositionById(stream: net.Stream, ctx: *BacenContext, psp_id: []const u8) void {
    if (psp_id.len == 0) {
        writeJsonError(stream, ctx.allocator, 400, "psp_id required");
        return;
    }

    const rec = ctx.db.getPositionById(psp_id) catch null orelse {
        writeJsonError(stream, ctx.allocator, 404, "PSP not found in BACEN ledger");
        return;
    };

    const net_pos = rec.credits_centavos - rec.debits_centavos;
    const body = std.fmt.allocPrint(ctx.allocator,
        "{{\"psp_id\":\"{s}\"," ++
        "\"debits_centavos\":{d}," ++
        "\"credits_centavos\":{d}," ++
        "\"net_centavos\":{d}," ++
        "\"tx_count\":{d}}}",
        .{ psp_id, rec.debits_centavos, rec.credits_centavos, net_pos, rec.tx_count },
    ) catch return;
    defer ctx.allocator.free(body);
    writeJsonResponse(stream, 200, body);
}

// ---------------------------------------------------------------------------
// GET /audit — latest ledger entries
// ---------------------------------------------------------------------------

fn handleAudit(stream: net.Stream, ctx: *BacenContext) void {
    const limit: usize = 50;
    const entries = ctx.db.getAuditEntries(ctx.allocator, limit) catch {
        writeJsonError(stream, ctx.allocator, 500, "Internal error");
        return;
    };
    defer {
        for (entries) |e| ctx.allocator.free(e.json);
        ctx.allocator.free(entries);
    }

    var json = std.ArrayListUnmanaged(u8){};
    defer json.deinit(ctx.allocator);

    json.appendSlice(ctx.allocator, "{\"entries\":[") catch return;
    for (entries, 0..) |e, i| {
        if (i > 0) json.appendSlice(ctx.allocator, ",") catch return;
        const item = std.fmt.allocPrint(ctx.allocator,
            "{{\"seq\":{d},\"event\":{s}}}",
            .{ e.seq, e.json },
        ) catch return;
        defer ctx.allocator.free(item);
        json.appendSlice(ctx.allocator, item) catch return;
    }
    var total_buf: [24]u8 = undefined;
    const total_str = std.fmt.bufPrint(&total_buf, "{d}", .{entries.len}) catch "0";
    const tail = std.fmt.allocPrint(ctx.allocator, "],\"total\":{s}}}", .{total_str}) catch return;
    defer ctx.allocator.free(tail);
    json.appendSlice(ctx.allocator, tail) catch return;

    writeJsonResponse(stream, 200, json.items);
}

// ---------------------------------------------------------------------------
// GET /metrics — Prometheus exposition format
// ---------------------------------------------------------------------------

fn handleMetrics(stream: net.Stream, ctx: *BacenContext) void {
    // Count audit_log entries as a proxy for processed transactions
    const entries = ctx.db.getAuditEntries(ctx.allocator, 10000) catch &[_]db_mod.AuditEntry{};
    defer {
        for (entries) |e| ctx.allocator.free(e.json);
        ctx.allocator.free(entries);
    }

    // Count settled vs reversed from JSON events in audit_log
    var settled_count:  u64 = 0;
    var reversed_count: u64 = 0;
    for (entries) |e| {
        if (mem.indexOf(u8, e.json, "\"payer_psp\"") != null) {
            settled_count += 1;  // event has payer_psp → it is a settled event
        } else {
            reversed_count += 1; // event without payer_psp → it is a reversed event
        }
    }

    var body_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        "# HELP nerve_bacen_settled_total PIX transactions settled by BACEN\n" ++
        "# TYPE nerve_bacen_settled_total counter\n" ++
        "nerve_bacen_settled_total {d}\n" ++
        "# HELP nerve_bacen_reversed_total PIX transactions reversed\n" ++
        "# TYPE nerve_bacen_reversed_total counter\n" ++
        "nerve_bacen_reversed_total {d}\n" ++
        "# HELP nerve_bacen_up BACEN service up\n" ++
        "# TYPE nerve_bacen_up gauge\n" ++
        "nerve_bacen_up 1\n",
        .{ settled_count, reversed_count },
    ) catch return;

    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n",
        .{body.len},
    ) catch return;
    socketWriteAll(stream, header) catch {};
    socketWriteAll(stream, body)   catch {};
}

// ---------------------------------------------------------------------------
// NATS subscriber thread
// ---------------------------------------------------------------------------

fn natsThread(ctx: *BacenContext) void {
    while (true) {
        natsRun(ctx) catch |err| {
            std.log.warn("BACEN NATS: disconnected ({}) — reconnecting in 5s", .{err});
        };
        std.Thread.sleep(5_000_000_000);
    }
}

fn natsRun(ctx: *BacenContext) !void {
    const stream = net.tcpConnectToHost(ctx.allocator, "127.0.0.1", ctx.nats_port) catch |err| {
        std.log.warn("BACEN NATS: failed to connect to 127.0.0.1:{d} ({})", .{ ctx.nats_port, err });
        return err;
    };
    defer stream.close();

    // Read INFO (first line from NATS server)
    var buf: [65536]u8 = undefined;
    var filled: usize = 0;
    _ = try natsReadLine(&buf, &filled, stream); // discard INFO

    // Send CONNECT
    try natsSend(stream, "CONNECT {\"verbose\":false,\"name\":\"bacen\",\"lang\":\"zig\"}\r\n");
    // Subscribe to subjects
    try natsSend(stream, "SUB pix.settled 1\r\n");
    try natsSend(stream, "SUB pix.reversed 2\r\n");

    std.log.info("BACEN NATS: connected — subscribed to pix.settled + pix.reversed", .{});

    while (true) {
        // Read next line (may be MSG, PING, INFO, etc.)
        const line = try natsReadLine(&buf, &filled, stream);

        if (mem.eql(u8, line, "PING")) {
            try natsSend(stream, "PONG\r\n");

        } else if (mem.startsWith(u8, line, "MSG ")) {
            // MSG <subject> <sid> [<reply>] <#bytes>
            const hdr = line["MSG ".len..];

            // Extract subject (first token)
            const subj_end = mem.indexOfScalar(u8, hdr, ' ') orelse continue;
            const subject  = hdr[0..subj_end];

            // Extract bytes (last space-separated token)
            var last_space: usize = hdr.len;
            var k: usize = hdr.len;
            while (k > 0) {
                k -= 1;
                if (hdr[k] == ' ') { last_space = k; break; }
            }
            const payload_len = std.fmt.parseInt(usize, hdr[last_space + 1..], 10) catch continue;

            // Ensure payload + \r\n are in buffer
            while (filled < payload_len + 2) {
                const n = natsRecv(stream, buf[filled..]) catch return error.Closed;
                if (n == 0) return error.Closed;
                filled += n;
            }

            const payload = buf[0..payload_len];
            processNatsMsg(ctx, subject, payload);

            // Consume payload + \r\n
            const total = payload_len + 2;
            mem.copyForwards(u8, &buf, buf[total..filled]);
            filled -= total;
        }
        // Other types (INFO, +OK, -ERR) — ignore
    }
}

/// Reads a line from the socket (blocking). Fills buffer until \r\n is found.
/// Returns the line without \r\n. Buffer is compacted after consumption.
fn natsReadLine(buf: []u8, filled: *usize, stream: net.Stream) ![]u8 {
    while (true) {
        if (mem.indexOf(u8, buf[0..filled.*], "\r\n")) |pos| {
            const line = buf[0..pos];
            // Compact: move remaining data to beginning
            const total = pos + 2;
            mem.copyForwards(u8, buf, buf[total..filled.*]);
            filled.* -= total;
            return line;
        }
        if (filled.* >= buf.len) return error.BufferFull;
        const n = natsRecv(stream, buf[filled.*..]) catch return error.Closed;
        if (n == 0) return error.Closed;
        filled.* += n;
    }
}

/// Processes a received NATS message.
fn processNatsMsg(ctx: *BacenContext, subject: []const u8, payload: []const u8) void {
    if (mem.eql(u8, subject, "pix.settled")) {
        const payer_psp = findJsonStr(payload, "payer_psp")      orelse {
            std.log.warn("BACEN NATS: pix.settled missing payer_psp", .{});
            return;
        };
        const payee_psp = findJsonStr(payload, "payee_psp")      orelse {
            std.log.warn("BACEN NATS: pix.settled missing payee_psp", .{});
            return;
        };
        const amount    = findJsonInt(payload, "amount_centavos") orelse {
            std.log.warn("BACEN NATS: pix.settled missing amount_centavos", .{});
            return;
        };

        ctx.db.recordSettle(payer_psp, payee_psp, amount, payload) catch |err| {
            std.log.err("BACEN: recordSettle error: {}", .{err});
            return;
        };
        std.log.info("BACEN: settled payer={s} payee={s} amount={d}", .{ payer_psp, payee_psp, amount });

    } else if (mem.eql(u8, subject, "pix.reversed")) {
        ctx.db.recordReverse(payload) catch |err| {
            std.log.err("BACEN: recordReverse error: {}", .{err});
            return;
        };
        std.log.info("BACEN: reversal recorded in ledger", .{});
    }
}

// ---------------------------------------------------------------------------
// Minimal JSON parsing (same pattern as other services)
// ---------------------------------------------------------------------------

fn findJsonStr(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    var i = val_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"') break;
        if (json[i] == '\\') i += 1;
    }
    if (i >= json.len) return null;
    return json[val_start..i];
}

fn findJsonInt(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const start = mem.indexOf(u8, json, needle) orelse return null;
    var i = start + needle.len;
    while (i < json.len and json[i] == ' ') i += 1;
    const num_start = i;
    if (i < json.len and json[i] == '-') i += 1;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
    if (i == num_start) return null;
    return std.fmt.parseInt(i64, json[num_start..i], 10) catch null;
}

// ---------------------------------------------------------------------------
// HTTP utilities
// ---------------------------------------------------------------------------

fn parseRequestLine(req: []const u8) ?struct { []const u8, []const u8 } {
    const line_end = mem.indexOfScalar(u8, req, '\r') orelse
                     mem.indexOfScalar(u8, req, '\n') orelse return null;
    const line = req[0..line_end];
    var it = mem.splitScalar(u8, line, ' ');
    const method    = it.next() orelse return null;
    const path_full = it.next() orelse return null;
    const path = if (mem.indexOfScalar(u8, path_full, '?')) |qi|
        path_full[0..qi] else path_full;
    return .{ method, path };
}

fn writeJsonResponse(stream: net.Stream, status: u16, body: []const u8) void {
    const status_text: []const u8 = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        else => "Internal Server Error",
    };
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n",
        .{ status, status_text, body.len },
    ) catch return;
    socketWriteAll(stream, header) catch {};
    socketWriteAll(stream, body)   catch {};
}

fn writeJsonError(stream: net.Stream, allocator: std.mem.Allocator, status: u16, msg: []const u8) void {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg}) catch return;
    defer allocator.free(body);
    writeJsonResponse(stream, status, body);
}

fn healthResp() []const u8 {
    // body = {"status":"ok","service":"bacen","version":"0.1.0"} = 51 chars
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 51\r\n\r\n" ++
        "{\"status\":\"ok\",\"service\":\"bacen\",\"version\":\"0.1.0\"}";
}
fn badRequestResp() []const u8 { return "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"; }
fn notFoundResp()   []const u8 { return "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"; }

// ---------------------------------------------------------------------------
// Windows socket helpers — ws2_32 instead of ReadFile/WriteFile
// ---------------------------------------------------------------------------

fn natsRecv(stream: net.Stream, buf: []u8) !usize {
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        const n = ws2.recv(stream.handle, buf.ptr, @intCast(buf.len), 0);
        if (n < 0) return error.Unexpected;
        return @as(usize, @intCast(n));
    }
    return stream.read(buf);
}

fn natsSend(stream: net.Stream, data: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        var pos: usize = 0;
        while (pos < data.len) {
            const n = ws2.send(stream.handle, data[pos..].ptr, @intCast(data.len - pos), 0);
            if (n < 0) return error.Unexpected;
            pos += @as(usize, @intCast(n));
        }
        return;
    }
    return stream.writeAll(data);
}

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
