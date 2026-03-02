//! STR DB — Monolith wrapper for the Settlement Transfer System
//!
//! DBIs:
//!   psp_reserves        — key: psp_id (string)        value: PspReserveRecord
//!   reservations        — key: reservation_id [16]u8  value: ReservationRecord
//!   reservations_by_psp — dupsort psp_id → reservation_id [16]u8
//!   ledger_entries      — key: seq big-endian [8]u8   value: LedgerEntry
//!   str_meta            — key: "ledger_seq"           value: u64 LE (monotonic counter)

const std = @import("std");
const m   = @import("monolith");

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

pub const ReservationStatus = enum(u8) {
    active   = 0,
    settled  = 1,
    reversed = 2,

    pub fn toString(self: ReservationStatus) []const u8 {
        return switch (self) {
            .active   => "ACTIVE",
            .settled  => "SETTLED",
            .reversed => "REVERSED",
        };
    }
};

pub const LedgerEntryType = enum(u8) {
    debit  = 0,  // funds leaving PSP on reserve
    credit = 1,  // funds returning to PSP on reversal
    settle = 2,  // final settlement
};

// ---------------------------------------------------------------------------
// Records (extern struct — C-compatible layout for serialization/deserialization via bytes)
// ---------------------------------------------------------------------------

pub const PspReserveRecord = extern struct {
    balance_centavos: i64,
    version:          u64,
};

pub const ReservationRecord = extern struct {
    status:          u8,
    _pad:            [7]u8,   // alignment for i64
    amount_centavos: i64,
    psp_id:          [16]u8,  // null-padded
    pix_txn_id:      [64]u8,  // null-padded (SPI UUID)
    created_at:      i64,
    version:         u64,
};

pub const LedgerEntry = extern struct {
    entry_type:      u8,
    _pad:            [7]u8,   // alignment for i64
    amount_centavos: i64,
    psp_id:          [16]u8,  // null-padded
    reservation_id:  [16]u8,
    created_at:      i64,
    sequence:        u64,
};

// ---------------------------------------------------------------------------
// Domain errors
// ---------------------------------------------------------------------------

pub const StrError = error{
    InsufficientFunds,
    ReservationNotFound,
    ReservationNotActive,
    PspNotFound,
};

// ---------------------------------------------------------------------------
// DB
// ---------------------------------------------------------------------------

