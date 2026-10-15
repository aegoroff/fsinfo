const std = @import("std");
const builtin = @import("builtin");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = resolveTarget(b);
    const optimize = b.standardOptimizeOption(.{});
    const strip = optimize != .debug;
    const options = b.addOptions();

    const version_opt = b.option([]const u8, "version", "The version of the app") orelse "0.3.0-dev";
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
    const zig_cli = b.dependency("zig_cli", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zig_cli", zig_cli.module("zig_cli"));
    exe.root_module.addImport("build_options", options.createModule());

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    // Passthru args keep the configure cache pure across `zig build run -- ...`.
    run_cmd.addPassthruArgs();

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
    unit_tests.root_module.addImport("zig_cli", zig_cli.module("zig_cli"));
    unit_tests.root_module.addImport("build_options", options.createModule());

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Packaging — install paths are LazyPath-only since Zig 0.17 (configure/make split).
    const tr = target.result;
    const gz_basename = b.fmt("fsinfo-{s}-{s}-{s}-{s}.tar.gz", .{
        version_opt,
        @tagName(tr.cpu.arch),
        @tagName(tr.os.tag),
        @tagName(tr.abi),
    });

    const pack = b.addSystemCommand(&.{ "tar", "-czvf" });
    const gz_file = pack.addOutputFileArg2(gz_basename, .{});
    pack.addArg("-C");
    pack.addDirectoryArg2(.{ .relative = .{ .base = .install_bin } }, .{ .make_absolute = true });
    pack.addArg(".");
    pack.step.dependOn(b.getInstallStep());

    // Keep the tarball off the default install step to avoid a cycle with getInstallStep().
    const install_tarball = b.addInstallFile(gz_file, gz_basename);
    const archive_step = b.step("archive", "Create a tar.gz archive of the build");
    archive_step.dependOn(&install_tarball.step);
}

// Pin glibc on the default Linux-gnu target so Zig links against its
// bundled CRT instead of the system crt1.o. GCC >= 15 emits a .sframe
// section there that Zig's linker cannot handle.
const pinned_glibc: std.Target.Query.SemanticVersion = .{
    .major = 2,
    .minor = 38,
    .patch = 0,
};

fn materializeHostTriple(query: *std.Target.Query) void {
    if (query.cpu_arch == null) query.cpu_arch = builtin.target.cpu.arch;
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
