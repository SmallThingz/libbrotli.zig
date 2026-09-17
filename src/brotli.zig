const std = @import("std");
const Memory = @import("memory.zig").Memory;
const raw = @import("brotli_raw.zig").c;

/// Full raw `libbrotli` C API exposed via `@cImport`.
pub const c = raw;

/// Default brotli quality used by `compressDefault`.
pub const default_quality: i32 = raw.BROTLI_DEFAULT_QUALITY;
/// Default brotli window used by `compressDefault`.
pub const default_window: i32 = raw.BROTLI_DEFAULT_WINDOW;
/// Default brotli mode used by `compressDefault`.
pub const Mode = enum(u32) { generic = 0, text = 1, font = 2 };
pub const default_mode: Mode = .generic;

/// Default input chunk size used by stream helpers.
pub const default_stream_in_buffer_size: usize = 64 * 1024;
/// Default output chunk size used by stream helpers.
pub const default_stream_out_buffer_size: usize = 64 * 1024;

/// Stream buffer sizing options.
pub const StreamOptions = struct {
    /// Size of temporary input buffer used by `encodeReader` / `decodeReader`.
    in_buffer_size: usize = default_stream_in_buffer_size,
    /// Size of temporary output buffer used for writer flushes.
    out_buffer_size: usize = default_stream_out_buffer_size,
};

/// Streaming encoder options.
pub const EncoderOptions = struct {
    /// Compression quality (`0`..`11`).
    quality: i32 = default_quality,
    /// Window size parameter (`10`..`24`).
    window: i32 = default_window,
    /// Compression mode (`generic`, `text`, `font`).
    mode: Mode = default_mode,
    /// Stream buffer sizing options.
    stream: StreamOptions = .{},
};

/// Streaming decoder options.
pub const DecoderOptions = struct {
    /// Maximum total decoded bytes. Enforced before writing each output chunk.
    max_output_size: usize = std.math.maxInt(usize),
    /// Enables "large window brotli" decoder mode.
    large_window: bool = false,
    /// Disables dynamic ring-buffer resizing.
    disable_ring_buffer_reallocation: bool = false,
    /// Stream buffer sizing options.
    stream: StreamOptions = .{},
};

/// Result from `Decoder.update`.
pub const DecodeStatus = enum {
    /// The brotli stream has reached end-of-frame.
    success,
    /// More input is required to continue decoding.
    needs_more_input,
};

/// Options for one-shot brotli compression.
pub const CompressOptions = struct {
    /// Compression quality (`0`..`11`).
    quality: i32 = default_quality,
    /// Window size parameter (`10`..`24`).
    window: i32 = default_window,
    /// Compression mode (`generic`, `text`, `font`).
    mode: Mode = default_mode,
};

