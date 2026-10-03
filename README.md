# libbrotli.zig

Brotli 1.2.0 for Zig 0.17.0. The native `std.Build` graph compiles the pinned
upstream C encoder, decoder, and shared-dictionary sources directly. No CMake,
Make, downloaded binaries, or custom libc is needed.

```zig
const brotli = @import("libbrotli");
const encoded = try brotli.compress(allocator, input, .{ .quality = 5, .mode = .text });
defer allocator.free(encoded);
const decoded = try brotli.decompress(allocator, encoded, 8 * 1024 * 1024);
defer allocator.free(decoded);
```

`decompress` enforces a hard output limit, rejects truncated streams and trailing
bytes, and grows output as needed. Brotli has no checksum: corruption that remains
a valid Brotli bitstream cannot be detected by the format.

## Streaming and ownership

`Encoder` and `Decoder` expose `init`, `update`, `finish`, and `deinit`.
Encoders also support `flush` and metadata. `encodeReader` / `decodeReader` and
`compressReaderToWriter` / `decompressReaderToWriter` bridge Zig's `std.Io.Reader`
and `std.Io.Writer`. Readers are consumed to EOF; writers are not flushed or closed.
Call decoder `finish()` at EOF when driving `update` yourself.

```zig
var decoder = try brotli.Decoder.init(allocator, .{
    .max_output_size = 8 * 1024 * 1024,
    .stream = .{ .in_buffer_size = 4096, .out_buffer_size = 4096 },
});
defer decoder.deinit();
try decoder.decodeReader(reader, writer);
```

All native allocations in these Zig APIs use the supplied allocator. Upstream's
cleanup-on-OOM mode returns `OutOfMemory` instead of terminating the process.
Owners must not be copied or used concurrently. The allocator must outlive them.
Codec or writer failures can leave partial output; discard it and deinitialize
the stream. Further updates on a failed stream return `InvalidState`. Finished
encoders reject further input with `StreamFinished`.

`PreparedDictionary.init(allocator, bytes, quality)` owns its byte copy and native
prepared state. `encoder.useDictionary(&dictionary)` borrows that owner, which
must outlive the encoder. `decoder.loadDictionary(bytes)` copies bytes. Advanced
raw attachment methods explicitly borrow dictionaries. The legacy
`prepareEncoderDictionary` handle helper uses libc; pair it with
`destroyEncoderDictionary`. Full upstream C declarations remain available as `c`.

## Build and consume

```sh
zig build test example -j2
zig build test -Doptimize=safe -j2
zig build check -Dshared=true -j2
zig build check -Dtarget=x86_64-linux-musl -j2
```

`-Dshared` selects the native library linkage (default static). Standard target
and optimization options apply. Libc uses Zig's target toolchain; select a musl
target for a self-contained Linux executable. The former `static_libc` custom
ziglibc option was removed. Test/example artifacts select LLVM + LLD to avoid
Zig 0.16's native self-hosted linker incompatibility with GCC 16 CRT objects.

Add this package as a Zig dependency, then wire its exported module:

```zig
const dep = b.dependency("libbrotli", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("libbrotli", dep.module("libbrotli"));
```

The module carries native include and library dependencies. `check` compiles
library, tests, and example without executing target binaries. Tests cover exact
binary/empty roundtrips, bytewise streams, truncation at every prefix, output
limits, dictionary lifetimes, and exhaustive native/Zig allocation failures.
