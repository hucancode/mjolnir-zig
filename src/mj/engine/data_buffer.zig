const std = @import("std");
const vk = @import("vulkan");
const VulkanContext = @import("context.zig").VulkanContext;

pub const DataBuffer = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    mapped: ?*anyopaque,
    size: usize,

    pub fn write(self: *DataBuffer, data: []const u8) void {
        if (self.mapped != null) {
            const dst_ptr: [*]u8 = @ptrCast(self.mapped);
            const dst = dst_ptr[0..data.len];
            const src = data;
            @memcpy(dst, src);
        }
    }

    pub fn deinit(self: *DataBuffer, context: *VulkanContext) void {
        if (self.mapped != null) {
            context.vkd.unmapMemory(self.memory);
        }
        context.vkd.destroyBuffer(self.buffer, null);
        context.vkd.freeMemory(self.memory, null);
    }
};

pub const ImageBuffer = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    width: u32,
    height: u32,
    format: vk.Format,
    view: vk.ImageView,

    pub fn deinit(self: *ImageBuffer, context: *VulkanContext) void {
        context.vkd.destroyImageView(self.view, null);
        context.vkd.destroyImage(self.image, null);
        context.vkd.freeMemory(self.memory, null);
    }
};

pub fn createImageView(context: *VulkanContext, image: vk.Image, format: vk.Format, aspect_mask: vk.ImageAspectFlags) !vk.ImageView {
    const create_info = vk.ImageViewCreateInfo{
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = .{
            .aspect_mask = aspect_mask,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    return try context.vkd.createImageView(&create_info, null);
}
