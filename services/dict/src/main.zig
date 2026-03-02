//! DICT — Directory of Transactional Account Identifiers
//! Complete registry with Monolith DB + dupsort indices
//!
//! Endpoints:
//!   POST /user                   — register user (CPF/CNPJ)
//!   POST /account                — register bank account
//!   POST /key                    — register PIX key
//!   GET  /key/:value             — resolve key → account data
//!   DELETE /key/:value           — remove PIX key
//!   GET  /account/:id/keys       — list keys for an account
//!   GET  /health

const std  = @import("std");
const net  = std.net;
const mem  = std.mem;

const db_mod  = @import("db.zig");
const env_util = @import("utils/env.zig");
const builtin  = @import("builtin");

const PORT: u16             = 8081;
const MAX_REQUEST_SIZE: usize = 16384;
const DEFAULT_DB_PATH: [:0]const u8 = "dict.monolith";

// ---------------------------------------------------------------------------
// Shared context
// ---------------------------------------------------------------------------

const DictContext = struct {
    db:        db_mod.DB,
    allocator: std.mem.Allocator,
};

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port: u16 = blk: {
        const s = env_util.get("DICT_PORT") orelse break :blk PORT;
        break :blk std.fmt.parseInt(u16, s, 10) catch PORT;
    };

    const db_path: [:0]const u8 = env_util.get("DB_PATH") orelse DEFAULT_DB_PATH;

    var db = try db_mod.DB.open(db_path);
    defer db.deinit();

    var ctx = DictContext{ .db = db, .allocator = allocator };

    const address = try net.Address.parseIp("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("DICT listening on :{d}", .{port});

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

fn handleConnection(conn: net.Server.Connection, ctx: *DictContext) !void {
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
    } else if (mem.eql(u8, method, "POST") and mem.eql(u8, path, "/user")) {
        handleCreateUser(conn.stream, ctx, req);
    } else if (mem.eql(u8, method, "POST") and mem.eql(u8, path, "/account")) {
        handleCreateAccount(conn.stream, ctx, req);
    } else if (mem.eql(u8, method, "POST") and mem.eql(u8, path, "/key")) {
        handleRegisterKey(conn.stream, ctx, req);
    } else if (mem.eql(u8, method, "GET") and mem.startsWith(u8, path, "/key/")) {
        handleResolveKey(conn.stream, ctx, path["/key/".len..]);
    } else if (mem.eql(u8, method, "DELETE") and mem.startsWith(u8, path, "/key/")) {
        handleDeleteKey(conn.stream, ctx, path["/key/".len..]);
    } else if (mem.eql(u8, method, "GET") and
               mem.startsWith(u8, path, "/account/") and
               mem.endsWith(u8, path, "/keys"))
    {
        // /account/:id/keys  →  inner = UUID
        const prefix = "/account/".len;
        const suffix = "/keys".len;
        if (path.len > prefix + suffix) {
            handleGetAccountKeys(conn.stream, ctx, path[prefix .. path.len - suffix]);
        } else {
            socketWriteAll(conn.stream, badRequestResp()) catch {};
        }
    } else {
        socketWriteAll(conn.stream, notFoundResp()) catch {};
    }
}

// ---------------------------------------------------------------------------
// POST /user
// ---------------------------------------------------------------------------

fn handleCreateUser(stream: net.Stream, ctx: *DictContext, req: []const u8) void {
    const body = extractBody(req) orelse {
        socketWriteAll(stream, badRequestResp()) catch {};
        return;
    };

    const document = findJsonString(body, "document") orelse {
        writeJsonError(stream, ctx.allocator, 400, "document required");
        return;
    };
    const name = findJsonString(body, "name") orelse {
        writeJsonError(stream, ctx.allocator, 400, "name required");
        return;
    };
    const psp_id = findJsonString(body, "psp_id") orelse {
        writeJsonError(stream, ctx.allocator, 400, "psp_id required");
        return;
    };

    const doc_type: db_mod.DocType = blk: {
        if (isAllDigits(document) and document.len == 11) break :blk .cpf;
        if (isAllDigits(document) and document.len == 14) break :blk .cnpj;
        writeJsonError(stream, ctx.allocator, 422, "invalid document: CPF=11 digits CNPJ=14 digits");
        return;
    };

    const user_id = ctx.db.createUser(doc_type, document, name, psp_id) catch {
        writeJsonError(stream, ctx.allocator, 500, "Error creating user");
        return;
    };

    var uid_str: [36]u8 = undefined;
    db_mod.fmtUuid(user_id, &uid_str);

    const body_resp = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"user_id\":\"{s}\",\"document\":\"{s}\",\"name\":\"{s}\",\"psp_id\":\"{s}\"}}",
        .{ uid_str, document, name, psp_id },
    ) catch return;
    defer ctx.allocator.free(body_resp);

    writeJsonResponse(stream, 201, body_resp);
}

