const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("zglfw");
const zm = @import("zmath");
const zstbi = @import("zstbi");
const zcgltf = @import("zmesh").io.zcgltf;

const Allocator = std.mem.Allocator;
const Time = std.time.Instant;
const ArrayList = std.ArrayList;

const Renderer = @import("renderer.zig").Renderer;
const Scene = @import("scene.zig").Scene;
const Handle = @import("resource.zig").Handle;
const Node = @import("../scene/node.zig").Node;
const NodeType = @import("../scene/node.zig").NodeType;
const Transform = @import("../scene/node.zig").Transform;
const AnimationStatus = @import("../geometry/animation.zig").AnimationStatus;
const AnimationPlayMode = @import("../geometry/animation.zig").AnimationPlayMode;
const Animation = @import("../geometry/animation.zig").Animation;
const AnimationTrack = @import("../geometry/animation.zig").AnimationTrack;
const PositionKeyframe = @import("../geometry/animation.zig").PositionKeyframe;
const RotationKeyframe = @import("../geometry/animation.zig").RotationKeyframe;
const ScaleKeyframe = @import("../geometry/animation.zig").ScaleKeyframe;
const SceneUniform = @import("renderer.zig").SceneUniform;
const SkeletalMesh = @import("../geometry/skeletal_mesh.zig").SkeletalMesh;
const SkinnedVertex = @import("../geometry/skeletal_mesh.zig").SkinnedVertex;
const Bone = @import("../geometry/skeletal_mesh.zig").Bone;
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
const createDepthImage = @import("../material/texture.zig").createDepthImage;
const context = @import("context.zig").get();

const MAX_LIGHTS = @import("renderer.zig").MAX_LIGHTS;
const RENDER_FPS = 60.0;
const FRAME_TIME = 1.0 / RENDER_FPS;
const FRAME_TIME_NANO: u64 = @intFromFloat(FRAME_TIME * 1_000_000_000.0);
const UPDATE_FPS = 60.0;
const UPDATE_FRAME_TIME = 1.0 / UPDATE_FPS;
const UPDATE_FRAME_TIME_NANO: u64 = @intFromFloat(UPDATE_FRAME_TIME * 1_000_000_000.0);