/// Streaming brotli encoder that writes compressed bytes to a `std.Io.Writer`.
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    state: *raw.BrotliEncoderState,
    memory: *Memory,
    failed: bool = false,
    in_buffer: []u8,
    out_buffer: []u8,

    /// Allocates and initializes an encoder stream.
    pub fn init(allocator: std.mem.Allocator, options: EncoderOptions) !Encoder {
        if (options.stream.in_buffer_size == 0 or options.stream.out_buffer_size == 0) {
            return error.InvalidBufferSize;
        }

        const memory = try Memory.create(allocator);
        errdefer memory.destroy();
        const state = raw.BrotliEncoderCreateInstance(Memory.alloc, Memory.free, memory) orelse return error.OutOfMemory;
        errdefer raw.BrotliEncoderDestroyInstance(state);

        const in_buffer = try allocator.alloc(u8, options.stream.in_buffer_size);
        errdefer allocator.free(in_buffer);
        const out_buffer = try allocator.alloc(u8, options.stream.out_buffer_size);
        errdefer allocator.free(out_buffer);

        var self = Encoder{
            .allocator = allocator,
            .state = state,
            .memory = memory,
            .in_buffer = in_buffer,
            .out_buffer = out_buffer,
        };

        try validateOptions(options.quality, options.window);
        try self.setParameter(raw.BROTLI_PARAM_QUALITY, try toU32Checked(options.quality));
        try self.setParameter(raw.BROTLI_PARAM_LGWIN, try toU32Checked(options.window));
        try self.setParameter(raw.BROTLI_PARAM_MODE, @intFromEnum(options.mode));

        return self;
    }

    /// Releases encoder state and owned buffers.
    pub fn deinit(self: *Encoder) void {
        self.allocator.free(self.in_buffer);
        self.allocator.free(self.out_buffer);
        raw.BrotliEncoderDestroyInstance(self.state);
        self.memory.destroy();
        self.* = undefined;
    }

    /// Sets an encoder parameter on the underlying stream state.
    pub fn setParameter(self: *Encoder, param: raw.BrotliEncoderParameter, value: u32) !void {
        const ok = raw.BrotliEncoderSetParameter(self.state, param, value);
        if (ok == raw.BROTLI_FALSE) return error.InvalidParameter;
    }

    /// Attach an owned dictionary by reference; it must outlive this encoder.
    pub fn useDictionary(self: *Encoder, dictionary: *const PreparedDictionary) !void {
        try self.attachPreparedDictionary(dictionary.handle);
    }

    /// Attaches a borrowed prepared dictionary; it must outlive the encoder.
    pub fn attachPreparedDictionary(self: *Encoder, dictionary: *const raw.BrotliEncoderPreparedDictionary) !void {
        const ok = raw.BrotliEncoderAttachPreparedDictionary(self.state, dictionary);
        if (ok == raw.BROTLI_FALSE) return if (self.memory.failed) error.OutOfMemory else error.InvalidDictionary;
    }

    /// Returns `true` when the stream has produced all final output.
    pub fn isFinished(self: *const Encoder) bool {
        return raw.BrotliEncoderIsFinished(self.state) != raw.BROTLI_FALSE;
    }

    /// Returns `true` when the encoder still has pending output.
    pub fn hasMoreOutput(self: *const Encoder) bool {
        return raw.BrotliEncoderHasMoreOutput(self.state) != raw.BROTLI_FALSE;
    }

    /// Encodes `input` with `BROTLI_OPERATION_PROCESS`.
    pub fn update(self: *Encoder, input: []const u8, writer: *std.Io.Writer) !void {
        try self.runOperation(input, raw.BROTLI_OPERATION_PROCESS, writer);
    }

    /// Flushes all currently buffered compressed data.
    pub fn flush(self: *Encoder, writer: *std.Io.Writer) !void {
        try self.runOperation(&.{}, raw.BROTLI_OPERATION_FLUSH, writer);
    }

    /// Finalizes the stream and writes trailing bytes.
    pub fn finish(self: *Encoder, writer: *std.Io.Writer) !void {
        if (self.failed) return error.InvalidState;
        while (!self.isFinished()) {
            try self.runOperation(&.{}, raw.BROTLI_OPERATION_FINISH, writer);
        }
    }

    /// Emits metadata block bytes into the brotli stream.
    pub fn emitMetadata(self: *Encoder, metadata: []const u8, writer: *std.Io.Writer) !void {
        const metadata_limit = 16 * 1024 * 1024;
        if (metadata.len > metadata_limit) return error.MetadataTooLarge;
        try self.runOperation(metadata, raw.BROTLI_OPERATION_EMIT_METADATA, writer);
    }

    /// Reads all bytes from `reader`, compresses them, and writes to `writer`.
    pub fn encodeReader(self: *Encoder, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        while (true) {
            const n = try reader.readSliceShort(self.in_buffer);
            if (n == 0) break;
            try self.update(self.in_buffer[0..n], writer);
        }
        try self.finish(writer);
    }

    fn runOperation(
        self: *Encoder,
        input: []const u8,
        op: raw.BrotliEncoderOperation,
        writer: *std.Io.Writer,
    ) !void {
        if (self.failed) return error.InvalidState;
        if (self.isFinished()) return error.StreamFinished;
        errdefer self.failed = true;
        var available_in: usize = input.len;
        var next_in: [*c]const u8 = if (input.len == 0) null else @ptrCast(input.ptr);

        while (true) {
            const prev_available_in = available_in;

            var available_out: usize = self.out_buffer.len;
            var next_out: [*c]u8 = @ptrCast(self.out_buffer.ptr);

            const ok = raw.BrotliEncoderCompressStream(
                self.state,
                op,
                &available_in,
                &next_in,
                &available_out,
                &next_out,
                null,
            );
            if (ok == raw.BROTLI_FALSE) return if (self.memory.failed) error.OutOfMemory else error.CompressionFailed;

            const produced = self.out_buffer.len - available_out;
            if (produced != 0) try writer.writeAll(self.out_buffer[0..produced]);

            const input_depleted = available_in == 0;
            const has_more_output = self.hasMoreOutput();

            if (input_depleted and !has_more_output) break;
            if (produced == 0 and available_in == prev_available_in) return error.CompressionStalled;
        }
    }
};