// ---------------------------------------------------------------------------
// POST /account
// ---------------------------------------------------------------------------

fn handleCreateAccount(stream: net.Stream, ctx: *DictContext, req: []const u8) void {
    const body = extractBody(req) orelse {
        socketWriteAll(stream, badRequestResp()) catch {};
        return;
    };

    const user_id_str    = findJsonString(body, "user_id")        orelse { writeJsonError(stream, ctx.allocator, 400, "user_id required");        return; };
    const psp_id         = findJsonString(body, "psp_id")         orelse { writeJsonError(stream, ctx.allocator, 400, "psp_id required");         return; };
    const bank_ispb      = findJsonString(body, "bank_ispb")      orelse { writeJsonError(stream, ctx.allocator, 400, "bank_ispb required");      return; };
    const agency         = findJsonString(body, "agency")         orelse { writeJsonError(stream, ctx.allocator, 400, "agency required");         return; };
    const account_number = findJsonString(body, "account_number") orelse { writeJsonError(stream, ctx.allocator, 400, "account_number required"); return; };
    const account_type_s = findJsonString(body, "account_type")   orelse { writeJsonError(stream, ctx.allocator, 400, "account_type required");   return; };

    const user_id = db_mod.parseUuid(user_id_str) catch {
        writeJsonError(stream, ctx.allocator, 400, "invalid user_id");
        return;
    };
    const account_type = db_mod.AccountType.fromString(account_type_s) orelse {
        writeJsonError(stream, ctx.allocator, 422, "invalid account_type: corrente ou poupanca");
        return;
    };

    // Verify user exists
    const user_exists = ctx.db.getUser(user_id) catch null;
    if (user_exists == null) {
        writeJsonError(stream, ctx.allocator, 404, "user not found");
        return;
    }

    const account_id = ctx.db.createAccount(user_id, psp_id, bank_ispb, agency, account_number, account_type) catch {
        writeJsonError(stream, ctx.allocator, 500, "Error creating account");
        return;
    };

    var uid_str: [36]u8 = undefined;
    var aid_str: [36]u8 = undefined;
    db_mod.fmtUuid(user_id,   &uid_str);
    db_mod.fmtUuid(account_id, &aid_str);

    const body_resp = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"account_id\":\"{s}\",\"user_id\":\"{s}\",\"psp_id\":\"{s}\"," ++
        "\"bank_ispb\":\"{s}\",\"agency\":\"{s}\",\"account_number\":\"{s}\",\"account_type\":\"{s}\"}}",
        .{ aid_str, uid_str, psp_id, bank_ispb, agency, account_number, account_type.toString() },
    ) catch return;
    defer ctx.allocator.free(body_resp);

    writeJsonResponse(stream, 201, body_resp);
}

// ---------------------------------------------------------------------------
// POST /key
// ---------------------------------------------------------------------------

fn handleRegisterKey(stream: net.Stream, ctx: *DictContext, req: []const u8) void {
    const body = extractBody(req) orelse {
        socketWriteAll(stream, badRequestResp()) catch {};
        return;
    };

    const key_value     = findJsonString(body, "key_value")  orelse { writeJsonError(stream, ctx.allocator, 400, "key_value required");  return; };
    const key_type_str  = findJsonString(body, "key_type")   orelse { writeJsonError(stream, ctx.allocator, 400, "key_type required");   return; };
    const account_id_s  = findJsonString(body, "account_id") orelse { writeJsonError(stream, ctx.allocator, 400, "account_id required"); return; };

    const key_type = db_mod.KeyType.fromString(key_type_str) orelse {
        writeJsonError(stream, ctx.allocator, 422, "invalid key_type: CPF CNPJ PHONE EMAIL RANDOM");
        return;
    };
    const account_id = db_mod.parseUuid(account_id_s) catch {
        writeJsonError(stream, ctx.allocator, 400, "invalid account_id");
        return;
    };

    // Fetch account to get user_id and psp_id
    const account = ctx.db.getAccount(account_id) catch null orelse {
        writeJsonError(stream, ctx.allocator, 404, "account not found");
        return;
    };
    const user_id = account.user_id;
    const psp_id  = db_mod.nullTermStr(&account.psp_id);

    ctx.db.registerKey(key_value, key_type, account_id, user_id, psp_id) catch |err| {
        if (err == error.KeyAlreadyExists) {
            writeJsonError(stream, ctx.allocator, 409, "PIX key already registered");
        } else {
            writeJsonError(stream, ctx.allocator, 500, "Error registering key");
        }
        return;
    };

    var aid_str: [36]u8 = undefined;
    var uid_str: [36]u8 = undefined;
    db_mod.fmtUuid(account_id, &aid_str);
    db_mod.fmtUuid(user_id,    &uid_str);

    const body_resp = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"key_value\":\"{s}\",\"key_type\":\"{s}\",\"account_id\":\"{s}\"," ++
        "\"user_id\":\"{s}\",\"psp_id\":\"{s}\"}}",
        .{ key_value, key_type.toString(), aid_str, uid_str, psp_id },
    ) catch return;
    defer ctx.allocator.free(body_resp);

    writeJsonResponse(stream, 201, body_resp);
}

