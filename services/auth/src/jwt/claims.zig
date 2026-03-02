//! JWT Claims — Base64url encode/decode + JSON header/payload
//! No external dependencies — uses std.base64 and manual JSON formatting.

const std = @import("std");

// Base64url without padding (RFC 4648 §5 + JWT RFC 7515)
pub const base64url = std.base64.url_safe_no_pad;

/// Encode bytes as Base64url without padding. Caller is responsible for freeing.
pub fn encode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoded_len = base64url.Encoder.calcSize(input.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = base64url.Encoder.encode(buf, input);
    return buf;
}

/// Decode a Base64url string. Caller is responsible for freeing.
pub fn decode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const decoded_len = try base64url.Decoder.calcSizeForSlice(input);
    const buf = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(buf);
    try base64url.Decoder.decode(buf, input);
    return buf;
}

/// Generate a UUID v4 using random bytes from std.crypto.random.
/// Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
pub fn generateUuidV4(buf: *[36]u8) void {
    var raw: [16]u8 = undefined;
    std.crypto.random.bytes(&raw);

    // Set version bits (4) and variant bits (RFC 4122)
    raw[6] = (raw[6] & 0x0F) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3F) | 0x80; // variant bits

    _ = std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        raw[0],  raw[1],  raw[2],  raw[3],
        raw[4],  raw[5],
        raw[6],  raw[7],
        raw[8],  raw[9],
        raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
    }) catch unreachable;
}

/// Fixed JWT header: {"alg":"EdDSA","typ":"JWT"}
/// Returns Base64url-encoded string. Caller frees.
pub fn encodedHeader(allocator: std.mem.Allocator) ![]u8 {
    const header = "{\"alg\":\"EdDSA\",\"typ\":\"JWT\"}";
    return encode(allocator, header);
}

/// Build and encode the JWT payload as Base64url. Caller frees.
pub fn encodedPayload(
    allocator: std.mem.Allocator,
    psp_id: []const u8,
    iat: i64,
    exp: i64,
    jti: []const u8,
) ![]u8 {
    // Manual JSON to avoid serializer dependency
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"iss\":\"nerve-auth\",\"sub\":\"{s}\",\"iat\":{d},\"exp\":{d},\"jti\":\"{s}\"}}",
        .{ psp_id, iat, exp, jti },
    );
    defer allocator.free(json);
    return encode(allocator, json);
}

/// Claims structure extracted from a decoded payload.
pub const Claims = struct {
    iss: []const u8,
    sub: []const u8,
    iat: i64,
    exp: i64,
    jti: []const u8,

    /// Parse payload JSON (slices point into json_buf).
    /// NOTE: returned strings point into json_buf — do not free json_buf before using Claims.
    pub fn parse(json_buf: []const u8, out: *Claims) !void {
        // Minimal parser: locate fields by string literals
        out.iss = findJsonString(json_buf, "iss") orelse return error.MissingField;
        out.sub = findJsonString(json_buf, "sub") orelse return error.MissingField;
        out.jti = findJsonString(json_buf, "jti") orelse return error.MissingField;
        out.iat = findJsonInt(json_buf, "iat") orelse return error.MissingField;
        out.exp = findJsonInt(json_buf, "exp") orelse return error.MissingField;
    }
};

/// Locate the string value of a JSON key (e.g. "sub":"psp-alpha" → "psp-alpha").
/// Returns a slice pointing into json.
fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const start_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const value_start = start_pos + needle.len;
    // Find closing '"' (first unescaped)
    var i = value_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"') break;
        if (json[i] == '\\') i += 1; // skip escape
    }
    if (i >= json.len) return null;
    return json[value_start..i];
}

/// Locate the integer value of a JSON key (e.g. "exp":1700000900 → 1700000900).
fn findJsonInt(json: []const u8, key: []const u8) ?i64 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const value_start = start_pos + needle.len;
    // Read digits (and optional negative sign)
    var end = value_start;
    if (end < json.len and json[end] == '-') end += 1;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == value_start) return null;
    return std.fmt.parseInt(i64, json[value_start..end], 10) catch null;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "base64url encode/decode round-trip" {
    const ally = std.testing.allocator;
    const original = "hello nerve";
    const enc = try encode(ally, original);
    defer ally.free(enc);
    const dec = try decode(ally, enc);
    defer ally.free(dec);
    try std.testing.expectEqualStrings(original, dec);
}

test "uuid v4 format" {
    var buf: [36]u8 = undefined;
    generateUuidV4(&buf);
    // Must have '-' at positions 8, 13, 18, 23
    try std.testing.expectEqual('-', buf[8]);
    try std.testing.expectEqual('-', buf[13]);
    try std.testing.expectEqual('-', buf[18]);
    try std.testing.expectEqual('-', buf[23]);
    // Version bit: buf[14] must be '4'
    try std.testing.expectEqual('4', buf[14]);
}

test "claims parse" {
    const json = "{\"iss\":\"nerve-auth\",\"sub\":\"psp-alpha\",\"iat\":1700000000,\"exp\":1700000900,\"jti\":\"abc-123\"}";
    var claims: Claims = undefined;
    try Claims.parse(json, &claims);
    try std.testing.expectEqualStrings("nerve-auth", claims.iss);
    try std.testing.expectEqualStrings("psp-alpha", claims.sub);
    try std.testing.expectEqual(@as(i64, 1700000000), claims.iat);
    try std.testing.expectEqual(@as(i64, 1700000900), claims.exp);
    try std.testing.expectEqualStrings("abc-123", claims.jti);
}
