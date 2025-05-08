const std = @import("std");
const zm = @import("zmath");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;

const context = @import("../engine/context.zig").get();
const Handle = @import("../engine/resource.zig").Handle;
const Texture = @import("texture.zig").Texture;
const Engine = @import("../engine/engine.zig").Engine;
const SKINNED_VERTEX_DESCRIPTION = @import("../geometry/geometry.zig").SKINNED_VERTEX_DESCRIPTION;
const SKINNED_VERTEX_ATTR_DESCRIPTION = @import("../geometry/geometry.zig").SKINNED_VERTEX_ATTR_DESCRIPTION;

/// Material for skinned mesh rendering
pub const SkinnedMaterial = struct {
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
    descriptor_set_layout: vk.DescriptorSetLayout,
    descriptor_set: vk.DescriptorSet,
    allocator: Allocator,

    pub fn init(allocator: Allocator) SkinnedMaterial {
        return .{
            .albedo = undefined,
            .metallic = undefined,
            .roughness = undefined,
            .pipeline_layout = .null_handle,
            .pipeline = .null_handle,
            .descriptor_set_layout = .null_handle,
            .descriptor_set = .null_handle,
            .allocator = allocator,
        };
    }

    pub fn initDescriptorSet(self: *SkinnedMaterial) !void {
        std.debug.print("Creating descriptor set layout...\n", .{});
        // Create descriptor set layout with bindings for textures and bones
        const albedo_binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };
        const metallic_binding = vk.DescriptorSetLayoutBinding{
            .binding = 1,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };
        const roughness_binding = vk.DescriptorSetLayoutBinding{
            .binding = 2,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };
        const bones_binding = vk.DescriptorSetLayoutBinding{
            .binding = 3,
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .vertex_bit = true },
            .p_immutable_samplers = null,
        };
        const bindings = [_]vk.DescriptorSetLayoutBinding{
            albedo_binding,
            metallic_binding,
            roughness_binding,
            bones_binding,
        };
        const layout_info = vk.DescriptorSetLayoutCreateInfo{
            .flags = .{},
            .binding_count = bindings.len,
            .p_bindings = &bindings,
        };
        std.debug.print("Creating descriptor set layout with {} bindings\n", .{bindings.len});
        self.descriptor_set_layout = try context.*.vkd.createDescriptorSetLayout(&layout_info, null);
        std.debug.print("Descriptor set layout created\n", .{});

        // Allocate descriptor set
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = context.*.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptor_set_layout),
        };
        std.debug.print("Allocating descriptor set from pool\n", .{});
        try context.*.vkd.allocateDescriptorSets(&alloc_info, @ptrCast(&self.descriptor_set));
        std.debug.print("Descriptor set allocated successfully\n", .{});
    }

    pub fn updateTextures(self: *SkinnedMaterial, albedo: *Texture, metallic: *Texture, roughness: *Texture) void {
        // Create image info structures for all textures
        const image_infos = [_]vk.DescriptorImageInfo{
            // Albedo
            .{
                .sampler = albedo.sampler,
                .image_view = albedo.buffer.view,
                .image_layout = .shader_read_only_optimal,
            },
            // Metallic
            .{
                .sampler = metallic.sampler,
                .image_view = metallic.buffer.view,
                .image_layout = .shader_read_only_optimal,
            },
            // Roughness
            .{
                .sampler = roughness.sampler,
                .image_view = roughness.buffer.view,
                .image_layout = .shader_read_only_optimal,
            },
        };
        // Create write descriptor set structures
        const writes = [_]vk.WriteDescriptorSet{
            // Albedo texture
            .{
                .dst_set = self.descriptor_set,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = 1,
                .p_image_info = @ptrCast(&image_infos[0]),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            // Metallic texture
            .{
                .dst_set = self.descriptor_set,
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = 1,
                .p_image_info = @ptrCast(&image_infos[1]),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            // Roughness texture
            .{
                .dst_set = self.descriptor_set,
                .dst_binding = 2,
                .dst_array_element = 0,
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = 1,
                .p_image_info = @ptrCast(&image_infos[2]),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
        };
        // Update descriptors
        context.*.vkd.updateDescriptorSets(writes.len, &writes, 0, undefined);
    }

    pub fn updateBoneBuffer(self: *SkinnedMaterial, buffer: vk.Buffer, size: usize) void {
        // Create buffer info
        const buffer_info = vk.DescriptorBufferInfo{
            .buffer = buffer,
            .offset = 0,
            .range = size,
        };
        // Create write descriptor set
        const write = vk.WriteDescriptorSet{
            .dst_set = self.descriptor_set,
            .dst_binding = 3,
            .dst_array_element = 0,
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .p_buffer_info = @ptrCast(&buffer_info),
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        // Update descriptor
        context.*.vkd.updateDescriptorSets(1, @ptrCast(&write), 0, undefined);
    }

    /// Build a skinned material pipeline
    pub fn build(self: *SkinnedMaterial, engine: *Engine, vertex_code: []align(@alignOf(u32)) const u8, fragment_code: []align(@alignOf(u32)) const u8) !void {
        // Create shader modules
        const vert_shader = try context.*.createShaderModule(vertex_code);
        defer context.*.vkd.destroyShaderModule(vert_shader, null);

        const frag_shader = try context.*.createShaderModule(fragment_code);
        defer context.*.vkd.destroyShaderModule(frag_shader, null);

        // Create shader stages
        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            // Vertex shader
            .{
                .stage = .{ .vertex_bit = true },
                .module = vert_shader,
                .p_name = "main",
            },
            // Fragment shader
            .{
                .stage = .{ .fragment_bit = true },
                .module = frag_shader,
                .p_name = "main",
            },
        };

        // Create vertex input state
        const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = SKINNED_VERTEX_DESCRIPTION.len,
            .p_vertex_binding_descriptions = &SKINNED_VERTEX_DESCRIPTION,
            .vertex_attribute_description_count = SKINNED_VERTEX_ATTR_DESCRIPTION.len,
            .p_vertex_attribute_descriptions = &SKINNED_VERTEX_ATTR_DESCRIPTION,
        };

        // Create input assembly state
        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = .triangle_list,
            .primitive_restart_enable = vk.FALSE,
        };

        // Create viewport state
        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .p_viewports = undefined, // Dynamic state
            .scissor_count = 1,
            .p_scissors = undefined, // Dynamic state
        };

        // Create rasterization state
        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = vk.FALSE,
            .rasterizer_discard_enable = vk.FALSE,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = true },
            .front_face = .clockwise,
            .depth_bias_enable = vk.FALSE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1.0,
        };

        // Create multisampling state
        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = vk.FALSE,
            .min_sample_shading = 0.0,
            .alpha_to_coverage_enable = vk.FALSE,
            .alpha_to_one_enable = vk.FALSE,
        };

        // Create color blend attachment state
        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blend_enable = vk.FALSE,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{
                .r_bit = true,
                .g_bit = true,
                .b_bit = true,
                .a_bit = true,
            },
        };

        // Create color blend state
        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = vk.FALSE,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_blend_attachment),
            .blend_constants = [_]f32{ 0, 0, 0, 0 },
        };

        // Create depth stencil state
        const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = vk.TRUE,
            .depth_write_enable = vk.TRUE,
            .depth_compare_op = .less,
            .depth_bounds_test_enable = vk.FALSE,
            .min_depth_bounds = 0.0,
            .max_depth_bounds = 1.0,
            .stencil_test_enable = vk.FALSE,
            .front = .{
                .fail_op = .keep,
                .pass_op = .keep,
                .depth_fail_op = .keep,
                .compare_op = .always,
                .compare_mask = 0,
                .write_mask = 0,
                .reference = 0,
            },
            .back = .{
                .fail_op = .keep,
                .pass_op = .keep,
                .depth_fail_op = .keep,
                .compare_op = .always,
                .compare_mask = 0,
                .write_mask = 0,
                .reference = 0,
            },
        };

        // Create dynamic state
        const dynamic_states = [_]vk.DynamicState{
            .viewport,
            .scissor,
        };

        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };

        // Create push constant range
        const push_constant = vk.PushConstantRange{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(zm.Mat),
        };

        // Create descriptor set layouts
        const set_layouts = [_]vk.DescriptorSetLayout{
            engine.renderer.main_pass_descriptor_set_layout,
            self.descriptor_set_layout,
        };

        // Create pipeline layout
        const layout_info = vk.PipelineLayoutCreateInfo{
            .set_layout_count = set_layouts.len,
            .p_set_layouts = &set_layouts,
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_constant),
        };

        self.pipeline_layout = try context.*.vkd.createPipelineLayout(&layout_info, null);

        const rendering_info = vk.PipelineRenderingCreateInfoKHR{
            .color_attachment_count = 1,
            .p_color_attachment_formats = @ptrCast(&engine.renderer.format.format),
            .depth_attachment_format = .d32_sfloat,
            .stencil_attachment_format = .undefined,
            .view_mask = 0,
        };

        // Create graphics pipeline
        const pipeline_info = vk.GraphicsPipelineCreateInfo{
            .stage_count = shader_stages.len,
            .p_stages = &shader_stages,
            .p_vertex_input_state = &vertex_input_info,
            .p_input_assembly_state = &input_assembly,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisampling,
            .p_color_blend_state = &color_blending,
            .p_dynamic_state = &dynamic_state,
            .p_depth_stencil_state = &depth_stencil,
            .layout = self.pipeline_layout,
            .subpass = 0,
            .base_pipeline_index = -1,
            .p_next = &rendering_info,
        };

        // Create pipeline
        _ = try context.*.vkd.createGraphicsPipelines(.null_handle, 1, @ptrCast(&pipeline_info), null, @ptrCast(&self.pipeline));
    }
    pub fn deinit(self: *SkinnedMaterial) void {
        context.*.vkd.destroyPipeline(self.pipeline, null);
        context.*.vkd.destroyPipelineLayout(self.pipeline_layout, null);
        context.*.vkd.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
    }
};
