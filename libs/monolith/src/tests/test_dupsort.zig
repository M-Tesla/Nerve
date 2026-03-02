//! Testes de dupsort — índices secundários.
//! Pattern usado em: accounts_by_user, keys_by_account, txn_by_user, etc.

const std = @import("std");
const m = @import("../lib.zig");

const PATH = "test_dupsort.monolith";

test "dupsort: put múltiplos valores por chave" {
    defer std.fs.cwd().deleteFile(PATH) catch {};
    defer std.fs.cwd().deleteFile(PATH ++ "-lck") catch {};

    var env = try m.Environment.open(PATH, .{}, 4, 16 * 1024 * 1024);
    defer env.close();

    // Inserir: user_doc → [account1, account2, account3]
    {
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("accounts_by_user", .{
            .create   = true,
            .dupsort  = true,
        });

        const user_doc = "12345678901   "; // 14 bytes (CPF zero-padded)
        try txn.put(dbi, user_doc, "account-uuid-001", .{});
        try txn.put(dbi, user_doc, "account-uuid-002", .{});
        try txn.put(dbi, user_doc, "account-uuid-003", .{});
        try txn.commit();
    }

    // Ler e iterar os dups
    var txn = try m.Transaction.begin(&env, null, .{ .rdonly = true });
    defer txn.abort();
    const dbi = try txn.openDbi("accounts_by_user", .{ .dupsort = true });
    var cur = try txn.cursor(dbi);
    defer cur.close();

    const user_doc = "12345678901   ";
    const found = try cur.find(user_doc);
    try std.testing.expect(found);

    // Primeiro valor
    const kv = try cur.current();
    try std.testing.expect(kv != null);

    // Contar os dups
    const count = try cur.countDups();
    try std.testing.expectEqual(@as(usize, 3), count);

    // Iterar
    var seen: usize = 1; // já estamos no primeiro
    while (try cur.nextDup()) |_| seen += 1;
    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "dupsort: delete de um valor específico" {
    defer std.fs.cwd().deleteFile(PATH) catch {};
    defer std.fs.cwd().deleteFile(PATH ++ "-lck") catch {};

    var env = try m.Environment.open(PATH, .{}, 4, 16 * 1024 * 1024);
    defer env.close();

    {
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("idx", .{ .create = true, .dupsort = true });
        try txn.put(dbi, "key", "val_a", .{});
        try txn.put(dbi, "key", "val_b", .{});
        try txn.commit();
    }

    // Deletar apenas val_a
    {
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("idx", .{ .dupsort = true });
        try txn.del(dbi, "key", "val_a");
        try txn.commit();
    }

    // Verificar que val_b ainda existe
    var txn = try m.Transaction.begin(&env, null, .{ .rdonly = true });
    defer txn.abort();
    const dbi = try txn.openDbi("idx", .{ .dupsort = true });
    var cur = try txn.cursor(dbi);
    defer cur.close();

    const found = try cur.find("key");
    try std.testing.expect(found);

    const kv = try cur.current();
    try std.testing.expect(kv != null);
    try std.testing.expectEqualStrings("val_b", kv.?.val);

    // Não deve ter mais dups
    const next = try cur.nextDup();
    try std.testing.expect(next == null);
}

test "dupsort: chaves múltiplas independentes" {
    defer std.fs.cwd().deleteFile(PATH) catch {};
    defer std.fs.cwd().deleteFile(PATH ++ "-lck") catch {};

    var env = try m.Environment.open(PATH, .{}, 4, 16 * 1024 * 1024);
    defer env.close();

    {
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("idx", .{ .create = true, .dupsort = true });

        // user A tem 2 contas
        try txn.put(dbi, "userA", "acc1", .{});
        try txn.put(dbi, "userA", "acc2", .{});
        // user B tem 1 conta
        try txn.put(dbi, "userB", "acc3", .{});
        try txn.commit();
    }

    var txn = try m.Transaction.begin(&env, null, .{ .rdonly = true });
    defer txn.abort();
    const dbi = try txn.openDbi("idx", .{ .dupsort = true });
    var cur = try txn.cursor(dbi);
    defer cur.close();

    // userA → 2 dups
    try std.testing.expect(try cur.find("userA"));
    try std.testing.expectEqual(@as(usize, 2), try cur.countDups());

    // userB → 1 dup
    try std.testing.expect(try cur.find("userB"));
    try std.testing.expectEqual(@as(usize, 1), try cur.countDups());
}
