const std = @import("std");

const vkgen = @import("vulkan_zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "mjolnir",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .link_libc = true,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    add_dependency(b, exe, target);
    compile_all_shaders(b, exe, "src/mj/shaders");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}

fn add_dependency(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const zglfw = b.dependency("zglfw", .{});
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    if (target.result.os.tag != .emscripten) {
        exe.linkLibrary(zglfw.artifact("glfw"));
    }
    const zmath = b.dependency("zmath", .{});
    exe.root_module.addImport("zmath", zmath.module("root"));
    const zstbi = b.dependency("zstbi", .{});
    exe.root_module.addImport("zstbi", zstbi.module("root"));
    const zmesh = b.dependency("zmesh", .{});
    exe.root_module.addImport("zmesh", zmesh.module("root"));
    exe.linkLibrary(zmesh.artifact("zmesh"));
    const vulkan = b.dependency("vulkan_zig", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    });
    exe.root_module.addImport("vulkan", vulkan.module("vulkan-zig"));
    // add path to system library directory where vulkan library at, in case it is not in $DYLD_LIBRARY_PATH
    // exe.addLibraryPath(std.Build.LazyPath{ .src_path = .{ .owner = b, .sub_path = "/usr/local/lib" } });
}

fn compile_all_shaders(b: *std.Build, exe: *std.Build.Step.Compile, shader_dir: []const u8) void {
    var dir = std.fs.cwd().openDir(shader_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open shader directory: {any}\n", .{err});
        return;
    };
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch |err| {
        std.debug.print("Error iterating shader directory: {any}\n", .{err});
        return;
    }) |entry| {
        if (entry.kind == .directory) {
            compile_shader(b, exe, shader_dir, entry.name);
        }
    }
}

fn compile_shader(b: *std.Build, exe: *std.Build.Step.Compile, shader_path: []const u8, shader_name: []const u8) void {
    const vert_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.3",
        "-o",
    });
    const vert_spv_path = b.pathJoin(&.{ "shaders", shader_name, "vert.spv" });
    const vert_spv = vert_cmd.addOutputFileArg(vert_spv_path);
    const vert_src_path = b.pathJoin(&.{ shader_path, shader_name, "shader.vert" });
    vert_cmd.addFileArg(b.path(vert_src_path));
    exe.root_module.addAnonymousImport(vert_spv_path, .{
        .root_source_file = vert_spv,
    });
    const frag_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.3",
        "-o",
    });
    const frag_spv_path = b.pathJoin(&.{ "shaders", shader_name, "frag.spv" });
    const frag_spv = frag_cmd.addOutputFileArg(frag_spv_path);
    const frag_src_path = b.pathJoin(&.{ shader_path, shader_name, "shader.frag" });
    std.debug.print("building {s} using {s}\n", .{frag_spv_path, frag_src_path});
    frag_cmd.addFileArg(b.path(frag_src_path));

    // Import as shaders/shadername/frag.spv
    exe.root_module.addAnonymousImport(frag_spv_path, .{
        .root_source_file = frag_spv,
    });
}
