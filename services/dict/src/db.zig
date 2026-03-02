//! DICT DB — Monolith wrapper for the PIX key directory
//!
//! DBIs:
//!   users            — key: user_id [16]u8          value: UserRecord
//!   accounts         — key: account_id [16]u8        value: AccountRecord
//!   pix_keys         — key: key_value (string)       value: PixKeyRecord
//!   accounts_by_user — key: user_id [16]u8           values: [account_id [16]u8, ...] (dupsort)
//!   keys_by_account  — key: account_id [16]u8        values: [key_value string, ...]  (dupsort)

const std = @import("std");
const m   = @import("monolith");

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

pub const DocType = enum(u8) {
    cpf  = 0,
    cnpj = 1,
};

pub const AccountType = enum(u8) {
    corrente = 0,
    poupanca = 1,

    pub fn fromString(s: []const u8) ?AccountType {
        if (std.mem.eql(u8, s, "corrente")) return .corrente;
        if (std.mem.eql(u8, s, "poupanca")) return .poupanca;
        return null;
    }
    pub fn toString(self: AccountType) []const u8 {
        return switch (self) { .corrente => "corrente", .poupanca => "poupanca" };
    }
};

pub const KeyType = enum(u8) {
    cpf    = 0,
    cnpj   = 1,
    phone  = 2,
    email  = 3,
    random = 4,

    pub fn fromString(s: []const u8) ?KeyType {
        if (std.mem.eql(u8, s, "CPF"))    return .cpf;
        if (std.mem.eql(u8, s, "CNPJ"))   return .cnpj;
        if (std.mem.eql(u8, s, "PHONE"))  return .phone;
        if (std.mem.eql(u8, s, "EMAIL"))  return .email;
        if (std.mem.eql(u8, s, "RANDOM")) return .random;
        return null;
    }
    pub fn toString(self: KeyType) []const u8 {
        return switch (self) {
            .cpf    => "CPF",
            .cnpj   => "CNPJ",
            .phone  => "PHONE",
            .email  => "EMAIL",
            .random => "RANDOM",
        };
    }
};

// ---------------------------------------------------------------------------
// Records (extern struct → fixed C layout for serialization/deserialization as bytes)
// ---------------------------------------------------------------------------

pub const UserRecord = extern struct {
    doc_type: u8,
    document: [14]u8,  // CPF (11) or CNPJ (14), zero-padded
    name:     [80]u8,  // null-padded
    psp_id:   [16]u8,  // null-padded
};

pub const AccountRecord = extern struct {
    user_id:        [16]u8,
    psp_id:         [16]u8, // null-padded
    bank_ispb:      [8]u8,  // null-padded
    agency:         [4]u8,  // null-padded
    account_number: [12]u8, // null-padded
    account_type:   u8,
};

pub const PixKeyRecord = extern struct {
    key_type:   u8,
    account_id: [16]u8,
    user_id:    [16]u8,
    psp_id:     [16]u8, // null-padded
    created_at: i64,    // unix seconds (compiler automatic padding)
};

// ---------------------------------------------------------------------------
// DB
// ---------------------------------------------------------------------------