/// Streaming brotli decoder that writes decompressed bytes to a `std.Io.Writer`.
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    state: *raw.BrotliDecoderState,
    memory: *Memory,
    failed: bool = false,
    total_output: usize = 0,
    max_output_size: usize,
    dictionaries: std.ArrayList([]u8) = .empty,
    in_buffer: []u8,
    out_buffer: []u8,

    /// Allocates and initializes a decoder stream.
    pub fn init(allocator: std.mem.Allocator, options: DecoderOptions) !Decoder {
        if (options.stream.in_buffer_size == 0 or options.stream.out_buffer_size == 0) {
            return error.InvalidBufferSize;
        }

        const memory = try Memory.create(allocator);
        errdefer memory.destroy();
        const state = raw.BrotliDecoderCreateInstance(Memory.alloc, Memory.free, memory) orelse return error.OutOfMemory;
        errdefer raw.BrotliDecoderDestroyInstance(state);

        const in_buffer = try allocator.alloc(u8, options.stream.in_buffer_size);
        errdefer allocator.free(in_buffer);
        const out_buffer = try allocator.alloc(u8, options.stream.out_buffer_size);
        errdefer allocator.free(out_buffer);

        var self = Decoder{
            .allocator = allocator,
            .max_output_size = options.max_output_size,
            .state = state,
            .memory = memory,
            .in_buffer = in_buffer,
            .out_buffer = out_buffer,
        };

        if (options.large_window) {
            try self.setParameter(raw.BROTLI_DECODER_PARAM_LARGE_WINDOW, 1);
        }
        if (options.disable_ring_buffer_reallocation) {
            try self.setParameter(raw.BROTLI_DECODER_PARAM_DISABLE_RING_BUFFER_REALLOCATION, 1);
        }

        return self;
    }

    /// Releases decoder state and owned buffers.
    pub fn deinit(self: *Decoder) void {
        self.allocator.free(self.in_buffer);
        self.allocator.free(self.out_buffer);
        raw.BrotliDecoderDestroyInstance(self.state);
        for (self.dictionaries.items) |bytes| self.allocator.free(bytes);
        self.dictionaries.deinit(self.allocator);
        self.memory.destroy();
        self.* = undefined;
    }

    /// Sets a decoder parameter on the underlying state.
    pub fn setParameter(self: *Decoder, param: raw.BrotliDecoderParameter, value: u32) !void {
        const ok = raw.BrotliDecoderSetParameter(self.state, param, value);
        if (ok == raw.BROTLI_FALSE) return error.InvalidParameter;
    }

    /// Copies a prefix dictionary into this decoder; caller bytes can be freed.
    pub fn loadDictionary(self: *Decoder, bytes: []const u8) !void {
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        try self.dictionaries.ensureUnusedCapacity(self.allocator, 1);
        try self.attachDictionary(raw.BROTLI_SHARED_DICTIONARY_RAW, owned);
        self.dictionaries.appendAssumeCapacity(owned);
    }

    /// Attaches a borrowed shared dictionary. Bytes must outlive this decoder.
    pub fn attachDictionary(
        self: *Decoder,
        dict_type: raw.BrotliSharedDictionaryType,
        dictionary: []const u8,
    ) !void {
        const ok = raw.BrotliDecoderAttachDictionary(
            self.state,
            dict_type,
            dictionary.len,
            if (dictionary.len == 0) null else @ptrCast(dictionary.ptr),
        );
        if (ok == raw.BROTLI_FALSE) return if (self.memory.failed) error.OutOfMemory else error.InvalidDictionary;
    }

    /// Returns `true` when stream reached final state.
    pub fn isFinished(self: *const Decoder) bool {
        return raw.BrotliDecoderIsFinished(self.state) != raw.BROTLI_FALSE;
    }

    /// Returns `true` when decoder reports pending output.
    pub fn hasMoreOutput(self: *const Decoder) bool {
        return raw.BrotliDecoderHasMoreOutput(self.state) != raw.BROTLI_FALSE;
    }

    /// Decodes one chunk and writes produced output.
    pub fn update(self: *Decoder, input: []const u8, writer: *std.Io.Writer) !DecodeStatus {
        if (self.failed) return error.InvalidState;
        errdefer self.failed = true;
        var available_in: usize = input.len;
        var next_in: [*c]const u8 = if (input.len == 0) null else @ptrCast(input.ptr);

        while (true) {
            var available_out: usize = self.out_buffer.len;
            var next_out: [*c]u8 = @ptrCast(self.out_buffer.ptr);

            const result = raw.BrotliDecoderDecompressStream(
                self.state,
                &available_in,
                &next_in,
                &available_out,
                &next_out,
                null,
            );

            const produced = self.out_buffer.len - available_out;
            if (produced > self.max_output_size - self.total_output) return error.OutputTooLarge;
            if (produced != 0) try writer.writeAll(self.out_buffer[0..produced]);
            self.total_output += produced;

            switch (result) {
                raw.BROTLI_DECODER_RESULT_SUCCESS => {
                    if (available_in != 0) return error.TrailingData;
                    return .success;
                },
                raw.BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT => {
                    if (produced == 0) return error.DecompressionStalled;
                    continue;
                },
                raw.BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT => {
                    if (available_in != 0) return error.DecompressionFailed;
                    return .needs_more_input;
                },
                raw.BROTLI_DECODER_RESULT_ERROR => return decodeFailure(self.state),
                else => return error.DecompressionFailed,
            }
        }
    }

    /// Validate EOF after incremental updates.
    pub fn finish(self: *Decoder) !void {
        if (self.failed) return error.InvalidState;
        if (!self.isFinished()) return error.TruncatedInput;
    }

    /// Reads compressed bytes from `reader`, decodes, and writes to `writer`.
    pub fn decodeReader(self: *Decoder, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        var finished = false;

        while (true) {
            const n = try reader.readSliceShort(self.in_buffer);
            if (n == 0) break;
            if (finished) return error.TrailingData;

            const status = try self.update(self.in_buffer[0..n], writer);
            finished = status == .success;
        }

        if (finished) return;

        while (true) {
            const status = try self.update(&.{}, writer);
            switch (status) {
                .success => return,
                .needs_more_input => return error.TruncatedInput,
            }
        }
    }
};

