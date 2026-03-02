//! Auth — Ed25519 JWT Authentication Service
//! Ed25519 sign/verify + Monolith DB (psp_keys, revoked_jtis)
//!
//! Endpoints:
//!   POST /token          — issue JWT for a PSP (body: {"psp_id":"psp-alpha"})
//!   POST /validate       — validate JWT (body: {"token":"..."})
//!   GET  /pubkey/:psp_id — return registered PSP public key
//!   GET  /health         — health check
//!   GET  /metrics        — Prometheus text (stub)

const std = @import("std");
const net = std.net;
const Ed25519 = std.crypto.sign.Ed25519;

const db_mod       = @import("store/db.zig");
const signer_mod   = @import("jwt/signer.zig");
const verifier_mod = @import("jwt/verifier.zig");
const registry_mod = @import("keys/registry.zig");
const claims_mod   = @import("jwt/claims.zig");
const env_util     = @import("utils/env.zig");

const PORT: u16 = 8084;
const TOKEN_TTL: i64 = 900; // 15 minutes
const MAX_REQUEST_SIZE: usize = 8192;
const DEFAULT_DB_PATH: [:0]const u8 = "auth.monolith";

// -------------------------------------------------------------------------
// Shared server state
// -------------------------------------------------------------------------

/// Context shared across handlers (passed by pointer).
const AuthContext = struct {
    keypair: Ed25519.KeyPair,
    db: db_mod.DB,
    allocator: std.mem.Allocator,
};

// -------------------------------------------------------------------------
// Entry point
// -------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Port from env var
    const port: u16 = blk: {
        const env_port = env_util.get("AUTH_PORT") orelse break :blk PORT;
        break :blk std.fmt.parseInt(u16, env_port, 10) catch PORT;
    };

    // 2. DB path from env var (null-terminated for Monolith)
    const db_path: [:0]const u8 = if (env_util.get("DB_PATH")) |p|
        @ptrCast(p)
    else
        DEFAULT_DB_PATH;

    // 3. Load or generate Auth service keypair
    const keypair = loadOrGenerateKeypair();
    const pubkey_hex = std.fmt.bytesToHex(keypair.public_key.bytes, .lower);
    std.log.info("Auth public key: {s}", .{pubkey_hex});

    // 4. Open Monolith DB
    var db = try db_mod.DB.open(db_path);
    defer db.deinit();

    // 5. Seed PSP keys from env vars
    try registry_mod.seedFromEnv(&db);

    // 6. Shared context
    var ctx = AuthContext{
        .keypair = keypair,
        .db = db,
        .allocator = allocator,
    };

    // 7. Start TCP server
    const address = try net.Address.parseIp("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("Auth service listening on :{d}", .{port});

    // Accept loop — single-threaded
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

// -------------------------------------------------------------------------
// Keypair loading
// -------------------------------------------------------------------------

/// Load or generate Ed25519 keypair for the Auth service.
/// Tries to read a 32-byte raw seed from AUTH_PRIVATE_KEY_PATH.
/// Falls back to in-memory generation if not found.
fn loadOrGenerateKeypair() Ed25519.KeyPair {
    const path = env_util.get("AUTH_PRIVATE_KEY_PATH") orelse "/run/secrets/auth-privkey";

    if (std.fs.cwd().openFile(path, .{})) |file| {
        defer file.close();
        var seed: [32]u8 = undefined;
        const n = file.read(&seed) catch 0;
        if (n == 32) {
            if (Ed25519.KeyPair.generateDeterministic(seed)) |kp| {
                std.log.info("Keypair loaded from: {s}", .{path});
                return kp;
            } else |_| {}
        }
    } else |_| {}

    // Generate new random keypair
    const kp = Ed25519.KeyPair.generate();
    std.log.warn("Keypair generated in memory (not persisted). Set AUTH_PRIVATE_KEY_PATH.", .{});
    return kp;
}

// -------------------------------------------------------------------------
// Main HTTP handler
// -------------------------------------------------------------------------

fn handleConnection(conn: net.Server.Connection, ctx: *AuthContext) !void {
    var buf: [MAX_REQUEST_SIZE]u8 = undefined;
    const n = conn.stream.read(&buf) catch return;
    if (n == 0) return;

    const req = buf[0..n];
    const method, const path = parseRequestLine(req) orelse {
        _ = conn.stream.write(badRequestResp()) catch {};
        return;
    };

    if (std.mem.eql(u8, path, "/health")) {
        _ = conn.stream.write(healthResponse()) catch {};
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/token")) {
        handleToken(conn.stream, ctx, req);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/validate")) {
        handleValidate(conn.stream, ctx, req);
    } else if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/pubkey/")) {
        handlePubkey(conn.stream, ctx, path["/pubkey/".len..]);
    } else if (std.mem.eql(u8, path, "/metrics")) {
        _ = conn.stream.write(metricsResponse()) catch {};
    } else {
        _ = conn.stream.write(notFoundResp()) catch {};
    }
}

// -------------------------------------------------------------------------
// Handlers
// -------------------------------------------------------------------------

