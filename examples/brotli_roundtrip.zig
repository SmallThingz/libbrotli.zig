const std = @import("std");
const libbrotli = @import("libbrotli");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const input = "Example payload compressed through libbrotli.zig";

    const compressed = try libbrotli.brotli.compressDefault(allocator, input);
    defer allocator.free(compressed);

    const decompressed = try libbrotli.brotli.decompress(allocator, compressed, input.len * 4);
    defer allocator.free(decompressed);

    if (!std.mem.eql(u8, input, decompressed)) return error.RoundtripMismatch;

    std.debug.print("input={d} compressed={d} decompressed={d}\n", .{
        input.len,
        compressed.len,
        decompressed.len,
    });
}