pub const DB = struct {
    env: m.Environment,

    /// Opens (or creates) the STR service .monolith file.
    ///
    /// Performance flags:
    ///   writemap    — writes directly into mmap, avoids shadow page copy
    ///   safe_nosync — no fsync per commit; a background thread calls
    ///                 env.sync() every 5ms (Erigon/Ethereum model)
    ///   liforeclaim — LIFO recycling policy improves locality on HDD
    pub fn open(path: [:0]const u8) !DB {
        var env = try m.Environment.open(path, .{
            .safe_nosync = true,
            .liforeclaim = true,
        }, 8, 256 * 1024 * 1024);
        errdefer env.close();

        // Create all DBIs in an initial write txn
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        _ = try txn.openDbi("psp_reserves",        .{ .create = true });
        _ = try txn.openDbi("reservations",        .{ .create = true });
        _ = try txn.openDbi("reservations_by_psp", .{ .create = true, .dupsort = true });
        _ = try txn.openDbi("ledger_entries",      .{ .create = true });
        _ = try txn.openDbi("str_meta",            .{ .create = true });
        try txn.commit();

        return .{ .env = env };
    }

    pub fn deinit(self: *DB) void {
        self.env.close();
    }

    // -----------------------------------------------------------------------
    // PSP Reserves — net balance of each PSP
    // -----------------------------------------------------------------------

    /// Initializes (or overwrites) the reserve of a PSP.
    /// Used in development seed.
    pub fn seedPsp(self: *DB, psp_id: []const u8, initial_balance: i64) !void {
        const rec = PspReserveRecord{ .balance_centavos = initial_balance, .version = 0 };
        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("psp_reserves", .{});
        try txn.put(dbi, psp_id, std.mem.asBytes(&rec), .{});
        try txn.commit();
    }

    /// Returns the current balance of a PSP, or null if the PSP has not been registered.
    pub fn getBalance(self: *DB, psp_id: []const u8) !?PspReserveRecord {
        var txn = try m.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("psp_reserves", .{});
        const val = try txn.get(dbi, psp_id) orelse return null;
        if (val.len < @sizeOf(PspReserveRecord)) return null;
        return std.mem.bytesAsValue(PspReserveRecord, val[0..@sizeOf(PspReserveRecord)]).*;
    }

    // -----------------------------------------------------------------------
    // Reservations — lifecycle of a PIX reservation
    // -----------------------------------------------------------------------

    /// Reserves `amount_centavos` from the PSP balance.
    /// Returns the generated reservation_id ([16]u8 UUID v4).
    /// Fails with InsufficientFunds if balance < amount.
    /// Fails with PspNotFound if the psp_id has not been seeded.
    pub fn reserve(
        self: *DB,
        psp_id: []const u8,
        amount_centavos: i64,
        pix_txn_id: []const u8,
    ) !([16]u8) {
        const reservation_id = generateUuid();

        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();

        const dbi_rsv  = try txn.openDbi("psp_reserves",        .{});
        const dbi_res  = try txn.openDbi("reservations",        .{});
        const dbi_idx  = try txn.openDbi("reservations_by_psp", .{ .dupsort = true });
        const dbi_led  = try txn.openDbi("ledger_entries",      .{});
        const dbi_meta = try txn.openDbi("str_meta",            .{});

        // Read and validate balance
        const rsv_bytes = try txn.get(dbi_rsv, psp_id) orelse
            return StrError.PspNotFound;
        if (rsv_bytes.len < @sizeOf(PspReserveRecord)) return StrError.PspNotFound;
        var reserve_rec = std.mem.bytesAsValue(
            PspReserveRecord, rsv_bytes[0..@sizeOf(PspReserveRecord)]).* ;
        if (reserve_rec.balance_centavos < amount_centavos) return StrError.InsufficientFunds;

        // Debit balance
        reserve_rec.balance_centavos -= amount_centavos;
        reserve_rec.version += 1;
        try txn.put(dbi_rsv, psp_id, std.mem.asBytes(&reserve_rec), .{});

        // Create ReservationRecord
        var rec = ReservationRecord{
            .status          = @intFromEnum(ReservationStatus.active),
            ._pad            = [_]u8{0} ** 7,
            .amount_centavos = amount_centavos,
            .psp_id          = [_]u8{0} ** 16,
            .pix_txn_id      = [_]u8{0} ** 64,
            .created_at      = std.time.timestamp(),
            .version         = 1,
        };
        const pn = @min(psp_id.len, 15);
        const tn = @min(pix_txn_id.len, 63);
        @memcpy(rec.psp_id[0..pn],     psp_id[0..pn]);
        @memcpy(rec.pix_txn_id[0..tn], pix_txn_id[0..tn]);

        try txn.put(dbi_res, &reservation_id, std.mem.asBytes(&rec), .{});
        // Secondary index: psp_id → reservation_id (dupsort)
        try txn.put(dbi_idx, psp_id, &reservation_id, .{});

        // Ledger: DEBIT
        try appendLedger(&txn, dbi_led, dbi_meta, .debit, amount_centavos, psp_id, reservation_id);

        try txn.commit();
        return reservation_id;
    }

    /// Marks the reservation as SETTLED. The balance is NOT restored — the funds
    /// leave the PSP definitively.
    pub fn settle(self: *DB, reservation_id: [16]u8) !void {
        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();

        const dbi_res  = try txn.openDbi("reservations",   .{});
        const dbi_led  = try txn.openDbi("ledger_entries", .{});
        const dbi_meta = try txn.openDbi("str_meta",       .{});

        const val = try txn.get(dbi_res, &reservation_id) orelse
            return StrError.ReservationNotFound;
        if (val.len < @sizeOf(ReservationRecord)) return StrError.ReservationNotFound;
        var rec = std.mem.bytesAsValue(ReservationRecord, val[0..@sizeOf(ReservationRecord)]).*;

        if (rec.status != @intFromEnum(ReservationStatus.active))
            return StrError.ReservationNotActive;

        rec.status  = @intFromEnum(ReservationStatus.settled);
        rec.version += 1;
        try txn.put(dbi_res, &reservation_id, std.mem.asBytes(&rec), .{});

        const psp_id_str = nullTermStr(&rec.psp_id);
        try appendLedger(&txn, dbi_led, dbi_meta, .settle, rec.amount_centavos, psp_id_str, reservation_id);

        try txn.commit();
    }

    /// Reverses the reservation: restores the PSP balance and marks as REVERSED.
    pub fn reverse(self: *DB, reservation_id: [16]u8) !void {
        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();

        const dbi_rsv  = try txn.openDbi("psp_reserves",   .{});
        const dbi_res  = try txn.openDbi("reservations",   .{});
        const dbi_led  = try txn.openDbi("ledger_entries", .{});
        const dbi_meta = try txn.openDbi("str_meta",       .{});

        const val = try txn.get(dbi_res, &reservation_id) orelse
            return StrError.ReservationNotFound;
        if (val.len < @sizeOf(ReservationRecord)) return StrError.ReservationNotFound;
        var rec = std.mem.bytesAsValue(ReservationRecord, val[0..@sizeOf(ReservationRecord)]).*;

        if (rec.status != @intFromEnum(ReservationStatus.active))
            return StrError.ReservationNotActive;

        const psp_id_str = nullTermStr(&rec.psp_id);

        // Restore balance
        const rsv_bytes = try txn.get(dbi_rsv, psp_id_str) orelse
            return StrError.PspNotFound;
        if (rsv_bytes.len < @sizeOf(PspReserveRecord)) return StrError.PspNotFound;
        var reserve_rec = std.mem.bytesAsValue(
            PspReserveRecord, rsv_bytes[0..@sizeOf(PspReserveRecord)]).*;
        reserve_rec.balance_centavos += rec.amount_centavos;
        reserve_rec.version += 1;
        try txn.put(dbi_rsv, psp_id_str, std.mem.asBytes(&reserve_rec), .{});

        rec.status  = @intFromEnum(ReservationStatus.reversed);
        rec.version += 1;
        try txn.put(dbi_res, &reservation_id, std.mem.asBytes(&rec), .{});

        // Ledger: CREDIT
        try appendLedger(&txn, dbi_led, dbi_meta, .credit, rec.amount_centavos, psp_id_str, reservation_id);

        try txn.commit();
    }

    /// Returns a ReservationRecord by ID, or null if not found.
    pub fn getReservation(self: *DB, reservation_id: [16]u8) !?ReservationRecord {
        var txn = try m.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("reservations", .{});
        const val = try txn.get(dbi, &reservation_id) orelse return null;
        if (val.len < @sizeOf(ReservationRecord)) return null;
        return std.mem.bytesAsValue(ReservationRecord, val[0..@sizeOf(ReservationRecord)]).*;
    }
};

