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
    exe.linkSystemLibrary("glfw");

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    });

    exe.root_module.addImport("vulkan", vulkan.module("vulkan-zig"));

    const vert_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.3",
        "-o",
    });
    const vert_spv = vert_cmd.addOutputFileArg("src/shaders/triangle.vert.spv");
    vert_cmd.addFileArg(b.path("src/shaders/triangle.vert"));
    exe.root_module.addAnonymousImport("vertex_shader", .{
        .root_source_file = vert_spv,
    });

    const frag_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.3",
        "-o",
    });
    const frag_spv = frag_cmd.addOutputFileArg("src/shaders/triangle.frag.spv");
    frag_cmd.addFileArg(b.path("src/shaders/triangle.frag"));
    exe.root_module.addAnonymousImport("fragment_shader", .{
        .root_source_file = frag_spv,
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
