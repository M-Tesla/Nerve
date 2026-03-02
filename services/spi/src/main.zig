//! SPI — Instant Payment System (Sistema de Pagamentos Instantâneos)
//! Full PIX orchestration + Monolith DB
//!
//! Endpoints:
//!   POST /pix/initiate     — initiate a PIX transfer
//!   GET  /pix/status/:id   — query a transaction state
//!   GET  /metrics          — Prometheus metrics
//!   GET  /health

const std  = @import("std");
const net  = std.net;
const mem  = std.mem;

const db_mod     = @import("db.zig");
const sm         = @import("state_machine.zig");
const http_cl    = @import("http_client.zig");
const nats_mod   = @import("nats.zig");
const env_util   = @import("utils/env.zig");
const builtin    = @import("builtin");

const PORT: u16               = 8080;
const MAX_REQUEST_SIZE: usize  = 32768;
const DEFAULT_DB_PATH: [:0]const u8 = "spi.monolith";

// ---------------------------------------------------------------------------
// Shared context
// ---------------------------------------------------------------------------

const SpiContext = struct {
    db:             db_mod.DB,
    allocator:      std.mem.Allocator,
    dict_port:      u16,   // default: 8081
    str_port:       u16,   // default: 8082
    psp_alpha_port: u16,   // default: 9080
    psp_beta_port:  u16,   // default: 9090
    nats:           nats_mod.Client,
};

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port: u16 = blk: {
        const s = env_util.get("SPI_PORT") orelse break :blk PORT;
        break :blk std.fmt.parseInt(u16, s, 10) catch PORT;
    };

    const db_path: [:0]const u8 = env_util.get("DB_PATH") orelse DEFAULT_DB_PATH;

    const dict_port: u16 = blk: {
        const s = env_util.get("DICT_PORT") orelse break :blk 8081;
        break :blk std.fmt.parseInt(u16, s, 10) catch 8081;
    };
    const str_port: u16 = blk: {
        const s = env_util.get("STR_PORT") orelse break :blk 8082;
        break :blk std.fmt.parseInt(u16, s, 10) catch 8082;
    };
    const psp_alpha_port: u16 = blk: {
        const s = env_util.get("PSP_ALPHA_PORT") orelse break :blk 9080;
        break :blk std.fmt.parseInt(u16, s, 10) catch 9080;
    };
    const psp_beta_port: u16 = blk: {
        const s = env_util.get("PSP_BETA_PORT") orelse break :blk 9090;
        break :blk std.fmt.parseInt(u16, s, 10) catch 9090;
    };
    const nats_port: u16 = blk: {
        const s = env_util.get("NATS_PORT") orelse break :blk 4222;
        break :blk std.fmt.parseInt(u16, s, 10) catch 4222;
    };

    var db = try db_mod.DB.open(db_path);
    defer db.deinit();

    var nats = nats_mod.Client.connect(allocator, "127.0.0.1", nats_port);
    defer nats.deinit();

    var ctx = SpiContext{
        .db             = db,
        .allocator      = allocator,
        .dict_port      = dict_port,
        .str_port       = str_port,
        .psp_alpha_port = psp_alpha_port,
        .psp_beta_port  = psp_beta_port,
        .nats           = nats,
    };

    const address = try net.Address.parseIp("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("SPI listening on :{d}", .{port});

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
// Dispatcher
// ---------------------------------------------------------------------------

fn handleConnection(conn: net.Server.Connection, ctx: *SpiContext) !void {
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
    } else if (mem.eql(u8, path, "/metrics")) {
        handleMetrics(conn.stream, ctx);
    } else if (mem.eql(u8, method, "POST") and mem.eql(u8, path, "/pix/initiate")) {
        handleInitiate(conn.stream, ctx, req);
    } else if (mem.eql(u8, method, "GET") and mem.startsWith(u8, path, "/pix/status/")) {
        handleStatus(conn.stream, ctx, path["/pix/status/".len..]);
    } else {
        socketWriteAll(conn.stream, notFoundResp()) catch {};
    }
}

// ---------------------------------------------------------------------------
// POST /pix/initiate — full PIX flow
// ---------------------------------------------------------------------------

