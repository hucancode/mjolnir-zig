const std = @import("std");
const vk = @import("vulkan");
const zm = @import("zmath");
const context = @import("context.zig").get();
const Camera = @import("camera.zig").Camera;
const Handle = @import("resource.zig").Handle;

pub const Scene = struct {
    root: Handle,
    camera: Camera,
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
        return self.camera.calculateViewMatrix();
    }

    pub fn projectionMatrix(self: *const Scene) zm.Mat {
        return self.camera.calculateProjectionMatrix();
    }
};
