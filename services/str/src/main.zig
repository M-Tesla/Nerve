//! STR — Settlement Transfer System
//! reserve/settle/reverse + double-entry ledger + Monolith DB
//!
//! Endpoints:
//!   POST /reserve              — reserve funds from PSP
//!   POST /settle               — settle reservation (funds leave definitively)
//!   POST /reverse              — reverse reservation (funds return to PSP)
//!   GET  /balance/:psp_id      — current PSP balance
//!   GET  /reservation/:id      — status of a reservation
//!   POST /admin/seed           — seed PSP (dev only)
//!   GET  /health

const std  = @import("std");
const net  = std.net;
const mem  = std.mem;

const db_mod   = @import("db.zig");
const env_util = @import("utils/env.zig");
const builtin  = @import("builtin");

const PORT: u16              = 8082;
const MAX_REQUEST_SIZE: usize = 16384;
const DEFAULT_DB_PATH: [:0]const u8 = "str.monolith";

// ---------------------------------------------------------------------------
// Shared context (thread-safe)
// ---------------------------------------------------------------------------
// The DB is thread-safe: mdbx serializes writers internally via internal lock;
// MVCC readers run in parallel without any application-level lock.
// The allocator uses std.heap.page_allocator (thread-safe, OS-backed).

const StrContext = struct {
    db: db_mod.DB,
};

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    const port: u16 = blk: {
        const s = env_util.get("STR_PORT") orelse break :blk PORT;
        break :blk std.fmt.parseInt(u16, s, 10) catch PORT;
    };

    const db_path: [:0]const u8 = env_util.get("DB_PATH") orelse DEFAULT_DB_PATH;

    var db = try db_mod.DB.open(db_path);
    defer db.deinit();

    // Automatic seed via env vars (e.g.: STR_SEED_PSP_ALPHA=10000000)
    if (env_util.get("STR_SEED_PSP_ALPHA")) |bal_str| {
        const bal = std.fmt.parseInt(i64, bal_str, 10) catch 10_000_000;
        db.seedPsp("psp-alpha", bal) catch {};
    }
    if (env_util.get("STR_SEED_PSP_BETA")) |bal_str| {
        const bal = std.fmt.parseInt(i64, bal_str, 10) catch 10_000_000;
        db.seedPsp("psp-beta", bal) catch {};
    }

    var ctx = StrContext{ .db = db };

    const address = try net.Address.parseIp("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("STR listening on :{d} [writemap+safe_nosync+sync@100ms]", .{port});

    // Sync thread: with SAFE_NOSYNC each write txn is < 0.1ms (no fsync).
    // This thread consolidates N commits into 1 fsync every 100ms.
    // sync at 100ms → 8ms flush / (100ms + 8ms) = 7% of time blocked.
    // (sync at 5ms → 61% blocked — worse than baseline with SYNC_DURABLE)
    const sync_thread = try std.Thread.spawn(.{}, syncLoop, .{&ctx.db});
    sync_thread.detach();

    // Single-threaded: with write txns of < 0.1ms, spawning per connection would add
    // 1-3ms of thread creation overhead — more than the work itself.
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

fn syncLoop(db: *db_mod.DB) void {
    while (true) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        db.env.sync();
    }
}

// ---------------------------------------------------------------------------
// Dispatcher
// ---------------------------------------------------------------------------

fn handleConnection(conn: net.Server.Connection, ctx: *StrContext) !void {
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
    } else if (mem.eql(u8, method, "POST") and mem.eql(u8, path, "/reserve")) {
        handleReserve(conn.stream, ctx, req);
    } else if (mem.eql(u8, method, "POST") and mem.eql(u8, path, "/settle")) {
        handleSettle(conn.stream, ctx, req);
    } else if (mem.eql(u8, method, "POST") and mem.eql(u8, path, "/reverse")) {
        handleReverse(conn.stream, ctx, req);
    } else if (mem.eql(u8, method, "GET") and mem.startsWith(u8, path, "/balance/")) {
        handleGetBalance(conn.stream, ctx, path["/balance/".len..]);
    } else if (mem.eql(u8, method, "GET") and mem.startsWith(u8, path, "/reservation/")) {
        handleGetReservation(conn.stream, ctx, path["/reservation/".len..]);
    } else if (mem.eql(u8, method, "POST") and mem.eql(u8, path, "/admin/seed")) {
        handleAdminSeed(conn.stream, ctx, req);
    } else {
        socketWriteAll(conn.stream, notFoundResp()) catch {};
    }
}

// ---------------------------------------------------------------------------
// POST /reserve
// ---------------------------------------------------------------------------

