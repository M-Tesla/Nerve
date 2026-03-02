//! BACEN — Persistence layer (Monolith/libmdbx)
//!
//! DBIs:
//!   positions  — psp_id → PositionRecord (accumulated debits/credits per PSP)
//!   audit_log  — big-endian u64 seq → JSON event string (append-only)
//!   bacen_meta — "audit_seq" → u64 LE (sequence counter)

const std      = @import("std");
const monolith = @import("monolith");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Net position of a PSP in BACEN.
/// net = credits - debits  (positive = net receiver, negative = net payer)
pub const PositionRecord = extern struct {
    debits_centavos:  i64 = 0, // money that left this PSP (as payer)
    credits_centavos: i64 = 0, // money that entered this PSP (as payee/receiver)
    tx_count:         u64 = 0, // transactions that involved this PSP
};

pub const PositionEntry = struct {
    psp_id: []const u8,
    rec:    PositionRecord,
};

pub const AuditEntry = struct {
    seq:  u64,
    json: []const u8, // caller is responsible for free
};

// ---------------------------------------------------------------------------
// DB
// ---------------------------------------------------------------------------

pub const DB = struct {
    env: monolith.Environment,

    pub fn open(path: [:0]const u8) !DB {
        const env = try monolith.Environment.open(path, .{ .liforeclaim = true }, 4, 32 * 1024 * 1024);

        // Initialize DBIs in write txn (creates if not exist)
        var txn = try monolith.Transaction.begin(@constCast(&env), null, .{});
        errdefer txn.abort();
        _ = try txn.openDbi("positions",  .{ .create = true });
        _ = try txn.openDbi("audit_log",  .{ .create = true });
        _ = try txn.openDbi("bacen_meta", .{ .create = true });
        try txn.commit();

        return .{ .env = env };
    }

    pub fn deinit(self: *DB) void {
        self.env.close();
    }

    // -----------------------------------------------------------------------
    // Writes
    // -----------------------------------------------------------------------

    /// Records a settlement: updates payer position (debit) and payee/receiver position (credit)
    /// and appends the event JSON to audit_log.
    pub fn recordSettle(
        self:             *DB,
        payer_psp:        []const u8,
        payee_psp:        []const u8,
        amount_centavos:  i64,
        evt_json:         []const u8,
    ) !void {
        var txn = try monolith.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();

        const dbi_pos  = try txn.openDbi("positions",  .{});
        const dbi_log  = try txn.openDbi("audit_log",  .{});
        const dbi_meta = try txn.openDbi("bacen_meta", .{});

        // Payer — debit
        {
            var rec = getPosition(&txn, dbi_pos, payer_psp) orelse PositionRecord{};
            rec.debits_centavos += amount_centavos;
            rec.tx_count        += 1;
            try txn.put(dbi_pos, payer_psp, std.mem.asBytes(&rec), .{});
        }

        // Payee/receiver — credit
        {
            var rec = getPosition(&txn, dbi_pos, payee_psp) orelse PositionRecord{};
            rec.credits_centavos += amount_centavos;
            rec.tx_count         += 1;
            try txn.put(dbi_pos, payee_psp, std.mem.asBytes(&rec), .{});
        }

        // Audit log
        const seq = nextSeq(&txn, dbi_meta);
        var seq_key: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_key, seq, .big);
        try txn.put(dbi_log, &seq_key, evt_json, .{});

        var seq_le: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_le, seq, .little);
        try txn.put(dbi_meta, "audit_seq", &seq_le, .{});

        try txn.commit();
    }

    /// Records a reversal in audit_log (positions do not change — it was never settled).
    pub fn recordReverse(self: *DB, evt_json: []const u8) !void {
        var txn = try monolith.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();

        const dbi_log  = try txn.openDbi("audit_log",  .{});
        const dbi_meta = try txn.openDbi("bacen_meta", .{});

        const seq = nextSeq(&txn, dbi_meta);
        var seq_key: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_key, seq, .big);
        try txn.put(dbi_log, &seq_key, evt_json, .{});

        var seq_le: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_le, seq, .little);
        try txn.put(dbi_meta, "audit_seq", &seq_le, .{});

        try txn.commit();
    }

    // -----------------------------------------------------------------------
    // Reads
    // -----------------------------------------------------------------------

    /// Position of a specific PSP. Returns null if PSP has never transacted.
    pub fn getPositionById(self: *DB, psp_id: []const u8) !?PositionRecord {
        var txn = try monolith.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("positions", .{});
        return getPosition(&txn, dbi, psp_id);
    }

    /// Returns all positions (allocated slice — caller calls free on each psp_id and on the slice).
    pub fn getAllPositions(self: *DB, allocator: std.mem.Allocator) ![]PositionEntry {
        var txn = try monolith.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("positions", .{});

        var cursor = try txn.cursor(dbi);
        defer cursor.close();

        var list = std.ArrayListUnmanaged(PositionEntry){};

        var kv_opt = try cursor.first();
        while (kv_opt) |kv| {
            if (kv.val.len >= @sizeOf(PositionRecord)) {
                const rec      = std.mem.bytesAsValue(PositionRecord, kv.val[0..@sizeOf(PositionRecord)]).*;
                const psp_copy = try allocator.dupe(u8, kv.key);
                try list.append(allocator, .{ .psp_id = psp_copy, .rec = rec });
            }
            kv_opt = try cursor.next();
        }

        return list.toOwnedSlice(allocator);
    }

    /// Returns up to `limit` entries from audit_log (from the beginning of the log).
    /// Caller must free each entry.json and the slice.
    pub fn getAuditEntries(self: *DB, allocator: std.mem.Allocator, limit: usize) ![]AuditEntry {
        var txn = try monolith.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("audit_log", .{});

        var cursor = try txn.cursor(dbi);
        defer cursor.close();

        var list  = std.ArrayListUnmanaged(AuditEntry){};
        var count: usize = 0;

        var kv_opt = try cursor.first();
        while (kv_opt) |kv| {
            if (count >= limit) break;
            if (kv.key.len == 8) {
                const seq      = std.mem.readInt(u64, kv.key[0..8], .big);
                const json_dup = try allocator.dupe(u8, kv.val);
                try list.append(allocator, .{ .seq = seq, .json = json_dup });
                count += 1;
            }
            kv_opt = try cursor.next();
        }

        return list.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

fn getPosition(txn: *monolith.Transaction, dbi: monolith.Dbi, psp_id: []const u8) ?PositionRecord {
    const bytes_opt = txn.get(dbi, psp_id) catch return null;
    const bytes = bytes_opt orelse return null;
    if (bytes.len < @sizeOf(PositionRecord)) return null;
    return std.mem.bytesAsValue(PositionRecord, bytes[0..@sizeOf(PositionRecord)]).*;
}

fn nextSeq(txn: *monolith.Transaction, dbi_meta: monolith.Dbi) u64 {
    const bytes_opt = txn.get(dbi_meta, "audit_seq") catch return 1;
    const bytes = bytes_opt orelse return 1;
    if (bytes.len < 8) return 1;
    return std.mem.readInt(u64, bytes[0..8], .little) + 1;
}
