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
    const zgui = b.dependency("zgui", .{ .backend = .glfw_vulkan });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));
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
        if (entry.kind != .directory) {
            continue;
        }
        const vert_src_path = b.pathJoin(&.{ shader_dir, entry.name, "shader.vert" });
        const vert_spv_path = b.pathJoin(&.{ "shaders", entry.name, "vert.spv" });
        compile_shader(b, exe, vert_src_path, vert_spv_path);
        const frag_src_path = b.pathJoin(&.{ shader_dir, entry.name, "shader.frag" });
        const frag_spv_path = b.pathJoin(&.{ "shaders", entry.name, "frag.spv" });
        compile_shader(b, exe, frag_src_path, frag_spv_path);
    }
}

fn compile_shader(b: *std.Build, exe: *std.Build.Step.Compile, input: []const u8, output: []const u8) void {
    const file = std.fs.cwd().openFile(input, .{}) catch return;
    std.fs.File.close(file);
    const cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.3",
        "-o",
    });
    const output_file = cmd.addOutputFileArg(output);
    cmd.addFileArg(b.path(input));
    exe.root_module.addAnonymousImport(output, .{
        .root_source_file = output_file,
    });
}
