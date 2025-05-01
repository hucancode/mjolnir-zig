const std = @import("std");
const zgui = @import("zgui");
const vk = @import("vulkan");
const glfw_vk = @import("glfw_vulkan.zig");
const Engine = @import("engine.zig").Engine;
const context = @import("context.zig").get();

pub const ImGui = struct {
    descriptor_pool: vk.DescriptorPool = undefined,

    pub fn init(self: *ImGui, engine: *Engine) !void {
        const sampler_size = vk.DescriptorPoolSize{
            .type = .combined_image_sampler,
            .descriptor_count = 10,
        };
        const pool_sizes = [_]vk.DescriptorPoolSize{sampler_size};
        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{ .free_descriptor_set_bit = true },
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
            .max_sets = 10,
        };
        self.descriptor_pool = try context.vkd.createDescriptorPool(&pool_info, null);
        const prend: zgui.backend.VkPipelineRenderingCreateInfo = .{
            .s_type = @intFromEnum(vk.StructureType.pipeline_rendering_create_info),
            .color_attachment_count = 1,
            .p_color_attachment_formats = &[_]i32{@intFromEnum(engine.renderer.format.format)},
            .view_mask = 0,
            .depth_attachment_format = 0,
            .stencil_attachment_format = 0,
        };
        const vk_init: zgui.backend.ImGui_ImplVulkan_InitInfo = .{
            .instance = @intFromEnum(context.vki.handle),
            .physical_device = @intFromEnum(context.physical_device),
            .device = @intFromEnum(context.vkd.handle),
            .queue_family = context.graphics_family,
            .queue = @intFromEnum(context.graphics_queue),
            .descriptor_pool = @intFromEnum(self.descriptor_pool),
            .min_image_count = 2,
            .image_count = 2,
            .render_pass = 0,
            .use_dynamic_rendering = true,
            .pipeline_rendering_create_info = prend,
        };
        const vk_loader = struct {
            pub fn load(function_name: [*:0]const u8, user_data: ?*anyopaque) callconv(.C) ?*anyopaque {
                const instance: *vk.Instance = @ptrCast(@alignCast(user_data.?));
                var ret = glfw_vk.getInstanceProcAddress(instance.*, function_name);
                if (ret == null) {
                    ret = context.vki.getDeviceProcAddr(context.vkd.handle, function_name);
                }
                if (ret) |ptr| {
                    std.debug.print("imgui is now loading vk function: {s} -> {p}\n", .{ function_name, ptr });
                } else {
                    std.debug.print("imgui failed to load vk function: {s}\n", .{function_name});
                }
                return @constCast(@ptrCast(ret));
            }
        }.load;
        zgui.init(engine.allocator);
        zgui.io.setConfigFlags(.{ .dock_enable = true, .is_srgb = true });
        const style = zgui.getStyle();
        zgui.Style.setColorsBuiltin(style, .dark);
        _ = zgui.backend.loadFunctions(vk_loader, &context.vki.handle);
        zgui.backend.init(vk_init, context.window);
    }

    pub fn deinit(self: *ImGui) void {
        zgui.backend.deinit();
        zgui.deinit();
        context.vkd.destroyDescriptorPool(self.descriptor_pool, null);
    }
};
