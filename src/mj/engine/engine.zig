const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("zglfw");
const zm = @import("zmath");
const zstbi = @import("zstbi");

const Allocator = std.mem.Allocator;
const Time = std.time.Instant;
const ArrayList = std.ArrayList;

const VulkanContext = @import("context.zig").VulkanContext;
const Renderer = @import("renderer.zig").Renderer;
const ResourceManager = @import("resource.zig").ResourceManager;
const Scene = @import("scene.zig").Scene;
const Handle = @import("resource.zig").Handle;
const Node = @import("../scene/node.zig").Node;
const NodeType = @import("../scene/node.zig").NodeType;
const AnimationStatus = @import("../geometry/animation.zig").AnimationStatus;
const AnimationPlayMode = @import("../geometry/animation.zig").AnimationPlayMode;
const SceneUniform = @import("renderer.zig").SceneUniform;
const SkeletalMesh = @import("../geometry/skeletal_mesh.zig").SkeletalMesh;
const Texture = @import("../material/texture.zig").Texture;
const QueueFamilyIndices = @import("context.zig").QueueFamilyIndices;
const SwapchainSupport = @import("context.zig").SwapchainSupport;
const buildMaterial = @import("../material/pbr.zig").buildMaterial;
const buildSkinnedMaterial = @import("../material/skinned_pbr.zig").buildSkinnedMaterial;
const buildCube = @import("../geometry/static_mesh.zig").buildCube;
const writeBuffer = @import("context.zig").writeBuffer;
const RENDER_FPS = 60.0;
const FRAME_TIME = 1.0 / RENDER_FPS;
const FRAME_TIME_NANO: u64 = @intFromFloat(FRAME_TIME * 1_000_000_000.0);
const UPDATE_FPS = 24.0;
const UPDATE_FRAME_TIME = 1.0 / UPDATE_FPS;
const UPDATE_FRAME_TIME_NANO: u64 = @intFromFloat(UPDATE_FRAME_TIME * 1_000_000_000.0);