/// Compresses `src` into a freshly allocated brotli buffer.
pub fn compress(allocator: std.mem.Allocator, src: []const u8, options: CompressOptions) ![]u8 {
    var encoder = try Encoder.init(allocator, .{
        .quality = options.quality,
        .window = options.window,
        .mode = options.mode,
    });
    defer encoder.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    encoder.update(src, &out.writer) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    encoder.finish(&out.writer) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    return out.toOwnedSlice();
}

/// Compresses `src` using default quality/window/mode.
pub fn compressDefault(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    return compress(allocator, src, .{});
}

/// Decompresses `src` into a newly allocated buffer.
///
/// `max_output_size` must be a safe upper bound for the decoded data.
pub fn decompress(allocator: std.mem.Allocator, src: []const u8, max_output_size: usize) ![]u8 {
    var decoder = try Decoder.init(allocator, .{ .max_output_size = max_output_size });
    defer decoder.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var reader: std.Io.Reader = .fixed(src);
    decoder.decodeReader(&reader, &out.writer) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    return out.toOwnedSlice();
}

/// Compresses all bytes from `reader` into `writer` using streaming brotli API.
pub fn compressReaderToWriter(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: EncoderOptions,
) !void {
    var encoder = try Encoder.init(allocator, options);
    defer encoder.deinit();
    try encoder.encodeReader(reader, writer);
}

