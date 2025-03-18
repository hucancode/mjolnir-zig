// glfw & vulkan glue

const vk = @import("vulkan");
const glfw = @import("zglfw");

pub fn getInstanceProcAddress(
    instance: vk.Instance,
    procname: [*:0]const u8,
) vk.PfnVoidFunction {
    return glfwGetInstanceProcAddress(instance, procname);
}
extern fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;

pub fn getPhysicalDevicePresentationSupport(
    instance: vk.Instance,
    pdev: vk.PhysicalDevice,
    queuefamily: u32,
) bool {
    return glfwGetPhysicalDevicePresentationSupport(instance, pdev, queuefamily);
}
extern fn glfwGetPhysicalDevicePresentationSupport(instance: vk.Instance, pdev: vk.PhysicalDevice, queuefamily: u32) bool;

pub fn createWindowSurface(
    instance: vk.Instance,
    window: *glfw.Window,
    p_allocator: ?*const vk.AllocationCallbacks,
    p_surface: *vk.SurfaceKHR,
) vk.Result {
    return glfwCreateWindowSurface(instance, window, p_allocator, p_surface);
}
extern fn glfwCreateWindowSurface(instance: vk.Instance, window: *glfw.Window, p_allocator: ?*const vk.AllocationCallbacks, p_surface: *vk.SurfaceKHR) vk.Result;