/// POST /token — body: {"psp_id":"psp-alpha"}
fn handleToken(stream: net.Stream, ctx: *AuthContext, req: []const u8) void {
    const body = extractBody(req) orelse {
        _ = stream.write(badRequestResp()) catch {};
        return;
    };

    const psp_id = findJsonString(body, "psp_id") orelse {
        writeJsonError(stream, ctx.allocator, 400, "psp_id required");
        return;
    };

    // Verify PSP is registered
    const registered = ctx.db.pspExists(psp_id) catch false;
    if (!registered) {
        writeJsonError(stream, ctx.allocator, 401, "PSP not registered");
        return;
    }

    // Issue JWT
    const signed = signer_mod.sign(ctx.allocator, psp_id, ctx.keypair, TOKEN_TTL) catch {
        writeJsonError(stream, ctx.allocator, 500, "Failed to sign token");
        return;
    };
    defer ctx.allocator.free(signed.token);

    const resp_body = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"token\":\"{s}\",\"expires_in\":{d},\"token_type\":\"Bearer\"}}",
        .{ signed.token, TOKEN_TTL },
    ) catch return;
    defer ctx.allocator.free(resp_body);

    writeJsonResponse(stream, 200, resp_body);
}

/// POST /validate — body: {"token":"<jwt>"}
fn handleValidate(stream: net.Stream, ctx: *AuthContext, req: []const u8) void {
    const body = extractBody(req) orelse {
        _ = stream.write(badRequestResp()) catch {};
        return;
    };

    const token = findJsonString(body, "token") orelse {
        writeJsonError(stream, ctx.allocator, 400, "token required");
        return;
    };

    var result = verifier_mod.verify(
        ctx.allocator,
        token,
        ctx.keypair.public_key,
        &ctx.db,
    ) catch |err| {
        const msg: []const u8 = switch (err) {
            verifier_mod.VerifyError.TokenExpired    => "Token expired",
            verifier_mod.VerifyError.TokenRevoked    => "Token revoked",
            verifier_mod.VerifyError.InvalidSignature => "Invalid signature",
            verifier_mod.VerifyError.MalformedToken  => "Malformed token",
            else                                     => "Validation error",
        };
        writeJsonError(stream, ctx.allocator, 401, msg);
        return;
    };
    defer result.deinit();

    const resp_body = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"valid\":true,\"psp_id\":\"{s}\",\"expires_at\":{d}}}",
        .{ result.psp_id, result.expires_at },
    ) catch return;
    defer ctx.allocator.free(resp_body);

    writeJsonResponse(stream, 200, resp_body);
}

/// GET /pubkey/:psp_id — returns the PSP public key in hex
fn handlePubkey(stream: net.Stream, ctx: *AuthContext, psp_id: []const u8) void {
    if (psp_id.len == 0) {
        writeJsonError(stream, ctx.allocator, 400, "psp_id required");
        return;
    }

    const pubkey = ctx.db.getPspKey(psp_id) catch {
        writeJsonError(stream, ctx.allocator, 500, "Internal error");
        return;
    } orelse {
        writeJsonError(stream, ctx.allocator, 404, "PSP not found");
        return;
    };

    const pubkey_hex = std.fmt.bytesToHex(pubkey, .lower);
    const resp_body = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"psp_id\":\"{s}\",\"public_key_hex\":\"{s}\",\"algorithm\":\"Ed25519\"}}",
        .{ psp_id, pubkey_hex },
    ) catch return;
    defer ctx.allocator.free(resp_body);

    writeJsonResponse(stream, 200, resp_body);
}

// -------------------------------------------------------------------------
// HTTP utilities
// -------------------------------------------------------------------------

/// Parse "METHOD /path HTTP/1.1" from the first line. Returns {method, path}.
fn parseRequestLine(req: []const u8) ?struct { []const u8, []const u8 } {
    const line_end = std.mem.indexOfScalar(u8, req, '\r') orelse
        std.mem.indexOfScalar(u8, req, '\n') orelse return null;
    const line = req[0..line_end];

    var it = std.mem.splitScalar(u8, line, ' ');
    const method = it.next() orelse return null;
    const path_full = it.next() orelse return null;
    // Strip query string
    const path = if (std.mem.indexOfScalar(u8, path_full, '?')) |qi|
        path_full[0..qi]
    else
        path_full;

    return .{ method, path };
}

/// Extract the HTTP body (after \r\n\r\n).
fn extractBody(req: []const u8) ?[]const u8 {
    const sep = "\r\n\r\n";
    const pos = std.mem.indexOf(u8, req, sep) orelse return null;
    const body = req[pos + sep.len ..];
    if (body.len == 0) return null;
    return body;
}

/// Locate a JSON string value: "key":"value" → value (slice into json).
fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
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

fn writeJsonResponse(stream: net.Stream, status: u16, body: []const u8) void {
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 {d} OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
        .{ status, body.len },
    ) catch return;
    _ = stream.write(header) catch {};
    _ = stream.write(body) catch {};
}

fn writeJsonError(stream: net.Stream, allocator: std.mem.Allocator, status: u16, msg: []const u8) void {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg}) catch return;
    defer allocator.free(body);
    writeJsonResponse(stream, status, body);
}

fn healthResponse() []const u8 {
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 48\r\n\r\n" ++
        "{\"status\":\"ok\",\"service\":\"auth\",\"version\":\"0.1.0\"}";
}

fn metricsResponse() []const u8 {
    return "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 28\r\n\r\n" ++
        "# auth metrics placeholder\n";
}

fn badRequestResp() []const u8 {
    return "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
}

fn notFoundResp() []const u8 {
    return "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
}
