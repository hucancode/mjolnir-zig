const builtin = @import("builtin");
const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("zglfw");
const glfw_vk = @import("glfw_vulkan.zig");
const Allocator = std.mem.Allocator;
const data_buffer = @import("data_buffer.zig");
const DataBuffer = data_buffer.DataBuffer;
const ImageBuffer = data_buffer.ImageBuffer;

const REQUIRED_DEVICE_EXTENSIONS = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
    vk.extensions.khr_dynamic_rendering.name,
};

const APIS: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_2,
    // vk.features.version_1_3, // MacOS MoltenVK does not support this
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.khr_dynamic_rendering,
    vk.extensions.khr_portability_enumeration,
    vk.extensions.ext_debug_utils,
};

const BaseDispatch = vk.BaseWrapper(APIS);
const InstanceDispatch = vk.InstanceWrapper(APIS);
const DeviceDispatch = vk.DeviceWrapper(APIS);
const Instance = vk.InstanceProxy(APIS);
const Device = vk.DeviceProxy(APIS);

pub const ENGINE_NAME = "Mjolnir";
pub const TITLE = "Vulkan Zig";
pub const REQUIRED_EXTENSIONS = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
    vk.extensions.khr_dynamic_rendering.name,
};
pub const ENABLE_VALIDATION_LAYERS = true;
pub const VALIDATION_LAYERS = if (ENABLE_VALIDATION_LAYERS) [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
} else [_][*:0]const u8{};
pub const ACTIVE_MATERIAL_COUNT = 1; // normally we would want around 1000
pub const MAX_SAMPLER_PER_MATERIAL = 3; // albedo, roughness, metalic
pub const MAX_SAMPLER_COUNT = ACTIVE_MATERIAL_COUNT * MAX_SAMPLER_PER_MATERIAL;
pub const SCENE_UNIFORM_COUNT = 3; // view, proj, time
pub const MAX_FRAMES_IN_FLIGHT = 2;

