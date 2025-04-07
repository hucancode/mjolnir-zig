const std = @import("std");
const vk = @import("vulkan");
const zm = @import("zmath");
const VulkanContext = @import("context.zig").VulkanContext;
const Camera = @import("camera.zig").Camera;
const Handle = @import("resource.zig").Handle;

pub const Scene = struct {
    root: Handle,
    camera: Camera,
    descriptor_set_layout: vk.DescriptorSetLayout,

    pub fn init(self: *Scene, context: *VulkanContext) !void {
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
        const bindings = [_]vk.DescriptorSetLayoutBinding{
            view_binding,
            proj_binding,
            time_binding,
        };
        const layout_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = bindings.len,
            .p_bindings = &bindings,
        };
        self.descriptor_set_layout = try context.vkd.createDescriptorSetLayout(&layout_info, null);
    }

    pub fn deinit(self: *Scene, context: *VulkanContext) void {
        context.vkd.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
    }

    pub fn viewMatrix(self: *const Scene) zm.Mat {
        return self.camera.calculateViewMatrix();
    }

    pub fn projectionMatrix(self: *const Scene) zm.Mat {
        return self.camera.calculateProjectionMatrix();
    }
};
