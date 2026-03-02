const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------------
    // mdbx.c compile flags
    // -------------------------------------------------------------------------
    const c_flags_base = &[_][]const u8{
        "-DMDBX_BUILD_SHARED_LIBRARY=0",
        "-DMDBX_FORCE_ASSERTIONS=0",
        "-DMDBX_BUILD_FLAGS=\"\"",
        "-DMDBX_GCC_FASTMATH_i686_SIMD_WORKAROUND=1",
        "-DMDBX_HAVE_BUILTIN_CPU_SUPPORTS=0",
        "-std=gnu11",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
        "-Wno-unused-function",
        "-Wno-deprecated-declarations",
        "-fno-sanitize=alignment",
    };
    const c_flags_windows = &[_][]const u8{
        "-DMDBX_BUILD_SHARED_LIBRARY=0",
        "-DMDBX_FORCE_ASSERTIONS=0",
        // Required string literal for mdbx static array concatenation
        "-DMDBX_BUILD_FLAGS=\"\"",
        // Disable SIMD paths (AVX512/AVX2/SSE2) rejected by clang 19+ due to evex512
        "-DMDBX_GCC_FASTMATH_i686_SIMD_WORKAROUND=1",
        // Disable runtime CPU detection (__builtin_cpu_supports)
        // Avoids missing compiler-rt symbols (__cpu_model, __cpu_indicator_init)
        "-DMDBX_HAVE_BUILTIN_CPU_SUPPORTS=0",
        "-std=gnu11",
        "-DNDEBUG",
        // Avoid _WIN32_WINNT redefinition error (Zig already defines it for Windows)
        "-Wno-macro-redefined",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
        "-Wno-unused-function",
        "-Wno-deprecated-declarations",
        // mdbx uses unaligned_poke_u64 intentionally (4-byte aligned u64 store).
        // Disable alignment UBSan to avoid Zig Debug mode panics.
        "-fno-sanitize=alignment",
    };

    const is_windows = target.result.os.tag == .windows;
    const c_flags = if (is_windows) c_flags_windows else c_flags_base;

    // -------------------------------------------------------------------------
    // libmdbx static C library (compiled from mdbx.c)
    // -------------------------------------------------------------------------
    const mdbx_root = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    const mdbx_c = b.addLibrary(.{
        .name = "mdbx",
        .linkage = .static,
        .root_module = mdbx_root,
    });
    mdbx_c.addCSourceFile(.{
        .file = b.path("libmdbx/mdbx.c"),
        .flags = c_flags,
    });
    mdbx_c.addIncludePath(b.path("libmdbx"));
    mdbx_c.linkLibC();
    if (is_windows) {
        mdbx_c.linkSystemLibrary("kernel32");
        mdbx_c.linkSystemLibrary("advapi32");
        mdbx_c.linkSystemLibrary("ntdll");
    }

    // -------------------------------------------------------------------------
    // Public Zig module — imported by services as a path dependency
    // -------------------------------------------------------------------------
    const monolith_mod = b.addModule("monolith", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Module needs mdbx.h for @cImport
    monolith_mod.addIncludePath(b.path("libmdbx"));
    // Link the static C library into the module
    monolith_mod.linkLibrary(mdbx_c);

    // -------------------------------------------------------------------------
    // Installable artifact (for standalone use)
    // -------------------------------------------------------------------------
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "monolith",
        .root_module = monolith_mod,
    });
    b.installArtifact(lib);

    // -------------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addIncludePath(b.path("libmdbx"));
    test_mod.linkLibrary(mdbx_c);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
