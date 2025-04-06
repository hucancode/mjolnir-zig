const std = @import("std");
const vk = @import("vulkan");
const Image = @import("zstbi").Image;

const VulkanContext = @import("../engine/context.zig").VulkanContext;
const ImageBuffer = @import("../engine/data_buffer.zig").ImageBuffer;
const createImageView = @import("../engine/data_buffer.zig").createImageView;
const Engine = @import("../engine/engine.zig").Engine;

pub const Texture = struct {
    image: Image,
    buffer: ImageBuffer,
    sampler: vk.Sampler,

    pub fn init() Texture {
        return .{
            .pixels = undefined,
            .buffer = undefined,
            .sampler = .null_handle,
        };
    }

    /// Initialize texture from raw pixel data
    pub fn initFromData(self: *Texture, data: []const u8) !void {
        self.image = try Image.loadFromMemory(data, 4);
    }

    /// Free resources
    pub fn deinit(self: *Texture, context: *VulkanContext) void {
        self.buffer.deinit(context);
        context.vkd.destroySampler(self.sampler, null);
        self.image.deinit();
    }
};
