//! Testes de múltiplos DBIs em um único ambiente.
//! Simula o esquema real do DICT: users + accounts + accounts_by_user.

const std = @import("std");
const m = @import("../lib.zig");

const PATH = "test_multi_dbi.monolith";

test "multi_dbi: 3 DBIs distintos no mesmo arquivo" {
    defer std.fs.cwd().deleteFile(PATH) catch {};
    defer std.fs.cwd().deleteFile(PATH ++ "-lck") catch {};

    var env = try m.Environment.open(PATH, .{}, 16, 32 * 1024 * 1024);
    defer env.close();

    // Setup: criar os 3 DBIs em uma write txn
    {
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();

        const dbi_users    = try txn.openDbi("users",            .{ .create = true });
        const dbi_accounts = try txn.openDbi("accounts",         .{ .create = true });
        const dbi_by_user  = try txn.openDbi("accounts_by_user", .{ .create = true, .dupsort = true });

        // Inserir um usuário
        const cpf = "12345678901   "; // 14 bytes
        const user_val = "user_struct_bytes_here";
        try txn.put(dbi_users, cpf, user_val, .{});

        // Inserir uma conta
        const acc_id = "uuid-acc-0000001"; // 16 bytes
        const acc_val = "account_struct_bytes";
        try txn.put(dbi_accounts, acc_id, acc_val, .{});

        // Índice secundário: user → account
        try txn.put(dbi_by_user, cpf, acc_id, .{});

        try txn.commit();
    }

    // Verificar os 3 DBIs em uma read txn
    var txn = try m.Transaction.begin(&env, null, .{ .rdonly = true });
    defer txn.abort();

    const dbi_users    = try txn.openDbi("users",            .{});
    const dbi_accounts = try txn.openDbi("accounts",         .{});
    const dbi_by_user  = try txn.openDbi("accounts_by_user", .{ .dupsort = true });

    // Verificar user
    const user = try txn.get(dbi_users, "12345678901   ");
    try std.testing.expect(user != null);
    try std.testing.expectEqualStrings("user_struct_bytes_here", user.?);

    // Verificar account
    const acc = try txn.get(dbi_accounts, "uuid-acc-0000001");
    try std.testing.expect(acc != null);

    // JOIN: user → accounts (via índice secundário)
    var cur = try txn.cursor(dbi_by_user);
    defer cur.close();

    const found = try cur.find("12345678901   ");
    try std.testing.expect(found);

    const kv = try cur.current();
    try std.testing.expect(kv != null);
    // O value é o account_id — usar para lookup no dbi_accounts
    try std.testing.expectEqualStrings("uuid-acc-0000001", kv.?.val);
}

test "multi_dbi: DBIs são isolados" {
    defer std.fs.cwd().deleteFile(PATH) catch {};
    defer std.fs.cwd().deleteFile(PATH ++ "-lck") catch {};

    var env = try m.Environment.open(PATH, .{}, 8, 16 * 1024 * 1024);
    defer env.close();

    {
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        const dbi_a = try txn.openDbi("db_a", .{ .create = true });
        const dbi_b = try txn.openDbi("db_b", .{ .create = true });

        // Mesma chave em DBIs diferentes
        try txn.put(dbi_a, "key", "value_from_a", .{});
        try txn.put(dbi_b, "key", "value_from_b", .{});
        try txn.commit();
    }

    var txn = try m.Transaction.begin(&env, null, .{ .rdonly = true });
    defer txn.abort();
    const dbi_a = try txn.openDbi("db_a", .{});
    const dbi_b = try txn.openDbi("db_b", .{});

    const va = try txn.get(dbi_a, "key");
    const vb = try txn.get(dbi_b, "key");

    try std.testing.expect(va != null);
    try std.testing.expect(vb != null);
    try std.testing.expectEqualStrings("value_from_a", va.?);
    try std.testing.expectEqualStrings("value_from_b", vb.?);
    // Os valores são diferentes apesar da mesma chave
    try std.testing.expect(!std.mem.eql(u8, va.?, vb.?));
}

test "multi_dbi: transação atômica em múltiplos DBIs" {
    defer std.fs.cwd().deleteFile(PATH) catch {};
    defer std.fs.cwd().deleteFile(PATH ++ "-lck") catch {};

    var env = try m.Environment.open(PATH, .{}, 8, 16 * 1024 * 1024);
    defer env.close();

    // Setup
    {
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        _ = try txn.openDbi("primary", .{ .create = true });
        _ = try txn.openDbi("secondary", .{ .create = true, .dupsort = true });
        try txn.commit();
    }

    // Simular abort: nada deve ter sido inserido
    {
        var txn = try m.Transaction.begin(&env, null, .{});
        const dbi_p = try txn.openDbi("primary",   .{});
        const dbi_s = try txn.openDbi("secondary", .{ .dupsort = true });
        try txn.put(dbi_p, "k", "v", .{});
        try txn.put(dbi_s, "k", "v", .{});
        txn.abort(); // descarta tudo
    }

    // Verificar que o abort funcionou
    var txn = try m.Transaction.begin(&env, null, .{ .rdonly = true });
    defer txn.abort();
    const dbi_p = try txn.openDbi("primary", .{});
    const val = try txn.get(dbi_p, "k");
    try std.testing.expect(val == null);
}
