const std = @import("std");
const builtin = @import("builtin");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = resolveTarget(b);
    const optimize = b.standardOptimizeOption(.{});
    const strip = optimize != .Debug;
    const options = b.addOptions();

    const version_opt = b.option([]const u8, "version", "The version of the app") orelse "0.2.0-dev";
    options.addOption([]const u8, "version", version_opt);

    const exe = b.addExecutable(.{
        .name = "fsinfo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .strip = strip,
            .link_libc = true,
        }),
    });
    const yazap = b.dependency("yazap", .{});
    exe.root_module.addImport("yazap", yazap.module("yazap"));
    exe.root_module.addImport("build_options", options.createModule());

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addImport("yazap", yazap.module("yazap"));
    unit_tests.root_module.addImport("build_options", options.createModule());

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const tr = target.result;
    const tar_file = b.fmt("{s}/fsinfo-{s}-{s}-{s}-{s}.tar.gz", .{
        b.install_prefix,
        version_opt,
        @tagName(tr.cpu.arch),
        @tagName(tr.os.tag),
        @tagName(tr.abi),
    });

    const zig_step = b.addSystemCommand(&.{
        "tar",
        "-czf", // c - create, z - gzip, f - file
        tar_file,
        "-C",
        b.exe_dir,
        ".",
    });
    zig_step.step.dependOn(b.getInstallStep());

    const archive_step = b.step("archive", "Create a tar.gz archive of the build");
    archive_step.dependOn(&zig_step.step);
}

// Pin glibc on the default Linux-gnu target so Zig links against its
// bundled CRT instead of the system crt1.o. GCC >= 15 emits a .sframe
// section there that Zig 0.16's linker cannot handle.
const pinned_glibc: std.Target.Query.SemanticVersion = .{
    .major = 2,
    .minor = 38,
    .patch = 0,
};

fn materializeHostTriple(query: *std.Target.Query) void {
    if (query.cpu_arch == null) query.cpu_arch = builtin.cpu.arch;
    if (query.os_tag == null) query.os_tag = builtin.target.os.tag;
    if (query.abi == null) query.abi = builtin.target.abi;
}

fn needsHostTripleMaterialization(query: std.Target.Query) bool {
    if (query.cpu_arch != null or query.os_tag != null) return false;
    return switch (query.cpu_model) {
        .native, .explicit => true,
        .baseline, .determined_by_arch_os => false,
    };
}

fn resolveTarget(b: *std.Build) std.Build.ResolvedTarget {
    const default_target: std.Target.Query = .{
        .abi = .gnu,
        .glibc_version = pinned_glibc,
    };

    var query = b.standardTargetOptionsQueryOnly(.{
        .default_target = default_target,
    });

    // `-Dcpu=...` without `-Dtarget` parses arch/os as "native"; use the host triple.
    if (needsHostTripleMaterialization(query)) {
        materializeHostTriple(&query);
    }

    // `-Dcpu=native` parses "native" without inheriting `default_target.glibc_version`.
    if (query.glibc_version == null) {
        const os = query.os_tag orelse builtin.target.os.tag;
        if (os == .linux) {
            const abi = query.abi orelse builtin.target.abi;
            if (abi.isGnu()) {
                query.glibc_version = pinned_glibc;
            }
        }
    }

    return b.resolveTargetQuery(query);
}
