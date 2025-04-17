const std = @import("std");
const vk = @import("vulkan");
const zm = @import("zmath");
const DataBuffer = @import("data_buffer.zig").DataBuffer;
const ImageBuffer = @import("data_buffer.zig").ImageBuffer;
const createImageView = @import("data_buffer.zig").createImageView;
const VulkanContext = @import("context.zig").VulkanContext;
const MAX_FRAMES_IN_FLIGHT = @import("context.zig").MAX_FRAMES_IN_FLIGHT;
pub const MAX_LIGHTS = 10;

pub const LightUniform = struct {
    color: zm.Vec = .{ 1.0, 1.0, 1.0, 1.0 },
    position: zm.Vec = .{ 0.0, 0.0, 0.0, 1.0 },
    direction: zm.Vec = .{ 0.0, 0.0, 0.0, 1.0 },
    angle: zm.Vec = undefined, // angle + 3 extra info
};

pub const SceneUniform = struct {
    view: zm.Mat,
    projection: zm.Mat,
    time: zm.Vec = undefined, // time + 3 extra info
    lights: [MAX_LIGHTS]LightUniform,
    // pub fn pushLight(self: *SceneUniform, light: LightUniform) void {
    //     if (self.light_count < MAX_LIGHTS) {
    //         self.lights[self.light_count] = light;
    //         self.light_count += 1;
    //     }
    // }
    // pub fn clearLights(self: *SceneUniform) void {
    //     self.light_count = 0;
    // }
};

pub const Frame = struct {
    image_available_semaphore: vk.Semaphore,
    render_finished_semaphore: vk.Semaphore,
    fence: vk.Fence,
    command_buffer: vk.CommandBuffer,
    uniform: DataBuffer,
    descriptor_set: vk.DescriptorSet,

    pub fn deinit(self: *Frame, context: *VulkanContext) void {
        context.vkd.destroySemaphore(self.image_available_semaphore, null);
        context.vkd.destroySemaphore(self.render_finished_semaphore, null);
        context.vkd.destroyFence(self.fence, null);
        context.vkd.freeCommandBuffers(context.command_pool, 1, @ptrCast(&self.command_buffer));
        self.uniform.deinit(context);
    }
};

