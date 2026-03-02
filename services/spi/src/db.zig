//! SPI DB — Monolith wrapper for the Instant Payment System
//!
//! DBIs:
//!   pix_transactions — key: tx_id [16]u8          value: PixTransaction
//!   idempotency      — key: sha256_hash [32]u8    value: tx_id [16]u8
//!   spi_meta         — reserved for future use

const std = @import("std");
const m   = @import("monolith");

// ---------------------------------------------------------------------------
// PIX transaction state
// ---------------------------------------------------------------------------

pub const TxState = enum(u8) {
    pending  = 0,  // created, waiting for DICT + STR
    reserved = 1,  // STR reserved, waiting for PSP credit
    settled  = 2,  // settled — PSP credited + STR settled
    reversed = 3,  // reversed — PSP credit failed + STR reversed
    failed   = 4,  // fatal failure (DICT/STR unavailable, insufficient balance)

    pub fn toString(self: TxState) []const u8 {
        return switch (self) {
            .pending  => "PENDING",
            .reserved => "RESERVED",
            .settled  => "SETTLED",
            .reversed => "REVERSED",
            .failed   => "FAILED",
        };
    }
};

// ---------------------------------------------------------------------------
// Transaction record (extern struct — C layout for serialization/deserialization)
// ---------------------------------------------------------------------------

pub const PixTransaction = extern struct {
    state:            u8,
    _pad:             [7]u8,
    amount_centavos:  i64,
    payer_key:        [128]u8,  // payer PIX key, null-padded
    payee_key:        [128]u8,  // payee/receiver PIX key, null-padded
    payer_psp_id:     [16]u8,   // payer PSP (filled at RESERVED)
    payee_psp_id:     [16]u8,   // payee/receiver PSP (filled at RESERVED)
    payer_account_id: [16]u8,   // DICT UUID bytes (filled at RESERVED)
    payee_account_id: [16]u8,   // DICT UUID bytes (filled at RESERVED)
    reservation_id:   [16]u8,   // STR UUID bytes (filled at RESERVED)
    created_at:       i64,
    updated_at:       i64,
    idempotency_hash: [32]u8,   // SHA-256(idempotency_key)
    description:      [256]u8,  // null-padded
};

// ---------------------------------------------------------------------------
// DB
// ---------------------------------------------------------------------------

