const std = @import("std");
const vk = @import("vulkan");
const Image = @import("zstbi").Image;

const context = @import("../engine/context.zig").get();
const ImageBuffer = @import("../engine/data_buffer.zig").ImageBuffer;
const createImageView = @import("../engine/data_buffer.zig").createImageView;
const Engine = @import("../engine/engine.zig").Engine;

pub const Texture = struct {
    image: Image = undefined,
    buffer: ImageBuffer = undefined,
    sampler: vk.Sampler = .null_handle,

    /// Initialize texture from raw pixel data
    pub fn initFromData(self: *Texture, data: []const u8) !void {
        self.image = try Image.loadFromMemory(data, 4);
    }

    /// Free resources
    pub fn deinit(self: *Texture) void {
        self.buffer.deinit();
        context.*.vkd.destroySampler(self.sampler, null);
        self.image.deinit();
    }
};

pub fn createDepthImage(format: vk.Format, width: u32, height: u32) !ImageBuffer {
    const create_info = vk.ImageCreateInfo{
        .image_type = .@"2d",
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .format = format,
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = .{ .depth_stencil_attachment_bit = true },
        .sharing_mode = .exclusive,
        .samples = .{ .@"1_bit" = true },
    };
    var result = ImageBuffer{
        .image = try context.*.vkd.createImage(&create_info, null),
        .memory = undefined,
        .width = width,
        .height = height,
        .format = format,
        .view = undefined,
    };
    const mem_requirements = context.*.vkd.getImageMemoryRequirements(result.image);
    result.memory = try context.*.allocateMemory(mem_requirements, .{});
    try context.*.vkd.bindImageMemory(result.image, result.memory, 0);
    // Transition image layout for depth attachment
    const cmd_buffer = try context.*.beginSingleTimeCommand();
    const barrier = vk.ImageMemoryBarrier{
        .old_layout = .undefined,
        .new_layout = .depth_stencil_attachment_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = result.image,
        .subresource_range = .{
            .aspect_mask = .{ .depth_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_access_mask = .{},
        .dst_access_mask = .{ .depth_stencil_attachment_write_bit = true },
    };
    context.*.vkd.cmdPipelineBarrier(
        cmd_buffer,
        .{ .top_of_pipe_bit = true },
        .{ .early_fragment_tests_bit = true },
        .{},
        0,
        undefined,
        0,
        undefined,
        1,
        @ptrCast(&barrier),
    );
    try context.*.endSingleTimeCommand(cmd_buffer);
    result.view = try createImageView(result.image, format, .{ .depth_bit = true });
    return result;
}
