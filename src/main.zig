const std = @import("std");
const vk = @import("vulkan");
const mj = @import("mj/engine/engine.zig");
const zm = @import("zmath");
const glfw = @import("zglfw");

const Handle = @import("mj/engine/resource.zig").Handle;
const AnimationPlayMode = @import("mj/geometry/animation.zig").PlayMode;
const Geometry = @import("mj/geometry/geometry.zig").Geometry;

const WIDTH = 1280;
const HEIGHT = 720;
const TITLE = "Hello Mjolnir!";
// disable safety to avoid excessive logs, enable it later to fix memory leaks
var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = false }){};
const allocator = gpa.allocator();
const LIGHT_COUNT = 5;
var light: [LIGHT_COUNT]Handle = undefined;
var light_cube: [LIGHT_COUNT]Handle = undefined;
var e: mj.Engine = undefined;

pub fn main() !void {
    defer _ = gpa.deinit();
    try e.init(allocator, WIDTH, HEIGHT, TITLE);
    defer e.deinit() catch unreachable;
    try setup();
    std.debug.print("App initialized\n", .{});
    while (!e.shouldClose()) {
        if (e.update()) {
            update();
        }
        e.render();
    }
}

fn setup() !void {
    const texture = e.makeTexture()
        .fromData(@embedFile("assets/statue-1275469_1280.jpg"))
        .build();
    const material = e.makeMaterial()
        .withTexture(texture)
        .build();

    const mesh = e.makeMesh()
        .withGeometry(Geometry.cube(.{ 1.0, 1.0, 1.0, 1.0 }))
        .withMaterial(material)
        .build();

    // Create ground plane
    const ground_material = e.makeMaterial()
        // .withColor(.{ 0.5, 0.5, 0.5, 1.0 })
        .build();

    _ = e.spawn()
        .atRoot()
        .withNewStaticMesh(Geometry.quad(.{ 1.0, 1.0, 1.0, 1.0 }), ground_material)
        .withPosition(.{ -10.0, 0.0, -10.0, 0.0 })
        .withScale(.{ 20.0, 20.0, 20.0, 0.0 })
        .build();

    // Set up orbit camera
    e.scene.setCameraMode(.orbit);
    e.scene.orbit_camera.setTarget(.{ 0.0, 0.0, 0.0, 0.0 });
    const gltf_nodes = try e.loadGltf()
        .withPath("assets/CesiumMan.glb")
        .submit();
    for (gltf_nodes) |armature| {
        const armature_ptr = e.nodes.get(armature) orelse continue;
        const skeleton = armature_ptr.children.getLastOrNull() orelse continue;
        const skeleton_ptr = e.nodes.get(skeleton) orelse continue;
        skeleton_ptr.transform.position = .{ 0.0, 0.0, 0.0, 0.0 };
        const name = "Anim_0";
        e.playAnimation(skeleton, name, .loop) catch continue;
    }
    for (0..light.len) |i| {
        const color: zm.Vec = .{
            std.math.sin(@as(f32, @floatFromInt(i))),
            std.math.cos(@as(f32, @floatFromInt(i))),
            std.math.sin(@as(f32, @floatFromInt(i))),
            1.0,
        };

        // Alternating between point lights and spot lights
        if (i % 2 == 0) {
            const spotAngle = std.math.pi / 6.0; // 30 degrees cone
            light[i] = e.spawn()
                .atRoot()
                .withNewSpotLight(color)
                .withLightAngle(spotAngle)
                .withLightRadius(5.0) // Longer range for spot lights
                .build();
        } else {
            light[i] = e.spawn()
                .atRoot()
                .withNewPointLight(color)
                .build();
        }

        light_cube[i] = e.spawn()
            .withStaticMesh(mesh)
            .withScale(zm.f32x4s(0.15))
            .withPosition(.{ 0.0, 1.0, 0.0, 0.0 })
            .asChildOf(light[i])
            .build();
    }
    // _ = e.spawn()
    //     .atRoot()
    //     .withNewDirectionalLight(.{ 0.01, 0.01, 0.01, 0.0 })
    //     .withPosition(.{ 0.0, 10.0, 5.0, 0.0 })
    //     .build();
    const ScrollHandler = struct {
        fn scroll_callback(window: *glfw.Window, xoffset: f64, yoffset: f64) callconv(.C) void {
            _ = window;
            _ = xoffset;
            const SCROLL_SENSITIVITY = 0.5;
            e.scene.zoomOrbitCamera(-@as(f32, @floatCast(yoffset)) * SCROLL_SENSITIVITY);
        }
    };
    _ = glfw.setScrollCallback(e.window, ScrollHandler.scroll_callback);
}

fn update() void {
    if (e.scene.camera_mode == .orbit) {
        // Handle camera rotation with right mouse button
        const mouse_state = e.window.getCursorPos();
        const mouse_button_state = e.window.getMouseButton(.left);

        const MOUSE_SENSITIVITY_X = 0.005;
        const MOUSE_SENSITIVITY_Y = 0.005;

        // Store static variables for tracking mouse state
        const S = struct {
            var last_mouse_x: f64 = 0;
            var last_mouse_y: f64 = 0;
            var dragging: bool = false;
        };

        if (mouse_button_state == .press) {
            if (!S.dragging) {
                S.last_mouse_x = mouse_state[0];
                S.last_mouse_y = mouse_state[1];
                S.dragging = true;
            }
            const delta_x = @as(f32, @floatCast(mouse_state[0] - S.last_mouse_x));
            const delta_y = @as(f32, @floatCast(mouse_state[1] - S.last_mouse_y));
            e.scene.rotateOrbitCamera(-delta_x * MOUSE_SENSITIVITY_X, delta_y * MOUSE_SENSITIVITY_Y);
            S.last_mouse_x = mouse_state[0];
            S.last_mouse_y = mouse_state[1];
        } else {
            S.dragging = false;
        }
    }

    for (0..light.len) |i| {
        const t = e.getTime() + @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(light.len)) * std.math.pi * 2.0;
        const light_ptr = e.nodes.get(light[i]).?;
        const rx = std.math.sin(t);
        const ry = (std.math.sin(t * 0.2) + 1.0) * 0.5 + 2.0;
        const rz = std.math.cos(t);
        const v = zm.normalize3(zm.f32x4(rx, ry, rz, 0.0));
        const radius = 4.0;
        light_ptr.transform.position = zm.f32x4(v[0] * radius, v[1] * radius, v[2] * radius, 0.0);
        const light_cube_ptr = e.nodes.get(light_cube[i]).?;
        light_cube_ptr.transform.rotation = zm.quatFromNormAxisAngle(.{ v[0], v[1], v[2], 0.0 }, std.math.pi * e.getTime() * 0.5);
    }
}