fn handleInitiate(stream: net.Stream, ctx: *SpiContext, req: []const u8) void {
    const body = extractBody(req) orelse {
        socketWriteAll(stream, badRequestResp()) catch {};
        return;
    };

    const idempotency_key = findStr(body, "idempotency_key") orelse {
        writeErr(stream, ctx.allocator, 400, "idempotency_key required");
        return;
    };
    const payer_key = findStr(body, "payer_key") orelse {
        writeErr(stream, ctx.allocator, 400, "payer_key required");
        return;
    };
    const payee_key = findStr(body, "payee_key") orelse {
        writeErr(stream, ctx.allocator, 400, "payee_key required");
        return;
    };
    const amount = findInt(body, "amount_centavos") orelse {
        writeErr(stream, ctx.allocator, 400, "amount_centavos required");
        return;
    };
    if (amount <= 0) {
        writeErr(stream, ctx.allocator, 422, "amount_centavos must be positive");
        return;
    }
    const description = findStr(body, "description") orelse "";

    // Idempotency hash = SHA-256(idempotency_key)
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var idem_hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(idempotency_key, &idem_hash, .{});

    // Create or retrieve transaction (atomic)
    const result = ctx.db.createOrGet(idem_hash, amount, payer_key, payee_key, description) catch {
        writeErr(stream, ctx.allocator, 500, "Failed to create transaction");
        return;
    };

    var tx_str: [36]u8 = undefined;
    db_mod.fmtUuid(result.tx_id, &tx_str);

    if (!result.is_new) {
        // Idempotent response — return current state
        const tx = ctx.db.getTransaction(result.tx_id) catch null orelse {
            writeErr(stream, ctx.allocator, 500, "Failed to fetch transaction");
            return;
        };
        const state = @as(db_mod.TxState, @enumFromInt(tx.state));
        const resp_body = std.fmt.allocPrint(ctx.allocator,
            "{{\"tx_id\":\"{s}\",\"status\":\"{s}\",\"amount_centavos\":{d},\"idempotent\":true}}",
            .{ tx_str, state.toString(), tx.amount_centavos },
        ) catch return;
        defer ctx.allocator.free(resp_body);
        writeResp(stream, 200, resp_body);
        return;
    }

    // Execute synchronous PIX flow
    orchestrate(ctx, result.tx_id, payer_key, payee_key, amount);

    // Return final state
    const tx = ctx.db.getTransaction(result.tx_id) catch null orelse {
        writeErr(stream, ctx.allocator, 500, "Failed to fetch transaction");
        return;
    };
    const state = @as(db_mod.TxState, @enumFromInt(tx.state));
    const http_status: u16 = switch (state) {
        .settled  => 200,
        .reversed => 422,
        .failed   => 422,
        else      => 202,
    };
    const resp_body = std.fmt.allocPrint(ctx.allocator,
        "{{\"tx_id\":\"{s}\",\"status\":\"{s}\",\"amount_centavos\":{d}}}",
        .{ tx_str, state.toString(), amount },
    ) catch return;
    defer ctx.allocator.free(resp_body);
    writeResp(stream, http_status, resp_body);
}

// ---------------------------------------------------------------------------
// GET /pix/status/:id
// ---------------------------------------------------------------------------

fn handleStatus(stream: net.Stream, ctx: *SpiContext, tx_id_str: []const u8) void {
    const tx_id = db_mod.parseUuid(tx_id_str) catch {
        writeErr(stream, ctx.allocator, 400, "invalid tx_id");
        return;
    };
    const tx = ctx.db.getTransaction(tx_id) catch null orelse {
        writeErr(stream, ctx.allocator, 404, "transaction not found");
        return;
    };
    const state = @as(db_mod.TxState, @enumFromInt(tx.state));
    const payer_key  = db_mod.nullTermStr(&tx.payer_key);
    const payee_key  = db_mod.nullTermStr(&tx.payee_key);
    const payer_psp  = db_mod.nullTermStr(&tx.payer_psp_id);
    const payee_psp  = db_mod.nullTermStr(&tx.payee_psp_id);

    const resp_body = std.fmt.allocPrint(ctx.allocator,
        "{{\"tx_id\":\"{s}\",\"status\":\"{s}\",\"amount_centavos\":{d}," ++
        "\"payer_key\":\"{s}\",\"payee_key\":\"{s}\"," ++
        "\"payer_psp_id\":\"{s}\",\"payee_psp_id\":\"{s}\"," ++
        "\"created_at\":{d},\"updated_at\":{d}}}",
        .{ tx_id_str, state.toString(), tx.amount_centavos,
           payer_key, payee_key, payer_psp, payee_psp,
           tx.created_at, tx.updated_at },
    ) catch return;
    defer ctx.allocator.free(resp_body);
    writeResp(stream, 200, resp_body);
}

