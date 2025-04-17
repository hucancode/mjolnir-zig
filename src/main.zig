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
var light: Handle = undefined;
var light_cube: Handle = undefined;

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
            node.transform.position[2] = 3.0;
        }
        prev = handle;
    }
    e.scene.camera.position = .{ 0.0, 0.0, -15.0, 0.0 };
    e.scene.camera.lookAt(.{ 0.0, 2.5, -5.0, 0.0 });
    try e.loadGltf("assets/Duck.glb");
    light = e.createLightNode(e.createPointLight(.{0.0, 0.25, 0.5, 0.0}));
    e.addToRoot(light);
    light_cube = e.createMeshNode(mesh);
    const light_cube_ptr = e.nodes.get(light_cube).?;
    light_cube_ptr.transform.scale = zm.f32x4s(0.5);
    e.parentNode(light, light_cube);
}

fn update(e: *mj.Engine) void {
    for (nodes) |cube| {
        const node = e.nodes.get(cube) orelse continue;
        node.transform.rotation = zm.quatFromNormAxisAngle(.{ 0.0, 1.0, 0.0, 0.0 }, std.math.pi * e.getTime() * 0.5);
    }
    e.scene.camera.lookAt(.{ 0.0, 2.5, -5.0, 0.0 });
    const light_ptr = e.nodes.get(light).?;
    const rx = std.math.sin(e.getTime());
    const ry = std.math.sin(e.getTime()*0.2) + 1.0;
    const rz = std.math.cos(e.getTime());
    const v = zm.normalize3(zm.f32x4(rx, ry, rz, 0.0));
    const radius = 4.0;
    light_ptr.transform.position = zm.f32x4(v[0] * radius, v[1] * radius, v[2] * radius, 0.0);
    const light_cube_ptr = e.nodes.get(light_cube).?;
    light_cube_ptr.transform.rotation = zm.quatFromNormAxisAngle(.{ v[0], v[1], v[2], 0.0 }, std.math.pi * e.getTime() * 0.5);
}