/// Decompresses all bytes from `reader` into `writer` using streaming brotli API.
pub fn decompressReaderToWriter(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: DecoderOptions,
) !void {
    var decoder = try Decoder.init(allocator, options);
    defer decoder.deinit();
    try decoder.decodeReader(reader, writer);
}

/// Returns the encoded brotli encoder library version number.
pub fn encoderVersion() u32 {
    return raw.BrotliEncoderVersion();
}

/// Returns the encoded brotli decoder library version number.
pub fn decoderVersion() u32 {
    return raw.BrotliDecoderVersion();
}

/// Legacy raw dictionary handle using libc allocation; dictionary bytes are borrowed.
/// Prefer PreparedDictionary for caller-allocator ownership.
pub fn prepareEncoderDictionary(
    dict_type: raw.BrotliSharedDictionaryType,
    dictionary: []const u8,
    quality: i32,
) !*raw.BrotliEncoderPreparedDictionary {
    const prepared = raw.BrotliEncoderPrepareDictionary(
        dict_type,
        dictionary.len,
        if (dictionary.len == 0) null else @ptrCast(dictionary.ptr),
        quality,
        null,
        null,
        null,
    ) orelse return error.OutOfMemory;
    return prepared;
}

/// Destroys a dictionary handle returned by `prepareEncoderDictionary`.
pub fn destroyEncoderDictionary(prepared: *raw.BrotliEncoderPreparedDictionary) void {
    raw.BrotliEncoderDestroyPreparedDictionary(prepared);
}

/// Returns the decoder error message for `code`.
pub fn decoderErrorString(code: raw.BrotliDecoderErrorCode) []const u8 {
    return std.mem.span(raw.BrotliDecoderErrorString(code));
}

const DecodeFailureError = error{
    InvalidArguments,
    OutOfMemory,
    DecompressionFailed,
};

fn decodeFailure(state: *raw.BrotliDecoderState) DecodeFailureError {
    const code = raw.BrotliDecoderGetErrorCode(state);
    if (code == raw.BROTLI_DECODER_ERROR_INVALID_ARGUMENTS) return error.InvalidArguments;

    switch (code) {
        raw.BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MODES,
        raw.BROTLI_DECODER_ERROR_ALLOC_TREE_GROUPS,
        raw.BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MAP,
        raw.BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_1,
        raw.BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_2,
        raw.BROTLI_DECODER_ERROR_ALLOC_BLOCK_TYPE_TREES,
        => return error.OutOfMemory,
        else => return error.DecompressionFailed,
    }
}

fn toU32Checked(value: i32) !u32 {
    if (value < 0) return error.InvalidParameterValue;
    return @intCast(value);
}

fn validateOptions(quality: i32, window: i32) !void {
    if (quality < 0 or quality > 11 or window < 10 or window > 24)
        return error.InvalidParameter;
}

/// Owned prepared raw-prefix dictionary. Do not copy; deinit after all encoders.
pub const PreparedDictionary = struct {
    memory: *Memory,
    bytes: []u8,
    handle: *raw.BrotliEncoderPreparedDictionary,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8, quality: i32) !PreparedDictionary {
        try validateOptions(quality, default_window);
        const memory = try Memory.create(allocator);
        errdefer memory.destroy();
        const owned = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned);
        const handle = raw.BrotliEncoderPrepareDictionary(
            raw.BROTLI_SHARED_DICTIONARY_RAW,
            owned.len,
            owned.ptr,
            quality,
            Memory.alloc,
            Memory.free,
            memory,
        ) orelse return if (memory.failed) error.OutOfMemory else error.InvalidDictionary;
        return .{ .memory = memory, .bytes = owned, .handle = handle };
    }

    pub fn deinit(self: *PreparedDictionary) void {
        raw.BrotliEncoderDestroyPreparedDictionary(self.handle);
        self.memory.allocator.free(self.bytes);
        self.memory.destroy();
        self.* = undefined;
    }
};