pub const Engine = struct {
    window: *glfw.Window,
    context: VulkanContext,
    renderer: Renderer,
    resource: ResourceManager,
    scene: Scene,
    last_frame_timestamp: Time,
    last_update_timestamp: Time,
    start_timestamp: Time,
    allocator: Allocator,

    pub fn init(self: *Engine, allocator: Allocator, width: u32, height: u32, title: [:0]const u8) !void {
        self.allocator = allocator;
        _ = glfw.setErrorCallback(glfwErrorCallback);
        try glfw.init();
        if (!glfw.isVulkanSupported()) {
            return error.NoVulkan;
        }
        glfw.windowHint(.client_api, .no_api);
        self.window = try glfw.createWindow(
            @intCast(width),
            @intCast(height),
            title,
            null,
        );
        std.debug.print("Window created {*}\n", .{self.window});
        self.start_timestamp = try Time.now();
        self.last_frame_timestamp = try Time.now();
        self.last_update_timestamp = try Time.now();
        try self.context.init(self.window, allocator);
        self.resource = ResourceManager.init(allocator);
        try self.buildScene();
        try self.buildRenderer();
        if (self.renderer.extent.width > 0 and self.renderer.extent.height > 0) {
            const w: f32 = @floatFromInt(self.renderer.extent.width);
            const h: f32 = @floatFromInt(self.renderer.extent.height);
            self.scene.camera.projection.perspective.aspect_ratio = w / h;
        }
        zstbi.init(allocator);
        std.debug.print("Engine initialized\n", .{});
    }

    fn buildScene(self: *Engine) !void {
        try self.scene.init(&self.context);
        self.scene.root = self.resource.initNode();
    }

    fn buildRenderer(self: *Engine) !void {
        const indices = try self.context.findQueueFamilies(self.context.physical_device);
        var support = try self.context.querySwapchainSupport(self.context.physical_device);
        defer support.deinit();
        self.renderer = Renderer.init(self.allocator);
        try self.renderer.buildSwapchain(&self.context, support.capabilities, support.formats, support.present_modes, indices.graphics_family, indices.present_family);
        try self.renderer.buildCommandBuffers(&self.context);
        try self.renderer.buildSynchronizers(&self.context);
        self.renderer.depth_buffer = try self.context.createDepthImage(.d32_sfloat, self.renderer.extent.width, self.renderer.extent.height);
        for (&self.renderer.frames, 0..) |*frame, i| {
            frame.uniform = try self.context.mallocHostVisibleBuffer(@sizeOf(SceneUniform), .{ .uniform_buffer_bit = true });
            const alloc_info = vk.DescriptorSetAllocateInfo{
                .descriptor_pool = self.context.descriptor_pool,
                .descriptor_set_count = 1,
                .p_set_layouts = @ptrCast(&self.scene.descriptor_set_layout),
            };
            std.debug.print("Creating descriptor set for frame {d} with pool {x} and set layout {x}\n", .{ i, self.context.descriptor_pool, self.scene.descriptor_set_layout });
            try self.context.vkd.allocateDescriptorSets(&alloc_info, @ptrCast(&frame.descriptor_set));
            std.debug.print("Created descriptor set\n", .{});
            const buffer_info = vk.DescriptorBufferInfo{
                .buffer = frame.uniform.buffer,
                .offset = 0,
                .range = @sizeOf(SceneUniform),
            };
            const write = vk.WriteDescriptorSet{
                .dst_set = frame.descriptor_set,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .p_buffer_info = @ptrCast(&buffer_info),
                .p_image_info = undefined,
                .p_texel_buffer_view = undefined,
            };
            self.context.vkd.updateDescriptorSets(1, @ptrCast(&write), 0, undefined);
        }
    }

    pub fn pushSceneUniform(self: *Engine) void {
        const now = Time.now() catch return;
        const elapsed_seconds = @as(f64, @floatFromInt(now.since(self.start_timestamp))) / 1000_000_000.0;
        std.debug.print("elapsed seconds = {}\n", .{elapsed_seconds});
        const data = SceneUniform {
            .view = self.scene.viewMatrix(),
            .projection = self.scene.projectionMatrix(),
            .time = @floatCast(elapsed_seconds),
        };
        writeBuffer(self.renderer.getUniform(), std.mem.asBytes(&data));
    }

    pub fn tryRender(self: *Engine) !void {
        const image_idx = try self.renderer.begin(&self.context);
        self.pushSceneUniform();
        const command_buffer = self.renderer.getCommandBuffer();
        var node_stack = ArrayList(Handle).init(self.allocator);
        defer node_stack.deinit();
        var transform_stack = ArrayList(zm.Mat).init(self.allocator);
        defer transform_stack.deinit();
        if (self.resource.getNode(self.scene.root)) |root_node| {
            for (root_node.children.items) |child| {
                try node_stack.append(child);
                try transform_stack.append(zm.identity());
            }
        }
        // Process nodes depth-first
        while (node_stack.items.len > 0) {
            const handle = node_stack.pop() orelse break;
            const node = self.resource.getNode(handle) orelse continue;
            const local_matrix = node.transform.toMatrix();
            const world_matrix = zm.mul(local_matrix, transform_stack.pop() orelse zm.identity());
            switch (node.data) {
                .light => |*light| {
                    //std.debug.print("light {}", {.light});
                    _ = light;
                },
                .skeletal_mesh => |*skeletal_mesh| {
                    if (self.resource.getSkeletalMesh(skeletal_mesh.handle)) |mesh| {
                        if (self.resource.getSkinnedMaterial(mesh.material)) |material| {
                            if (mesh.bone_buffer.mapped) |mapped| {
                                const bones: [*]zm.Mat = @ptrCast(@alignCast(mapped));
                                for (mesh.bones, 0..) |bone_handle, i| {
                                    if (self.resource.getNode(bone_handle)) |bone_node| {
                                        bones[i] = bone_node.transform.toMatrix();
                                    }
                                }
                            }
                            material.updateBoneBuffer(&self.context, mesh.bone_buffer.buffer, mesh.bone_buffer.size);
                            // Bind pipeline and descriptors
                            self.context.vkd.cmdBindPipeline(command_buffer, .graphics, material.pipeline);
                            const descriptor_sets = [_]vk.DescriptorSet{
                                self.renderer.getDescriptorSet(),
                                material.descriptor_set,
                            };
                            self.context.vkd.cmdBindDescriptorSets(command_buffer, .graphics, material.pipeline_layout, 0, descriptor_sets.len, &descriptor_sets, 0, undefined);
                            // Push world matrix as a constant
                            self.context.vkd.cmdPushConstants(command_buffer, material.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(zm.Mat), &world_matrix);
                            const offset: vk.DeviceSize = 0;
                            self.context.vkd.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast(&mesh.vertex_buffer.buffer), @ptrCast(&offset));
                            self.context.vkd.cmdBindIndexBuffer(command_buffer, mesh.index_buffer.buffer, 0, .uint32);
                            self.context.vkd.cmdDrawIndexed(command_buffer, mesh.indices_len, 1, 0, 0, 0);
                        }
                    }
                },
                .static_mesh => |*mesh_handle| {
                    if (self.resource.getMesh(mesh_handle.*)) |mesh| {
                        if (self.resource.getMaterial(mesh.material)) |material| {
                            self.context.vkd.cmdBindPipeline(command_buffer, .graphics, material.pipeline);
                            const descriptor_sets = [_]vk.DescriptorSet{
                                self.renderer.getDescriptorSet(),
                                material.descriptor_set,
                            };
                            self.context.vkd.cmdBindDescriptorSets(command_buffer, .graphics, material.pipeline_layout, 0, descriptor_sets.len, &descriptor_sets, 0, undefined);
                            self.context.vkd.cmdPushConstants(command_buffer, material.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(zm.Mat), &world_matrix);
                            const offset: vk.DeviceSize = 0;
                            self.context.vkd.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast(&mesh.vertex_buffer.buffer), @ptrCast(&offset));
                            self.context.vkd.cmdBindIndexBuffer(command_buffer, mesh.index_buffer.buffer, 0, .uint32);
                            self.context.vkd.cmdDrawIndexed(command_buffer, mesh.indices_len, 1, 0, 0, 0);
                        }
                    }
                },
                .none => {},
            }
            for (node.children.items) |child| {
                if (child.index == self.scene.root.index) {
                    std.debug.print("A node can't have root node as a child {d} {d}\n", .{ handle.index, handle.generation });
                    continue;
                }
                try node_stack.append(child);
                try transform_stack.append(world_matrix);
            }
        }
        try self.renderer.end(&self.context, image_idx);
    }

    pub fn render(self: *Engine) void {
        const now = Time.now() catch return;
        if (now.since(self.last_frame_timestamp) < FRAME_TIME_NANO) {
            return;
        }
        self.tryRender() catch |err| {
            if (err == error.OutOfDateKHR or err == error.SuboptimalKHR) {
                // Recreate swapchain if outdated
                self.recreateSwapchain() catch |recreate_err| {
                    std.debug.print("Something went wrong while recreating swapchain: {any}\n", .{recreate_err});
                };
            } else {
                std.debug.print("Something went wrong while rendering: {any}\n", .{err});
            }
        };
        self.last_frame_timestamp = now;
    }

    pub fn recreateSwapchain(self: *Engine) !void {
        var support = try self.context.querySwapchainSupport(self.context.physical_device);
        defer support.deinit();
        const indices = try self.context.findQueueFamilies(self.context.physical_device);
        try self.context.vkd.deviceWaitIdle();
        self.renderer.destroySwapchain(&self.context);
        try self.renderer.buildSwapchain(&self.context, support.capabilities, support.formats, support.present_modes, indices.graphics_family, indices.present_family);
    }

    pub fn getDeltaTime(self: *Engine) f32 {
        const now = Time.now() catch return 0.0;
        return @floatCast(@as(f64, @floatFromInt(now.since(self.last_update_timestamp))) / 1000_000_000.0);
    }

    pub fn getTime(self: *Engine) f32 {
        const now = Time.now() catch return 0.0;
        return @floatCast(@as(f64, @floatFromInt(now.since(self.start_timestamp))) / 1000_000_000.0);
    }

    pub fn shouldClose(self: *Engine) bool {
        return glfw.windowShouldClose(self.window);
    }

    pub fn update(self: *Engine) bool {
        glfw.pollEvents();
        const delta_time = self.getDeltaTime();
        if (delta_time < UPDATE_FRAME_TIME) {
            return false;
        }
        for (self.resource.nodes.entries.items) |*entry| {
            if (!entry.active) continue;
            const node = &entry.item;
            switch (node.data) {
                .skeletal_mesh => |*skeletal_mesh| {
                    if (skeletal_mesh.animation.status != AnimationStatus.playing) continue;
                    const anim = &skeletal_mesh.animation;
                    anim.*.time += delta_time;
                    const mesh = self.resource.getSkeletalMesh(skeletal_mesh.handle) orelse continue;
                    const track = mesh.animations.getPtr(anim.name) orelse continue;

                    switch (anim.mode) {
                        .loop => {
                            anim.time = std.math.mod(f32, anim.time, track.duration) catch 0.0;
                        },
                        .once => {
                            if (anim.time >= track.duration) {
                                anim.time = track.duration;
                                anim.status = AnimationStatus.stopped;
                            }
                        },
                        .pingpong => {
                            // Handle playing in reverse (not implemented in original)
                        },
                    }
                    track.update(anim.time, &self.resource.nodes, mesh.bones);
                },
                else => {},
            }
        }
        self.last_update_timestamp = Time.now() catch return true;
        return true;
    }

    pub fn deinit(self: *Engine) !void {
        try self.context.vkd.deviceWaitIdle();
        self.resource.deinit(&self.context);
        self.renderer.deinit(&self.context);
        self.scene.deinit(&self.context);
        self.context.deinit();
        glfw.destroyWindow(self.window);
        glfw.terminate();
    }

    pub fn getNode(self: *Engine, handle: Handle) ?*Node {
        return self.resource.getNode(handle);
    }

    pub fn parentNode(self: *Engine, parent: Handle, child: Handle) void {
        self.resource.parentNode(parent, child);
    }

    pub fn addToRoot(self: *Engine, node: Handle) void {
        self.parentNode(self.scene.root, node);
    }

    pub fn buildSkeletalMesh(
        self: *Engine,
        mesh: *SkeletalMesh,
        vertices: []const SkeletalMesh.Vertex,
        indices: []const u32,
        bones: []const Handle,
        material: Handle,
    ) !void {
        mesh.material = material;
        mesh.vertices = try self.allocator.dupe(SkeletalMesh.Vertex, vertices);
        mesh.indices = try self.allocator.dupe(u32, indices);
        mesh.bones = try self.allocator.dupe(Handle, bones);
        mesh.animations = std.StringHashMap(SkeletalMesh.AnimationTrack).init(self.allocator);
        mesh.vertex_buffer = try self.context.createLocalBuffer(std.mem.sliceAsBytes(mesh.vertices), .{ .vertex_buffer_bit = true });
        mesh.index_buffer = try self.context.createLocalBuffer(std.mem.sliceAsBytes(mesh.indices), .{ .index_buffer_bit = true });
        if (bones.len > 0) {
            const bone_buffer_size = bones.len * @sizeOf(zm.Mat);
            mesh.bone_buffer = try self.context.mallocHostVisibleBuffer(bone_buffer_size, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        }
    }

    pub fn createSkeletalMesh(
        self: *Engine,
        vertices: []const SkeletalMesh.Vertex,
        indices: []const u32,
        bones: []const Handle,
        material: Handle,
    ) !Handle {
        const handle = self.resource.mallocSkeletalMesh();
        const mesh = self.resource.getSkeletalMesh(handle) orelse return error.ResourceAllocationFailed;
        try self.buildSkeletalMesh(mesh, vertices, indices, bones, material);
        return handle;
    }

    /// Create a new texture from raw data
    pub fn createTexture(self: *Engine, data: []const u8) !Handle {
        // Allocate texture
        const texture_handle = self.resource.mallocTexture();
        const texture = self.resource.getTexture(texture_handle) orelse return error.ResourceAllocationFailed;
        try texture.initFromData(data);
        try self.buildTexture(texture);
        std.debug.print("Texture created {d}\n", .{texture_handle.index});
        return texture_handle;
    }

    pub fn buildTexture(self: *Engine, texture: *Texture) !void {
        texture.buffer = try self.context.createImageBuffer(
            texture.image.data,
            .r8g8b8a8_srgb,
            @intCast(texture.image.width),
            @intCast(texture.image.height),
        );
        const sampler_info = vk.SamplerCreateInfo{
            .mag_filter = .linear,
            .min_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .anisotropy_enable = vk.FALSE,
            .max_anisotropy = 1.0,
            .border_color = .int_opaque_white,
            .unnormalized_coordinates = vk.FALSE,
            .compare_enable = vk.FALSE,
            .compare_op = .always,
            .mipmap_mode = .linear,
            .mip_lod_bias = 0.0,
            .min_lod = 0.0,
            .max_lod = 0.0,
        };

        texture.sampler = try self.context.vkd.createSampler(&sampler_info, null);
    }
    /// Create a new PBR material
    pub fn createMaterial(self: *Engine) !Handle {
        const material_handle = self.resource.mallocMaterial();
        const mat = self.resource.getMaterial(material_handle) orelse return error.ResourceAllocationFailed;
        const vertex_code align(@alignOf(u32)) = @embedFile("shaders/pbr.vert.spv").*;
        const fragment_code align(@alignOf(u32)) = @embedFile("shaders/pbr.frag.spv").*;
        try mat.initDescriptorSet(&self.context);
        std.debug.print("Material descriptor set initialized\n", .{});
        try buildMaterial(mat, self, &vertex_code, &fragment_code);
        std.debug.print("Material created\n", .{});
        return material_handle;
    }
    /// Create a new skinned material
    pub fn createSkinnedMaterial(self: *Engine, max_bones: u32) !Handle {
        const material_handle = self.resource.createSkinnedMaterial();
        const mat = self.resource.getSkinnedMaterial(material_handle) orelse {
            return error.ResourceAllocationFailed;
        };
        const vertex_code align(@alignOf(u32)) = @embedFile("shaders/skinned_pbr.vert.spv").*;
        const fragment_code align(@alignOf(u32)) = @embedFile("shaders/skinned_pbr.frag.spv").*;
        mat.max_bones = max_bones;
        try mat.initDescriptorSet(self.context);
        try buildSkinnedMaterial(mat, self, &vertex_code, &fragment_code);
        return material_handle;
    }
    pub fn createCube(self: *Engine, material: Handle) !Handle {
        const ret = self.resource.mallocMesh();
        const mesh_ptr = self.resource.getMesh(ret).?;
        try buildCube(&self.context, mesh_ptr, material, .{ 0.0, 0.0, 0.0, 0.0 });
        return ret;
    }
};

fn glfwErrorCallback(error_code: c_int, description: ?[*:0]const u8) callconv(.C) void {
    std.debug.print("GLFW error({x}): {s}\n", .{ error_code, description orelse "No description provided" });
}
