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
var light: [3]Handle = undefined;
var light_cube: [3]Handle = undefined;

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
    e.scene.camera.position = .{ 0.0, 0.0, -15.0, 0.0 };
    e.scene.camera.lookAt(.{ 0.0, 2.5, -5.0, 0.0 });
    try e.loadGltf("assets/Duck.glb");
    for (0..light.len) |i| {
        const color: zm.Vec = .{
            std.math.sin(@as(f32, @floatFromInt(i))),
            std.math.cos(@as(f32, @floatFromInt(i))),
            std.math.sin(@as(f32, @floatFromInt(i))),
            1.0,
        };
        light[i] = e.createLightNode(e.createPointLight(color));
        e.addToRoot(light[i]);
        light_cube[i] = e.createMeshNode(mesh);
        const light_cube_ptr = e.nodes.get(light_cube[i]).?;
        light_cube_ptr.transform.scale = zm.f32x4s(0.1);
        e.parentNode(light[i], light_cube[i]);
    }
    const sunlight = e.createLightNode(e.createDirectionalLight(.{0.0, 0.05, 0.1, 0.0}));
    e.addToRoot(sunlight);
    const sunlight_ptr = e.nodes.get(sunlight).?;
    sunlight_ptr.transform.position = .{ 0.0, -10.0, 5.0, 0.0 };
}

fn update(e: *mj.Engine) void {
    e.scene.camera.lookAt(.{ 0.0, 2.5, -5.0, 0.0 });
    for(0..light.len) |i| {
        const t = e.getTime() + @as(f32, @floatFromInt(i))/@as(f32, @floatFromInt(light.len)) * std.math.pi * 2.0;
        const light_ptr = e.nodes.get(light[i]).?;
        const rx = std.math.sin(t);
        const ry = std.math.sin(t * 0.2) + 1.0;
        const rz = std.math.cos(t);
        const v = zm.normalize3(zm.f32x4(rx, ry, rz, 0.0));
        const radius = 4.0;
        light_ptr.transform.position = zm.f32x4(v[0] * radius, v[1] * radius, v[2] * radius, 0.0);
        const light_cube_ptr = e.nodes.get(light_cube[i]).?;
        light_cube_ptr.transform.rotation = zm.quatFromNormAxisAngle(.{ v[0], v[1], v[2], 0.0 }, std.math.pi * e.getTime() * 0.5);
    }
}
