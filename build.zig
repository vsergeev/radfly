const std = @import("std");

pub fn discoverFrontendAssets(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.ArrayList([]const u8) {
    var frontend_assets: std.ArrayList([]const u8) = .empty;

    var frontend_assets_dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer frontend_assets_dir.close(io);

    var frontend_assets_it = frontend_assets_dir.iterate();
    while (try frontend_assets_it.next(io)) |entry| {
        switch (entry.kind) {
            .file => try frontend_assets.append(allocator, try std.mem.concat(allocator, u8, &[_][]const u8{ "/assets/", entry.name })),
            else => {},
        }
    }

    return frontend_assets;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const radio = b.dependency("radio", .{});
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const frontend_assets = try discoverFrontendAssets(b.allocator, b.graph.io, b.path("src/dist/assets").getPath(b));

    const build_options = b.addOptions();
    build_options.addOption([]const []const u8, "FRONTEND_ASSETS", frontend_assets.items);
    build_options.addOption([]const u8, "VERSION", "0.4.0");

    const exe = b.addExecutable(.{
        .name = "radfly",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("radio", radio.module("radio"));
    exe.root_module.addImport("httpz", httpz.module("httpz"));
    exe.root_module.addOptions("build_options", build_options);

    b.installArtifact(exe);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_unit_tests.root_module.addImport("radio", radio.module("radio"));
    exe_unit_tests.root_module.addImport("httpz", httpz.module("httpz"));
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
