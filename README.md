# libbrotli.zig

`libbrotli.zig` vendors upstream `libbrotli` sources and exposes a Zig-first API
plus the full raw C API.

## Features

- Compiles `libbrotli` C sources with Zig (`c/common`, `c/enc`, `c/dec`)
- Typed Zig helpers: `compress`, `compressDefault`, `decompress`
- Streaming Zig helpers compatible with `std.Io.Reader` / `std.Io.Writer`
- Full raw API exposed under `libbrotli.c`
- Supports both libc modes:
  - static libc via `ziglibc` (default)
  - system libc via `-Dstatic_libc=false`

## Build Options

- `-Dstatic_libc=true|false` (default `true`)
- `-Dshared=true|false` (default `false`)

## Commands

```bash
zig build test
zig build test -Dstatic_libc=false
zig build example
zig build example -Dstatic_libc=false
```

## Zig Usage

```zig
const libbrotli = @import("libbrotli");

const compressed = try libbrotli.compressDefault(allocator, input);
defer allocator.free(compressed);

const decompressed = try libbrotli.decompress(allocator, compressed, input.len * 4);
defer allocator.free(decompressed);
```

## Streaming Usage

```zig
var reader = std.Io.Reader.fixed(input);
var compressed = try std.Io.Writer.Allocating.initCapacity(allocator, input.len + 64);
defer compressed.deinit();

try libbrotli.compressReaderToWriter(allocator, &reader, &compressed.writer, .{});
```