fn handleReserve(stream: net.Stream, ctx: *StrContext, req: []const u8) void {
    const body = extractBody(req) orelse {
        socketWriteAll(stream, badRequestResp()) catch {};
        return;
    };

    const psp_id     = findJsonString(body, "psp_id")     orelse { writeJsonError(stream, std.heap.page_allocator, 400, "psp_id required");     return; };
    const pix_txn_id = findJsonString(body, "pix_txn_id") orelse { writeJsonError(stream, std.heap.page_allocator, 400, "pix_txn_id required"); return; };
    const amount     = findJsonInt(body, "amount_centavos") orelse {
        writeJsonError(stream, std.heap.page_allocator, 400, "amount_centavos required");
        return;
    };
    if (amount <= 0) {
        writeJsonError(stream, std.heap.page_allocator, 422, "amount_centavos must be positive");
        return;
    }

    const res_id = ctx.db.reserve(psp_id, amount, pix_txn_id) catch |err| {
        switch (err) {
            db_mod.StrError.PspNotFound       => writeJsonError(stream, std.heap.page_allocator, 404, "PSP not found"),
            db_mod.StrError.InsufficientFunds => writeJsonError(stream, std.heap.page_allocator, 422, "insufficient balance"),
            else => writeJsonError(stream, std.heap.page_allocator, 500, "Internal error"),
        }
        return;
    };

    var res_str: [36]u8 = undefined;
    db_mod.fmtUuid(res_id, &res_str);

    const body_resp = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{{\"reservation_id\":\"{s}\",\"psp_id\":\"{s}\"," ++
        "\"amount_centavos\":{d},\"status\":\"ACTIVE\"}}",
        .{ res_str, psp_id, amount },
    ) catch return;
    defer std.heap.page_allocator.free(body_resp);

    writeJsonResponse(stream, 201, body_resp);
}

// ---------------------------------------------------------------------------
// POST /settle
// ---------------------------------------------------------------------------

fn handleSettle(stream: net.Stream, ctx: *StrContext, req: []const u8) void {
    const body = extractBody(req) orelse {
        socketWriteAll(stream, badRequestResp()) catch {};
        return;
    };

    const res_id_str = findJsonString(body, "reservation_id") orelse {
        writeJsonError(stream, std.heap.page_allocator, 400, "reservation_id required");
        return;
    };
    const res_id = db_mod.parseUuid(res_id_str) catch {
        writeJsonError(stream, std.heap.page_allocator, 400, "invalid reservation_id");
        return;
    };

    ctx.db.settle(res_id) catch |err| {
        switch (err) {
            db_mod.StrError.ReservationNotFound  => writeJsonError(stream, std.heap.page_allocator, 404, "reservation not found"),
            db_mod.StrError.ReservationNotActive => writeJsonError(stream, std.heap.page_allocator, 409, "reservation is not ACTIVE"),
            else => writeJsonError(stream, std.heap.page_allocator, 500, "Internal error"),
        }
        return;
    };

    const body_resp = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{{\"reservation_id\":\"{s}\",\"status\":\"SETTLED\"}}",
        .{res_id_str},
    ) catch return;
    defer std.heap.page_allocator.free(body_resp);

    writeJsonResponse(stream, 200, body_resp);
}

// ---------------------------------------------------------------------------
// POST /reverse
// ---------------------------------------------------------------------------

fn handleReverse(stream: net.Stream, ctx: *StrContext, req: []const u8) void {
    const body = extractBody(req) orelse {
        socketWriteAll(stream, badRequestResp()) catch {};
        return;
    };

    const res_id_str = findJsonString(body, "reservation_id") orelse {
        writeJsonError(stream, std.heap.page_allocator, 400, "reservation_id required");
        return;
    };
    const res_id = db_mod.parseUuid(res_id_str) catch {
        writeJsonError(stream, std.heap.page_allocator, 400, "invalid reservation_id");
        return;
    };

    ctx.db.reverse(res_id) catch |err| {
        switch (err) {
            db_mod.StrError.ReservationNotFound  => writeJsonError(stream, std.heap.page_allocator, 404, "reservation not found"),
            db_mod.StrError.ReservationNotActive => writeJsonError(stream, std.heap.page_allocator, 409, "reservation is not ACTIVE"),
            db_mod.StrError.PspNotFound          => writeJsonError(stream, std.heap.page_allocator, 500, "inconsistency: PSP not found"),
            else => writeJsonError(stream, std.heap.page_allocator, 500, "Internal error"),
        }
        return;
    };

    const body_resp = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{{\"reservation_id\":\"{s}\",\"status\":\"REVERSED\"}}",
        .{res_id_str},
    ) catch return;
    defer std.heap.page_allocator.free(body_resp);

    writeJsonResponse(stream, 200, body_resp);
}

// ---------------------------------------------------------------------------
// GET /balance/:psp_id
// ---------------------------------------------------------------------------

fn handleGetBalance(stream: net.Stream, ctx: *StrContext, psp_id: []const u8) void {
    if (psp_id.len == 0) {
        writeJsonError(stream, std.heap.page_allocator, 400, "psp_id required");
        return;
    }

    const rec = ctx.db.getBalance(psp_id) catch null orelse {
        writeJsonError(stream, std.heap.page_allocator, 404, "PSP not found");
        return;
    };

    const body_resp = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{{\"psp_id\":\"{s}\",\"balance_centavos\":{d},\"version\":{d}}}",
        .{ psp_id, rec.balance_centavos, rec.version },
    ) catch return;
    defer std.heap.page_allocator.free(body_resp);

    writeJsonResponse(stream, 200, body_resp);
}

// ---------------------------------------------------------------------------
// GET /reservation/:id
// ---------------------------------------------------------------------------

fn handleGetReservation(stream: net.Stream, ctx: *StrContext, res_id_str: []const u8) void {
    const res_id = db_mod.parseUuid(res_id_str) catch {
        writeJsonError(stream, std.heap.page_allocator, 400, "invalid reservation_id");
        return;
    };

    const rec = ctx.db.getReservation(res_id) catch null orelse {
        writeJsonError(stream, std.heap.page_allocator, 404, "reservation not found");
        return;
    };

    const status = @as(db_mod.ReservationStatus, @enumFromInt(rec.status));
    const psp_id = db_mod.nullTermStr(&rec.psp_id);
    const pix_txn_id = db_mod.nullTermStr(&rec.pix_txn_id);

    const body_resp = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{{\"reservation_id\":\"{s}\",\"status\":\"{s}\"," ++
        "\"amount_centavos\":{d},\"psp_id\":\"{s}\"," ++
        "\"pix_txn_id\":\"{s}\",\"created_at\":{d},\"version\":{d}}}",
        .{ res_id_str, status.toString(), rec.amount_centavos,
           psp_id, pix_txn_id, rec.created_at, rec.version },
    ) catch return;
    defer std.heap.page_allocator.free(body_resp);

    writeJsonResponse(stream, 200, body_resp);
}

// ---------------------------------------------------------------------------
// POST /admin/seed
// ---------------------------------------------------------------------------

fn handleAdminSeed(stream: net.Stream, ctx: *StrContext, req: []const u8) void {
    const body = extractBody(req) orelse {
        socketWriteAll(stream, badRequestResp()) catch {};
        return;
    };

    const psp_id  = findJsonString(body, "psp_id") orelse {
        writeJsonError(stream, std.heap.page_allocator, 400, "psp_id required");
        return;
    };
    const balance = findJsonInt(body, "balance_centavos") orelse {
        writeJsonError(stream, std.heap.page_allocator, 400, "balance_centavos required");
        return;
    };

    ctx.db.seedPsp(psp_id, balance) catch {
        writeJsonError(stream, std.heap.page_allocator, 500, "Error seeding PSP");
        return;
    };

    const body_resp = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{{\"psp_id\":\"{s}\",\"balance_centavos\":{d},\"seeded\":true}}",
        .{ psp_id, balance },
    ) catch return;
    defer std.heap.page_allocator.free(body_resp);

    writeJsonResponse(stream, 200, body_resp);
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

fn extractBody(req: []const u8) ?[]const u8 {
    const pos = mem.indexOf(u8, req, "\r\n\r\n") orelse return null;
    const body = req[pos + 4..];
    return if (body.len == 0) null else body;
}

/// Extracts the string value of a JSON field: "key":"value" → value
fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
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

/// Extracts an integer value of a JSON field: "key": <integer> → i64
fn findJsonInt(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const start = mem.indexOf(u8, json, needle) orelse return null;
    var i = start + needle.len;
    // skip spaces
    while (i < json.len and json[i] == ' ') i += 1;
    // accept negative sign
    const num_start = i;
    if (i < json.len and json[i] == '-') i += 1;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
    if (i == num_start) return null;
    return std.fmt.parseInt(i64, json[num_start..i], 10) catch null;
}

fn writeJsonResponse(stream: net.Stream, status: u16, body: []const u8) void {
    const status_text: []const u8 = switch (status) {
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        404 => "Not Found",
        409 => "Conflict",
        422 => "Unprocessable Entity",
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
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 49\r\n\r\n" ++
        "{\"status\":\"ok\",\"service\":\"str\",\"version\":\"0.1.0\"}";
}
fn badRequestResp() []const u8 { return "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"; }
fn notFoundResp()   []const u8 { return "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"; }

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
