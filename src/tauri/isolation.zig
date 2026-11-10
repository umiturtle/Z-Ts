//! Tauri v2 `app.security.pattern: "isolation"` — AES-256-GCM IPC envelope, in Pure Zig.
//!
//! Upstream Tauri puts the frontend inside an *isolation iframe* that encrypts every IPC payload
//! with AES-GCM before it reaches Rust. The Rust side owns the key, so JavaScript injected by an
//! XSS (or a compromised dev server) can see neither the plaintext arguments nor the results of
//! commands it did not originate. ziggurats reproduces the same wire contract:
//!
//!  1. `config_import.zig` reads `pattern.use == "isolation"` and `pattern.options.dir`.
//!  2. `js_bootstrap.zig` injects `__TAURI_ISOLATION_HOOK__` support and encrypts the raw IPC
//!     body with WebCrypto (`crypto.subtle`, AES-GCM, 96-bit random nonce per message).
//!  3. `protocol.zig` verifies the CSRF key as usual, then decrypts the envelope with this module
//!     and dispatches the *plaintext* body.
//!
//! No OpenSSL / ring / OS crypto dependency: `std.crypto.aead.aes_gcm.Aes256Gcm` is Pure Zig and
//! behaves identically on Linux, macOS and Windows. The key is derived deterministically from a
//! fixed seed (plus an optional config seed), so two builds of the same source produce the same
//! bundle. Nonces are generated per request at runtime by the WebView — never at build time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

/// Additional authenticated data. Binds a ciphertext to this IPC protocol version so a blob from
/// another scheme (or a future format) cannot be replayed as a command body.
pub const associated_data = "ziggurats-isolation-v1";

/// Build-time seed. Deterministic by design; the real per-install secret is the config-provided
/// seed (or the per-launch CSRF invoke key, which every message still has to present).
pub const domain_seed = "ziggurats/isolation/aes-256-gcm/v1";

pub const Key = [Aes256Gcm.key_length]u8;
pub const Nonce = [Aes256Gcm.nonce_length]u8;
pub const Tag = [Aes256Gcm.tag_length]u8;

/// Errors returned while opening an envelope. All of them map to HTTP 403 in `protocol.zig`.
pub const OpenError = error{
    OutOfMemory,
    /// Body is not the expected `{"nonce":...,"ct":...}` JSON.
    MalformedEnvelope,
    /// Base64 is invalid.
    BadBase64,
    /// Ciphertext is shorter than the 16-byte GCM tag.
    TruncatedCiphertext,
    /// Authentication failed: wrong key, wrong nonce, tampered ciphertext, or a replay with
    /// different associated data.
    AuthenticationFailed,
};

/// Derives a 32-byte key. `seed` may be empty: the domain seed alone produces a stable key, so
/// builds are reproducible. Passing a config seed (e.g. the app identifier) separates apps.
pub fn deriveKey(seed: []const u8) Key {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(domain_seed);
    hasher.update(&.{0});
    hasher.update(seed);
    var out: Key = undefined;
    hasher.final(&out);
    return out;
}

/// Resolves the runtime key from `app.security.pattern.options.keyHex` and the app identifier.
/// A missing/invalid hex string falls back to a deterministic derivation, so a config typo can
/// never silently disable encryption; it only changes the key (and is reported by the importer).
pub fn keyFor(identifier: []const u8, hex: []const u8) Key {
    if (parseKeyHex(hex)) |key| return key;
    return deriveKey(identifier);
}