// ---------------------------------------------------------------------------
// GET /key/:value
// ---------------------------------------------------------------------------

fn handleResolveKey(stream: net.Stream, ctx: *DictContext, key_value: []const u8) void {
    if (key_value.len == 0) {
        writeJsonError(stream, ctx.allocator, 400, "key_value required");
        return;
    }

    const key_rec = ctx.db.resolveKey(key_value) catch null orelse {
        writeJsonError(stream, ctx.allocator, 404, "PIX key not found");
        return;
    };

    const account = ctx.db.getAccount(key_rec.account_id) catch null orelse {
        writeJsonError(stream, ctx.allocator, 500, "internal inconsistency");
        return;
    };

    const key_type    = @as(db_mod.KeyType, @enumFromInt(key_rec.key_type));
    const account_type = @as(db_mod.AccountType, @enumFromInt(account.account_type));

    var aid_str: [36]u8 = undefined;
    var uid_str: [36]u8 = undefined;
    db_mod.fmtUuid(key_rec.account_id, &aid_str);
    db_mod.fmtUuid(key_rec.user_id,    &uid_str);

    const psp_id        = db_mod.nullTermStr(&key_rec.psp_id);
    const bank_ispb     = db_mod.nullTermStr(&account.bank_ispb);
    const agency        = db_mod.nullTermStr(&account.agency);
    const account_num   = db_mod.nullTermStr(&account.account_number);

    const body_resp = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"key_value\":\"{s}\",\"key_type\":\"{s}\",\"account_id\":\"{s}\"," ++
        "\"user_id\":\"{s}\",\"psp_id\":\"{s}\",\"bank_ispb\":\"{s}\"," ++
        "\"agency\":\"{s}\",\"account_number\":\"{s}\",\"account_type\":\"{s}\"}}",
        .{ key_value, key_type.toString(), aid_str, uid_str, psp_id,
           bank_ispb, agency, account_num, account_type.toString() },
    ) catch return;
    defer ctx.allocator.free(body_resp);

    writeJsonResponse(stream, 200, body_resp);
}

// ---------------------------------------------------------------------------
// DELETE /key/:value
// ---------------------------------------------------------------------------

fn handleDeleteKey(stream: net.Stream, ctx: *DictContext, key_value: []const u8) void {
    if (key_value.len == 0) {
        writeJsonError(stream, ctx.allocator, 400, "key_value required");
        return;
    }

    const deleted = ctx.db.deleteKey(key_value) catch {
        writeJsonError(stream, ctx.allocator, 500, "Internal error");
        return;
    };

    if (!deleted) {
        writeJsonError(stream, ctx.allocator, 404, "PIX key not found");
        return;
    }

    writeJsonResponse(stream, 200, "{\"deleted\":true}");
}

// ---------------------------------------------------------------------------
// GET /account/:id/keys
// ---------------------------------------------------------------------------

fn handleGetAccountKeys(stream: net.Stream, ctx: *DictContext, account_id_str: []const u8) void {
    const account_id = db_mod.parseUuid(account_id_str) catch {
        writeJsonError(stream, ctx.allocator, 400, "invalid account_id");
        return;
    };

    const keys = ctx.db.getKeysByAccount(ctx.allocator, account_id) catch {
        writeJsonError(stream, ctx.allocator, 500, "Internal error");
        return;
    };
    defer { for (keys) |k| ctx.allocator.free(k); ctx.allocator.free(keys); }

    // Build JSON array
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(ctx.allocator);
    buf.appendSlice(ctx.allocator, "[") catch return;
    for (keys, 0..) |key, i| {
        if (i > 0) buf.appendSlice(ctx.allocator, ",") catch return;
        buf.appendSlice(ctx.allocator, "\"") catch return;
        buf.appendSlice(ctx.allocator, key) catch return;
        buf.appendSlice(ctx.allocator, "\"") catch return;
    }
    buf.appendSlice(ctx.allocator, "]") catch return;

    var aid_str: [36]u8 = undefined;
    db_mod.fmtUuid(account_id, &aid_str);

    const body_resp = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"account_id\":\"{s}\",\"keys\":{s}}}",
        .{ aid_str, buf.items },
    ) catch return;
    defer ctx.allocator.free(body_resp);

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

fn isAllDigits(s: []const u8) bool {
    for (s) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

fn healthResp() []const u8 {
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 50\r\n\r\n" ++
        "{\"status\":\"ok\",\"service\":\"dict\",\"version\":\"0.1.0\"}";
}
fn badRequestResp() []const u8 { return "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"; }
fn notFoundResp()   []const u8 { return "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"; }