// ---------------------------------------------------------------------------
// Private helper: append entry to ledger
// ---------------------------------------------------------------------------

fn appendLedger(
    txn: *m.Transaction,
    dbi_ledger: m.Dbi,
    dbi_meta: m.Dbi,
    entry_type: LedgerEntryType,
    amount_centavos: i64,
    psp_id_str: []const u8,
    reservation_id: [16]u8,
) !void {
    const seq_key = "ledger_seq";

    // Read and increment monotonic sequence
    const current: u64 = blk: {
        const v = try txn.get(dbi_meta, seq_key) orelse break :blk 0;
        if (v.len < @sizeOf(u64)) break :blk 0;
        break :blk std.mem.readInt(u64, v[0..@sizeOf(u64)], .little);
    };
    const seq = current + 1;
    var seq_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq_le, seq, .little);
    try txn.put(dbi_meta, seq_key, &seq_le, .{});

    // Ledger key: big-endian for ascending lexicographic order
    var key_be: [8]u8 = undefined;
    std.mem.writeInt(u64, &key_be, seq, .big);

    var entry = LedgerEntry{
        .entry_type      = @intFromEnum(entry_type),
        ._pad            = [_]u8{0} ** 7,
        .amount_centavos = amount_centavos,
        .psp_id          = [_]u8{0} ** 16,
        .reservation_id  = reservation_id,
        .created_at      = std.time.timestamp(),
        .sequence        = seq,
    };
    const pn = @min(psp_id_str.len, 15);
    @memcpy(entry.psp_id[0..pn], psp_id_str[0..pn]);

    // MDBX_APPEND: the seq key is always larger than the previous — skips B-tree search
    try txn.put(dbi_ledger, &key_be, std.mem.asBytes(&entry), .{ .append = true });
}

