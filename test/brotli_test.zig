const std = @import("std");
const libbrotli = @import("libbrotli");

test "brotli compress/decompress roundtrip" {
    const input = "libbrotli.zig one-shot roundtrip test payload";

    const compressed = try libbrotli.brotli.compressDefault(std.testing.allocator, input);
    defer std.testing.allocator.free(compressed);

    const decompressed = try libbrotli.brotli.decompress(std.testing.allocator, compressed, input.len * 4);
    defer std.testing.allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "brotli invalid payload is rejected" {
    const invalid = "not-brotli-data";
    try std.testing.expectError(
        error.DecompressionFailed,
        libbrotli.brotli.decompress(std.testing.allocator, invalid, 1024),
    );
}

test "brotli raw API is exposed" {
    try std.testing.expect(libbrotli.brotli.c.BrotliEncoderVersion() > 0);
    try std.testing.expect(libbrotli.brotli.c.BrotliDecoderVersion() > 0);
}
