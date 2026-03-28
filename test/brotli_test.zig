const std = @import("std");
const libbrotli = @import("libbrotli");

test "brotli compress/decompress roundtrip" {
    const input = "libbrotli.zig one-shot roundtrip test payload";

    const compressed = try libbrotli.compressDefault(std.testing.allocator, input);
    defer std.testing.allocator.free(compressed);

    const decompressed = try libbrotli.decompress(std.testing.allocator, compressed, input.len * 4);
    defer std.testing.allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "brotli invalid payload is rejected" {
    const invalid = "not-brotli-data";
    try std.testing.expectError(
        error.DecompressionFailed,
        libbrotli.decompress(std.testing.allocator, invalid, 1024),
    );
}

test "brotli raw API is exposed" {
    try std.testing.expect(libbrotli.c.BrotliEncoderVersion() > 0);
    try std.testing.expect(libbrotli.c.BrotliDecoderVersion() > 0);
}

test "brotli stream reader/writer roundtrip" {
    const input =
        "streamed brotli encode/decode should work with std.Io.Reader and std.Io.Writer";

    var reader = std.Io.Reader.fixed(input);
    var compressed = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, input.len + 64);
    errdefer compressed.deinit();

    try libbrotli.compressReaderToWriter(std.testing.allocator, &reader, &compressed.writer, .{});

    var compressed_list = compressed.toArrayList();
    defer compressed_list.deinit(std.testing.allocator);

    var compressed_reader = std.Io.Reader.fixed(compressed_list.items);
    var decompressed = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, input.len + 64);
    errdefer decompressed.deinit();

    try libbrotli.decompressReaderToWriter(std.testing.allocator, &compressed_reader, &decompressed.writer, .{});

    var decompressed_list = decompressed.toArrayList();
    defer decompressed_list.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(input, decompressed_list.items);
}
