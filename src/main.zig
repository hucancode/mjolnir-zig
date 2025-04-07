const std = @import("std");
const vk = @import("vulkan");
const mj = @import("mj/engine/engine.zig");
const zm = @import("zmath");
const Handle = @import("mj/engine/resource.zig").Handle;

const WIDTH = 1280;
const HEIGHT = 720;
const TITLE = "Hello Mjolnir!";
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var nodes: [2]Handle = undefined;

pub fn main() !void {
    defer _ = gpa.deinit();
    var e: mj.Engine = undefined;
    try e.init(allocator, WIDTH, HEIGHT, TITLE);
    defer e.deinit() catch unreachable;
    try setup(&e);
    std.debug.print("App initialized\n", .{});
    while (!e.shouldClose()) {
        if (e.update()) {
            update(&e);
        }
        e.render();
    }
}

fn setup(e: *mj.Engine) !void {
    const texture = try e.createTexture(@embedFile("assets/statue-1275469_1280.jpg"));
    const texture_ptr = e.textures.get(texture).?;
    const material = try e.createMaterial();
    const material_ptr = e.materials.get(material).?;
    material_ptr.updateTextures(&e.context, texture_ptr, texture_ptr, texture_ptr);
    const mesh = try e.createCube(material);
    var prev = e.scene.root;
    // animating tail
    for (0..nodes.len) |i| {
        const handle = e.createMeshNode(mesh);
        nodes[i] = handle;
        const node = e.nodes.get(handle) orelse continue;
        e.parentNode(prev, handle);
        if (i > 0) {
            node.transform.position[0] = 3.0;
        } else {
            node.transform.position[1] = 2.5;
            node.transform.position[2] = 0.0;
        }
        prev = handle;
    }
    // cube array
    for (0..5) |i_unsigned| {
        const i = @as(i32, @intCast(i_unsigned)) - 2;
        for (0..5) |j_unsigned| {
            const j = @as(i32, @intCast(j_unsigned)) - 2;
            const handle = e.createMeshNode(mesh);
            e.addToRoot(handle);
            const node = e.nodes.get(handle) orelse continue;
            node.transform.position[0] = @as(f32, @floatFromInt(i)) * 3.0;
            node.transform.position[2] = @as(f32, @floatFromInt(j)) * 3.0;
        }
    }
    e.scene.camera.position = .{ 0.0, 10.0, -15.0, 0.0 };
    e.scene.camera.lookAt(.{ 0.0, 2.5, -5.0, 0.0 });
}

fn update(e: *mj.Engine) void {
    for (nodes) |cube| {
        const node = e.nodes.get(cube) orelse continue;
        node.transform.rotation = zm.quatFromNormAxisAngle(.{ 0.0, 1.0, 0.0, 0.0 }, std.math.pi * e.getTime() * 0.5);
    }

}