pub const SwapchainSupport = struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,
    allocator: Allocator,

    pub fn init(allocator: Allocator) SwapchainSupport {
        return .{
            .capabilities = undefined,
            .formats = &[_]vk.SurfaceFormatKHR{},
            .present_modes = &[_]vk.PresentModeKHR{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SwapchainSupport) void {
        self.allocator.free(self.formats);
        self.allocator.free(self.present_modes);
    }
};

pub const QueueFamilyIndices = struct {
    graphics_family: u32,
    present_family: u32,
};

pub const VulkanContext = struct {
    window: *glfw.Window,
    vkb: BaseDispatch,
    vki: Instance,
    vkd: Device,
    instance: vk.Instance,
    device: vk.Device,
    surface: vk.SurfaceKHR,
    surface_capabilities: vk.SurfaceCapabilitiesKHR,
    surface_formats: []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,
    debug_messenger: if (ENABLE_VALIDATION_LAYERS) vk.DebugUtilsMessengerEXT else void,
    physical_device: vk.PhysicalDevice,
    graphics_family: u32,
    graphics_queue: vk.Queue,
    present_family: u32,
    present_queue: vk.Queue,
    descriptor_pool: vk.DescriptorPool,
    command_pool: vk.CommandPool,
    allocator: Allocator,

    pub fn init(self: *VulkanContext, window: *glfw.Window, allocator: Allocator) !void {
        self.window = window;
        self.allocator = allocator;
        try self.initVulkanInstance();
        try self.initWindowSurface();
        try self.initPhysicalDevice();
        try self.initLogicalDevice();
        try self.initCommandPool();
        try self.initDescriptorPool();
    }

    pub fn deinit(self: *VulkanContext) void {
        self.vkd.destroyDescriptorPool(self.descriptor_pool, null);
        self.vkd.destroyCommandPool(self.command_pool, null);
        self.vkd.destroyDevice(null);
        self.vki.destroySurfaceKHR(self.surface, null);
        if (ENABLE_VALIDATION_LAYERS) {
            self.vki.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        }
        self.vki.destroyInstance(null);
        self.allocator.free(self.surface_formats);
        self.allocator.free(self.present_modes);
        self.allocator.destroy(self.vki.wrapper);
        self.allocator.destroy(self.vkd.wrapper);
    }

    fn initVulkanInstance(self: *VulkanContext) !void {
        // Get required extensions from GLFW
        self.vkb = try BaseDispatch.load(glfw_vk.getInstanceProcAddress);
        const glfw_exts = try glfw.getRequiredInstanceExtensions();
        var extensions: [][*:0]const u8 = undefined;
        if (builtin.target.os.tag == .macos) {
            extensions = try self.allocator.alloc([*:0]const u8, glfw_exts.len + 1);
            @memcpy(extensions[0..glfw_exts.len], glfw_exts[0..glfw_exts.len]);
            extensions[glfw_exts.len] = vk.extensions.khr_portability_enumeration.name;
        } else {
            extensions = try self.allocator.alloc([*:0]const u8, glfw_exts.len);
            @memcpy(extensions[0..glfw_exts.len], glfw_exts[0..glfw_exts.len]);
        }
        defer self.allocator.free(extensions);
        std.debug.print("Number of extensions: {}\n", .{extensions.len});
        for (extensions) |e| {
            std.debug.print("Extension: {s}\n", .{e});
        }
        const app_info = vk.ApplicationInfo{
            .p_application_name = TITLE,
            .application_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .p_engine_name = ENGINE_NAME,
            .engine_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_2),
        };
        var create_info = vk.InstanceCreateInfo{
            .p_application_info = &app_info,
            .enabled_extension_count = @intCast(extensions.len),
            .pp_enabled_extension_names = @ptrCast(extensions),
        };
        if (builtin.target.os.tag == .macos) {
            create_info.flags.enumerate_portability_bit_khr = true;
        }
        // Add validation layers if enabled
        var debug_create_info: vk.DebugUtilsMessengerCreateInfoEXT = undefined;
        if (ENABLE_VALIDATION_LAYERS) {
            create_info.enabled_layer_count = VALIDATION_LAYERS.len;
            create_info.pp_enabled_layer_names = &VALIDATION_LAYERS;
            // Add debug extension
            extensions = try self.allocator.realloc(extensions, extensions.len + 1);
            extensions[extensions.len - 1] = vk.extensions.ext_debug_utils.name;
            create_info.enabled_extension_count = @intCast(extensions.len);
            create_info.pp_enabled_extension_names = extensions.ptr;
            debug_create_info = vk.DebugUtilsMessengerCreateInfoEXT{
                .message_severity = vk.DebugUtilsMessageSeverityFlagsEXT{
                    .error_bit_ext = true,
                    .warning_bit_ext = true,
                    .info_bit_ext = true,
                },
                .message_type = vk.DebugUtilsMessageTypeFlagsEXT{
                    .general_bit_ext = true,
                    .validation_bit_ext = true,
                    .performance_bit_ext = true,
                    .device_address_binding_bit_ext = true,
                },
                .pfn_user_callback = debugCallback,
                .p_user_data = null,
            };
            create_info.p_next = &debug_create_info;
        }
        const instance = try self.vkb.createInstance(&create_info, null);
        const instance_dispatch = try self.allocator.create(InstanceDispatch);
        errdefer self.allocator.destroy(instance_dispatch);
        instance_dispatch.* = try InstanceDispatch.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr);
        self.vki = Instance.init(instance, instance_dispatch);
        errdefer self.vki.destroyInstance(null);
        std.debug.print("Instance created {x}\n", .{instance});
        // Create debug messenger if validation is enabled
        if (ENABLE_VALIDATION_LAYERS) {
            self.debug_messenger = try self.vki.createDebugUtilsMessengerEXT(&debug_create_info, null);
        }
    }

    fn initWindowSurface(self: *VulkanContext) !void {
        std.debug.print("Initializing window surface with instance {x}\n", .{self.vki.handle});
        if (glfw_vk.createWindowSurface(self.vki.handle, self.window, null, &self.surface) != .success) {
            return error.SurfaceCreationFailed;
        }
    }

    pub fn querySwapchainSupport(self: *VulkanContext, device: vk.PhysicalDevice) !SwapchainSupport {
        var support = SwapchainSupport.init(self.allocator);
        support.capabilities = try self.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(device, self.surface);
        self.allocator.free(support.formats);
        support.formats = try self.vki.getPhysicalDeviceSurfaceFormatsAllocKHR(device, self.surface, self.allocator);
        self.allocator.free(support.present_modes);
        support.present_modes = try self.vki.getPhysicalDeviceSurfacePresentModesAllocKHR(device, self.surface, self.allocator);
        return support;
    }

    fn scorePhysicalDevice(self: *VulkanContext, device: vk.PhysicalDevice) !u32 {
        var score: u32 = 0;
        const props = self.vki.getPhysicalDeviceProperties(device);
        const features = self.vki.getPhysicalDeviceFeatures(device);
        const device_name = std.mem.sliceTo(&props.device_name, 0);
        std.debug.print("Scoring device {s}\n", .{device_name});
        defer std.debug.print("Device {s} scored {d}\n", .{ device_name, score });
        if (@import("builtin").target.os.tag != .macos) {
            if (features.geometry_shader == vk.FALSE) {
                return 0;
            }
        }
        const extensions = try self.vki.enumerateDeviceExtensionPropertiesAlloc(device, null, self.allocator);
        defer self.allocator.free(extensions);
        ext_loop: for (REQUIRED_EXTENSIONS) |required| {
            const required_name = std.mem.span(required);
            for (extensions) |ext| {
                const ext_name = std.mem.sliceTo(&ext.extension_name, 0);
                if (std.mem.eql(u8, ext_name, required_name)) {
                    continue :ext_loop;
                }
            }
            // Extension not found
            std.debug.print("Extension {s} not found in {s}\n", .{ required, device_name });
            return 0;
        }
        var support = try self.querySwapchainSupport(device);
        defer support.deinit();
        if (support.formats.len == 0 or support.present_modes.len == 0) {
            return 0;
        }
        _ = try self.findQueueFamilies(device);
        switch (props.device_type) {
            .discrete_gpu => score += 400_000,
            .integrated_gpu => score += 300_000,
            .virtual_gpu => score += 200_000,
            .cpu, .other => score += 100_000,
            _ => {},
        }
        score += props.limits.max_image_dimension_2d;
        return score;
    }

    fn initPhysicalDevice(self: *VulkanContext) !void {
        // Get physical devices
        const devices = try self.vki.enumeratePhysicalDevicesAlloc(self.allocator);
        defer self.allocator.free(devices);
        self.physical_device = devices[0];
        var best_score: u32 = 0;
        for (devices) |device| {
            const score = try self.scorePhysicalDevice(device);
            std.debug.print("Device {any} score: {d}\n", .{ device, score });
            if (score > best_score) {
                self.physical_device = device;
                best_score = score;
            }
        }

        std.debug.print("Selected physical device: {any} with score {d}\n", .{ self.physical_device, best_score });
    }

    pub fn findQueueFamilies(self: *VulkanContext, physical_device: vk.PhysicalDevice) !QueueFamilyIndices {
        const queue_families = try self.vki.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, self.allocator);
        defer self.allocator.free(queue_families);
        var graphics_family: ?u32 = null;
        var present_family: ?u32 = null;
        for (queue_families, 0..) |family, i| {
            const index = @as(u32, @intCast(i));
            if (family.queue_flags.graphics_bit) {
                graphics_family = index;
                std.debug.print("Queue family {d} supports graphics\n", .{index});
            }
            const present_support = try self.vki.getPhysicalDeviceSurfaceSupportKHR(physical_device, index, self.surface);
            if (present_support == vk.TRUE) {
                present_family = index;
                std.debug.print("Queue family {d} supports present\n", .{index});
            }
            if (graphics_family != null and present_family != null) {
                break;
            }
        }
        if (graphics_family == null or present_family == null) {
            return error.NoSuitableQueueFamily;
        }
        return QueueFamilyIndices{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
    }

    fn initLogicalDevice(self: *VulkanContext) !void {
        const indices = try self.findQueueFamilies(self.physical_device);
        self.graphics_family = indices.graphics_family;
        self.present_family = indices.present_family;
        const support = try self.querySwapchainSupport(self.physical_device);
        self.surface_capabilities = support.capabilities;
        self.surface_formats = support.formats;
        self.present_modes = support.present_modes;
        var queue_create_infos: [2]vk.DeviceQueueCreateInfo = undefined;
        // const queue_indices = [_]u32{ indices.graphics_family, indices.present_family };
        var unique_queue_count: u32 = 1;
        const queue_priority = &[_]f32{1.0};
        queue_create_infos[0] = vk.DeviceQueueCreateInfo{
            .queue_family_index = indices.graphics_family,
            .queue_count = queue_priority.len,
            .p_queue_priorities = queue_priority,
        };
        if (indices.graphics_family != indices.present_family) {
            queue_create_infos[1] = vk.DeviceQueueCreateInfo{
                .queue_family_index = indices.present_family,
                .queue_count = queue_priority.len,
                .p_queue_priorities = queue_priority,
            };
            unique_queue_count += 1;
        }

        // Enable dynamic rendering
        const dynamic_rendering_feature = vk.PhysicalDeviceDynamicRenderingFeaturesKHR{
            .dynamic_rendering = vk.TRUE,
        };
        const layers = if (ENABLE_VALIDATION_LAYERS) VALIDATION_LAYERS else [_][*:0]const u8{};
        var device_create_info = vk.DeviceCreateInfo{
            .queue_create_info_count = unique_queue_count,
            .p_queue_create_infos = &queue_create_infos,
            .enabled_extension_count = REQUIRED_EXTENSIONS.len,
            .pp_enabled_extension_names = &REQUIRED_EXTENSIONS,
            .enabled_layer_count = layers.len,
            .pp_enabled_layer_names = &layers,
            .p_next = &dynamic_rendering_feature,
        };
        const device = try self.vki.createDevice(self.physical_device, &device_create_info, null);
        const device_dispatch = try self.allocator.create(DeviceDispatch);
        errdefer self.allocator.destroy(device_dispatch);
        device_dispatch.* = try DeviceDispatch.load(device, self.vki.wrapper.dispatch.vkGetDeviceProcAddr);
        self.vkd = Device.init(device, device_dispatch);
        self.graphics_queue = self.vkd.getDeviceQueue(self.graphics_family, 0);
        self.present_queue = self.vkd.getDeviceQueue(self.present_family, 0);
    }

    fn initDescriptorPool(self: *VulkanContext) !void {
        const sampler_size = vk.DescriptorPoolSize{
            .type = .combined_image_sampler,
            .descriptor_count = MAX_SAMPLER_COUNT,
        };
        const uniform_size = vk.DescriptorPoolSize{
            .type = .uniform_buffer,
            .descriptor_count = MAX_FRAMES_IN_FLIGHT * SCENE_UNIFORM_COUNT,
        };
        const pool_sizes = [_]vk.DescriptorPoolSize{ sampler_size, uniform_size };
        const pool_info = vk.DescriptorPoolCreateInfo{
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
            .max_sets = MAX_FRAMES_IN_FLIGHT + ACTIVE_MATERIAL_COUNT,
        };
        self.descriptor_pool = try self.vkd.createDescriptorPool(&pool_info, null);
    }

    fn initCommandPool(self: *VulkanContext) !void {
        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.graphics_family,
        };
        self.command_pool = try self.vkd.createCommandPool(&pool_info, null);
    }

    pub fn createShaderModule(self: *VulkanContext, code: []align(@alignOf(u32)) const u8) !vk.ShaderModule {
        const create_info = vk.ShaderModuleCreateInfo{
            .code_size = code.len,
            .p_code = @ptrCast(code.ptr),
        };
        return try self.vkd.createShaderModule(&create_info, null);
    }

    pub fn beginSingleTimeCommand(self: *VulkanContext) !vk.CommandBuffer {
        var cmd_buffer: vk.CommandBuffer = undefined;
        const alloc_info = vk.CommandBufferAllocateInfo{
            .level = .primary,
            .command_pool = self.command_pool,
            .command_buffer_count = 1,
        };
        try self.vkd.allocateCommandBuffers(&alloc_info, @ptrCast(&cmd_buffer));
        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        };
        try self.vkd.beginCommandBuffer(cmd_buffer, &begin_info);
        return cmd_buffer;
    }

    pub fn endSingleTimeCommand(self: *VulkanContext, cmd_buffer: vk.CommandBuffer) !void {
        defer self.vkd.freeCommandBuffers(self.command_pool, 1, @ptrCast(&cmd_buffer));
        try self.vkd.endCommandBuffer(cmd_buffer);
        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmd_buffer),
        };
        try self.vkd.queueSubmit(self.graphics_queue, 1, @ptrCast(&submit_info), .null_handle);
        try self.vkd.queueWaitIdle(self.graphics_queue);
    }

    pub fn mallocImageBuffer(self: *VulkanContext, format: vk.Format, width: u32, height: u32) !ImageBuffer {
        const create_info = vk.ImageCreateInfo{
            .image_type = .@"2d",
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .format = format,
            .tiling = .optimal,
            .initial_layout = .undefined,
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
            .sharing_mode = .exclusive,
            .samples = .{ .@"1_bit" = true },
        };
        var result: ImageBuffer = .{
            .image = try self.vkd.createImage(&create_info, null),
            .memory = undefined,
            .width = width,
            .height = height,
            .format = format,
            .view = undefined,
        };
        const mem_requirements = self.vkd.getImageMemoryRequirements(result.image);
        result.memory = try self.allocateMemory(mem_requirements, .{});
        try self.vkd.bindImageMemory(result.image, result.memory, 0);
        return result;
    }

    pub fn mallocLocalBuffer(self: *VulkanContext, size: usize, usage: vk.BufferUsageFlags) !DataBuffer {
        const create_info = vk.BufferCreateInfo{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        };
        var result = DataBuffer{
            .buffer = try self.vkd.createBuffer(&create_info, null),
            .memory = undefined,
            .mapped = null,
            .size = size,
        };
        const mem_requirements = self.vkd.getBufferMemoryRequirements(result.buffer);
        result.memory = try self.allocateMemory(mem_requirements, .{});
        try self.vkd.bindBufferMemory(result.buffer, result.memory, 0);
        return result;
    }

    pub fn mallocHostVisibleBuffer(self: *VulkanContext, size: usize, usage: vk.BufferUsageFlags) !DataBuffer {
        const create_info = vk.BufferCreateInfo{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        };
        var result = DataBuffer{
            .buffer = try self.vkd.createBuffer(&create_info, null),
            .memory = undefined,
            .mapped = null,
            .size = size,
        };
        const mem_requirements = self.vkd.getBufferMemoryRequirements(result.buffer);
        result.memory = try self.allocateMemory(mem_requirements, .{ .host_visible_bit = true, .host_coherent_bit = true });
        try self.vkd.bindBufferMemory(result.buffer, result.memory, 0);
        result.mapped = try self.vkd.mapMemory(result.memory, 0, size, .{});
        return result;
    }

    pub fn createLocalBuffer(self: *VulkanContext, data: []const u8, usage: vk.BufferUsageFlags) !DataBuffer {
        std.debug.print("Creating local buffer size {d}\n", .{data.len});
        var staging = try self.createHostVisibleBuffer(data, .{ .transfer_src_bit = true });
        defer staging.deinit(self);
        var result = try self.mallocLocalBuffer(
            data.len,
            usage.merge(.{ .transfer_dst_bit = true }),
        );
        try self.copyBuffer(&result, &staging);
        return result;
    }

    pub fn createHostVisibleBuffer(self: *VulkanContext, data: []const u8, usage: vk.BufferUsageFlags) !DataBuffer {
        var buffer = try self.mallocHostVisibleBuffer(data.len, usage);
        buffer.write(data);
        return buffer;
    }

    pub fn createImageBuffer(self: *VulkanContext, data: []const u8, format: vk.Format, width: u32, height: u32) !ImageBuffer {
        var staging = try self.createHostVisibleBuffer(data, .{ .transfer_src_bit = true });
        defer staging.deinit(self);
        var result = try self.mallocImageBuffer(format, width, height);
        try self.copyImage(&result, &staging);
        const color_aspect = vk.ImageAspectFlags{ .color_bit = true };
        result.view = try data_buffer.createImageView(self, result.image, format, color_aspect);
        return result;
    }

    pub fn copyBuffer(self: *VulkanContext, dst: *DataBuffer, src: *DataBuffer) !void {
        const cmd_buffer = try self.beginSingleTimeCommand();
        const copy_region = vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = 0,
            .size = src.size,
        };
        self.vkd.cmdCopyBuffer(cmd_buffer, src.buffer, dst.buffer, 1, @ptrCast(&copy_region));
        try self.endSingleTimeCommand(cmd_buffer);
    }

    pub fn copyImage(self: *VulkanContext, dst: *ImageBuffer, src: *DataBuffer) !void {
        try self.transitionImageLayout(dst.image, dst.format, .undefined, .transfer_dst_optimal);
        const cmd_buffer = try self.beginSingleTimeCommand();
        const copy_region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{
                .width = dst.width,
                .height = dst.height,
                .depth = 1,
            },
        };
        self.vkd.cmdCopyBufferToImage(cmd_buffer, src.buffer, dst.image, .transfer_dst_optimal, 1, @ptrCast(&copy_region));
        try self.endSingleTimeCommand(cmd_buffer);
        try self.transitionImageLayout(dst.image, dst.format, .transfer_dst_optimal, .shader_read_only_optimal);
    }

    pub fn findMemoryType(self: *VulkanContext, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
        const mem_properties = self.vki.getPhysicalDeviceMemoryProperties(self.physical_device);
        for (0..mem_properties.memory_type_count) |i| {
            const type_match = (type_filter & (@as(u32, 1) << @intCast(i))) != 0;
            const property_match = mem_properties.memory_types[i].property_flags.contains(properties);
            if (type_match and property_match) {
                return @intCast(i);
            }
        }
        return error.NoSuitableMemoryType;
    }

    pub fn allocateMemory(self: *VulkanContext, requirements: vk.MemoryRequirements, properties: vk.MemoryPropertyFlags) !vk.DeviceMemory {
        const alloc_info = vk.MemoryAllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryType(requirements.memory_type_bits, properties),
        };
        return try self.vkd.allocateMemory(&alloc_info, null);
    }

    pub fn transitionImageLayout(self: *VulkanContext, image: vk.Image, format: vk.Format, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) !void {
        const cmd_buffer = try self.beginSingleTimeCommand();
        std.debug.print("Transitioning image layout from {d} to {d} format {d}\n", .{ old_layout, new_layout, format });
        var src_stage: vk.PipelineStageFlags = undefined;
        var dst_stage: vk.PipelineStageFlags = undefined;
        var barrier = vk.ImageMemoryBarrier{
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_access_mask = .{},
            .dst_access_mask = .{},
        };
        if (old_layout == .undefined and new_layout == .transfer_dst_optimal) {
            barrier.src_access_mask = .{};
            barrier.dst_access_mask = .{ .transfer_write_bit = true };
            src_stage = .{ .top_of_pipe_bit = true };
            dst_stage = .{ .transfer_bit = true };
        } else if (old_layout == .transfer_dst_optimal and new_layout == .shader_read_only_optimal) {
            barrier.src_access_mask = .{ .transfer_write_bit = true };
            barrier.dst_access_mask = .{ .shader_read_bit = true };
            src_stage = .{ .transfer_bit = true };
            dst_stage = .{ .fragment_shader_bit = true };
        }
        self.vkd.cmdPipelineBarrier(
            cmd_buffer,
            src_stage,
            dst_stage,
            .{},
            0,
            undefined,
            0,
            undefined,
            1,
            @ptrCast(&barrier),
        );
        try self.endSingleTimeCommand(cmd_buffer);
    }

    pub fn createDepthImage(self: *VulkanContext, format: vk.Format, width: u32, height: u32) !ImageBuffer {
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
            .image = try self.vkd.createImage(&create_info, null),
            .memory = undefined,
            .width = width,
            .height = height,
            .format = format,
            .view = undefined,
        };
        const mem_requirements = self.vkd.getImageMemoryRequirements(result.image);
        result.memory = try self.allocateMemory(mem_requirements, .{});
        try self.vkd.bindImageMemory(result.image, result.memory, 0);
        // Transition image layout for depth attachment
        const cmd_buffer = try self.beginSingleTimeCommand();
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
        self.vkd.cmdPipelineBarrier(
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
        try self.endSingleTimeCommand(cmd_buffer);
        result.view = try data_buffer.createImageView(self, result.image, format, .{ .depth_bit = true });
        return result;
    }
};

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_type: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(.C) vk.Bool32 {
    _ = message_severity;
    _ = message_type;
    _ = p_user_data;
    if (p_callback_data) |callback_data| {
        if (callback_data.p_message) |message| {
            std.debug.print("Debug message: {s}\n", .{message});
        }
    }
    return vk.FALSE;
}