/// Parses 64 hexadecimal characters into a key. Accepts upper/lowercase; rejects anything else.
pub fn parseKeyHex(hex: []const u8) ?Key {
    if (hex.len != Aes256Gcm.key_length * 2) return null;
    var out: Key = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

/// Renders a key as the 64 lowercase hex characters `js_bootstrap.zig` embeds in the script.
pub fn keyHex(key: Key) [Aes256Gcm.key_length * 2]u8 {
    return std.fmt.bytesToHex(key, .lower);
}

/// Encrypts `plaintext` into a JSON envelope:
/// `{"nonce":"<base64 12 bytes>","ct":"<base64 ciphertext||tag>"}`.
/// The caller supplies the nonce; the WebView uses `crypto.getRandomValues` per message.
pub fn seal(allocator: Allocator, key: Key, nonce: Nonce, plaintext: []const u8) Allocator.Error![]u8 {
    const cipher_len = plaintext.len;
    const cipher = try allocator.alloc(u8, cipher_len);
    defer allocator.free(cipher);
    var tag: Tag = undefined;
    Aes256Gcm.encrypt(cipher, &tag, plaintext, associated_data, nonce, key);

    var sealed = try allocator.alloc(u8, cipher_len + Aes256Gcm.tag_length);
    defer allocator.free(sealed);
    @memcpy(sealed[0..cipher_len], cipher);
    @memcpy(sealed[cipher_len..], &tag);

    const enc = std.base64.standard.Encoder;
    const nonce_b64 = try allocator.alloc(u8, enc.calcSize(nonce.len));
    defer allocator.free(nonce_b64);
    const ct_b64 = try allocator.alloc(u8, enc.calcSize(sealed.len));
    defer allocator.free(ct_b64);
    _ = enc.encode(nonce_b64, &nonce);
    _ = enc.encode(ct_b64, sealed);

    return std.fmt.allocPrint(allocator, "{{\"nonce\":\"{s}\",\"ct\":\"{s}\"}}", .{ nonce_b64, ct_b64 });
}

/// The inverse of `seal`. Returns the plaintext body, owned by `allocator`.
pub fn open(allocator: Allocator, key: Key, envelope_json: []const u8) OpenError![]u8 {
    const parsed = std.json.parseFromSliceLeaky(
        struct { nonce: []const u8, ct: []const u8 },
        allocator,
        envelope_json,
        .{ .ignore_unknown_fields = true },
    ) catch return error.MalformedEnvelope;

    const dec = std.base64.standard.Decoder;
    const nonce_len = dec.calcSizeForSlice(parsed.nonce) catch return error.BadBase64;
    const ct_len = dec.calcSizeForSlice(parsed.ct) catch return error.BadBase64;
    if (nonce_len != Aes256Gcm.nonce_length) return error.MalformedEnvelope;
    if (ct_len < Aes256Gcm.tag_length) return error.TruncatedCiphertext;

    var nonce: Nonce = undefined;
    dec.decode(&nonce, parsed.nonce) catch return error.BadBase64;
    const sealed = try allocator.alloc(u8, ct_len);
    defer allocator.free(sealed);
    dec.decode(sealed, parsed.ct) catch return error.BadBase64;

    const cipher_len = ct_len - Aes256Gcm.tag_length;
    const plain = try allocator.alloc(u8, cipher_len);
    errdefer allocator.free(plain);
    var tag: Tag = undefined;
    @memcpy(&tag, sealed[cipher_len..]);
    Aes256Gcm.decrypt(plain, sealed[0..cipher_len], tag, associated_data, nonce, key) catch
        return error.AuthenticationFailed;
    return plain;
}

test "P0-3: seal/open round-trips text and binary bodies" {
    const key = deriveKey("com.example.isolated");
    var nonce: Nonce = undefined;
    for (&nonce, 0..) |*b, i| b.* = @intCast(i + 1);

    for ([_][]const u8{
        "{\"who\":\"world\"}",
        "",
        "こんにちは\xff\x00\x01binary",
    }) |body| {
        const envelope = try seal(testing.allocator, key, nonce, body);
        defer testing.allocator.free(envelope);
        try testing.expect(std.mem.indexOf(u8, body, "who") == null or
            std.mem.indexOf(u8, envelope, "who") == null);
        const plain = try open(testing.allocator, key, envelope);
        defer testing.allocator.free(plain);
        try testing.expectEqualStrings(body, plain);
    }
}

test "P0-3: wrong key, tampered ciphertext, malformed envelope and truncated tag are rejected" {
    const key = deriveKey("app-a");
    const other = deriveKey("app-b");
    const nonce: Nonce = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const envelope = try seal(testing.allocator, key, nonce, "{\"secret\":42}");
    defer testing.allocator.free(envelope);

    try testing.expectError(error.AuthenticationFailed, open(testing.allocator, other, envelope));

    const parsed = std.json.parseFromSliceLeaky(
        struct { nonce: []const u8, ct: []const u8 },
        testing.allocator,
        envelope,
        .{},
    ) catch unreachable;
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(parsed.ct) catch unreachable;
    var sealed = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(sealed);
    dec.decode(sealed, parsed.ct) catch unreachable;
    sealed[0] ^= 0x80;
    const enc = std.base64.standard.Encoder;
    const flipped = try testing.allocator.alloc(u8, enc.calcSize(sealed.len));
    defer testing.allocator.free(flipped);
    _ = enc.encode(flipped, sealed);
    const tampered = try std.fmt.allocPrint(testing.allocator, "{{\"nonce\":\"{s}\",\"ct\":\"{s}\"}}", .{ parsed.nonce, flipped });
    defer testing.allocator.free(tampered);
    try testing.expectError(error.AuthenticationFailed, open(testing.allocator, key, tampered));

    try testing.expectError(error.MalformedEnvelope, open(testing.allocator, key, "{}"));
    try testing.expectError(error.MalformedEnvelope, open(testing.allocator, key, "not json"));
    try testing.expectError(error.MalformedEnvelope, open(testing.allocator, key, "{\"nonce\":\"AAAA\",\"ct\":\"AAAA\"}"));
    const short = try std.fmt.allocPrint(testing.allocator, "{{\"nonce\":\"{s}\",\"ct\":\"\"}}", .{parsed.nonce});
    defer testing.allocator.free(short);
    try testing.expectError(error.TruncatedCiphertext, open(testing.allocator, key, short));
}

test "P0-3: key derivation and hex serialisation are deterministic" {
    const a = deriveKey("com.example.isolation");
    try testing.expectEqualSlices(u8, &a, &deriveKey("com.example.isolation"));
    try testing.expect(!std.mem.eql(u8, &a, &deriveKey("com.example.other")));
    const hex = keyHex(a);
    const back = parseKeyHex(&hex).?;
    try testing.expectEqualSlices(u8, &a, &back);
    try testing.expect(parseKeyHex("deadbeef") == null);
    var bad_hex: [64]u8 = undefined;
    @memset(&bad_hex, 'z');
    try testing.expect(parseKeyHex(&bad_hex) == null);
}
