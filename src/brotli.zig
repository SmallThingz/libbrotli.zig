const std = @import("std");
const raw = @import("brotli_raw.zig").c;

/// Full raw `libbrotli` C API exposed via `@cImport`.
pub const c = raw;

/// Default brotli quality used by `compressDefault`.
pub const default_quality: i32 = raw.BROTLI_DEFAULT_QUALITY;
/// Default brotli window used by `compressDefault`.
pub const default_window: i32 = raw.BROTLI_DEFAULT_WINDOW;

/// Options for one-shot brotli compression.
pub const CompressOptions = struct {
    /// Compression quality (`0`..`11`).
    quality: i32 = default_quality,
    /// Window size parameter (`10`..`24`).
    window: i32 = default_window,
    /// Compression mode (`generic`, `text`, `font`).
    mode: raw.BrotliEncoderMode = raw.BROTLI_DEFAULT_MODE,
};

/// Compresses `src` into a freshly allocated brotli buffer.
pub fn compress(allocator: std.mem.Allocator, src: []const u8, options: CompressOptions) ![]u8 {
    const max_size = raw.BrotliEncoderMaxCompressedSize(src.len);
    if (max_size == 0 and src.len != 0) return error.InputTooLarge;

    const out = try allocator.alloc(u8, max_size);
    errdefer allocator.free(out);

    var encoded_size: usize = out.len;
    const ok = raw.BrotliEncoderCompress(
        options.quality,
        options.window,
        options.mode,
        src.len,
        src.ptr,
        &encoded_size,
        out.ptr,
    );
    if (ok == raw.BROTLI_FALSE) return error.CompressionFailed;

    return shrinkOwnedSlice(allocator, out, encoded_size);
}

/// Compresses `src` using default quality/window/mode.
pub fn compressDefault(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    return compress(allocator, src, .{});
}

/// Decompresses `src` into a newly allocated buffer.
///
/// `max_output_size` must be a safe upper bound for the decoded data.
pub fn decompress(allocator: std.mem.Allocator, src: []const u8, max_output_size: usize) ![]u8 {
    const out = try allocator.alloc(u8, max_output_size);
    errdefer allocator.free(out);

    var decoded_size: usize = max_output_size;
    const res = raw.BrotliDecoderDecompress(
        src.len,
        src.ptr,
        &decoded_size,
        out.ptr,
    );

    if (res != raw.BROTLI_DECODER_RESULT_SUCCESS) return error.DecompressionFailed;
    return shrinkOwnedSlice(allocator, out, decoded_size);
}

fn shrinkOwnedSlice(allocator: std.mem.Allocator, buf: []u8, len: usize) ![]u8 {
    if (len == buf.len) return buf;
    if (allocator.resize(buf, len)) return buf[0..len];

    const exact = try allocator.alloc(u8, len);
    @memcpy(exact, buf[0..len]);
    allocator.free(buf);
    return exact;
}
