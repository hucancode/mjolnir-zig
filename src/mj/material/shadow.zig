
const std = @import("std");
const zm = @import("zmath");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;

const context = @import("../engine/context.zig").get();
const Handle = @import("../engine/resource.zig").Handle;
const Texture = @import("texture.zig").Texture;
const Renderer = @import("../engine/renderer.zig").Renderer;

pub const ShadowMaterial = struct {
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ShadowMaterial {
        return .{
            .albedo = undefined,
            .metallic = undefined,
            .roughness = undefined,
            .pipeline_layout = .null_handle,
            .pipeline = .null_handle,
            .allocator = allocator,
        };
    }

    pub fn build(self: *ShadowMaterial, renderer: *Renderer) !void {
        const SHADOW_VERTEX_CODE align(@alignOf(u32)) = @embedFile("shaders/shadow/vert.spv").*;
        const vert_shader = try context.*.createShaderModule(&SHADOW_VERTEX_CODE);
        defer context.*.vkd.destroyShaderModule(vert_shader, null);
        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .stage = .{ .vertex_bit = true },
                .module = vert_shader,
                .p_name = "main",
            },
        };
        const dynamic_states = [_]vk.DynamicState{
            .viewport,
            .scissor,
            .depth_bias,
        };

        const dynamic_state_info = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };

        const vertex_binding_description = [_]vk.VertexInputBindingDescription{
            .{
                .binding = 0,
                .stride = @sizeOf([4]f32),
                .input_rate = .vertex,
            },
        };
        const vertex_attribute_descriptions = [_]vk.VertexInputAttributeDescription{
            .{
                .binding = 0,
                .location = 0,
                .format = .r32g32b32a32_sfloat,
                .offset = 0,
            },
        };
        const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = vertex_binding_description.len,
            .p_vertex_binding_descriptions = &vertex_binding_description,
            .vertex_attribute_description_count = vertex_attribute_descriptions.len,
            .p_vertex_attribute_descriptions = &vertex_attribute_descriptions,
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
            .depth_bias_enable = vk.TRUE,
            .depth_bias_constant_factor = 1.25,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 1.75,
            .line_width = 1.0,
        };

        // Create multisampling state
        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = vk.FALSE,
            .min_sample_shading = 1.0,
            .alpha_to_coverage_enable = vk.FALSE,
            .alpha_to_one_enable = vk.FALSE,
        };

        // Create color blend state
        const blending = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = vk.FALSE,
            .logic_op = .copy,
            .blend_constants = [_]f32{ 0, 0, 0, 0 },
        };
        const set_layouts = [_]vk.DescriptorSetLayout{
            renderer.shadow_pass_descriptor_set_layout
        };

        // Create push constant range
        const push_constant = vk.PushConstantRange{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(zm.Mat),
        };

        // Create pipeline layout
        const layout_info = vk.PipelineLayoutCreateInfo{
            .set_layout_count = set_layouts.len,
            .p_set_layouts = &set_layouts,
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_constant),
        };

        self.pipeline_layout = try context.*.vkd.createPipelineLayout(&layout_info, null);
        std.debug.print("Shadow Material pipeline layout created\n", .{});

        // Create depth stencil state
        const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = vk.TRUE,
            .depth_write_enable = vk.TRUE,
            .depth_compare_op = .less,
            .depth_bounds_test_enable = vk.FALSE,
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
            .min_depth_bounds = 0.0,
            .max_depth_bounds = 1.0,
        };

        // Create dynamic rendering info
        const rendering_info = vk.PipelineRenderingCreateInfoKHR{
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
            .p_color_blend_state = &blending,
            .p_dynamic_state = &dynamic_state_info,
            .p_depth_stencil_state = &depth_stencil,
            .layout = self.pipeline_layout,
            .subpass = 0,
            .base_pipeline_index = -1,
            .p_next = &rendering_info,
        };

        _ = try context.*.vkd.createGraphicsPipelines(.null_handle, 1, @ptrCast(&pipeline_info), null, @ptrCast(&self.pipeline));

        std.debug.print("Material pipeline created\n", .{});
    }

    pub fn deinit(self: *ShadowMaterial) void {
        context.*.vkd.destroyPipeline(self.pipeline, null);
        context.*.vkd.destroyPipelineLayout(self.pipeline_layout, null);
        context.*.vkd.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
    }
};
