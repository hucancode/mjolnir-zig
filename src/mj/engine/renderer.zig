const std = @import("std");
const vk = @import("vulkan");
const zm = @import("zmath");
const DataBuffer = @import("data_buffer.zig").DataBuffer;
const ImageBuffer = @import("data_buffer.zig").ImageBuffer;
const ShadowMaterial = @import("../material/shadow.zig").ShadowMaterial;
const createImageView = @import("data_buffer.zig").createImageView;
const DepthTexture = @import("../material/texture.zig").DepthTexture;
const context = @import("context.zig").get();
const MAX_FRAMES_IN_FLIGHT = @import("context.zig").MAX_FRAMES_IN_FLIGHT;
pub const MAX_LIGHTS = 10;

// Shadow map constants
pub const SHADOW_MAP_SIZE = 512;
pub const MAX_SHADOW_MAPS = MAX_LIGHTS;

pub const SingleLightUniform = struct {
    view_proj: zm.Mat = zm.identity(),
    color: zm.Vec = .{ 1.0, 1.0, 1.0, 1.0 },
    position: zm.Vec = .{ 0.0, 0.0, 0.0, 1.0 },
    direction: zm.Vec = .{ 0.0, -1.0, 0.0, 0.0 },
    kind: u32 = 0,
    angle: f32 = 0.2,
    radius: f32 = 10.0,
    has_shadow: u32 = 0, // 0 = no shadow, 1 = has shadow
};

pub const SceneUniform = struct {
    view: zm.Mat,
    projection: zm.Mat,
    time: f32 = 0.0,
};

pub const SceneLightUniform = struct {
    lights: [MAX_LIGHTS]SingleLightUniform = undefined,
    light_count: u32 = 0,
    pub fn pushLight(self: *SceneLightUniform, light: SingleLightUniform) void {
        if (self.light_count < MAX_LIGHTS) {
            self.lights[self.light_count] = light;
            self.light_count += 1;
        }
    }
    pub fn clearLights(self: *SceneLightUniform) void {
        self.light_count = 0;
    }
};

pub const Frame = struct {
    image_available_semaphore: vk.Semaphore,
    render_finished_semaphore: vk.Semaphore,
    fence: vk.Fence,
    command_buffer: vk.CommandBuffer,
    scene_uniform: DataBuffer,
    light_uniform: DataBuffer,
    shadow_maps: [MAX_SHADOW_MAPS]DepthTexture,
    main_pass_descriptor_set: vk.DescriptorSet,
    light_view_proj_uniform: DataBuffer,
    shadow_pass_descriptor_set: vk.DescriptorSet,

    pub fn init(self: *Frame, main_descriptor_set_layout: vk.DescriptorSetLayout, shadow_pass_descriptor_set_layout: vk.DescriptorSetLayout) !void {
        self.scene_uniform = try context.*.mallocHostVisibleBuffer(@sizeOf(SceneUniform), .{ .uniform_buffer_bit = true });
        self.light_uniform = try context.*.mallocHostVisibleBuffer(@sizeOf(SceneLightUniform), .{ .uniform_buffer_bit = true });
        for (&self.shadow_maps) |*map| {
            try map.init(SHADOW_MAP_SIZE, SHADOW_MAP_SIZE);
        }
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = context.*.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&main_descriptor_set_layout),
        };
        try context.*.vkd.allocateDescriptorSets(&alloc_info, @ptrCast(&self.main_pass_descriptor_set));
        self.light_view_proj_uniform = try context.*.mallocHostVisibleBuffer(@sizeOf(zm.Mat), .{ .uniform_buffer_bit = true });

        const shadow_pass_alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = context.*.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&shadow_pass_descriptor_set_layout),
        };
        try context.*.vkd.allocateDescriptorSets(&shadow_pass_alloc_info , @ptrCast(&self.shadow_pass_descriptor_set));
        std.debug.print("Created descriptor set\n", .{});
        var shadow_map_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo = undefined;
        for (0..MAX_SHADOW_MAPS) |i| {
            shadow_map_infos[i] = .{
                .sampler = self.shadow_maps[i].sampler,
                .image_view = self.shadow_maps[i].buffer.view,
                .image_layout = .shader_read_only_optimal,
            };
        }
        const scene_buffer_info = [_]vk.DescriptorBufferInfo {
            .{
                .buffer = self.scene_uniform.buffer,
                .offset = 0,
                .range = @sizeOf(SceneUniform),
            },
        };
        const light_buffer_info = [_]vk.DescriptorBufferInfo {
            .{
                .buffer = self.light_uniform.buffer,
                .offset = 0,
                .range = @sizeOf(SceneLightUniform),
            },
        };
        const writes = [_]vk.WriteDescriptorSet {
            .{
                .dst_set = self.main_pass_descriptor_set,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = scene_buffer_info.len,
                .p_buffer_info = &scene_buffer_info,
                .p_image_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            .{
                .dst_set = self.main_pass_descriptor_set,
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = light_buffer_info.len,
                .p_buffer_info = &light_buffer_info,
                .p_image_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            .{
                .dst_set = self.main_pass_descriptor_set,
                .dst_binding = 2,
                .dst_array_element = 0,
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = shadow_map_infos.len,
                .p_image_info = &shadow_map_infos,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            }
        };
        context.*.vkd.updateDescriptorSets(writes.len, &writes, 0, null);
        const light_view_proj_buffer_info = [_]vk.DescriptorBufferInfo {
            .{
                .buffer = self.light_view_proj_uniform.buffer,
                .offset = 0,
                .range = @sizeOf(zm.Mat),
            },
        };
        const shadow_pass_writes = [_]vk.WriteDescriptorSet {
            .{
                .dst_set = self.shadow_pass_descriptor_set,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = light_view_proj_buffer_info .len,
                .p_buffer_info = &light_view_proj_buffer_info ,
                .p_image_info = undefined,
                .p_texel_buffer_view = undefined,
            },
        };
        context.*.vkd.updateDescriptorSets(shadow_pass_writes .len, &shadow_pass_writes , 0, null);
    }

    pub fn deinit(self: *Frame) void {
        context.*.vkd.destroySemaphore(self.image_available_semaphore, null);
        context.*.vkd.destroySemaphore(self.render_finished_semaphore, null);
        context.*.vkd.destroyFence(self.fence, null);
        context.*.vkd.freeCommandBuffers(context.*.command_pool, 1, @ptrCast(&self.command_buffer));
        self.scene_uniform.deinit();
    }
};

