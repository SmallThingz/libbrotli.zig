pub const packages = struct {
    pub const @"N-V-__8AAF_gIQDX2wVzXI-r96NyCgKuDj9W_Gab-TU7Qzoi" = struct {
        pub const build_root = "/home/a/projects/zig/libbrotli.zig/zig-pkg/N-V-__8AAF_gIQDX2wVzXI-r96NyCgKuDj9W_Gab-TU7Qzoi";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"N-V-__8AAOg8CgBsWJ9s3O7sKDdMR56qqkTUlWl4nZjhXq5Z" = struct {
        pub const build_root = "/home/a/projects/zig/libbrotli.zig/zig-pkg/N-V-__8AAOg8CgBsWJ9s3O7sKDdMR56qqkTUlWl4nZjhXq5Z";
        pub const build_zig = @import("N-V-__8AAOg8CgBsWJ9s3O7sKDdMR56qqkTUlWl4nZjhXq5Z");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "brotli_upstream", "N-V-__8AAF_gIQDX2wVzXI-r96NyCgKuDj9W_Gab-TU7Qzoi" },
    .{ "ziglibc", "N-V-__8AAOg8CgBsWJ9s3O7sKDdMR56qqkTUlWl4nZjhXq5Z" },
};