// ---------------------------------------------------------------------------
// GET /metrics — basic Prometheus
// ---------------------------------------------------------------------------

fn handleMetrics(stream: net.Stream, ctx: *SpiContext) void {
    const stats = ctx.db.getStats() catch db_mod.DB.Stats{};

    var body_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        "# HELP nerve_pix_transactions_total Total PIX transactions by state\n" ++
        "# TYPE nerve_pix_transactions_total counter\n" ++
        "nerve_pix_transactions_total{{state=\"settled\"}}  {d}\n" ++
        "nerve_pix_transactions_total{{state=\"failed\"}}   {d}\n" ++
        "nerve_pix_transactions_total{{state=\"reversed\"}} {d}\n" ++
        "nerve_pix_transactions_total{{state=\"pending\"}}  {d}\n" ++
        "# HELP nerve_spi_up SPI service up\n" ++
        "# TYPE nerve_spi_up gauge\n" ++
        "nerve_spi_up 1\n",
        .{ stats.settled, stats.failed, stats.reversed, stats.pending },
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
// PIX orchestration — synchronous full flow
// ---------------------------------------------------------------------------

fn orchestrate(ctx: *SpiContext, tx_id: [16]u8, payer_key: []const u8, payee_key: []const u8, amount: i64) void {
    var tx_str: [36]u8 = undefined;
    db_mod.fmtUuid(tx_id, &tx_str);

    // ── Step 1: DICT lookup payer key ──────────────────────────────────────
    const payer_path = std.fmt.allocPrint(ctx.allocator, "/key/{s}", .{payer_key}) catch {
        fail(ctx, tx_id, "OOM on payer path");
        return;
    };
    defer ctx.allocator.free(payer_path);

    var payer_resp = http_cl.get(ctx.allocator, ctx.dict_port, payer_path) catch {
        fail(ctx, tx_id, "DICT unreachable (payer)");
        return;
    };
    defer payer_resp.deinit();

    if (payer_resp.status != 200) {
        fail(ctx, tx_id, "payer PIX key not found");
        return;
    }
    const payer_psp_id      = http_cl.jsonString(payer_resp.body, "psp_id")     orelse { fail(ctx, tx_id, "DICT: payer psp_id missing");      return; };
    const payer_account_str = http_cl.jsonString(payer_resp.body, "account_id") orelse { fail(ctx, tx_id, "DICT: payer account_id missing");  return; };
    const payer_account_id  = db_mod.parseUuid(payer_account_str) catch { fail(ctx, tx_id, "DICT: payer account_id invalid"); return; };

    // ── Step 2: DICT lookup payee key ─────────────────────────────────────
    const payee_path = std.fmt.allocPrint(ctx.allocator, "/key/{s}", .{payee_key}) catch {
        fail(ctx, tx_id, "OOM on payee path");
        return;
    };
    defer ctx.allocator.free(payee_path);

    var payee_resp = http_cl.get(ctx.allocator, ctx.dict_port, payee_path) catch {
        fail(ctx, tx_id, "DICT unreachable (payee)");
        return;
    };
    defer payee_resp.deinit();

    if (payee_resp.status != 200) {
        fail(ctx, tx_id, "payee PIX key not found");
        return;
    }
    const payee_psp_id      = http_cl.jsonString(payee_resp.body, "psp_id")     orelse { fail(ctx, tx_id, "DICT: payee psp_id missing");      return; };
    const payee_account_str = http_cl.jsonString(payee_resp.body, "account_id") orelse { fail(ctx, tx_id, "DICT: payee account_id missing");  return; };
    const payee_account_id  = db_mod.parseUuid(payee_account_str) catch { fail(ctx, tx_id, "DICT: payee account_id invalid"); return; };

    // ── Step 3: STR reserve ───────────────────────────────────────────────
    const reserve_body = std.fmt.allocPrint(ctx.allocator,
        "{{\"psp_id\":\"{s}\",\"amount_centavos\":{d},\"pix_txn_id\":\"{s}\"}}",
        .{ payer_psp_id, amount, tx_str },
    ) catch { fail(ctx, tx_id, "OOM reserve body"); return; };
    defer ctx.allocator.free(reserve_body);

    var reserve_resp = http_cl.post(ctx.allocator, ctx.str_port, "/reserve", reserve_body) catch {
        fail(ctx, tx_id, "STR unreachable (reserve)");
        return;
    };
    defer reserve_resp.deinit();

    if (reserve_resp.status != 201) {
        fail(ctx, tx_id, "STR reserve failed (insufficient balance or PSP not registered)");
        return;
    }
    const res_id_str = http_cl.jsonString(reserve_resp.body, "reservation_id") orelse {
        fail(ctx, tx_id, "STR: reservation_id missing");
        return;
    };
    const reservation_id = db_mod.parseUuid(res_id_str) catch {
        fail(ctx, tx_id, "STR: reservation_id invalid");
        return;
    };

    // ── Step 4: Update DB → RESERVED ──────────────────────────────────────
    ctx.db.setReserved(tx_id, reservation_id, payer_psp_id, payee_psp_id, payer_account_id, payee_account_id) catch |err| {
        // Reserve created in STR but not persisted in DB — critical, must reverse
        std.log.err("SPI: setReserved failed ({}) — reversing STR", .{err});
        doReverse(ctx, tx_id, res_id_str);
        return;
    };

    // ── Step 5: Credit payee PSP ──────────────────────────────────────────
    const payee_port = pspPort(ctx, payee_psp_id);
    if (payee_port == 0) {
        std.log.err("SPI: unknown PSP '{s}' — reversing", .{payee_psp_id});
        doReverse(ctx, tx_id, res_id_str);
        return;
    }

    const credit_body = std.fmt.allocPrint(ctx.allocator,
        "{{\"tx_id\":\"{s}\",\"payee_key\":\"{s}\"," ++
        "\"amount_centavos\":{d},\"payer_psp_id\":\"{s}\"}}",
        .{ tx_str, payee_key, amount, payer_psp_id },
    ) catch { doReverse(ctx, tx_id, res_id_str); return; };
    defer ctx.allocator.free(credit_body);

    var credit_resp = http_cl.post(ctx.allocator, payee_port, "/credit", credit_body) catch {
        std.log.warn("SPI: payee PSP /credit unreachable — reversing", .{});
        doReverse(ctx, tx_id, res_id_str);
        return;
    };
    defer credit_resp.deinit();

    if (credit_resp.status != 200 and credit_resp.status != 201) {
        std.log.warn("SPI: payee PSP /credit returned {d} — reversing", .{credit_resp.status});
        doReverse(ctx, tx_id, res_id_str);
        return;
    }

    // ── Step 6: STR settle ────────────────────────────────────────────────
    const settle_body = std.fmt.allocPrint(ctx.allocator,
        "{{\"reservation_id\":\"{s}\"}}",
        .{res_id_str},
    ) catch { doReverse(ctx, tx_id, res_id_str); return; };
    defer ctx.allocator.free(settle_body);

    var settle_resp = http_cl.post(ctx.allocator, ctx.str_port, "/settle", settle_body) catch {
        std.log.err("SPI: STR settle failed — reversing", .{});
        doReverse(ctx, tx_id, res_id_str);
        return;
    };
    defer settle_resp.deinit();

    if (settle_resp.status != 200) {
        std.log.err("SPI: STR settle returned {d} — reversing", .{settle_resp.status});
        doReverse(ctx, tx_id, res_id_str);
        return;
    }

    // ── SETTLED ───────────────────────────────────────────────────────────
    ctx.db.updateState(tx_id, .settled) catch {};

    // Publish rich event to BACEN (payer/payee/amount for net settlement)
    const settled_json = std.fmt.allocPrint(ctx.allocator,
        "{{\"tx_id\":\"{s}\",\"payer_psp\":\"{s}\",\"payee_psp\":\"{s}\"," ++
        "\"amount_centavos\":{d},\"ts\":{d}}}",
        .{ tx_str, payer_psp_id, payee_psp_id, amount, std.time.milliTimestamp() },
    ) catch null;
    if (settled_json) |json| {
        ctx.nats.publish("pix.settled", json);
        ctx.allocator.free(json);
    } else {
        ctx.nats.publish("pix.settled", &tx_str);
    }
    std.log.info("PIX SETTLED tx={s} amount={d}", .{ tx_str, amount });
}

/// Attempt to reverse the STR reservation and mark transaction as REVERSED.
fn doReverse(ctx: *SpiContext, tx_id: [16]u8, res_id_str: []const u8) void {
    const rev_body = std.fmt.allocPrint(ctx.allocator,
        "{{\"reservation_id\":\"{s}\"}}",
        .{res_id_str},
    ) catch {
        ctx.db.updateState(tx_id, .reversed) catch {};
        return;
    };
    defer ctx.allocator.free(rev_body);

    _ = http_cl.post(ctx.allocator, ctx.str_port, "/reverse", rev_body) catch {};
    ctx.db.updateState(tx_id, .reversed) catch {};

    var tx_str: [36]u8 = undefined;
    db_mod.fmtUuid(tx_id, &tx_str);

    // Rich event for BACEN
    const rev_json = std.fmt.allocPrint(ctx.allocator,
        "{{\"tx_id\":\"{s}\",\"event\":\"reversed\",\"ts\":{d}}}",
        .{ tx_str, std.time.milliTimestamp() },
    ) catch null;
    if (rev_json) |json| {
        ctx.nats.publish("pix.reversed", json);
        ctx.allocator.free(json);
    } else {
        ctx.nats.publish("pix.reversed", &tx_str);
    }
    std.log.info("PIX REVERSED tx={s}", .{tx_str});
}

/// Mark transaction as FAILED and log the reason.
fn fail(ctx: *SpiContext, tx_id: [16]u8, reason: []const u8) void {
    ctx.db.updateState(tx_id, .failed) catch {};
    var tx_str: [36]u8 = undefined;
    db_mod.fmtUuid(tx_id, &tx_str);
    std.log.warn("PIX FAILED tx={s} reason={s}", .{ tx_str, reason });
}

fn pspPort(ctx: *SpiContext, psp_id: []const u8) u16 {
    if (mem.eql(u8, psp_id, "psp-alpha")) return ctx.psp_alpha_port;
    if (mem.eql(u8, psp_id, "psp-beta"))  return ctx.psp_beta_port;
    return 0;
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

fn findStr(json: []const u8, key: []const u8) ?[]const u8 {
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

fn findInt(json: []const u8, key: []const u8) ?i64 {
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

fn writeResp(stream: net.Stream, status: u16, body: []const u8) void {
    const status_text: []const u8 = switch (status) {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        400 => "Bad Request",
        404 => "Not Found",
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

fn writeErr(stream: net.Stream, allocator: std.mem.Allocator, status: u16, msg: []const u8) void {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg}) catch return;
    defer allocator.free(body);
    writeResp(stream, status, body);
}

fn healthResp() []const u8 {
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 49\r\n\r\n" ++
        "{\"status\":\"ok\",\"service\":\"spi\",\"version\":\"0.1.0\"}";
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

// ---------------------------------------------------------------------------
// Tests — include modules to collect their tests
// ---------------------------------------------------------------------------

test {
    _ = @import("db.zig");
    _ = @import("state_machine.zig");
}

test "health response not empty" {
    try std.testing.expect(healthResp().len > 0);
}

test "findStr extracts JSON field" {
    const json = "{\"psp_id\":\"psp-alpha\",\"amount\":1000}";
    try std.testing.expectEqualStrings("psp-alpha", findStr(json, "psp_id").?);
}

test "findInt extracts JSON integer" {
    const json = "{\"amount_centavos\": 5000,\"other\":\"x\"}";
    try std.testing.expectEqual(@as(i64, 5000), findInt(json, "amount_centavos").?);
}