pub const DB = struct {
    env: m.Environment,

    pub fn open(path: [:0]const u8) !DB {
        var env = try m.Environment.open(path, .{ .liforeclaim = true }, 4, 64 * 1024 * 1024);
        errdefer env.close();

        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        _ = try txn.openDbi("pix_transactions", .{ .create = true });
        _ = try txn.openDbi("idempotency",      .{ .create = true });
        _ = try txn.openDbi("spi_meta",         .{ .create = true });
        try txn.commit();

        return .{ .env = env };
    }

    pub fn deinit(self: *DB) void {
        self.env.close();
    }

    // -----------------------------------------------------------------------
    // Atomic transaction creation with idempotency
    // -----------------------------------------------------------------------

    /// Atomically: checks idempotency and creates new PENDING transaction.
    /// If `idempotency_hash` already exists → returns { tx_id=existing, is_new=false }.
    /// If not exists → creates transaction and returns { tx_id=new, is_new=true }.
    pub fn createOrGet(
        self: *DB,
        idempotency_hash: [32]u8,
        amount_centavos: i64,
        payer_key: []const u8,
        payee_key: []const u8,
        description: []const u8,
    ) !struct { tx_id: [16]u8, is_new: bool } {
        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();

        const dbi_tx   = try txn.openDbi("pix_transactions", .{});
        const dbi_idem = try txn.openDbi("idempotency",      .{});

        // Check idempotency
        if (try txn.get(dbi_idem, &idempotency_hash)) |existing| {
            if (existing.len >= 16) {
                var existing_id: [16]u8 = undefined;
                @memcpy(&existing_id, existing[0..16]);
                try txn.commit();
                return .{ .tx_id = existing_id, .is_new = false };
            }
        }

        // New transaction
        const tx_id = generateUuid();
        const now   = std.time.timestamp();

        var rec = PixTransaction{
            .state            = @intFromEnum(TxState.pending),
            ._pad             = [_]u8{0} ** 7,
            .amount_centavos  = amount_centavos,
            .payer_key        = [_]u8{0} ** 128,
            .payee_key        = [_]u8{0} ** 128,
            .payer_psp_id     = [_]u8{0} ** 16,
            .payee_psp_id     = [_]u8{0} ** 16,
            .payer_account_id = [_]u8{0} ** 16,
            .payee_account_id = [_]u8{0} ** 16,
            .reservation_id   = [_]u8{0} ** 16,
            .created_at       = now,
            .updated_at       = now,
            .idempotency_hash = idempotency_hash,
            .description      = [_]u8{0} ** 256,
        };
        const pkn = @min(payer_key.len, 127);
        const ykn = @min(payee_key.len, 127);
        const dn  = @min(description.len, 255);
        @memcpy(rec.payer_key[0..pkn],   payer_key[0..pkn]);
        @memcpy(rec.payee_key[0..ykn],   payee_key[0..ykn]);
        @memcpy(rec.description[0..dn],  description[0..dn]);

        try txn.put(dbi_tx,   &tx_id,            std.mem.asBytes(&rec), .{});
        try txn.put(dbi_idem, &idempotency_hash,  &tx_id,               .{});
        try txn.commit();

        return .{ .tx_id = tx_id, .is_new = true };
    }

    pub fn getTransaction(self: *DB, tx_id: [16]u8) !?PixTransaction {
        var txn = try m.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("pix_transactions", .{});
        const val = try txn.get(dbi, &tx_id) orelse return null;
        if (val.len < @sizeOf(PixTransaction)) return null;
        return std.mem.bytesAsValue(PixTransaction, val[0..@sizeOf(PixTransaction)]).*;
    }

    /// Updates only the state of a transaction.
    pub fn updateState(self: *DB, tx_id: [16]u8, new_state: TxState) !void {
        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("pix_transactions", .{});
        const val = try txn.get(dbi, &tx_id) orelse return error.TxNotFound;
        if (val.len < @sizeOf(PixTransaction)) return error.TxNotFound;
        var rec = std.mem.bytesAsValue(PixTransaction, val[0..@sizeOf(PixTransaction)]).*;
        rec.state      = @intFromEnum(new_state);
        rec.updated_at = std.time.timestamp();
        try txn.put(dbi, &tx_id, std.mem.asBytes(&rec), .{});
        try txn.commit();
    }

    // -----------------------------------------------------------------------
    // Metrics
    // -----------------------------------------------------------------------

    pub const Stats = struct {
        total:    u64 = 0,
        settled:  u64 = 0,
        failed:   u64 = 0,
        reversed: u64 = 0,
        pending:  u64 = 0,
    };

    /// Scans all transactions and returns counts by state.
    pub fn getStats(self: *DB) !Stats {
        var txn = try m.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("pix_transactions", .{});
        var cursor = try txn.cursor(dbi);
        defer cursor.close();

        var stats = Stats{};
        var kv_opt = try cursor.first();
        while (kv_opt) |kv| {
            if (kv.val.len > 0) {
                stats.total += 1;
                switch (kv.val[0]) {
                    @intFromEnum(TxState.settled)  => stats.settled  += 1,
                    @intFromEnum(TxState.failed)   => stats.failed   += 1,
                    @intFromEnum(TxState.reversed) => stats.reversed += 1,
                    @intFromEnum(TxState.pending),
                    @intFromEnum(TxState.reserved) => stats.pending  += 1,
                    else => {},
                }
            }
            kv_opt = try cursor.next();
        }
        return stats;
    }

    /// Updates the transaction with STR reservation data and DICT account data.
    /// Changes state to RESERVED.
    pub fn setReserved(
        self: *DB,
        tx_id: [16]u8,
        reservation_id: [16]u8,
        payer_psp_id: []const u8,
        payee_psp_id: []const u8,
        payer_account_id: [16]u8,
        payee_account_id: [16]u8,
    ) !void {
        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("pix_transactions", .{});
        const val = try txn.get(dbi, &tx_id) orelse return error.TxNotFound;
        if (val.len < @sizeOf(PixTransaction)) return error.TxNotFound;
        var rec = std.mem.bytesAsValue(PixTransaction, val[0..@sizeOf(PixTransaction)]).*;
        rec.state            = @intFromEnum(TxState.reserved);
        rec.reservation_id   = reservation_id;
        rec.payer_account_id = payer_account_id;
        rec.payee_account_id = payee_account_id;
        rec.updated_at       = std.time.timestamp();
        const ppn = @min(payer_psp_id.len, 15);
        const ypn = @min(payee_psp_id.len, 15);
        @memcpy(rec.payer_psp_id[0..ppn], payer_psp_id[0..ppn]);
        @memcpy(rec.payee_psp_id[0..ypn], payee_psp_id[0..ypn]);
        try txn.put(dbi, &tx_id, std.mem.asBytes(&rec), .{});
        try txn.commit();
    }
};