pub const DB = struct {
    env: m.Environment,

    /// Opens (or creates) the DICT service .monolith file.
    pub fn open(path: [:0]const u8) !DB {
        var env = try m.Environment.open(path, .{ .liforeclaim = true }, 8, 64 * 1024 * 1024);
        errdefer env.close();

        // Create all DBIs in an initial write txn
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        _ = try txn.openDbi("users",            .{ .create = true });
        _ = try txn.openDbi("accounts",         .{ .create = true });
        _ = try txn.openDbi("pix_keys",         .{ .create = true });
        _ = try txn.openDbi("accounts_by_user", .{ .create = true, .dupsort = true });
        _ = try txn.openDbi("keys_by_account",  .{ .create = true, .dupsort = true });
        try txn.commit();

        return .{ .env = env };
    }

    pub fn deinit(self: *DB) void {
        self.env.close();
    }

    // -----------------------------------------------------------------------
    // Users
    // -----------------------------------------------------------------------

    pub fn createUser(
        self: *DB,
        doc_type: DocType,
        document: []const u8,
        name: []const u8,
        psp_id: []const u8,
    ) ![16]u8 {
        const user_id = generateUuid();
        var rec = UserRecord{
            .doc_type = @intFromEnum(doc_type),
            .document = [_]u8{0} ** 14,
            .name     = [_]u8{0} ** 80,
            .psp_id   = [_]u8{0} ** 16,
        };
        const dn = @min(document.len, 14);
        const nn = @min(name.len, 79);
        const pn = @min(psp_id.len, 15);
        @memcpy(rec.document[0..dn], document[0..dn]);
        @memcpy(rec.name[0..nn],     name[0..nn]);
        @memcpy(rec.psp_id[0..pn],   psp_id[0..pn]);

        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("users", .{});
        try txn.put(dbi, &user_id, std.mem.asBytes(&rec), .{});
        try txn.commit();
        return user_id;
    }

    pub fn getUser(self: *DB, user_id: [16]u8) !?UserRecord {
        var txn = try m.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("users", .{});
        const val = try txn.get(dbi, &user_id) orelse return null;
        if (val.len < @sizeOf(UserRecord)) return null;
        return std.mem.bytesAsValue(UserRecord, val[0..@sizeOf(UserRecord)]).*;
    }

    // -----------------------------------------------------------------------
    // Accounts
    // -----------------------------------------------------------------------

    pub fn createAccount(
        self: *DB,
        user_id: [16]u8,
        psp_id: []const u8,
        bank_ispb: []const u8,
        agency: []const u8,
        account_number: []const u8,
        account_type: AccountType,
    ) ![16]u8 {
        const account_id = generateUuid();
        var rec = AccountRecord{
            .user_id        = user_id,
            .psp_id         = [_]u8{0} ** 16,
            .bank_ispb      = [_]u8{0} ** 8,
            .agency         = [_]u8{0} ** 4,
            .account_number = [_]u8{0} ** 12,
            .account_type   = @intFromEnum(account_type),
        };
        const pn  = @min(psp_id.len, 15);
        const bn  = @min(bank_ispb.len, 8);
        const agn = @min(agency.len, 4);
        const an  = @min(account_number.len, 11);
        @memcpy(rec.psp_id[0..pn],         psp_id[0..pn]);
        @memcpy(rec.bank_ispb[0..bn],      bank_ispb[0..bn]);
        @memcpy(rec.agency[0..agn],        agency[0..agn]);
        @memcpy(rec.account_number[0..an], account_number[0..an]);

        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();
        const dbi_acc = try txn.openDbi("accounts",         .{});
        const dbi_idx = try txn.openDbi("accounts_by_user", .{ .dupsort = true });
        try txn.put(dbi_acc, &account_id, std.mem.asBytes(&rec), .{});
        // Secondary index: user_id → account_id (dupsort)
        try txn.put(dbi_idx, &user_id, &account_id, .{});
        try txn.commit();
        return account_id;
    }

    pub fn getAccount(self: *DB, account_id: [16]u8) !?AccountRecord {
        var txn = try m.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("accounts", .{});
        const val = try txn.get(dbi, &account_id) orelse return null;
        if (val.len < @sizeOf(AccountRecord)) return null;
        return std.mem.bytesAsValue(AccountRecord, val[0..@sizeOf(AccountRecord)]).*;
    }

    // -----------------------------------------------------------------------
    // PIX Keys
    // -----------------------------------------------------------------------

    pub fn registerKey(
        self: *DB,
        key_value: []const u8,
        key_type: KeyType,
        account_id: [16]u8,
        user_id: [16]u8,
        psp_id: []const u8,
    ) !void {
        var rec = PixKeyRecord{
            .key_type   = @intFromEnum(key_type),
            .account_id = account_id,
            .user_id    = user_id,
            .psp_id     = [_]u8{0} ** 16,
            .created_at = std.time.timestamp(),
        };
        const pn = @min(psp_id.len, 15);
        @memcpy(rec.psp_id[0..pn], psp_id[0..pn]);

        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();
        const dbi_keys = try txn.openDbi("pix_keys",        .{});
        const dbi_idx  = try txn.openDbi("keys_by_account", .{ .dupsort = true });

        // Key already exists?
        if (try txn.get(dbi_keys, key_value)) |_| return error.KeyAlreadyExists;

        try txn.put(dbi_keys, key_value, std.mem.asBytes(&rec), .{});
        // Secondary index: account_id → key_value (dupsort)
        try txn.put(dbi_idx, &account_id, key_value, .{});
        try txn.commit();
    }

    pub fn resolveKey(self: *DB, key_value: []const u8) !?PixKeyRecord {
        var txn = try m.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("pix_keys", .{});
        const val = try txn.get(dbi, key_value) orelse return null;
        if (val.len < @sizeOf(PixKeyRecord)) return null;
        return std.mem.bytesAsValue(PixKeyRecord, val[0..@sizeOf(PixKeyRecord)]).*;
    }

    pub fn deleteKey(self: *DB, key_value: []const u8) !bool {
        var txn = try m.Transaction.begin(&self.env, null, .{});
        errdefer txn.abort();
        const dbi_keys = try txn.openDbi("pix_keys",        .{});
        const dbi_idx  = try txn.openDbi("keys_by_account", .{ .dupsort = true });

        // Fetch to get account_id before deleting
        const val = try txn.get(dbi_keys, key_value) orelse {
            txn.abort();
            return false;
        };
        if (val.len < @sizeOf(PixKeyRecord)) {
            txn.abort();
            return false;
        }
        // Copy account_id to stack before any mutation
        const rec = std.mem.bytesAsValue(PixKeyRecord, val[0..@sizeOf(PixKeyRecord)]);
        const account_id = rec.account_id;

        // Delete specific dup from secondary index (account_id → key_value)
        try txn.del(dbi_idx, &account_id, key_value);
        // Delete from primary table
        try txn.del(dbi_keys, key_value, null);
        try txn.commit();
        return true;
    }

    /// Returns all PIX keys for an account.
    /// Caller must free each slice and the outer slice with `allocator`.
    pub fn getKeysByAccount(
        self: *DB,
        allocator: std.mem.Allocator,
        account_id: [16]u8,
    ) ![][]u8 {
        var txn = try m.Transaction.begin(&self.env, null, .{ .rdonly = true });
        defer txn.abort();
        const dbi = try txn.openDbi("keys_by_account", .{ .dupsort = true });

        var cursor = try m.Cursor.open(&txn, dbi);
        defer cursor.close();

        var list: std.ArrayListUnmanaged([]u8) = .{};
        errdefer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }

        // Position at first dup of account_id
        if (!try cursor.find(&account_id)) return list.toOwnedSlice(allocator);

        const first = try cursor.current() orelse return list.toOwnedSlice(allocator);
        try list.append(allocator, try allocator.dupe(u8, first.val));

        while (try cursor.nextDup()) |val| {
            try list.append(allocator, try allocator.dupe(u8, val));
        }
        return list.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// UUID helpers
// ---------------------------------------------------------------------------

pub fn generateUuid() [16]u8 {
    var uuid: [16]u8 = undefined;
    std.crypto.random.bytes(&uuid);
    uuid[6] = (uuid[6] & 0x0F) | 0x40; // version 4
    uuid[8] = (uuid[8] & 0x3F) | 0x80; // variant RFC 4122
    return uuid;
}

/// Formats a UUID [16]u8 as string "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
pub fn fmtUuid(uuid: [16]u8, buf: *[36]u8) void {
    const hex = std.fmt.bytesToHex(uuid, .lower);
    @memcpy(buf[0..8],  hex[0..8]);   buf[8]  = '-';
    @memcpy(buf[9..13], hex[8..12]);  buf[13] = '-';
    @memcpy(buf[14..18], hex[12..16]); buf[18] = '-';
    @memcpy(buf[19..23], hex[16..20]); buf[23] = '-';
    @memcpy(buf[24..36], hex[20..32]);
}

/// Parses "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" → [16]u8.
pub fn parseUuid(s: []const u8) ![16]u8 {
    if (s.len != 36) return error.InvalidUuid;
    if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') return error.InvalidUuid;
    var hex: [32]u8 = undefined;
    @memcpy(hex[0..8],  s[0..8]);
    @memcpy(hex[8..12], s[9..13]);
    @memcpy(hex[12..16], s[14..18]);
    @memcpy(hex[16..20], s[19..23]);
    @memcpy(hex[20..32], s[24..36]);
    var uuid: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&uuid, &hex) catch return error.InvalidUuid;
    return uuid;
}

