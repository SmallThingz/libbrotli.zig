const std = @import("std");

const brotli_version = std.SemanticVersion{
    .major = 1,
    .minor = 2,
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
    "c/enc/static_dict_lut.c",
    "c/enc/static_init.c",
    "c/enc/static_dict.c",
    "c/enc/utf8_util.c",
};

const brotli_dec_sources = [_][]const u8{
    "c/dec/bit_reader.c",
    "c/dec/decode.c",
    "c/dec/huffman.c",
    "c/dec/prefix.c",
    "c/dec/state.c",
    "c/dec/static_init.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.option(bool, "shared", "Build libbrotli as a shared library") orelse false;

    const brotli_upstream = b.dependency("brotli_upstream", .{});

    const lib = b.addLibrary(.{
        .name = "brotli",
        .linkage = if (shared) .dynamic else .static,
        .version = brotli_version,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    configureBrotliLibrary(b, lib.root_module, brotli_upstream);

    b.installArtifact(lib);

    const mod = b.addModule("libbrotli", .{
        .root_source_file = b.path("src/brotli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(brotli_upstream.path("c/include"));
    mod.addIncludePath(brotli_upstream.path("c"));
    mod.linkLibrary(lib);

    const headers = b.addWriteFiles();
    const bindings = b.addTranslateC(.{
        .root_source_file = headers.add("brotli.h", "#include <brotli/encode.h>\n#include <brotli/decode.h>\n"),
        .target = target,
        .optimize = optimize,
    });
    bindings.addIncludePath(brotli_upstream.path("c/include"));
    mod.addImport("brotli_c", bindings.createModule());

    const tests = b.addTest(.{
        .use_lld = target.result.ofmt != .macho,
        .use_llvm = true,
        .root_module = b.addModule("libbrotli_tests", .{
            .root_source_file = b.path("test/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addImport("libbrotli", mod);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    const example = b.addExecutable(.{
        .use_lld = target.result.ofmt != .macho,
        .use_llvm = true,
        .name = "brotli-roundtrip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/brotli_roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    example.root_module.addImport("libbrotli", mod);
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Run brotli roundtrip example");
    example_step.dependOn(&run_example.step);

    const check = b.step("check", "Compile library, tests and example without running");
    check.dependOn(&lib.step);
    check.dependOn(&tests.step);
    check.dependOn(&example.step);
}

fn configureBrotliLibrary(b: *std.Build, module: *std.Build.Module, dep: *std.Build.Dependency) void {
    module.addIncludePath(b.path("include"));
    // Library allocation failures must return errors, never terminate the process.
    module.addCMacro("BROTLI_ENCODER_CLEANUP_ON_OOM", "1");
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
