const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("zglfw");
const zm = @import("zmath");
const zstbi = @import("zstbi");
const zcgltf = @import("zmesh").io.zcgltf;

const Allocator = std.mem.Allocator;
const Time = std.time.Instant;
const ArrayList = std.ArrayList;

const VulkanContext = @import("context.zig").VulkanContext;
const Renderer = @import("renderer.zig").Renderer;
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
const StaticMesh = @import("../geometry/static_mesh.zig").StaticMesh;
const Vertex = @import("../geometry/static_mesh.zig").Vertex;
const Material = @import("../material/pbr.zig").Material;
const SkinnedMaterial = @import("../material/skinned_pbr.zig").SkinnedMaterial;
const Light = @import("../scene/light.zig").Light;
const ResourcePool = @import("resource.zig").ResourcePool;
const LightUniform = @import("renderer.zig").LightUniform;

const buildMaterial = @import("../material/pbr.zig").buildMaterial;
const buildSkinnedMaterial = @import("../material/skinned_pbr.zig").buildSkinnedMaterial;

pub const MAX_LIGHTS = @cImport("renderer.zig").MAX_LIGHTS;
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
    scene: Scene,
    last_frame_timestamp: Time,
    last_update_timestamp: Time,
    start_timestamp: Time,
    meshes: ResourcePool(StaticMesh),
    skeletal_meshes: ResourcePool(SkeletalMesh),
    materials: ResourcePool(Material),
    skinned_materials: ResourcePool(SkinnedMaterial),
    textures: ResourcePool(Texture),
    lights: ResourcePool(Light),
    nodes: ResourcePool(Node),
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
        self.meshes = ResourcePool(StaticMesh).init(allocator);
        self.skeletal_meshes = ResourcePool(SkeletalMesh).init(allocator);
        self.materials = ResourcePool(Material).init(allocator);
        self.skinned_materials = ResourcePool(SkinnedMaterial).init(allocator);
        self.textures = ResourcePool(Texture).init(allocator);
        self.lights = ResourcePool(Light).init(allocator);
        self.nodes = ResourcePool(Node).init(allocator);
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
        self.scene.root = self.initNode();
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
        const data = SceneUniform{
            .view = self.scene.viewMatrix(),
            .projection = self.scene.projectionMatrix(),
            .time = @floatCast(elapsed_seconds),
        };
        self.renderer.getUniform().write(std.mem.asBytes(&data));
    }

    pub fn tryRender(self: *Engine) !void {
        const image_idx = try self.renderer.begin(&self.context);
        const command_buffer = self.renderer.getCommandBuffer();
        var node_stack = ArrayList(Handle).init(self.allocator);
        defer node_stack.deinit();
        var transform_stack = ArrayList(zm.Mat).init(self.allocator);
        defer transform_stack.deinit();
        if (self.nodes.get(self.scene.root)) |root_node| {
            for (root_node.children.items) |child| {
                try node_stack.append(child);
                try transform_stack.append(zm.identity());
            }
        }
        var scene_uniform = SceneUniform {
            .view = self.scene.viewMatrix(),
            .projection = self.scene.projectionMatrix(),
            .light_count = 0,
            .lights = undefined,
            .time = undefined,
        };
        if (Time.now()) |now| {
            const elapsed_seconds = @as(f64, @floatFromInt(now.since(self.start_timestamp))) / 1000_000_000.0;
            scene_uniform.time = @floatCast(elapsed_seconds);
        } else |err| {
            std.debug.print("{}", .{err});
            scene_uniform.time = 0.0;
        }
        while (node_stack.items.len > 0) {
            const handle = node_stack.pop() orelse break;
            const node = self.nodes.get(handle) orelse continue;
            const local_matrix = node.transform.toMatrix();
            const world_matrix = zm.mul(local_matrix, transform_stack.pop() orelse zm.identity());
            switch (node.data) {
                .light => |light| {
                    if (self.lights.get(light)) |light_ptr| {
                        var light_uniform = LightUniform {
                            .color = light_ptr.color,
                            .intensity = light_ptr.intensity,
                            .position = undefined,
                            .spot_light_angle = undefined,
                            .direction = undefined,
                            .type = undefined,
                        };
                        switch (light_ptr.data) {
                            .point => {
                                light_uniform.type = 0;
                                zm.store(&light_uniform.position,zm.mul(zm.f32x4s(0.0), world_matrix), 3);
                            },
                            .directional => {
                                light_uniform.type = 1;
                                zm.store(&light_uniform.direction,zm.mul(zm.f32x4(0.0, 0.0, 1.0, 1.0), world_matrix), 3);
                            },
                            .spot => |data|{
                                light_uniform.type = 2;
                                light_uniform.spot_light_angle = data.angle;
                                zm.store(&light_uniform.position,zm.mul(zm.f32x4s(0.0), world_matrix), 3);
                                zm.store(&light_uniform.direction,zm.mul(zm.f32x4(0.0, 0.0, 1.0, 1.0), world_matrix), 3);
                            },
                        }
                        scene_uniform.pushLight(light_uniform);
                    }
                },
                .skeletal_mesh => |*skeletal_mesh| {
                    if (self.skeletal_meshes.get(skeletal_mesh.handle)) |mesh| {
                        if (self.skinned_materials.get(mesh.material)) |material| {
                            if (mesh.bone_buffer.mapped) |mapped| {
                                const bones: [*]zm.Mat = @ptrCast(@alignCast(mapped));
                                for (mesh.bones, 0..) |bone_handle, i| {
                                    if (self.nodes.get(bone_handle)) |bone_node| {
                                        bones[i] = bone_node.transform.toMatrix();
                                    }
                                }
                            }
                            material.updateBoneBuffer(&self.context, mesh.bone_buffer.buffer, mesh.bone_buffer.size);
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
                .static_mesh => |*mesh_handle| {
                    if (self.meshes.get(mesh_handle.*)) |mesh| {
                        if (self.materials.get(mesh.material)) |material| {
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
                // if (child.index == self.scene.root.index) {
                //     std.debug.print("A node can't have root node as a child {d} {d}\n", .{ handle.index, handle.generation });
                //     continue;
                // }
                try node_stack.append(child);
                try transform_stack.append(world_matrix);
            }
        }
        self.renderer.getUniform().write(std.mem.asBytes(&scene_uniform));
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
        for (self.nodes.entries.items) |*entry| {
            if (!entry.active) continue;
            const node = &entry.item;
            switch (node.data) {
                .skeletal_mesh => |*skeletal_mesh| {
                    if (skeletal_mesh.animation.status != AnimationStatus.playing) continue;
                    const anim = &skeletal_mesh.animation;
                    anim.*.time += delta_time;
                    const mesh = self.skeletal_meshes.get(skeletal_mesh.handle) orelse continue;
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
                    track.update(anim.time, &self.nodes, mesh.bones);
                },
                else => {},
            }
        }
        self.last_update_timestamp = Time.now() catch return true;
        return true;
    }

    pub fn deinit(self: *Engine) !void {
        try self.context.vkd.deviceWaitIdle();
        for (self.nodes.entries.items) |*entry| {
            if (entry.active) {
                entry.item.deinit();
            }
        }
        for (self.meshes.entries.items) |*entry| {
            if (entry.active) {
                entry.item.deinit(&self.context);
            }
        }
        for (self.skeletal_meshes.entries.items) |*entry| {
            if (entry.active) {
                entry.item.deinit(&self.context);
            }
        }
        for (self.textures.entries.items) |*entry| {
            if (entry.active) {
                entry.item.deinit(&self.context);
            }
        }
        for (self.materials.entries.items) |*entry| {
            if (entry.active) {
                entry.item.deinit(&self.context);
            }
        }
        for (self.skinned_materials.entries.items) |*entry| {
            if (entry.active) {
                entry.item.deinit(&self.context);
            }
        }
        self.meshes.deinit();
        self.skeletal_meshes.deinit();
        self.materials.deinit();
        self.skinned_materials.deinit();
        self.textures.deinit();
        self.lights.deinit();
        self.nodes.deinit();
        self.renderer.deinit(&self.context);
        self.scene.deinit(&self.context);
        self.context.deinit();
        glfw.destroyWindow(self.window);
        glfw.terminate();
    }

    pub fn addToRoot(self: *Engine, node: Handle) void {
        self.parentNode(self.scene.root, node);
    }

    pub fn createSkeletalMesh(
        self: *Engine,
        vertices: []const SkeletalMesh.Vertex,
        indices: []const u32,
        bones: []const Handle,
        material: Handle,
    ) !Handle {
        const handle = self.skeletal_meshes.malloc();
        const mesh = try self.skeletal_meshes.get(handle);
        mesh.vertices_len = vertices.len;
        mesh.indices_len = indices.len;
        mesh.material = material;
        mesh.bones = try self.allocator.dupe(Handle, bones);
        mesh.animations = std.StringHashMap(SkeletalMesh.AnimationTrack).init(self.allocator);
        mesh.vertex_buffer = try self.context.createLocalBuffer(std.mem.sliceAsBytes(vertices), .{ .vertex_buffer_bit = true });
        mesh.index_buffer = try self.context.createLocalBuffer(std.mem.sliceAsBytes(indices), .{ .index_buffer_bit = true });
        if (bones.len > 0) {
            const bone_buffer_size = bones.len * @sizeOf(zm.Mat);
            mesh.bone_buffer = try self.context.mallocHostVisibleBuffer(bone_buffer_size, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        }
        return handle;
    }

    /// Create a new texture from raw data
    pub fn createTexture(self: *Engine, data: []const u8) !Handle {
        // Allocate texture
        const handle = self.textures.malloc();
        const texture = self.textures.get(handle) orelse return error.ResourceAllocationFailed;
        try texture.initFromData(data);
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
        std.debug.print("Texture created {d}\n", .{handle.index});
        return handle;
    }

    /// Create a new PBR material
    pub fn createMaterial(self: *Engine) !Handle {
        const handle = self.materials.malloc();
        const mat = self.materials.get(handle) orelse return error.ResourceAllocationFailed;
        const vertex_code align(@alignOf(u32)) = @embedFile("shaders/pbr.vert.spv").*;
        const fragment_code align(@alignOf(u32)) = @embedFile("shaders/pbr.frag.spv").*;
        try mat.initDescriptorSet(&self.context);
        std.debug.print("Material descriptor set initialized\n", .{});
        try buildMaterial(self, mat, &vertex_code, &fragment_code);
        std.debug.print("Material created\n", .{});
        return handle;
    }
    /// Create a new skinned material
    pub fn createSkinnedMaterial(self: *Engine, max_bones: u32) !Handle {
        const handle = self.skinned_materials.malloc();
        const mat = self.skinned_materials.get(handle) orelse return error.ResourceAllocationFailed;
        const vertex_code align(@alignOf(u32)) = @embedFile("shaders/skinned_pbr.vert.spv").*;
        const fragment_code align(@alignOf(u32)) = @embedFile("shaders/skinned_pbr.frag.spv").*;
        mat.max_bones = max_bones;
        try mat.initDescriptorSet(&self.context);
        try buildSkinnedMaterial(self, mat, &vertex_code, &fragment_code);
        return handle;
    }

    pub fn createCube(self: *Engine, material: Handle) !Handle {
        const ret = self.meshes.malloc();
        const mesh_ptr = self.meshes.get(ret).?;
        try mesh_ptr.buildCube(&self.context, material, .{ 0.0, 0.0, 0.0, 0.0 });
        return ret;
    }

    pub fn createMesh(self: *Engine, vertices: []const Vertex, indices: []const u32, material: Handle) !Handle {
        const ret = self.meshes.malloc();
        const mesh_ptr = self.meshes.get(ret).?;
        try mesh_ptr.buildMesh(&self.context, vertices, indices, material);
        return ret;
    }

    // Node methods
    pub fn initNode(self: *Engine) Handle {
        const handle = self.nodes.malloc();
        if (self.nodes.get(handle)) |node| {
            node.init(self.allocator);
            node.parent = handle;
            node.data = .none;
        }
        return handle;
    }

    pub fn createMeshNode(self: *Engine, mesh: Handle) Handle {
        const handle = self.initNode();
        if (self.nodes.get(handle)) |node| {
            node.data = .{ .static_mesh = mesh };
        }
        return handle;
    }

    pub fn createSkeletalMeshNode(self: *Engine, mesh: Handle) Handle {
        const handle = self.initNode();
        if (self.nodes.get(handle)) |node| {
            node.data = .{ .skeletal_mesh = mesh };
        }
        return handle;
    }

    pub fn createLightNode(self: *Engine, light: Handle) Handle {
        const handle = self.initNode();
        if (self.nodes.get(handle)) |node| {
            node.data = .{ .light = light };
        }
        return handle;
    }

    pub fn deinitNodeCascade(self: *Engine, handle: Handle) void {
        if (self.nodes.get(handle)) |node| {
            for (node.children.items) |child| {
                self.deinitNodeCascade(child);
            }
            node.deinit();
            self.nodes.free(handle);
        }
    }

    pub fn deinitNode(self: *Engine, handle: Handle) void {
        self.unparentNode(handle);
        self.deinitNodeCascade(handle);
    }

    pub fn deinitMesh(self: *Engine, handle: Handle) void {
        if (self.meshes.get(handle)) |mesh| {
            mesh.deinit(&self.context);
            self.meshes.free(handle);
        }
    }

    pub fn deinitSkeletalMesh(self: *Engine, handle: Handle) void {
        if (self.skeletal_meshes.get(handle)) |mesh| {
            mesh.deinit(&self.context);
            self.skeletal_meshes.free(handle);
        }
    }

    pub fn deinitTexture(self: *Engine, handle: Handle) void {
        if (self.textures.get(handle)) |texture| {
            texture.deinit(&self.context);
            self.textures.free(handle);
        }
    }

    pub fn deinitMaterial(self: *Engine, handle: Handle) void {
        if (self.materials.get(handle)) |material| {
            material.deinit(&self.context);
            self.materials.free(handle);
        }
    }

    pub fn deinitSkinnedMaterial(self: *Engine, handle: Handle) void {
        if (self.skinned_materials.get(handle)) |material| {
            material.deinit(&self.context);
            self.skinned_materials.free(handle);
        }
    }

    pub fn deinitLight(self: *Engine, handle: Handle) void {
        self.lights.free(handle);
    }

    pub fn unparentNode(self: *Engine, node: Handle) void {
        const child_node = self.nodes.get(node) orelse return;
        const parent_handle = child_node.parent;
        const parent_node = self.nodes.get(parent_handle) orelse return;
        if (parent_node == child_node) return;
        for (parent_node.children.items, 0..) |child, i| {
            if (child.index == node.index and child.generation == node.generation) {
                if (i < parent_node.children.items.len - 1) {
                    parent_node.children.items[i] = parent_node.children.items[parent_node.children.items.len - 1];
                }
                _ = parent_node.children.pop();
                break;
            }
        }
        child_node.parent = node;
    }

    pub fn parentNode(self: *Engine, parent: Handle, child: Handle) void {
        std.debug.print("Parenting node {} to {}\n", .{ child, parent });
        self.unparentNode(child);
        const parent_node = self.nodes.get(parent) orelse return;
        const child_node = self.nodes.get(child) orelse return;
        child_node.parent = parent;
        parent_node.children.append(child) catch |err| {
            std.debug.print("Failed to append child to parent: {any}\n", .{err});
        };
    }

    pub fn loadGltf(self: *Engine, path: [:0]const u8) !void {
        const options = zcgltf.Options{};
        const data = try zcgltf.parseFile(options, path);
        defer zcgltf.free(data);
        if (data.buffers_count > 0) {
            try zcgltf.loadBuffers(options, data, path);
        }
        if (data.nodes) |nodes| {
            for (nodes[0..data.nodes_count]) |*node| {
                try self.processGltfNode(data, node, self.scene.root);
            }
        }
    }

    fn processGltfNode(self: *Engine, data: *zcgltf.Data, node: *zcgltf.Node, parent: Handle) !void {
        const handle = self.initNode();
        const engine_node = self.nodes.get(handle) orelse return;
        if (node.has_translation != 0) {
            engine_node.transform.position = zm.loadArr3w(node.translation, 1.0);
        }
        if (node.has_rotation != 0) {
            engine_node.transform.rotation = zm.loadArr4(node.rotation);
        }
        if (node.has_scale != 0) {
            engine_node.transform.scale = zm.loadArr3w(node.scale, 1.0);
        }
        if (node.has_matrix != 0) {
            const mat = zm.matFromArr(node.matrix);
            engine_node.transform.fromMatrix(mat);
        }
        if (node.mesh) |mesh| {
            try self.processGltfMesh(mesh, handle);
        }
        self.parentNode(parent, handle);
        if (node.children) |children| {
            for (children[0..node.children_count]) |child| {
                try self.processGltfNode(data, child, handle);
            }
        }
    }

    fn processGltfMesh(self: *Engine, mesh: *zcgltf.Mesh, node: Handle) !void {
        const material_handle = try self.createMaterial();
        for (mesh.primitives[0..mesh.primitives_count]) |*primitive| {
            var vertices = std.ArrayList(Vertex).init(self.allocator);
            defer vertices.deinit();
            var indices = std.ArrayList(u32).init(self.allocator);
            defer indices.deinit();
            // Process attributes
            for (primitive.attributes[0..primitive.attributes_count]) |attribute| {
                const accessor = attribute.data;
                if (attribute.type == .position) {
                    const positions = try self.unpackAccessorFloats(3, accessor);
                    defer self.allocator.free(positions);
                    try vertices.resize(@max(positions.len, vertices.items.len));
                    for (positions, 0..) |pos, i| {
                        vertices.items[i].position = pos;
                    }
                    std.debug.print("loaded {} positions", .{positions.len});
                } else if (attribute.type == .normal) {
                    const normals = try self.unpackAccessorFloats(3, accessor);
                    defer self.allocator.free(normals);
                    try vertices.resize(@max(normals.len, vertices.items.len));
                    for (normals, 0..) |normal, i| {
                        vertices.items[i].normal = normal;
                    }
                    std.debug.print("loaded {} normals", .{normals.len});
                } else if (attribute.type == .texcoord) {
                    const uvs = try self.unpackAccessorFloats(2, accessor);
                    defer self.allocator.free(uvs);
                    try vertices.resize(@max(uvs.len, vertices.items.len));
                    for (uvs, 0..) |uv, i| {
                        vertices.items[i].uv = .{ uv[0], uv[1] };
                    }
                    std.debug.print("loaded {} uvs", .{uvs.len});
                }
            }
            if (primitive.indices) |accessor| {
                const index_count = accessor.count;
                try indices.resize(index_count);
                _ = accessor.unpackIndices(indices.items);
            }
            const mesh_handle = try self.createMesh(vertices.items, indices.items, material_handle);
            if (self.nodes.get(node)) |engine_node| {
                engine_node.data = .{ .static_mesh = mesh_handle };
            }
        }
    }

    fn unpackAccessorFloats(self: *Engine, comptime components: usize, accessor: *zcgltf.Accessor) ![][components]f32 {
        const count = accessor.count;
        const float_count = count * components;
        const floats = try self.allocator.alloc(f32, float_count);
        const unpacked_count = accessor.unpackFloats(floats);
        if (unpacked_count.len != count * components) {
            self.allocator.free(floats);
            return error.InvalidAccessorData;
        }
        const result = try self.allocator.alloc([components]f32, count);
        for (0..count) |i| {
            for (0..components) |j| {
                result[i][j] = floats[i * components + j];
            }
        }
        return result;
    }
};

fn glfwErrorCallback(error_code: c_int, description: ?[*:0]const u8) callconv(.C) void {
    std.debug.print("GLFW error({x}): {s}\n", .{ error_code, description orelse "No description provided" });
}