/// Extracts a string from a null-padded buffer.
pub fn nullTermStr(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "createUser and getUser round-trip" {
    const ally = std.testing.allocator;
    _ = ally;
    const path = "test_dict_user.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    const uid = try db.createUser(.cpf, "12345678901", "João Silva", "psp-alpha");
    const rec = (try db.getUser(uid)).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(DocType.cpf)), rec.doc_type);
    try std.testing.expectEqualSlices(u8, "12345678901", rec.document[0..11]);
    try std.testing.expectEqualSlices(u8, "João Silva", nullTermStr(&rec.name));
}

test "createAccount and getAccount round-trip" {
    const path = "test_dict_account.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    const uid = try db.createUser(.cpf, "11122233344", "Maria", "psp-beta");
    const aid = try db.createAccount(uid, "psp-beta", "99887766", "0001", "123456-7", .corrente);
    const rec = (try db.getAccount(aid)).?;
    try std.testing.expectEqualSlices(u8, &uid, &rec.user_id);
    try std.testing.expectEqualSlices(u8, "99887766", nullTermStr(&rec.bank_ispb));
    try std.testing.expectEqual(@as(u8, @intFromEnum(AccountType.corrente)), rec.account_type);
}

test "registerKey and resolveKey round-trip" {
    const path = "test_dict_key.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    const uid = try db.createUser(.cpf, "55566677788", "Carlos", "psp-alpha");
    const aid = try db.createAccount(uid, "psp-alpha", "01234567", "0002", "654321-0", .poupanca);

    try db.registerKey("+5511998877665", .phone, aid, uid, "psp-alpha");

    const rec = (try db.resolveKey("+5511998877665")).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(KeyType.phone)), rec.key_type);
    try std.testing.expectEqualSlices(u8, &aid, &rec.account_id);

    // Duplicate key must fail
    try std.testing.expectError(error.KeyAlreadyExists,
        db.registerKey("+5511998877665", .phone, aid, uid, "psp-alpha"));
}