// ---------------------------------------------------------------------------
// UUID helpers (identical to dict and str)
// ---------------------------------------------------------------------------

pub fn generateUuid() [16]u8 {
    var uuid: [16]u8 = undefined;
    std.crypto.random.bytes(&uuid);
    uuid[6] = (uuid[6] & 0x0F) | 0x40; // version 4
    uuid[8] = (uuid[8] & 0x3F) | 0x80; // variant RFC 4122
    return uuid;
}

pub fn fmtUuid(uuid: [16]u8, buf: *[36]u8) void {
    const hex = std.fmt.bytesToHex(uuid, .lower);
    @memcpy(buf[0..8],   hex[0..8]);   buf[8]  = '-';
    @memcpy(buf[9..13],  hex[8..12]);  buf[13] = '-';
    @memcpy(buf[14..18], hex[12..16]); buf[18] = '-';
    @memcpy(buf[19..23], hex[16..20]); buf[23] = '-';
    @memcpy(buf[24..36], hex[20..32]);
}

pub fn parseUuid(s: []const u8) ![16]u8 {
    if (s.len != 36) return error.InvalidUuid;
    if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') return error.InvalidUuid;
    var hex: [32]u8 = undefined;
    @memcpy(hex[0..8],   s[0..8]);
    @memcpy(hex[8..12],  s[9..13]);
    @memcpy(hex[12..16], s[14..18]);
    @memcpy(hex[16..20], s[19..23]);
    @memcpy(hex[20..32], s[24..36]);
    var uuid: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&uuid, &hex) catch return error.InvalidUuid;
    return uuid;
}

pub fn nullTermStr(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "createOrGet creates PENDING transaction" {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("idem-key-001", &hash, .{});

    const path = "test_spi_create.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    const r = try db.createOrGet(hash, 5_000, "55566677788", "ana@email.com", "test payment");
    try std.testing.expect(r.is_new);

    const tx = (try db.getTransaction(r.tx_id)).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(TxState.pending)), tx.state);
    try std.testing.expectEqual(@as(i64, 5_000), tx.amount_centavos);
    try std.testing.expectEqualSlices(u8, "55566677788", nullTermStr(&tx.payer_key));
}

test "createOrGet idempotency returns existing transaction" {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("idem-key-002", &hash, .{});

    const path = "test_spi_idem.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    const r1 = try db.createOrGet(hash, 1_000, "key1", "key2", "desc");
    try std.testing.expect(r1.is_new);

    const r2 = try db.createOrGet(hash, 9_999, "key-x", "key-y", "desc2");
    try std.testing.expect(!r2.is_new);
    try std.testing.expectEqualSlices(u8, &r1.tx_id, &r2.tx_id);

    // The second call does NOT overwrite the original data
    const tx = (try db.getTransaction(r1.tx_id)).?;
    try std.testing.expectEqual(@as(i64, 1_000), tx.amount_centavos);
}

test "updateState PENDING → SETTLED" {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("idem-key-003", &hash, .{});

    const path = "test_spi_state.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    const r = try db.createOrGet(hash, 2_000, "k1", "k2", "");
    try db.updateState(r.tx_id, .reserved);

    const tx1 = (try db.getTransaction(r.tx_id)).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(TxState.reserved)), tx1.state);

    try db.updateState(r.tx_id, .settled);
    const tx2 = (try db.getTransaction(r.tx_id)).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(TxState.settled)), tx2.state);
}

test "setReserved fills reservation fields" {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("idem-key-004", &hash, .{});

    const path = "test_spi_reserved.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    const r = try db.createOrGet(hash, 3_000, "cpf1", "cpf2", "");

    const fake_res_id     = generateUuid();
    const fake_payer_acct = generateUuid();
    const fake_payee_acct = generateUuid();
    try db.setReserved(r.tx_id, fake_res_id, "psp-alpha", "psp-beta", fake_payer_acct, fake_payee_acct);

    const tx = (try db.getTransaction(r.tx_id)).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(TxState.reserved)), tx.state);
    try std.testing.expectEqualSlices(u8, &fake_res_id, &tx.reservation_id);
    try std.testing.expectEqualSlices(u8, "psp-alpha", nullTermStr(&tx.payer_psp_id));
    try std.testing.expectEqualSlices(u8, "psp-beta",  nullTermStr(&tx.payee_psp_id));
}
