const std = @import("std");
const vk = @import("vulkan");
const mj = @import("mj/engine/engine.zig");
const zm = @import("zmath");
const Handle = @import("mj/engine/resource.zig").Handle;

const WIDTH = 1280;
const HEIGHT = 720;
const TITLE = "Hello Mjolnir!";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    var e: mj.Engine = undefined;
    try e.init(allocator, WIDTH, HEIGHT, TITLE);
    defer e.deinit() catch unreachable;
    const texture = try e.createTexture(@embedFile("assets/statue-1275469_1280.jpg"));
    const texture_ptr = e.resource.getTexture(texture).?;
    const material = try e.createMaterial();
    const material_ptr = e.resource.getMaterial(material).?;
    material_ptr.updateTextures(&e.context, texture_ptr, texture_ptr, texture_ptr);
    const mesh = try e.createCube(material);
    var nodes: [4]Handle = undefined;
    var prev = e.scene.root;
    // animating tail
    for (0..4) |i| {
        const handle = e.resource.createMeshNode(mesh);
        nodes[i] = handle;
        const node = e.resource.nodes.get(handle) orelse continue;
        e.parentNode(prev, handle);
        if (i > 0) {
            node.transform.position[0] = 3.0;
        } else {
            node.transform.position[1] = 2.5;
        }
        prev = handle;
    }

    // cube array
    for (0..5) |i_unsigned| {
        const i = @as(i32, @intCast(i_unsigned)) - 2;
        for (0..5) |j_unsigned| {
            const j = @as(i32, @intCast(j_unsigned)) - 2;
            const handle = e.resource.createMeshNode(mesh);
            e.addToRoot(handle);
            const node = e.resource.nodes.get(handle) orelse continue;
            node.transform.position[0] = @as(f32, @floatFromInt(i)) * 3.0;
            node.transform.position[2] = @as(f32, @floatFromInt(j)) * 3.0;
        }
    }

    e.scene.camera.perspective.position = .{ 0.0, 5.0, 10.0, 1.0 };
    std.debug.print("App initialized\n", .{});

    while (!e.shouldClose()) {
        if (e.update()) {
            // animate tail by setting rotation
            for (nodes) |cube| {
                const node = e.resource.nodes.get(cube) orelse continue;
                node.transform.rotation = zm.quatFromNormAxisAngle(.{ 0.0, 1.0, 0.0, 0.0 }, std.math.pi * e.getTime() * 0.5);
            }
        }
        e.render();
    }
}