pub const Renderer = struct {
    swapchain: vk.SwapchainKHR,
    format: vk.SurfaceFormatKHR,
    extent: vk.Extent2D,
    images: []vk.Image,
    views: []vk.ImageView,
    frames: [MAX_FRAMES_IN_FLIGHT]Frame,
    main_pass_descriptor_set_layout: vk.DescriptorSetLayout,
    shadow_pass_descriptor_set_layout: vk.DescriptorSetLayout,
    depth_buffer: ImageBuffer,
    current_frame: u32 = 0,
    allocator: std.mem.Allocator,
    shadow_pass_material: ShadowMaterial,

    pub fn init(self: *Renderer, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        const view_proj_time_binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        };
        const light_binding = vk.DescriptorSetLayoutBinding{
            .binding = 1,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
        };
        const shadow_sampler_binding = vk.DescriptorSetLayoutBinding{
            .binding = 2,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = MAX_SHADOW_MAPS,
            .stage_flags = .{ .fragment_bit = true },
        };
        const bindings = [_]vk.DescriptorSetLayoutBinding{
            view_proj_time_binding,
            light_binding,
            shadow_sampler_binding,
        };
        const layout_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = bindings.len,
            .p_bindings = &bindings,
        };
        self.main_pass_descriptor_set_layout = try context.*.vkd.createDescriptorSetLayout(&layout_info, null);
        const shadow_pass_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0, // light view projection matrix
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .vertex_bit = true },
            },
        };
        const shadow_pass_layout_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = shadow_pass_bindings.len,
            .p_bindings = &shadow_pass_bindings,
        };
        self.shadow_pass_descriptor_set_layout = try context.*.vkd.createDescriptorSetLayout(&shadow_pass_layout_info , null);
        for (&self.frames) |*frame| {
            try frame.init(self.main_pass_descriptor_set_layout, self.shadow_pass_descriptor_set_layout);
        }
        try self.shadow_pass_material.build(self);
    }

    pub fn buildCommandBuffers(self: *Renderer) !void {
        const alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = context.*.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        for (&self.frames) |*frame| {
            try context.*.vkd.allocateCommandBuffers(&alloc_info, @ptrCast(&frame.command_buffer));
        }
    }
    pub fn buildSynchronizers(self: *Renderer) !void {
        const semaphore_info = vk.SemaphoreCreateInfo{};

        const fence_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = true },
        };

        for (&self.frames) |*frame| {
            frame.image_available_semaphore = try context.*.vkd.createSemaphore(&semaphore_info, null);
            frame.render_finished_semaphore = try context.*.vkd.createSemaphore(&semaphore_info, null);
            frame.fence = try context.*.vkd.createFence(&fence_info, null);
        }
    }

    pub fn buildSwapchain(
        self: *Renderer,
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
            .surface = context.*.surface,
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

        self.swapchain = try context.*.vkd.createSwapchainKHR(&create_info, null);

        // Get swapchain images
        var swapchain_image_count: u32 = 0;
        _ = try context.*.vkd.getSwapchainImagesKHR(self.swapchain, &swapchain_image_count, null);
        if (self.images.len > 0) self.allocator.free(self.images);
        self.images = try self.allocator.alloc(vk.Image, swapchain_image_count);
        _ = try context.*.vkd.getSwapchainImagesKHR(self.swapchain, &swapchain_image_count, self.images.ptr);

        // Create image views
        if (self.views.len > 0) self.allocator.free(self.views);
        self.views = try self.allocator.alloc(vk.ImageView, swapchain_image_count);

        for (self.images, 0..) |image, i| {
            self.views[i] = try createImageView(image, self.format.format, .{ .color_bit = true });
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

    // main pass camera view proj uniform
    pub fn getSceneUniform(self: *Renderer) *DataBuffer {
        return &self.frames[self.current_frame].scene_uniform;
    }

    // main pass light data uniform
    pub fn getLightUniform(self: *Renderer) *DataBuffer {
        return &self.frames[self.current_frame].light_uniform;
    }

    // shadow pass

    pub fn getLightViewProjUniform(self: *Renderer) *DataBuffer {
        return &self.frames[self.current_frame].light_view_proj_uniform;
    }

    pub fn getShadowMap(self: *Renderer, light_idx: u16) *DepthTexture {
        return &self.frames[self.current_frame].shadow_maps[light_idx];
    }

    pub fn getSceneDescriptorSet(self: *Renderer) vk.DescriptorSet {
        return self.frames[self.current_frame].main_pass_descriptor_set;
    }

    pub fn getShadowDescriptorSet(self: *Renderer) vk.DescriptorSet {
        return self.frames[self.current_frame].shadow_pass_descriptor_set;
    }

    // end shadow pass

    pub fn begin(self: *Renderer) !u32 {
        // Wait for previous frame
        _ = try context.*.vkd.waitForFences(1, @ptrCast(&self.getInFlightFence()), vk.TRUE, std.math.maxInt(u64));

        const result = try context.*.vkd.acquireNextImageKHR(
            self.swapchain,
            std.math.maxInt(u64),
            self.getImageAvailableSemaphore(),
            .null_handle,
        );
        try context.*.vkd.resetFences(1, @ptrCast(&self.getInFlightFence()));
        try context.*.vkd.resetCommandBuffer(self.getCommandBuffer(), .{});
        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        };
        try context.*.vkd.beginCommandBuffer(self.getCommandBuffer(), &begin_info);
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

        context.*.vkd.cmdPipelineBarrier(
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

        context.*.vkd.cmdBeginRenderingKHR(self.getCommandBuffer(), &render_info);

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

        context.*.vkd.cmdSetViewport(self.getCommandBuffer(), 0, 1, @ptrCast(&viewport));
        context.*.vkd.cmdSetScissor(self.getCommandBuffer(), 0, 1, @ptrCast(&scissor));

        return result.image_index;
    }

    pub fn end(self: *Renderer, image_idx: u32) !void {
        // End rendering
        context.*.vkd.cmdEndRenderingKHR(self.getCommandBuffer());

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

        context.*.vkd.cmdPipelineBarrier(
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
        try context.*.vkd.endCommandBuffer(self.getCommandBuffer());

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

        try context.*.vkd.queueSubmit(context.*.graphics_queue, 1, @ptrCast(&submit_info), self.getInFlightFence());

        // Present
        const present_info = vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.getRenderFinishedSemaphore()),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain),
            .p_image_indices = @ptrCast(&image_idx),
        };

        _ = try context.*.vkd.queuePresentKHR(context.*.present_queue, &present_info);

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

    pub fn destroySwapchain(self: *Renderer) void {
        for (self.views) |view| {
            context.*.vkd.destroyImageView(view, null);
        }
        self.depth_buffer.deinit();
        context.*.vkd.destroySwapchainKHR(self.swapchain, null);
        self.allocator.free(self.views);
        self.allocator.free(self.images);
    }

    pub fn deinit(self: *Renderer) void {
        self.destroySwapchain();
        for (&self.frames) |*frame| {
            frame.deinit();
        }
    }
};

pub fn pickSwapPresentMode(present_modes: []vk.PresentModeKHR) vk.PresentModeKHR {
    if (std.mem.containsAtLeastScalar(vk.PresentModeKHR, present_modes, 1, .mailbox_khr)) {
        return .mailbox_khr;
    }
    return .fifo_khr;
}