pub const Renderer = struct {
    swapchain: vk.SwapchainKHR,
    format: vk.SurfaceFormatKHR,
    extent: vk.Extent2D,
    images: []vk.Image,
    views: []vk.ImageView,
    mutable_uniform_layout: vk.DescriptorSetLayout,
    frames: [MAX_FRAMES_IN_FLIGHT]Frame,
    depth_buffer: ImageBuffer,
    current_frame: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Renderer {
        return .{
            .swapchain = .null_handle,
            .format = undefined,
            .extent = undefined,
            .images = &[_]vk.Image{},
            .views = &[_]vk.ImageView{},
            .mutable_uniform_layout = .null_handle,
            .frames = undefined,
            .depth_buffer = undefined,
            .current_frame = 0,
            .allocator = allocator,
        };
    }

    pub fn buildCommandBuffers(self: *Renderer, context: *VulkanContext) !void {
        const alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = context.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        for (&self.frames) |*frame| {
            try context.vkd.allocateCommandBuffers(&alloc_info, @ptrCast(&frame.command_buffer));
        }
    }

    pub fn buildSynchronizers(self: *Renderer, context: *VulkanContext) !void {
        const semaphore_info = vk.SemaphoreCreateInfo{};

        const fence_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = true },
        };

        for (&self.frames) |*frame| {
            frame.image_available_semaphore = try context.vkd.createSemaphore(&semaphore_info, null);
            frame.render_finished_semaphore = try context.vkd.createSemaphore(&semaphore_info, null);
            frame.fence = try context.vkd.createFence(&fence_info, null);
        }
    }

    pub fn buildSwapchain(
        self: *Renderer,
        context: *VulkanContext,
        capabilities: vk.SurfaceCapabilitiesKHR,
        formats: []vk.SurfaceFormatKHR,
        present_modes: []vk.PresentModeKHR,
        graphics_family: u32,
        present_family: u32,
    ) !void {
        self.buildSwapSurfaceFormat(formats);
        self.buildSwapExtent(capabilities);

        var image_count = capabilities.min_image_count + 1;
        const unlimited = capabilities.max_image_count == 0;
        if (!unlimited and image_count > capabilities.max_image_count) {
            image_count = capabilities.max_image_count;
        }

        const indices = [_]u32{ graphics_family, present_family };
        var create_info = vk.SwapchainCreateInfoKHR{
            .surface = context.surface,
            .min_image_count = image_count,
            .image_format = self.format.format,
            .image_color_space = self.format.color_space,
            .image_extent = self.extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = pickSwapPresentMode(present_modes),
            .clipped = vk.TRUE,
        };

        if (graphics_family != present_family) {
            create_info.image_sharing_mode = .concurrent;
            create_info.queue_family_index_count = indices.len;
            create_info.p_queue_family_indices = &indices;
        }

        self.swapchain = try context.vkd.createSwapchainKHR(&create_info, null);

        // Get swapchain images
        var swapchain_image_count: u32 = 0;
        _ = try context.vkd.getSwapchainImagesKHR(self.swapchain, &swapchain_image_count, null);
        if (self.images.len > 0) self.allocator.free(self.images);
        self.images = try self.allocator.alloc(vk.Image, swapchain_image_count);
        _ = try context.vkd.getSwapchainImagesKHR(self.swapchain, &swapchain_image_count, self.images.ptr);

        // Create image views
        if (self.views.len > 0) self.allocator.free(self.views);
        self.views = try self.allocator.alloc(vk.ImageView, swapchain_image_count);

        for (self.images, 0..) |image, i| {
            self.views[i] = try createImageView(context, image, self.format.format, .{ .color_bit = true });
        }
    }

    pub fn getInFlightFence(self: *Renderer) vk.Fence {
        return self.frames[self.current_frame].fence;
    }

    pub fn getImageAvailableSemaphore(self: *Renderer) vk.Semaphore {
        return self.frames[self.current_frame].image_available_semaphore;
    }

    pub fn getRenderFinishedSemaphore(self: *Renderer) vk.Semaphore {
        return self.frames[self.current_frame].render_finished_semaphore;
    }

    pub fn getCommandBuffer(self: *Renderer) vk.CommandBuffer {
        return self.frames[self.current_frame].command_buffer;
    }

    pub fn getUniform(self: *Renderer) *DataBuffer {
        return &self.frames[self.current_frame].uniform;
    }

    pub fn getDescriptorSet(self: *Renderer) vk.DescriptorSet {
        return self.frames[self.current_frame].descriptor_set;
    }

    pub fn begin(self: *Renderer, context: *VulkanContext) !u32 {
        // Wait for previous frame
        _ = try context.vkd.waitForFences(1, @ptrCast(&self.getInFlightFence()), vk.TRUE, std.math.maxInt(u64));

        // Acquire next image
        const result = context.vkd.acquireNextImageKHR(
            self.swapchain,
            std.math.maxInt(u64),
            self.getImageAvailableSemaphore(),
            .null_handle,
        ) catch |err| {
            if (err == error.OutOfDateKHR) {
                return error.OutOfDateKHR;
            }
            return err;
        };

        // Reset fence
        try context.vkd.resetFences(1, @ptrCast(&self.getInFlightFence()));

        // Begin command buffer
        try context.vkd.resetCommandBuffer(self.getCommandBuffer(), .{});

        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        };
        try context.vkd.beginCommandBuffer(self.getCommandBuffer(), &begin_info);

        // Transition image layout to color attachment optimal
        const barrier = vk.ImageMemoryBarrier{
            .old_layout = .undefined,
            .new_layout = .color_attachment_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.images[result.image_index],
            .subresource_range = vk.ImageSubresourceRange{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_access_mask = .{},
            .dst_access_mask = .{ .color_attachment_write_bit = true },
        };

        context.vkd.cmdPipelineBarrier(
            self.getCommandBuffer(),
            .{ .top_of_pipe_bit = true },
            .{ .color_attachment_output_bit = true },
            .{},
            0,
            undefined,
            0,
            undefined,
            1,
            @ptrCast(&barrier),
        );

        // Begin rendering
        const color_attachment = vk.RenderingAttachmentInfoKHR{
            .image_view = self.views[result.image_index],
            .image_layout = .color_attachment_optimal,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{
                .color = .{
                    .float_32 = [_]f32{ 0.0117, 0.0117, 0.0179, 1.0 },
                },
            },
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
        };

        const depth_attachment = vk.RenderingAttachmentInfoKHR{
            .image_view = self.depth_buffer.view,
            .image_layout = .depth_stencil_attachment_optimal,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{
                .depth_stencil = .{
                    .depth = 1.0,
                    .stencil = 0,
                },
            },
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
        };

        const render_info = vk.RenderingInfoKHR{
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.extent,
            },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment),
            .p_depth_attachment = @ptrCast(&depth_attachment),
        };

        context.vkd.cmdBeginRenderingKHR(self.getCommandBuffer(), &render_info);

        // Vulkan coordinate system default to:
        // +Y down
        // +X right
        // +Z back
        // It is convenient to have +Y up so we need to transform the viewport here
        // { width: vp.width, height: -vp.height }
        // { x: 0, y: vp.height }
        const viewport = vk.Viewport{
            .x = 0,
            .y = @floatFromInt(self.extent.height),
            .width = @floatFromInt(self.extent.width),
            .height = -@as(f32, @floatFromInt(self.extent.height)),
            .min_depth = 0.0,
            .max_depth = 1.0,
        };

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.extent,
        };

        context.vkd.cmdSetViewport(self.getCommandBuffer(), 0, 1, @ptrCast(&viewport));
        context.vkd.cmdSetScissor(self.getCommandBuffer(), 0, 1, @ptrCast(&scissor));

        return result.image_index;
    }

    pub fn end(self: *Renderer, context: *VulkanContext, image_idx: u32) !void {
        // End rendering
        context.vkd.cmdEndRenderingKHR(self.getCommandBuffer());

        // Transition image layout to present
        const barrier = vk.ImageMemoryBarrier{
            .old_layout = .color_attachment_optimal,
            .new_layout = .present_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.images[image_idx],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_access_mask = .{ .color_attachment_write_bit = true },
            .dst_access_mask = .{},
        };

        context.vkd.cmdPipelineBarrier(
            self.getCommandBuffer(),
            .{ .color_attachment_output_bit = true },
            .{ .bottom_of_pipe_bit = true },
            .{},
            0,
            undefined,
            0,
            undefined,
            1,
            @ptrCast(&barrier),
        );

        // End command buffer
        try context.vkd.endCommandBuffer(self.getCommandBuffer());

        // Submit command buffer
        const wait_stage = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.getImageAvailableSemaphore()),
            .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&self.getCommandBuffer()),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&self.getRenderFinishedSemaphore()),
        };

        try context.vkd.queueSubmit(context.graphics_queue, 1, @ptrCast(&submit_info), self.getInFlightFence());

        // Present
        const present_info = vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.getRenderFinishedSemaphore()),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain),
            .p_image_indices = @ptrCast(&image_idx),
        };

        _ = try context.vkd.queuePresentKHR(context.present_queue, &present_info);

        // Advance to next frame
        self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
    }

    pub fn buildSwapSurfaceFormat(self: *Renderer, formats: []vk.SurfaceFormatKHR) void {
        // Look for preferred format
        for (formats) |format| {
            if (format.format == .b8g8r8a8_srgb and
                format.color_space == .srgb_nonlinear_khr)
            {
                self.format = format;
                return;
            }
        }

        // If preferred format not found, use first available
        self.format = formats[0];
    }

    pub fn buildSwapExtent(self: *Renderer, capabilities: vk.SurfaceCapabilitiesKHR) void {
        if (capabilities.current_extent.width != std.math.maxInt(u32)) {
            self.extent = capabilities.current_extent;
            return;
        }

        // Set default size
        self.extent = .{
            .width = 1280,
            .height = 720,
        };

        // Clamp to min/max allowed sizes
        self.extent.width = @max(capabilities.min_image_extent.width, @min(capabilities.max_image_extent.width, self.extent.width));
        self.extent.height = @max(capabilities.min_image_extent.height, @min(capabilities.max_image_extent.height, self.extent.height));
    }

    pub fn destroySwapchain(self: *Renderer, context: *VulkanContext) void {
        for (self.views) |view| {
            context.vkd.destroyImageView(view, null);
        }
        self.depth_buffer.deinit(context);
        context.vkd.destroySwapchainKHR(self.swapchain, null);
        self.allocator.free(self.views);
        self.allocator.free(self.images);
    }

    pub fn deinit(self: *Renderer, context: *VulkanContext) void {
        self.destroySwapchain(context);
        for (&self.frames) |*frame| {
            frame.deinit(context);
        }
    }
};

pub fn pickSwapPresentMode(present_modes: []vk.PresentModeKHR) vk.PresentModeKHR {
    for (present_modes) |mode| {
        if (mode == .mailbox_khr) {
            return mode;
        }
    }
    return .fifo_khr;
}