// ---------------------------------------------------------------------------
// UUID helpers (identical to dict)
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

test "seedPsp and getBalance round-trip" {
    const path = "test_str_balance.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    try db.seedPsp("psp-alpha", 10_000_000); // R$100,000.00
    const rec = (try db.getBalance("psp-alpha")).?;
    try std.testing.expectEqual(@as(i64, 10_000_000), rec.balance_centavos);
    try std.testing.expectEqual(@as(u64, 0), rec.version);
}

test "reserve debits balance and creates ACTIVE reservation" {
    const path = "test_str_reserve.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    try db.seedPsp("psp-alpha", 5_000);
    const res_id = try db.reserve("psp-alpha", 1_000, "txn-uuid-001");

    const rec = (try db.getReservation(res_id)).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(ReservationStatus.active)), rec.status);
    try std.testing.expectEqual(@as(i64, 1_000), rec.amount_centavos);

    const bal = (try db.getBalance("psp-alpha")).?;
    try std.testing.expectEqual(@as(i64, 4_000), bal.balance_centavos);
}

test "reserve fails with insufficient balance" {
    const path = "test_str_insufficient.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    try db.seedPsp("psp-beta", 100);
    const result = db.reserve("psp-beta", 500, "txn-001");
    try std.testing.expectError(StrError.InsufficientFunds, result);
}

test "settle changes status to SETTLED without restoring balance" {
    const path = "test_str_settle.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    try db.seedPsp("psp-alpha", 10_000);
    const res_id = try db.reserve("psp-alpha", 2_000, "txn-settle-001");
    try db.settle(res_id);

    const rec = (try db.getReservation(res_id)).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(ReservationStatus.settled)), rec.status);

    // Balance is NOT restored on settlement (funds leave the system)
    const bal = (try db.getBalance("psp-alpha")).?;
    try std.testing.expectEqual(@as(i64, 8_000), bal.balance_centavos);
}

test "reverse returns balance and changes status to REVERSED" {
    const path = "test_str_reverse.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    try db.seedPsp("psp-alpha", 10_000);
    const res_id = try db.reserve("psp-alpha", 3_000, "txn-rev-001");
    try db.reverse(res_id);

    const rec = (try db.getReservation(res_id)).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(ReservationStatus.reversed)), rec.status);

    // Balance fully restored
    const bal = (try db.getBalance("psp-alpha")).?;
    try std.testing.expectEqual(@as(i64, 10_000), bal.balance_centavos);
}

test "settle twice fails with ReservationNotActive" {
    const path = "test_str_double_settle.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    try db.seedPsp("psp-alpha", 10_000);
    const res_id = try db.reserve("psp-alpha", 1_000, "txn-ds-001");
    try db.settle(res_id);
    try std.testing.expectError(StrError.ReservationNotActive, db.settle(res_id));
}
