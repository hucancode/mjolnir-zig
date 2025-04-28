const std = @import("std");
const vk = @import("vulkan");
const mj = @import("mj/engine/engine.zig");
const zm = @import("zmath");
const Handle = @import("mj/engine/resource.zig").Handle;
const AnimationPlayMode = @import("mj/geometry/animation.zig").PlayMode;
const Geometry = @import("mj/geometry/geometry.zig").Geometry;

const WIDTH = 1280;
const HEIGHT = 720;
const TITLE = "Hello Mjolnir!";
// disable safety to avoid excessive logs, enable it later to fix memory leaks
var gpa = std.heap.GeneralPurposeAllocator(.{.safety = false}){};
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
    const texture = e.makeTexture()
        .fromData(@embedFile("assets/statue-1275469_1280.jpg"))
        .build();
    const material = e.makeMaterial()
        .withTexture(texture)
        .build();

    const mesh = e.makeMesh()
        .withGeometry(Geometry.cube(.{1.0, 1.0, 1.0, 1.0}))
        .withMaterial(material)
        .build();
    e.scene.camera.position = .{ 0.0, 10.0, -15.0, 0.0 };
    e.scene.camera.lookAt(.{ 0.0, 2.5, -5.0, 0.0 });
    // _ = try e.loadGltf("assets/Duck.glb");
    const gltf_nodes = try e.loadGltf("assets/CesiumMan.glb");
    for (gltf_nodes) |node| {
        const name = "Anim_0";
        e.playAnimation(node, name, .loop) catch {
            // e.unparentNode(node);
            // continue;
        };
        const ptr = e.nodes.get(node).?;
        ptr.transform.position = .{0.0, 0.0, 0.0, 0.0};
        ptr.transform.scale = .{3.0, 3.0, 3.0, 3.0};
        ptr.transform.rotation = zm.quatFromNormAxisAngle(.{ 0.0, 1.0, 0.0, 0.0 }, std.math.pi);
    }
    for (0..light.len) |i| {
        const color: zm.Vec = .{
            std.math.sin(@as(f32, @floatFromInt(i))),
            std.math.cos(@as(f32, @floatFromInt(i))),
            std.math.sin(@as(f32, @floatFromInt(i))),
            1.0,
        };
        light[i] = e.spawn()
            .atRoot()
            .withNewPointLight(color)
            .build();
        light_cube[i] = e.spawn()
            .withStaticMesh(mesh)
            .withScale(zm.f32x4s(0.2 * @as(f32, @floatFromInt(i)) + 0.4))
            .asChildOf(light[i])
            .build();
    }
    _ = e.spawn()
        .atRoot()
        .withNewDirectionalLight(.{ 0.01, 0.01, 0.01, 0.0 })
        .withPosition(.{ 0.0, -10.0, 5.0, 0.0 })
        .build();
}

fn update(e: *mj.Engine) void {
    e.scene.camera.lookAt(.{ 0.0, 2.5, -5.0, 0.0 });
    for (0..light.len) |i| {
        const t = e.getTime() + @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(light.len)) * std.math.pi * 2.0;
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