pub const Engine = struct {
    window: *glfw.Window,
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
        try context.*.init(self.window, allocator);
        self.start_timestamp = try Time.now();
        self.last_frame_timestamp = try Time.now();
        self.last_update_timestamp = try Time.now();
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
        try self.scene.init();
        self.scene.root = self.initNode();
    }

    fn buildRenderer(self: *Engine) !void {
        const indices = try context.*.findQueueFamilies(context.*.physical_device);
        var support = try context.*.querySwapchainSupport(context.*.physical_device);
        defer support.deinit();
        self.renderer = Renderer.init(self.allocator);
        try self.renderer.buildSwapchain(support.capabilities, support.formats, support.present_modes, indices.graphics_family, indices.present_family);
        try self.renderer.buildCommandBuffers();
        try self.renderer.buildSynchronizers();
        self.renderer.depth_buffer = try createDepthImage(.d32_sfloat, self.renderer.extent.width, self.renderer.extent.height);
        for (&self.renderer.frames, 0..) |*frame, i| {
            frame.uniform = try context.*.mallocHostVisibleBuffer(@sizeOf(SceneUniform), .{ .uniform_buffer_bit = true });
            const alloc_info = vk.DescriptorSetAllocateInfo{
                .descriptor_pool = context.*.descriptor_pool,
                .descriptor_set_count = 1,
                .p_set_layouts = @ptrCast(&self.scene.descriptor_set_layout),
            };
            std.debug.print("Creating descriptor set for frame {d} with pool {x} and set layout {x}\n", .{ i, context.*.descriptor_pool, self.scene.descriptor_set_layout });
            try context.*.vkd.allocateDescriptorSets(&alloc_info, @ptrCast(&frame.descriptor_set));
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
            context.*.vkd.updateDescriptorSets(1, @ptrCast(&write), 0, undefined);
        }
    }

    pub fn tryRender(self: *Engine) !void {
        const image_idx = try self.renderer.begin();
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
            .lights = undefined,
        };
        if (Time.now()) |now| {
            const elapsed_seconds = @as(f64, @floatFromInt(now.since(self.start_timestamp))) / 1000_000_000.0;
            scene_uniform.time = @floatCast(elapsed_seconds);
        } else |err| {
            std.debug.print("{}", .{err});
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
                        };
                        switch (light_ptr.data) {
                            .point => {
                                light_uniform.kind = 0;
                                light_uniform.position = zm.mul(zm.f32x4(0.0, 0.0, 0.0, 1.0), world_matrix);
                                //std.debug.print("light uniform = {any}\n", .{light_uniform});
                            },
                            .directional => {
                                light_uniform.kind = 1;
                                light_uniform.direction = zm.mul(zm.f32x4(0.0, 0.0, 1.0, 1.0), world_matrix);
                            },
                            .spot => |angle|{
                                light_uniform.kind = 2;
                                light_uniform.angle = angle;
                                light_uniform.position = zm.mul(zm.f32x4(0.0, 0.0, 0.0, 1.0), world_matrix);
                                light_uniform.direction = zm.mul(zm.f32x4(0.0, 0.0, 1.0, 1.0), world_matrix);
                            },
                        }
                        scene_uniform.pushLight(light_uniform);
                    }
                },
                .skeletal_mesh => |*skeletal_mesh| {
                    if (self.skeletal_meshes.get(skeletal_mesh.handle)) |mesh| {
                        // TODO: update bone transformation
                        if (self.skinned_materials.get(mesh.material)) |material| {
                            // update bone matrices buffer
                            context.*.vkd.cmdBindPipeline(command_buffer, .graphics, material.pipeline);
                            const descriptor_sets = [_]vk.DescriptorSet{
                                self.renderer.getDescriptorSet(),
                                material.descriptor_set,
                            };
                            context.*.vkd.cmdBindDescriptorSets(command_buffer, .graphics, material.pipeline_layout, 0, descriptor_sets.len, &descriptor_sets, 0, undefined);
                            context.*.vkd.cmdPushConstants(command_buffer, material.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(zm.Mat), &world_matrix);
                            const offset: vk.DeviceSize = 0;
                            context.*.vkd.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast(&mesh.vertex_buffer.buffer), @ptrCast(&offset));
                            context.*.vkd.cmdBindIndexBuffer(command_buffer, mesh.index_buffer.buffer, 0, .uint32);
                            context.*.vkd.cmdDrawIndexed(command_buffer, mesh.indices_len, 1, 0, 0, 0);
                        }
                    }
                },
                .static_mesh => |*mesh_handle| {
                    if (self.meshes.get(mesh_handle.*)) |mesh| {
                        if (self.materials.get(mesh.material)) |material| {
                            context.*.vkd.cmdBindPipeline(command_buffer, .graphics, material.pipeline);
                            const descriptor_sets = [_]vk.DescriptorSet{
                                self.renderer.getDescriptorSet(),
                                material.descriptor_set,
                            };
                            context.*.vkd.cmdBindDescriptorSets(command_buffer, .graphics, material.pipeline_layout, 0, descriptor_sets.len, &descriptor_sets, 0, undefined);
                            context.*.vkd.cmdPushConstants(command_buffer, material.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(zm.Mat), &world_matrix);
                            const offset: vk.DeviceSize = 0;
                            context.*.vkd.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast(&mesh.vertex_buffer.buffer), @ptrCast(&offset));
                            context.*.vkd.cmdBindIndexBuffer(command_buffer, mesh.index_buffer.buffer, 0, .uint32);
                            context.*.vkd.cmdDrawIndexed(command_buffer, mesh.indices_len, 1, 0, 0, 0);
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
        try self.renderer.end(image_idx);
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
        var support = try context.*.querySwapchainSupport(context.*.physical_device);
        defer support.deinit();
        const indices = try context.*.findQueueFamilies(context.*.physical_device);
        try context.*.vkd.deviceWaitIdle();
        self.renderer.destroySwapchain();
        try self.renderer.buildSwapchain(support.capabilities, support.formats, support.present_modes, indices.graphics_family, indices.present_family);
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
                    track.update(anim.time, mesh.bones);
                },
                else => {},
            }
        }
        self.last_update_timestamp = Time.now() catch return true;

        // Camera Controls
        const move_speed: f32 = 2.0; // Units per second
        //const rotate_speed: f32 = 1.0; // Radians per second
        const window = self.window;

        // Movement
        if (glfw.getKey(window, glfw.Key.w) == glfw.Action.press) {
            self.scene.camera.position[2] += move_speed * delta_time;
        }
        if (glfw.getKey(window, glfw.Key.s) == glfw.Action.press) {
            self.scene.camera.position[2] -=  move_speed * delta_time;
        }
        if (glfw.getKey(window, glfw.Key.a) == glfw.Action.press) {
            self.scene.camera.position[0] -= move_speed * delta_time;
        }
        if (glfw.getKey(window, glfw.Key.d) == glfw.Action.press) {
            self.scene.camera.position[0] += move_speed * delta_time;
        }
        if (glfw.getKey(window, glfw.Key.z) == glfw.Action.press) {
            self.scene.camera.position[1] -= move_speed * delta_time;
        }
        if (glfw.getKey(window, glfw.Key.x) == glfw.Action.press) {
            self.scene.camera.position[1] += move_speed * delta_time;
        }

        // Rotation
        // if (glfw.getKey(window, glfw.Key.left) == glfw.Action.press) {
        //     self.scene.camera.rotation = zm.qmul(self.scene.camera.rotation, zm.quatFromAxisAngle(self.scene.camera.up, -std.math.pi*rotate_speed*delta_time));
        // }
        // if (glfw.getKey(window, glfw.Key.right) == glfw.Action.press) {
        //     self.scene.camera.rotation = zm.qmul(self.scene.camera.rotation, zm.quatFromAxisAngle(self.scene.camera.up, std.math.pi*rotate_speed*delta_time));
        // }
        // if (glfw.getKey(window, glfw.Key.up) == glfw.Action.press) {
        //     self.scene.camera.rotation = zm.qmul(self.scene.camera.rotation, zm.quatFromAxisAngle(self.scene.camera.right(), -std.math.pi*rotate_speed*delta_time));
        // }
        // if (glfw.getKey(window, glfw.Key.down) == glfw.Action.press) {
        //     self.scene.camera.rotation = zm.qmul(self.scene.camera.rotation, zm.quatFromAxisAngle(self.scene.camera.right(), std.math.pi*rotate_speed*delta_time));
        // }
        return true;
    }

    pub fn deinit(self: *Engine) !void {
        try context.*.vkd.deviceWaitIdle();
        for (self.nodes.entries.items) |*entry| {
            if (entry.active) {
                entry.item.deinit();
            }
        }
        for (self.meshes.entries.items) |*entry| {
            if (entry.active) {
                entry.item.deinit();
            }
        }
        for (self.skeletal_meshes.entries.items) |*entry| {
            if (entry.active) {
                entry.item.deinit();
            }
        }
        for (self.textures.entries.items) |*entry| {
            if (entry.active) {
                entry.item.deinit();
            }
        }
        for (self.materials.entries.items) |*entry| {
            if (entry.active) {
                entry.item.deinit();
            }
        }
        for (self.skinned_materials.entries.items) |*entry| {
            if (entry.active) {
                entry.item.deinit();
            }
        }
        self.meshes.deinit();
        self.skeletal_meshes.deinit();
        self.materials.deinit();
        self.skinned_materials.deinit();
        self.textures.deinit();
        self.lights.deinit();
        self.nodes.deinit();
        self.renderer.deinit();
        self.scene.deinit();
        context.*.deinit();
        glfw.destroyWindow(self.window);
        glfw.terminate();
    }

    pub fn addToRoot(self: *Engine, node: Handle) void {
        self.parentNode(self.scene.root, node);
    }

    pub fn createSkeletalMesh(
        self: *Engine,
        vertices: []const SkinnedVertex,
        indices: []const u32,
        bones: []Bone,
        material: Handle,
    ) !Handle {
        const handle = self.skeletal_meshes.malloc();
        const mesh = self.skeletal_meshes.get(handle).?;
        mesh.vertices_len = @intCast(vertices.len);
        mesh.indices_len = @intCast(indices.len);
        mesh.material = material;
        mesh.bones = bones;
        mesh.animations = std.StringHashMap(AnimationTrack).init(self.allocator);
        mesh.vertex_buffer = try context.*.createLocalBuffer(std.mem.sliceAsBytes(vertices), .{ .vertex_buffer_bit = true });
        mesh.index_buffer = try context.*.createLocalBuffer(std.mem.sliceAsBytes(indices), .{ .index_buffer_bit = true });
        if (bones.len > 0) {
            const bone_buffer_size = bones.len * @sizeOf(zm.Mat);
            mesh.bone_buffer = try context.*.mallocHostVisibleBuffer(bone_buffer_size, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        }
        return handle;
    }

    /// Create a new texture from raw data
    pub fn createTextureFromData(self: *Engine, data: []const u8) !Handle {
        // Allocate texture
        const handle = self.textures.malloc();
        const texture = self.textures.get(handle) orelse return error.ResourceAllocationFailed;
        try texture.initFromData(data);
        texture.buffer = try context.*.createImageBuffer(
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
        texture.sampler = try context.*.vkd.createSampler(&sampler_info, null);
        std.debug.print("Texture created {d}\n", .{handle.index});
        return handle;
    }

    /// Create a new PBR material
    pub fn createMaterial(self: *Engine) !Handle {
        const handle = self.materials.malloc();
        const mat = self.materials.get(handle) orelse return error.ResourceAllocationFailed;
        const vertex_code align(@alignOf(u32)) = @embedFile("shaders/pbr/vert.spv").*;
        const fragment_code align(@alignOf(u32)) = @embedFile("shaders/pbr/frag.spv").*;
        try mat.initDescriptorSet();
        std.debug.print("Material descriptor set initialized\n", .{});
        try buildMaterial(self, mat, &vertex_code, &fragment_code);
        std.debug.print("Material created\n", .{});
        return handle;
    }
    /// Create a new skinned material
    pub fn createSkinnedMaterial(self: *Engine, max_bones: u32) !Handle {
        std.debug.print("Creating skinned material with max_bones: {d}\n", .{max_bones});
        const handle = self.skinned_materials.malloc();
        std.debug.print("Got material handle: {any}\n", .{handle});

        const mat = self.skinned_materials.get(handle) orelse {
            std.debug.print("Failed to get material from handle\n", .{});
            return error.ResourceAllocationFailed;
        };
        std.debug.print("Got material from handle\n", .{});

        const vertex_code align(@alignOf(u32)) = @embedFile("shaders/skinned_pbr/vert.spv").*;
        const fragment_code align(@alignOf(u32)) = @embedFile("shaders/skinned_pbr/frag.spv").*;
        std.debug.print("Loaded shader code\n", .{});

        mat.max_bones = max_bones;
        std.debug.print("Set max_bones\n", .{});

        std.debug.print("Initializing descriptor set\n", .{});
        try mat.initDescriptorSet();
        std.debug.print("Descriptor set initialized\n", .{});

        std.debug.print("Building skinned material\n", .{});
        try buildSkinnedMaterial(self, mat, &vertex_code, &fragment_code);
        std.debug.print("Skinned material built successfully\n", .{});

        return handle;
    }

    pub fn createCube(self: *Engine, material: Handle) !Handle {
        const ret = self.meshes.malloc();
        const mesh_ptr = self.meshes.get(ret).?;
        try mesh_ptr.buildCube(material, .{ 0.0, 0.0, 0.0, 0.0 });
        return ret;
    }

    pub fn createMesh(self: *Engine, vertices: []const Vertex, indices: []const u32, material: Handle) !Handle {
        const ret = self.meshes.malloc();
        const mesh_ptr = self.meshes.get(ret).?;
        try mesh_ptr.buildMesh(vertices, indices, material);
        return ret;
    }

    pub fn createPointLight(self: *Engine, color: zm.Vec) Handle {
        const ret = self.lights.malloc();
        const light_ptr = self.lights.get(ret).?;
        light_ptr.data = .point;
        light_ptr.color = color;
        return ret;
    }

    pub fn createDirectionalLight(self: *Engine, color: zm.Vec) Handle {
        const ret = self.lights.malloc();
        const light_ptr = self.lights.get(ret).?;
        light_ptr.data = .directional;
        light_ptr.color = color;
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
            mesh.deinit();
            self.meshes.free(handle);
        }
    }

    pub fn deinitSkeletalMesh(self: *Engine, handle: Handle) void {
        if (self.skeletal_meshes.get(handle)) |mesh| {
            mesh.deinit();
            self.skeletal_meshes.free(handle);
        }
    }

    pub fn deinitTexture(self: *Engine, handle: Handle) void {
        if (self.textures.get(handle)) |texture| {
            texture.deinit();
            self.textures.free(handle);
        }
    }

    pub fn deinitMaterial(self: *Engine, handle: Handle) void {
        if (self.materials.get(handle)) |material| {
            material.deinit();
            self.materials.free(handle);
        }
    }

    pub fn deinitSkinnedMaterial(self: *Engine, handle: Handle) void {
        if (self.skinned_materials.get(handle)) |material| {
            material.deinit();
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
        std.debug.print("Processing GLTF node (parent handle: {d})\n", .{parent.index});
        const handle = self.initNode();
        const engine_node = self.nodes.get(handle) orelse return;

        if (node.has_translation != 0) {
            std.debug.print("Node has translation\n", .{});
            engine_node.transform.position = zm.loadArr3w(node.translation, 1.0);
        }
        if (node.has_rotation != 0) {
            std.debug.print("Node has rotation\n", .{});
            engine_node.transform.rotation = zm.loadArr4(node.rotation);
        }
        if (node.has_scale != 0) {
            std.debug.print("Node has scale\n", .{});
            engine_node.transform.scale = zm.loadArr3w(node.scale, 1.0);
        }
        if (node.has_matrix != 0) {
            std.debug.print("Node has matrix\n", .{});
            const mat = zm.matFromArr(node.matrix);
            engine_node.transform.fromMatrix(mat);
        }
        if (node.mesh) |mesh| {
            std.debug.print("Node has mesh\n", .{});
            try self.processGltfMesh(mesh, handle, data);
        }

        if (node.skin) |skin| {
            std.debug.print("Node has skin with {d} joints\n", .{skin.joints_count});
            // Log information about joints
            const bones = try self.allocator.alloc(Bone, skin.joints_count);
            for (bones) |*bone| {
                bone.* = .{
                    .children = std.ArrayList(u32).init(self.allocator),
                    .transform = .{},
                    .inverse_bind_matrix = zm.identity(),  // Initialize with identity
                };
            }

            // If inverse bind matrices are available in the skin data
            if (skin.inverse_bind_matrices) |matrices| {
                // Load inverse bind matrices from accessor
                const inverse_matrices = try self.unpackAccessorFloats(16, matrices);
                defer self.allocator.free(inverse_matrices);

                // Copy matrices to bones
                for (inverse_matrices, 0..) |*matrix, i| {
                    bones[i].inverse_bind_matrix = zm.loadMat(matrix);
                }
            }

            // Set up bone hierarchy using skin.joints
            for (skin.joints[0..skin.joints_count], 0..) |joint, i| {
                if (joint.children) |children| {
                    for (children[0..joint.children_count]) |child| {
                        const j = 0; // TODO: find actual index of child in the array
                        _ = child;
                        try bones[i].children.append(j);
                    }
                }
            }
            // TODO: gives this bone list to skeletal mesh
        }

        std.debug.print("Parenting node {d} to {d}\n", .{handle.index, parent.index});
        self.parentNode(parent, handle);

        if (node.children) |children| {
            std.debug.print("Processing {d} child nodes\n", .{node.children_count});
            for (children[0..node.children_count]) |child| {
                try self.processGltfNode(data, child, handle);
            }
        }
    }

    fn processGltfMesh(self: *Engine, mesh: *zcgltf.Mesh, node: Handle, data: *zcgltf.Data) !void {
        std.debug.print("Processing GLTF mesh with {d} primitives\n", .{mesh.primitives_count});
        for (mesh.primitives[0..mesh.primitives_count]) |*primitive| {
            // Detect if mesh has skinning data
            var has_joints = false;
            var has_weights = false;
            std.debug.print("Checking {d} attributes for skinning data\n", .{primitive.attributes_count});
            for (primitive.attributes[0..primitive.attributes_count]) |attribute| {
                if (attribute.type == .joints) {
                    has_joints = true;
                    std.debug.print("Found joints attribute\n", .{});
                } else if (attribute.type == .weights) {
                    has_weights = true;
                    std.debug.print("Found weights attribute\n", .{});
                }
            }

            const is_skinned = has_joints and has_weights;
            std.debug.print("Mesh is {s}\n", .{if (is_skinned) "skinned" else "static"});
            if (is_skinned) {
                try self.processSkinnedPrimitive(mesh, primitive, node, data);
            } else {
                try self.processStaticPrimitive(mesh, primitive, node);
            }
        }
    }

    fn processStaticPrimitive(self: *Engine, _: *zcgltf.Mesh, primitive: *zcgltf.Primitive, node: Handle) !void {
        const material_handle = try self.createMaterial();
        const material = self.materials.get(material_handle) orelse return error.ResourceAllocationFailed;
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
            } else if (attribute.type == .normal) {
                const normals = try self.unpackAccessorFloats(3, accessor);
                defer self.allocator.free(normals);
                try vertices.resize(@max(normals.len, vertices.items.len));
                for (normals, 0..) |normal, i| {
                    vertices.items[i].normal = normal;
                }
            } else if (attribute.type == .texcoord) {
                const uvs = try self.unpackAccessorFloats(2, accessor);
                defer self.allocator.free(uvs);
                try vertices.resize(@max(uvs.len, vertices.items.len));
                for (uvs, 0..) |uv, i| {
                    vertices.items[i].uv = .{ uv[0], uv[1] };
                }
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

        try self.loadMaterialTextures(primitive, material);
    }

    fn processSkinnedPrimitive(self: *Engine, _: *zcgltf.Mesh, primitive: *zcgltf.Primitive, node: Handle, data: *zcgltf.Data) !void {
        std.debug.print("Creating skinned material...\n", .{});
        const material_handle = try self.createSkinnedMaterial(100); // TODO: Calculate actual bone count
        var vertices = std.ArrayList(SkinnedVertex).init(self.allocator);
        defer vertices.deinit();
        var indices = std.ArrayList(u32).init(self.allocator);
        defer indices.deinit();

        // Initialize vertices with default values
        const vertex_count = blk: {
            for (primitive.attributes[0..primitive.attributes_count]) |attribute| {
                if (attribute.type == .position) {
                    break :blk attribute.data.count;
                }
            }
            break :blk 0;
        };
        std.debug.print("Initializing {d} vertices with default values\n", .{vertex_count});
        try vertices.resize(vertex_count);
        for (vertices.items) |*vertex| {
            vertex.* = .{
                .position = .{ 0, 0, 0 },
                .normal = .{ 0, 0, 1 },
                .color = .{ 1, 1, 1, 1 },
                .uv = .{ 0, 0 },
                .joints = .{ 0, 0, 0, 0 },
                .weights = .{ 0, 0, 0, 0 },
            };
        }

        // Process attributes
        std.debug.print("Processing {d} vertex attributes\n", .{primitive.attributes_count});
        for (primitive.attributes[0..primitive.attributes_count]) |attribute| {
            const accessor = attribute.data;
            if (attribute.type == .position) {
                std.debug.print("Processing positions\n", .{});
                const positions = try self.unpackAccessorFloats(3, accessor);
                defer self.allocator.free(positions);
                for (positions, 0..) |pos, i| {
                    vertices.items[i].position = pos;
                }
            } else if (attribute.type == .normal) {
                std.debug.print("Processing normals\n", .{});
                const normals = try self.unpackAccessorFloats(3, accessor);
                defer self.allocator.free(normals);
                for (normals, 0..) |normal, i| {
                    vertices.items[i].normal = normal;
                }
            } else if (attribute.type == .texcoord) {
                std.debug.print("Processing UVs\n", .{});
                const uvs = try self.unpackAccessorFloats(2, accessor);
                defer self.allocator.free(uvs);
                for (uvs, 0..) |uv, i| {
                    vertices.items[i].uv = .{ uv[0], uv[1] };
                }
            } else if (attribute.type == .joints) {
                std.debug.print("Processing joints\n", .{});
                const joints = try self.unpackAccessorFloats(4, accessor);
                defer self.allocator.free(joints);
                for (joints, 0..) |joint, i| {
                    vertices.items[i].joints = .{
                        @intFromFloat(joint[0]),
                        @intFromFloat(joint[1]),
                        @intFromFloat(joint[2]),
                        @intFromFloat(joint[3]),
                    };
                }
            } else if (attribute.type == .weights) {
                std.debug.print("Processing weights\n", .{});
                const weights = try self.unpackAccessorFloats(4, accessor);
                defer self.allocator.free(weights);
                for (weights, 0..) |weight, i| {
                    vertices.items[i].weights = weight;
                }
            }
        }

        if (primitive.indices) |accessor| {
            const index_count = accessor.count;
            std.debug.print("Processing {d} indices\n", .{index_count});
            try indices.resize(index_count);
            _ = accessor.unpackIndices(indices.items);
        }

        // Create bones
        std.debug.print("Creating bones array\n", .{});
        const bones = try self.allocator.alloc(Bone, 100); // TODO: Calculate actual bone count
        for (bones) |*bone| {
            bone.* = .{
                .children = std.ArrayList(u32).init(self.allocator),
                .transform = .{},
                .inverse_bind_matrix = zm.identity(),
            };
        }

        std.debug.print("Creating skeletal mesh\n", .{});
        const mesh_handle = try self.createSkeletalMesh(vertices.items, indices.items, bones, material_handle);

        // Process animations if present
        std.debug.print("Processing animations\n", .{});
        try self.processAnimationsForMesh(data, mesh_handle);

        if (self.nodes.get(node)) |engine_node| {
            std.debug.print("Setting up node data for skeletal mesh\n", .{});
            engine_node.data = .{ .skeletal_mesh = .{
                .handle = mesh_handle,
                .animation = .{
                    .status = .stopped,
                    .mode = .loop,
                    .name = "default",
                    .time = 0,
                },
            }};
        }

        std.debug.print("Loading material textures\n", .{});
        try self.loadMaterialTextures(primitive, self.skinned_materials.get(material_handle).?);
    }

    fn loadMaterialTextures(self: *Engine, primitive: *zcgltf.Primitive, material: anytype) !void {
        if (primitive.material) |mtl| {
            const pbr = mtl.pbr_metallic_roughness;
            if (pbr.base_color_texture.texture) |tex| {
                if (tex.image) |img| {
                    if (img.uri) |uri| {
                        const texture_data = try std.fs.cwd().readFileAlloc(self.allocator, std.mem.sliceTo(uri, 0), std.math.maxInt(usize));
                        defer self.allocator.free(texture_data);
                        const texture_handle = try self.createTextureFromData(texture_data);
                        const texture_ptr = self.textures.get(texture_handle).?;
                        material.albedo = texture_handle;
                        material.updateTextures(texture_ptr, texture_ptr, texture_ptr);
                    } else if (img.buffer_view) |buffer_view| {
                        const buffer = buffer_view.buffer;
                        const offset = buffer_view.offset;
                        const size = buffer_view.size;
                        const data_ptr: [*]u8 = @ptrCast(buffer.data);
                        const data = data_ptr[offset..offset+size];
                        const texture_handle = try self.createTextureFromData(data);
                        const texture_ptr = self.textures.get(texture_handle).?;
                        material.albedo = texture_handle;
                        material.updateTextures(texture_ptr, texture_ptr, texture_ptr);
                    }
                }
            }
        }
    }

    fn unpackAccessorFloats(self: *Engine, comptime components: usize, accessor: *zcgltf.Accessor) ![][components]f32 {
        const count = accessor.count;
        const float_count = count * components;
        std.debug.print("Unpacking accessor with {d} elements, {d} components ({d} total floats)\n", .{count, components, float_count});

        const floats = try self.allocator.alloc(f32, float_count);
        defer self.allocator.free(floats);

        const unpacked_count = accessor.unpackFloats(floats);
        std.debug.print("Unpacked {d} floats\n", .{unpacked_count.len});

        if (unpacked_count.len != count * components) {
            std.debug.print("ERROR: Unpacked count ({d}) doesn't match expected count ({d})\n", .{unpacked_count.len, count * components});
            return error.InvalidAccessorData;
        }

        const result = try self.allocator.alloc([components]f32, count);
        std.debug.print("Repackaging {d} floats into {d} vectors of size {d}\n", .{float_count, count, components});

        for (0..count) |i| {
            for (0..components) |j| {
                result[i][j] = floats[i * components + j];
            }
        }
        return result;
    }

    pub fn playAnimation(self: *Engine, node: Handle, name: []const u8, mode: AnimationPlayMode) !void {
        if (self.nodes.get(node)) |node_ptr| {
            switch (node_ptr.data) {
                .skeletal_mesh => |*skeletal_mesh| {
                    if (self.skeletal_meshes.get(skeletal_mesh.handle)) |mesh| {
                        if (mesh.animations.get(name)) |_| {
                            skeletal_mesh.animation.name = name;
                            skeletal_mesh.animation.mode = mode;
                            skeletal_mesh.animation.status = .playing;
                            skeletal_mesh.animation.time = 0;
                        } else {
                            return error.AnimationNotFound;
                        }
                    }
                },
                else => return error.NotASkeletalMesh,
            }
        }
    }

    pub fn pauseAnimation(self: *Engine, node: Handle) !void {
        if (self.nodes.get(node)) |node_ptr| {
            switch (node_ptr.data) {
                .skeletal_mesh => |*skeletal_mesh| {
                    skeletal_mesh.animation.status = .paused;
                },
                else => return error.NotASkeletalMesh,
            }
        }
    }

    pub fn resumeAnimation(self: *Engine, node: Handle) !void {
        if (self.nodes.get(node)) |node_ptr| {
            switch (node_ptr.data) {
                .skeletal_mesh => |*skeletal_mesh| {
                    skeletal_mesh.animation.status = .playing;
                },
                else => return error.NotASkeletalMesh,
            }
        }
    }

    pub fn stopAnimation(self: *Engine, node: Handle) !void {
        if (self.nodes.get(node)) |node_ptr| {
            switch (node_ptr.data) {
                .skeletal_mesh => |*skeletal_mesh| {
                    skeletal_mesh.animation.status = .stopped;
                    skeletal_mesh.animation.time = 0;
                },
                else => return error.NotASkeletalMesh,
            }
        }
    }

    pub fn setAnimationMode(self: *Engine, node: Handle, mode: AnimationPlayMode) !void {
        if (self.nodes.get(node)) |node_ptr| {
            switch (node_ptr.data) {
                .skeletal_mesh => |*skeletal_mesh| {
                    skeletal_mesh.animation.mode = mode;
                },
                else => return error.NotASkeletalMesh,
            }
        }
    }

    fn processAnimationsForMesh(self: *Engine, data: *zcgltf.Data, mesh_handle: Handle) !void {
        std.debug.print("Checking for animations in GLTF data\n", .{});
        if (data.animations) |animations| {
            std.debug.print("Processing {d} animations\n", .{data.animations_count});
            for (animations[0..data.animations_count]) |*anim| {
                var track = AnimationTrack{
                    .animations = try self.allocator.alloc(Animation, anim.channels_count),
                    .duration = 0.0,
                };
                std.debug.print("Animation '{s}' has {d} channels\n", .{ if (anim.name) |n| std.mem.sliceTo(n, 0) else "unnamed", anim.channels_count });

                for (anim.channels[0..anim.channels_count], 0..) |*channel, i| {
                    if (channel.target_node) |target_node| {
                        _ = target_node;
                        const sampler = channel.sampler;
                        // Create animation entry
                        var animation = &track.animations[i];
                        animation.* = Animation{
                            .bone_idx = 0, // TODO: use actual bone index here
                            .positions = &[_]PositionKeyframe{},
                            .rotations = &[_]RotationKeyframe{},
                            .scales = &[_]ScaleKeyframe{},
                        };

                        // Get input times
                        const input_acc = sampler.input;
                        std.debug.print("Getting input times for channel {d}\n", .{i});
                        const times = try self.unpackAccessorFloats(1, input_acc);
                        defer self.allocator.free(times);

                        // Get output values
                        const output_acc = sampler.output;
                        std.debug.print("Processing {s} animation data for channel {d}\n", .{ @tagName(channel.target_path), i });
                        switch (channel.target_path) {
                            .translation => {
                                const positions = try self.unpackAccessorFloats(3, output_acc);
                                defer self.allocator.free(positions);
                                var keyframes = try self.allocator.alloc(PositionKeyframe, times.len);
                                for (times, positions, 0..) |time, pos, frame_idx| {
                                    keyframes[frame_idx] = .{
                                        .time = time[0],
                                        .value = zm.loadArr3w(pos, 1.0),
                                    };
                                    track.duration = @max(track.duration, time[0]);
                                }
                                animation.positions = keyframes;
                            },
                            .rotation => {
                                const rotations = try self.unpackAccessorFloats(4, output_acc);
                                defer self.allocator.free(rotations);
                                var keyframes = try self.allocator.alloc(RotationKeyframe, times.len);
                                for (times, rotations, 0..) |time, rot, frame_idx| {
                                    keyframes[frame_idx] = .{
                                        .time = time[0],
                                        .value = zm.loadArr4(rot),
                                    };
                                    track.duration = @max(track.duration, time[0]);
                                }
                                animation.rotations = keyframes;
                            },
                            .scale => {
                                const scales = try self.unpackAccessorFloats(3, output_acc);
                                defer self.allocator.free(scales);
                                var keyframes = try self.allocator.alloc(ScaleKeyframe, times.len);
                                for (times, scales, 0..) |time, scale, frame_idx| {
                                    keyframes[frame_idx] = .{
                                        .time = time[0],
                                        .value = zm.loadArr3w(scale, 1.0),
                                    };
                                    track.duration = @max(track.duration, time[0]);
                                }
                                animation.scales = keyframes;
                            },
                            else => {},
                        }
                    }
                }

                // Add animation track to mesh
                if (self.skeletal_meshes.get(mesh_handle)) |mesh| {
                    const name = if (anim.name) |n| std.mem.sliceTo(n, 0) else "default";
                    std.debug.print("Adding animation track '{s}' to mesh\n", .{name});
                    try mesh.animations.put(name, track);
                }
            }
        }
    }
};

fn glfwErrorCallback(error_code: c_int, description: ?[*:0]const u8) callconv(.C) void {
    std.debug.print("GLFW error({x}): {s}\n", .{ error_code, description orelse "No description provided" });
}
