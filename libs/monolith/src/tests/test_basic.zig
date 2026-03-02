//! Testes básicos: open/close, put/get/del, transação simples.

const std = @import("std");
const m = @import("../lib.zig");

const PATH = "test_basic.monolith";

test "Environment: open e close" {
    defer std.fs.cwd().deleteFile(PATH) catch {};
    defer std.fs.cwd().deleteFile(PATH ++ "-lck") catch {};

    var env = try m.Environment.open(PATH, .{}, 4, 16 * 1024 * 1024);
    env.close();
}

test "Transaction: write e read simples" {
    defer std.fs.cwd().deleteFile(PATH) catch {};
    defer std.fs.cwd().deleteFile(PATH ++ "-lck") catch {};

    var env = try m.Environment.open(PATH, .{}, 4, 16 * 1024 * 1024);
    defer env.close();

    // Write txn — cria DBI e insere um valor
    {
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();

        const dbi = try txn.openDbi("kv", .{ .create = true });
        try txn.put(dbi, "hello", "world", .{});
        try txn.commit();
    }

    // Read txn — verifica o valor
    {
        var txn = try m.Transaction.begin(&env, null, .{ .rdonly = true });
        defer txn.abort();

        const dbi = try txn.openDbi("kv", .{});
        const val = try txn.get(dbi, "hello");
        try std.testing.expect(val != null);
        try std.testing.expectEqualStrings("world", val.?);
    }
}

test "Transaction: get de chave inexistente retorna null" {
    defer std.fs.cwd().deleteFile(PATH) catch {};
    defer std.fs.cwd().deleteFile(PATH ++ "-lck") catch {};

    var env = try m.Environment.open(PATH, .{}, 4, 16 * 1024 * 1024);
    defer env.close();

    {
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("kv", .{ .create = true });
        try txn.commit();
        _ = dbi;
    }

    var txn = try m.Transaction.begin(&env, null, .{ .rdonly = true });
    defer txn.abort();
    const dbi = try txn.openDbi("kv", .{});
    const val = try txn.get(dbi, "nao_existe");
    try std.testing.expect(val == null);
}

test "Transaction: del remove chave" {
    defer std.fs.cwd().deleteFile(PATH) catch {};
    defer std.fs.cwd().deleteFile(PATH ++ "-lck") catch {};

    var env = try m.Environment.open(PATH, .{}, 4, 16 * 1024 * 1024);
    defer env.close();

    {
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("kv", .{ .create = true });
        try txn.put(dbi, "k1", "v1", .{});
        try txn.del(dbi, "k1", null);
        try txn.commit();
    }

    var txn = try m.Transaction.begin(&env, null, .{ .rdonly = true });
    defer txn.abort();
    const dbi = try txn.openDbi("kv", .{});
    const val = try txn.get(dbi, "k1");
    try std.testing.expect(val == null);
}

test "Cursor: iteração completa" {
    defer std.fs.cwd().deleteFile(PATH) catch {};
    defer std.fs.cwd().deleteFile(PATH ++ "-lck") catch {};

    var env = try m.Environment.open(PATH, .{}, 4, 16 * 1024 * 1024);
    defer env.close();

    // Inserir 3 chaves
    {
        var txn = try m.Transaction.begin(&env, null, .{});
        errdefer txn.abort();
        const dbi = try txn.openDbi("kv", .{ .create = true });
        try txn.put(dbi, "a", "1", .{});
        try txn.put(dbi, "b", "2", .{});
        try txn.put(dbi, "c", "3", .{});
        try txn.commit();
    }

    // Iterar via cursor
    var txn = try m.Transaction.begin(&env, null, .{ .rdonly = true });
    defer txn.abort();
    const dbi = try txn.openDbi("kv", .{});
    var cur = try txn.cursor(dbi);
    defer cur.close();

    var count: usize = 0;
    if (try cur.first()) |_| {
        count += 1;
        while (try cur.next()) |_| count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}
