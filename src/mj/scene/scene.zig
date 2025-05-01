const std = @import("std");
const vk = @import("vulkan");
const zm = @import("zmath");
const context = @import("../engine/context.zig").get();
const Camera = @import("camera.zig").Camera;
const OrbitCamera = @import("orbit_camera.zig").OrbitCamera;
const Handle = @import("../engine/resource.zig").Handle;

pub const CameraMode = enum {
    free,
    orbit,
};

pub const Scene = struct {
    root: Handle,
    camera: Camera,
    orbit_camera: OrbitCamera,
    camera_mode: CameraMode = .free,
    descriptor_set_layout: vk.DescriptorSetLayout,

    pub fn init(self: *Scene) !void {
        self.camera = .{
            .projection = .{
                .perspective = .{
                    .fov = 45.0,
                    .aspect_ratio = 16.0 / 9.0,
                    .near = 0.1,
                    .far = 10000.0,
                },
            },
        };
        self.orbit_camera = OrbitCamera.init(45.0, 16.0 / 9.0, 0.1, 10000.0);
        const view_binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        };
        const proj_binding = vk.DescriptorSetLayoutBinding{
            .binding = 1,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        };
        const time_binding = vk.DescriptorSetLayoutBinding{
            .binding = 2,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        };
        const light_count_binding = vk.DescriptorSetLayoutBinding{
            .binding = 3,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
        };
        const light_binding = vk.DescriptorSetLayoutBinding{
            .binding = 4,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
        };
        const bindings = [_]vk.DescriptorSetLayoutBinding{
            view_binding,
            proj_binding,
            time_binding,
            light_count_binding,
            light_binding,
        };
        const layout_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = bindings.len,
            .p_bindings = &bindings,
        };
        self.descriptor_set_layout = try context.*.vkd.createDescriptorSetLayout(&layout_info, null);
    }

    pub fn deinit(self: *Scene) void {
        context.*.vkd.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
    }

    pub fn viewMatrix(self: *const Scene) zm.Mat {
        return switch (self.camera_mode) {
            .free => self.camera.calculateViewMatrix(),
            .orbit => self.orbit_camera.getViewMatrix(),
        };
    }

    pub fn projectionMatrix(self: *const Scene) zm.Mat {
        return switch (self.camera_mode) {
            .free => self.camera.calculateProjectionMatrix(),
            .orbit => self.orbit_camera.getProjectionMatrix(),
        };
    }

    pub fn rotateOrbitCamera(self: *Scene, delta_yaw: f32, delta_pitch: f32) void {
        if (self.camera_mode == .orbit) {
            self.orbit_camera.rotate(delta_yaw, delta_pitch);
        }
    }

    pub fn zoomOrbitCamera(self: *Scene, delta: f32) void {
        if (self.camera_mode == .orbit) {
            self.orbit_camera.zoom(delta);
        }
    }

    pub fn setOrbitTarget(self: *Scene, target: zm.Vec) void {
        if (self.camera_mode == .orbit) {
            self.orbit_camera.setTarget(target);
        }
    }

    pub fn setCameraMode(self: *Scene, mode: CameraMode) void {
        self.camera_mode = mode;
    }
};