test "deleteKey removes primary and index" {
    const path = "test_dict_del.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    const uid = try db.createUser(.cnpj, "12345678000195", "Empresa", "psp-beta");
    const aid = try db.createAccount(uid, "psp-beta", "12345678", "0001", "000001-0", .corrente);

    try db.registerKey("12345678000195", .cnpj, aid, uid, "psp-beta");
    try std.testing.expect(try db.deleteKey("12345678000195"));
    try std.testing.expect((try db.resolveKey("12345678000195")) == null);
    try std.testing.expect(!try db.deleteKey("12345678000195")); // already deleted
}

test "getKeysByAccount lists all keys" {
    const ally = std.testing.allocator;
    const path = "test_dict_list.monolith";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = try DB.open(path);
    defer db.deinit();

    const uid = try db.createUser(.cpf, "99988877766", "Ana", "psp-alpha");
    const aid = try db.createAccount(uid, "psp-alpha", "01234567", "0001", "111111-1", .corrente);

    try db.registerKey("99988877766", .cpf, aid, uid, "psp-alpha");
    try db.registerKey("ana@email.com", .email, aid, uid, "psp-alpha");

    const keys = try db.getKeysByAccount(ally, aid);
    defer { for (keys) |k| ally.free(k); ally.free(keys); }

    try std.testing.expectEqual(@as(usize, 2), keys.len);
}
