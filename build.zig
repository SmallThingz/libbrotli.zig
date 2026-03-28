const std = @import("std");

const brotli_version = std.SemanticVersion{
    .major = 1,
    .minor = 1,
    .patch = 0,
};

const brotli_common_sources = [_][]const u8{
    "c/common/constants.c",
    "c/common/context.c",
    "c/common/dictionary.c",
    "c/common/platform.c",
    "c/common/shared_dictionary.c",
    "c/common/transform.c",
};

const brotli_enc_sources = [_][]const u8{
    "c/enc/backward_references.c",
    "c/enc/backward_references_hq.c",
    "c/enc/bit_cost.c",
    "c/enc/block_splitter.c",
    "c/enc/brotli_bit_stream.c",
    "c/enc/cluster.c",
    "c/enc/command.c",
    "c/enc/compound_dictionary.c",
    "c/enc/compress_fragment.c",
    "c/enc/compress_fragment_two_pass.c",
    "c/enc/dictionary_hash.c",
    "c/enc/encode.c",
    "c/enc/encoder_dict.c",
    "c/enc/entropy_encode.c",
    "c/enc/fast_log.c",
    "c/enc/histogram.c",
    "c/enc/literal_cost.c",
    "c/enc/memory.c",
    "c/enc/metablock.c",
    "c/enc/static_dict.c",
    "c/enc/utf8_util.c",
};

const brotli_dec_sources = [_][]const u8{
    "c/dec/bit_reader.c",
    "c/dec/decode.c",
    "c/dec/huffman.c",
    "c/dec/state.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.option(bool, "shared", "Build libbrotli as a shared library") orelse false;
    const static_libc = b.option(bool, "static_libc", "Link against static ziglibc instead of system libc") orelse true;

    const brotli_upstream = b.dependency("brotli_upstream", .{});

    const lib = b.addLibrary(.{
        .name = "brotli",
        .linkage = if (shared) .dynamic else .static,
        .version = brotli_version,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
            .sanitize_c = .off,
        }),
    });
    configureBrotliLibrary(lib.root_module, brotli_upstream);

    const static_libc_artifact = if (static_libc) blk: {
        const ziglibc_dep = b.lazyDependency("ziglibc", .{
            .target = target,
            .optimize = optimize,
            .trace = false,
        }) orelse return;

        const ziglibc_lib = findDependencyArtifactByLinkage(ziglibc_dep, "cguana", .static);
        configureStaticLibc(lib.root_module, ziglibc_lib, ziglibc_dep);
        break :blk ziglibc_lib;
    } else null;

    b.installArtifact(lib);

    const mod = b.addModule("libbrotli", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !static_libc,
    });
    mod.addIncludePath(brotli_upstream.path("c/include"));
    mod.addIncludePath(brotli_upstream.path("c"));
    mod.linkLibrary(lib);
    if (static_libc_artifact) |artifact| {
        const ziglibc_dep = b.lazyDependency("ziglibc", .{
            .target = target,
            .optimize = optimize,
            .trace = false,
        }) orelse return;
        configureStaticLibc(mod, artifact, ziglibc_dep);
    }

    const tests = b.addTest(.{
        .root_module = b.addModule("libbrotli_tests", .{
            .root_source_file = b.path("test/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
        }),
    });
    tests.root_module.addImport("libbrotli", mod);
    if (static_libc_artifact) |artifact| {
        const ziglibc_dep = b.lazyDependency("ziglibc", .{
            .target = target,
            .optimize = optimize,
            .trace = false,
        }) orelse return;
        configureStaticLibc(tests.root_module, artifact, ziglibc_dep);
    }
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    const example = b.addExecutable(.{
        .name = "brotli-roundtrip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/brotli_roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
        }),
    });
    example.root_module.addImport("libbrotli", mod);
    if (static_libc_artifact) |artifact| {
        const ziglibc_dep = b.lazyDependency("ziglibc", .{
            .target = target,
            .optimize = optimize,
            .trace = false,
        }) orelse return;
        configureStaticLibc(example.root_module, artifact, ziglibc_dep);
    }
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Run brotli roundtrip example");
    example_step.dependOn(&run_example.step);

    const check = b.step("check", "Compile library, tests and example without running");
    check.dependOn(&lib.step);
    check.dependOn(&tests.step);
    check.dependOn(&example.step);
}

fn configureBrotliLibrary(module: *std.Build.Module, dep: *std.Build.Dependency) void {
    module.addIncludePath(.{ .cwd_relative = "include" });
    module.addIncludePath(dep.path("c/include"));
    module.addIncludePath(dep.path("c"));

    module.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &brotli_common_sources,
        .flags = &.{"-std=c99"},
    });
    module.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &brotli_enc_sources,
        .flags = &.{"-std=c99"},
    });
    module.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &brotli_dec_sources,
        .flags = &.{"-std=c99"},
    });
}

fn configureStaticLibc(module: *std.Build.Module, artifact: *std.Build.Step.Compile, dep: *std.Build.Dependency) void {
    module.addIncludePath(dep.path("inc/libc"));
    module.addIncludePath(dep.path("inc/posix"));
    module.addIncludePath(dep.path("inc/gnu"));
    module.linkLibrary(artifact);
}

fn findDependencyArtifactByLinkage(
    dep: *std.Build.Dependency,
    name: []const u8,
    linkage: std.builtin.LinkMode,
) *std.Build.Step.Compile {
    var found: ?*std.Build.Step.Compile = null;
    for (dep.builder.install_tls.step.dependencies.items) |dep_step| {
        const install_artifact = dep_step.cast(std.Build.Step.InstallArtifact) orelse continue;
        if (!std.mem.eql(u8, install_artifact.artifact.name, name)) continue;
        if (install_artifact.artifact.linkage != linkage) continue;

        if (found != null) {
            std.debug.panic(
                "artifact '{s}' with linkage '{s}' is ambiguous in dependency",
                .{ name, @tagName(linkage) },
            );
        }
        found = install_artifact.artifact;
    }

    if (found) |artifact| return artifact;
    std.debug.panic(
        "unable to find artifact '{s}' with linkage '{s}' in dependency install graph",
        .{ name, @tagName(linkage) },
    );
}
