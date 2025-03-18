const builtin = @import("builtin");
const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("zglfw");
const glfw_vk = @import("glfw_vulkan.zig");
const Allocator = std.mem.Allocator;

const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
    vk.extensions.khr_dynamic_rendering.name,
};

const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_2,
    // vk.features.version_1_3, // MacOS MoltenVK does not support this
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.khr_dynamic_rendering,
    vk.extensions.khr_portability_enumeration,
};

const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);

const Instance = vk.InstanceProxy(apis);
const Device = vk.DeviceProxy(apis);

pub const GraphicsContext = struct {
    pub const CommandBuffer = vk.CommandBufferProxy(apis);

    allocator: Allocator,

    vkb: BaseDispatch,

    instance: Instance,
    surface: vk.SurfaceKHR,
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    dev: Device,
    graphics_queue: Queue,
    present_queue: Queue,

    pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: *glfw.Window) !GraphicsContext {
        var self: GraphicsContext = undefined;
        self.allocator = allocator;
        self.vkb = try BaseDispatch.load(glfw_vk.getInstanceProcAddress);
        const glfw_exts = try glfw.getRequiredInstanceExtensions();
        var extensions: [][*c]const u8 = undefined;
        if (builtin.target.os.tag == .macos) {
            extensions = try allocator.alloc([*c]const u8, glfw_exts.len + 1);
            @memcpy(extensions[0..glfw_exts.len], glfw_exts[0..glfw_exts.len]);
            extensions[glfw_exts.len] = vk.extensions.khr_portability_enumeration.name;
        } else {
            extensions = try allocator.alloc([*c]const u8, glfw_exts.len);
            @memcpy(extensions[0..glfw_exts.len], glfw_exts[0..glfw_exts.len]);
        }
        defer allocator.free(extensions);
        std.debug.print("Number of extensions: {}\n", .{extensions.len});
        for (extensions) |e| {
            std.debug.print("Extension: {s}\n", .{e});
        }
        const app_info = vk.ApplicationInfo{
            .p_application_name = app_name,
            .application_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .p_engine_name = app_name,
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
        const instance = try self.vkb.createInstance(&create_info, null);
        const vki = try allocator.create(InstanceDispatch);
        errdefer allocator.destroy(vki);
        vki.* = try InstanceDispatch.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr);
        self.instance = Instance.init(instance, vki);
        errdefer self.instance.destroyInstance(null);
        self.surface = try createSurface(self.instance, window);
        errdefer self.instance.destroySurfaceKHR(self.surface, null);
        const candidate = try pickPhysicalDevice(self.instance, allocator, self.surface);
        self.pdev = candidate.pdev;
        self.props = candidate.props;
        const dev = try initializeCandidate(self.instance, candidate);
        const vkd = try allocator.create(DeviceDispatch);
        errdefer allocator.destroy(vkd);
        vkd.* = try DeviceDispatch.load(dev, self.instance.wrapper.dispatch.vkGetDeviceProcAddr);
        self.dev = Device.init(dev, vkd);
        errdefer self.dev.destroyDevice(null);
        self.graphics_queue = Queue.init(self.dev, candidate.queues.graphics_family);
        self.present_queue = Queue.init(self.dev, candidate.queues.present_family);
        self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);
        return self;
    }

    pub fn deinit(self: GraphicsContext) void {
        self.dev.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);
        self.instance.destroyInstance(null);

        // Don't forget to free the tables to prevent a memory leak.
        self.allocator.destroy(self.dev.wrapper);
        self.allocator.destroy(self.instance.wrapper);
    }

    pub fn deviceName(self: *const GraphicsContext) []const u8 {
        return std.mem.sliceTo(&self.props.device_name, 0);
    }

    pub fn findMemoryTypeIndex(self: GraphicsContext, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
            if (memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
                return @truncate(i);
            }
        }

        return error.NoSuitableMemoryType;
    }

    pub fn allocate(self: GraphicsContext, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
        return try self.dev.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
        }, null);
    }
};

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(device: Device, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

fn createSurface(instance: Instance, window: *glfw.Window) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    if (glfw_vk.createWindowSurface(instance.handle, window, null, &surface) != .success) {
        return error.SurfaceInitFailed;
    }
    return surface;
}

fn initializeCandidate(instance: Instance, candidate: DeviceCandidate) !vk.Device {
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family)
        1
    else
        2;

    const dynamic_rendering_features = vk.PhysicalDeviceDynamicRenderingFeaturesKHR{
        .dynamic_rendering = vk.TRUE,
    };
    return try instance.createDevice(candidate.pdev, &.{
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
        .p_next = @ptrCast(&dynamic_rendering_features),
    }, null);
}

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

fn pickPhysicalDevice(
    instance: Instance,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !DeviceCandidate {
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(pdevs);

    for (pdevs) |pdev| {
        if (try checkSuitable(instance, pdev, allocator, surface)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevice;
}

fn checkSuitable(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !?DeviceCandidate {
    if (!try checkExtensionSupport(instance, pdev, allocator)) {
        return null;
    }

    if (!try checkSurfaceSupport(instance, pdev, surface)) {
        return null;
    }

    if (try allocateQueues(instance, pdev, allocator, surface)) |allocation| {
        const props = instance.getPhysicalDeviceProperties(pdev);
        return DeviceCandidate{
            .pdev = pdev,
            .props = props,
            .queues = allocation,
        };
    }

    return null;
}

fn allocateQueues(instance: Instance, pdev: vk.PhysicalDevice, allocator: Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(families);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == vk.TRUE) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
    }

    return null;
}

fn checkSurfaceSupport(instance: Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkExtensionSupport(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
) !bool {
    const propsv = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
    defer allocator.free(propsv);

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}
