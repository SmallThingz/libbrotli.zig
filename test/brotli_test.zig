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

const allocator = std.testing.allocator;

test "binary and empty exact roundtrips with output limits" {
    var binary: [131071]u8 = undefined;
    for (&binary, 0..) |*byte, i| byte.* = @truncate(i *% 197 +% (i >> 7));
    for ([_][]const u8{ "", &binary }) |input| {
        const encoded = try libbrotli.compressDefault(allocator, input);
        defer allocator.free(encoded);
        const restored = try libbrotli.decompress(allocator, encoded, input.len);
        defer allocator.free(restored);
        try std.testing.expectEqualSlices(u8, input, restored);
        if (input.len != 0)
            try std.testing.expectError(error.OutputTooLarge, libbrotli.decompress(allocator, encoded, input.len - 1));
    }
}

test "incremental tiny buffers flush and finalized encoder state" {
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    var encoder = try libbrotli.Encoder.init(allocator, .{ .stream = .{ .in_buffer_size = 3, .out_buffer_size = 1 } });
    defer encoder.deinit();
    const input = "repeated repeated repeated binary\x00\xff repeated";
    for (input) |byte| {
        try encoder.update(&.{byte}, &encoded.writer);
    }
    try encoder.flush(&encoded.writer);
    try encoder.finish(&encoded.writer);
    try encoder.finish(&encoded.writer);
    try std.testing.expectError(error.StreamFinished, encoder.update("late", &encoded.writer));
    var restored: std.Io.Writer.Allocating = .init(allocator);
    defer restored.deinit();
    var decoder = try libbrotli.Decoder.init(allocator, .{ .max_output_size = input.len, .stream = .{ .in_buffer_size = 1, .out_buffer_size = 1 } });
    defer decoder.deinit();
    for (encoded.written()) |byte| {
        _ = try decoder.update(&.{byte}, &restored.writer);
    }
    try std.testing.expect(decoder.isFinished());
    try decoder.finish();
    try std.testing.expectEqualSlices(u8, input, restored.written());
}

test "every truncated prefix is rejected by streaming decoder" {
    const encoded = try libbrotli.compressDefault(allocator, "all bytes matter in this complete compressed frame");
    defer allocator.free(encoded);
    for (0..encoded.len) |n| {
        var decoder = try libbrotli.Decoder.init(allocator, .{ .stream = .{ .in_buffer_size = 1, .out_buffer_size = 7 } });
        defer decoder.deinit();
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var reader: std.Io.Reader = .fixed(encoded[0..n]);
        try std.testing.expectError(error.TruncatedInput, decoder.decodeReader(&reader, &out.writer));
    }
}

test "stream limit and failed writer poison decoder or encoder" {
    const encoded = try libbrotli.compressDefault(allocator, &@as([4096]u8, @splat('a')));
    defer allocator.free(encoded);
    var decoder = try libbrotli.Decoder.init(allocator, .{ .max_output_size = 9, .stream = .{ .out_buffer_size = 5 } });
    defer decoder.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.OutputTooLarge, decoder.update(encoded, &out.writer));
    try std.testing.expect(out.written().len <= 9);
    try std.testing.expectError(error.InvalidState, decoder.update(encoded, &out.writer));

    var encoder = try libbrotli.Encoder.init(allocator, .{});
    defer encoder.deinit();
    var buffer: [0]u8 = .{};
    var writer: std.Io.Writer = .fixed(&buffer);
    try encoder.update("payload", &writer);
    try std.testing.expectError(error.WriteFailed, encoder.finish(&writer));
    try std.testing.expect(encoder.isFinished());
    try std.testing.expectError(error.InvalidState, encoder.finish(&writer));
    try std.testing.expectError(error.InvalidState, encoder.flush(&writer));
    try std.testing.expectError(error.InvalidState, encoder.update("retry", &writer));
}

fn allocationRoundtrip(a: std.mem.Allocator) !void {
    const encoded = try libbrotli.compressDefault(a, "allocation failure across native state buffers and output");
    defer a.free(encoded);
    const restored = try libbrotli.decompress(a, encoded, 100);
    defer a.free(restored);
    try std.testing.expectEqualStrings("allocation failure across native state buffers and output", restored);
}

test "every native and Zig allocation failure is leak free" {
    try std.testing.checkAllAllocationFailures(allocator, allocationRoundtrip, .{});
}

test "zero buffer sizes rejected without leaking" {
    try std.testing.expectError(error.InvalidBufferSize, libbrotli.Encoder.init(allocator, .{ .stream = .{ .out_buffer_size = 0 } }));
    try std.testing.expectError(error.InvalidBufferSize, libbrotli.Decoder.init(allocator, .{ .stream = .{ .in_buffer_size = 0 } }));
}

test "invalid options clean up once and trailing bytes are rejected" {
    try std.testing.expectError(error.InvalidParameter, libbrotli.Encoder.init(allocator, .{ .quality = 12 }));
    try std.testing.expectError(error.InvalidParameter, libbrotli.compress(allocator, "input", .{ .window = 9 }));
    const encoded = try libbrotli.compressDefault(allocator, "complete");
    defer allocator.free(encoded);
    const extra = try std.mem.concat(allocator, u8, &.{ encoded, "junk" });
    defer allocator.free(extra);
    try std.testing.expectError(error.TrailingData, libbrotli.decompress(allocator, extra, 100));
}

fn dictionaryRoundtrip(a: std.mem.Allocator) !void {
    const phrase = "prefix dictionary vocabulary usable for this data ";
    var bytes: [phrase.len * 4]u8 = undefined;
    for (0..4) |i| @memcpy(bytes[i * phrase.len ..][0..phrase.len], phrase);
    var dictionary = try libbrotli.PreparedDictionary.init(a, &bytes, 5);
    defer dictionary.deinit();
    var encoder = try libbrotli.Encoder.init(a, .{ .quality = 5 });
    defer encoder.deinit();
    try encoder.useDictionary(&dictionary);
    var decoder = try libbrotli.Decoder.init(a, .{});
    defer decoder.deinit();
    try decoder.loadDictionary(&bytes);
    @memset(&bytes, 0);
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    const input = "prefix dictionary vocabulary usable for this data ";
    encoder.update(input, &encoded.writer) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    encoder.finish(&encoded.writer) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    _ = decoder.update(encoded.written(), &output.writer) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    try std.testing.expect(decoder.isFinished());
    try decoder.finish();
    try std.testing.expectEqualStrings(input, output.written());
}

test "owned dictionaries roundtrip and native allocation failures" {
    try std.testing.checkAllAllocationFailures(allocator, dictionaryRoundtrip, .{});
}
