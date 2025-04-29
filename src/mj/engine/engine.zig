const std = @import("std");
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;
const ArrayList = std.ArrayList;

const glfw = @import("zglfw");
const vk = @import("vulkan");
const zcgltf = @import("zmesh").io.zcgltf;
const zm = @import("zmath");
const zstbi = @import("zstbi");
const context = @import("context.zig").get();
const animation = @import("../geometry/animation.zig");
const SkeletalMesh = @import("../geometry/skeletal_mesh.zig").SkeletalMesh;
const SkinnedVertex = @import("../geometry/geometry.zig").SkinnedVertex;
const Bone = @import("../geometry/skeletal_mesh.zig").Bone;
const StaticMesh = @import("../geometry/static_mesh.zig").StaticMesh;
const Vertex = @import("../geometry/geometry.zig").Vertex;
const Material = @import("../material/pbr.zig").Material;
const SkinnedMaterial = @import("../material/skinned_pbr.zig").SkinnedMaterial;
const Texture = @import("../material/texture.zig").Texture;
const createDepthImage = @import("../material/texture.zig").createDepthImage;
const Light = @import("../scene/light.zig").Light;
const Node = @import("../scene/node.zig").Node;
const NodeType = @import("../scene/node.zig").NodeType;
const Transform = @import("../scene/node.zig").Transform;
const Scene = @import("../scene/scene.zig").Scene;
const Handle = @import("resource.zig").Handle;
const LightUniform = @import("renderer.zig").LightUniform;
const MAX_LIGHTS = @import("renderer.zig").MAX_LIGHTS;
const QueueFamilyIndices = @import("context.zig").QueueFamilyIndices;
const Renderer = @import("renderer.zig").Renderer;
const ResourcePool = @import("resource.zig").ResourcePool;
const SceneUniform = @import("renderer.zig").SceneUniform;
const SwapchainSupport = @import("context.zig").SwapchainSupport;
const Pose = @import("../geometry/animation.zig").Pose;
const TextureBuilder = @import("builder.zig").TextureBuilder;
const MaterialBuilder = @import("builder.zig").MaterialBuilder;
const SkinnedMaterialBuilder = @import("builder.zig").SkinnedMaterialBuilder;
const MeshBuilder = @import("builder.zig").MeshBuilder;
const SkeletalMeshBuilder = @import("builder.zig").SkeletalMeshBuilder;
const NodeBuilder = @import("builder.zig").NodeBuilder;
const SkinnedGeometry = @import("../geometry/geometry.zig").SkinnedGeometry;
const Geometry = @import("../geometry/geometry.zig").Geometry;

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
    last_frame_timestamp: Instant,
    last_update_timestamp: Instant,
    start_timestamp: Instant,
    meshes: ResourcePool(StaticMesh),
    skeletal_meshes: ResourcePool(SkeletalMesh),
    materials: ResourcePool(Material),
    in_transaction: bool = false,
    dirty_transforms: std.ArrayList(Handle),
    skinned_materials: ResourcePool(SkinnedMaterial),
    textures: ResourcePool(Texture),
    lights: ResourcePool(Light),
    nodes: ResourcePool(Node),
    allocator: Allocator,

    pub fn beginTransaction(self: *Engine) void {
        self.in_transaction = true;
    }

    pub fn commitTransaction(self: *Engine) void {
        self.in_transaction = false;
        // Process all dirty transforms
        for (self.dirty_transforms.items) |handle| {
            if (self.nodes.get(handle)) |node| {
                _ = node;
                // Here you would update any GPU buffers or do other work
                // that needs to happen when transforms change
            }
        }
        self.dirty_transforms.clearRetainingCapacity();
    }

    pub fn markTransformDirty(self: *Engine, node: Handle) void {
        if (self.in_transaction) {
            self.dirty_transforms.append(node) catch {};
        }
    }

    pub fn init(self: *Engine, allocator: Allocator, width: u32, height: u32, title: [:0]const u8) !void {
        self.allocator = allocator;
        self.dirty_transforms = std.ArrayList(Handle).init(allocator);
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
        self.start_timestamp = try Instant.now();
        self.last_frame_timestamp = try Instant.now();
        self.last_update_timestamp = try Instant.now();
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
        self.scene.root = self.spawn().build();
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
        try node_stack.append(self.scene.root);
        try transform_stack.append(zm.identity());
        var scene_uniform = SceneUniform{
            .view = self.scene.viewMatrix(),
            .projection = self.scene.projectionMatrix(),
            .lights = undefined,
        };
        const now = try Instant.now();
        const elapsed_seconds = @as(f64, @floatFromInt(now.since(self.start_timestamp))) / 1000_000_000.0;
        scene_uniform.time = @floatCast(elapsed_seconds);
        while (node_stack.pop()) |handle| {
            const node = self.nodes.get(handle) orelse continue;
            const parent_matrix = transform_stack.pop() orelse zm.identity();
            const local_matrix = node.transform.toMatrix();
            const world_matrix = zm.mul(local_matrix, parent_matrix);
            for (node.children.items) |child| {
                // if (child.index == self.scene.root.index) {
                //     std.debug.print("A node can't have root node as a child {d} {d}\n", .{ handle.index, handle.generation });
                //     continue;
                // }
                try node_stack.append(child);
                try transform_stack.append(world_matrix);
            }
            switch (node.data) {
                .light => |light| {
                    const light_ptr = self.lights.get(light) orelse continue;
                    var light_uniform = LightUniform{
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
                        .spot => |angle| {
                            light_uniform.kind = 2;
                            light_uniform.angle = angle;
                            light_uniform.position = zm.mul(zm.f32x4(0.0, 0.0, 0.0, 1.0), world_matrix);
                            light_uniform.direction = zm.mul(zm.f32x4(0.0, 0.0, 1.0, 1.0), world_matrix);
                        },
                    }
                    scene_uniform.pushLight(light_uniform);
                },
                .skeletal_mesh => |*skeletal_mesh| {
                    const mesh = self.skeletal_meshes.get(skeletal_mesh.handle) orelse continue;
                    const material = self.skinned_materials.get(mesh.material) orelse continue;
                    const descriptor_sets = [_]vk.DescriptorSet{
                        self.renderer.getDescriptorSet(),
                        material.descriptor_set,
                    };
                    material.updateBoneBuffer(skeletal_mesh.pose.bone_buffer.buffer, skeletal_mesh.pose.bone_buffer.size);
                    context.*.vkd.cmdBindPipeline(command_buffer, .graphics, material.pipeline);
                    context.*.vkd.cmdBindDescriptorSets(command_buffer, .graphics, material.pipeline_layout, 0, descriptor_sets.len, &descriptor_sets, 0, undefined);
                    context.*.vkd.cmdPushConstants(command_buffer, material.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(zm.Mat), &world_matrix);
                    const offset: vk.DeviceSize = 0;
                    context.*.vkd.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast(&mesh.vertex_buffer.buffer), @ptrCast(&offset));
                    context.*.vkd.cmdBindIndexBuffer(command_buffer, mesh.index_buffer.buffer, 0, .uint32);
                    context.*.vkd.cmdDrawIndexed(command_buffer, mesh.indices_len, 1, 0, 0, 0);
                },
                .static_mesh => |mesh_handle| {
                    const mesh = self.meshes.get(mesh_handle) orelse continue;
                    const material = self.materials.get(mesh.material) orelse continue;
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
                },
                .none => {},
            }
        }
        self.renderer.getUniform().write(std.mem.asBytes(&scene_uniform));
        try self.renderer.end(image_idx);
    }

    pub fn render(self: *Engine) void {
        const now = Instant.now() catch return;
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
        const now = Instant.now() catch return 0.0;
        return @floatCast(@as(f64, @floatFromInt(now.since(self.last_update_timestamp))) / 1000_000_000.0);
    }

    pub fn getTime(self: *Engine) f32 {
        const now = Instant.now() catch return 0.0;
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
            if (node.data == .skeletal_mesh) {
                const skeletal_mesh = &node.data.skeletal_mesh;
                const skeletal_mesh_ptr = self.skeletal_meshes.get(skeletal_mesh.handle).?;
                if (skeletal_mesh.animation) |*anim| {
                    anim.update(delta_time);
                    skeletal_mesh_ptr.calculateAnimationTransform(self.allocator, anim, &skeletal_mesh.pose);
                }
                skeletal_mesh.pose.flush();
            }
        }
        self.last_update_timestamp = Instant.now() catch return true;
        // Camera Controls
        const move_speed: f32 = 2.0; // Units per second
        //const rotate_speed: f32 = 1.0; // Radians per second
        const window = self.window;
        // Movement
        if (glfw.getKey(window, glfw.Key.w) == glfw.Action.press) {
            self.scene.camera.position[2] += move_speed * delta_time;
        }
        if (glfw.getKey(window, glfw.Key.s) == glfw.Action.press) {
            self.scene.camera.position[2] -= move_speed * delta_time;
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

    pub fn setNodeName(self: *Engine, node: Handle, name: []const u8) !void {
        if (self.nodes.get(node)) |node_ptr| {
            try node_ptr.setName(name);
        }
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

    pub fn makeMaterial(self: *Engine) *MaterialBuilder {
        const builder = self.allocator.create(MaterialBuilder) catch unreachable;
        builder.init(self);
        return builder;
    }

    pub fn makeSkinnedMaterial(self: *Engine) *SkinnedMaterialBuilder {
        const builder = self.allocator.create(SkinnedMaterialBuilder ) catch unreachable;
        builder.init(self);
        return builder;
    }

    pub fn makeMesh(self: *Engine) *MeshBuilder {
        const builder = self.allocator.create(MeshBuilder) catch unreachable;
        builder.init(self);
        return builder;
    }

    pub fn makeSkeletalMesh(self: *Engine) *SkeletalMeshBuilder {
        const builder = self.allocator.create(SkeletalMeshBuilder) catch unreachable;
        builder.init(self);
        return builder;
    }

    pub fn makeTexture(self: *Engine) *TextureBuilder {
        const builder = self.allocator.create(TextureBuilder) catch unreachable;
        builder.init(self);
        return builder;
    }

    pub fn spawn(self: *Engine) *NodeBuilder {
        const builder = self.allocator.create(NodeBuilder) catch unreachable;
        builder.init(self);
        return builder;
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
        // std.debug.print("Parenting node {} to {}\n", .{ child, parent });
        self.unparentNode(child);
        const parent_node = self.nodes.get(parent) orelse return;
        const child_node = self.nodes.get(child) orelse return;
        child_node.parent = parent;
        parent_node.children.append(child) catch |err| {
            std.debug.print("Failed to append child to parent: {any}\n", .{err});
        };
    }

    pub fn loadGltf(self: *Engine, path: [:0]const u8) ![]Handle {
        const options = zcgltf.Options{};
        const data = try zcgltf.parseFile(options, path);
        defer zcgltf.free(data);
        if (data.buffers_count > 0) {
            try zcgltf.loadBuffers(options, data, path);
        }
        var ret = try self.allocator.alloc(Handle, data.nodes_count);
        const nodes = data.nodes orelse return ret;
        // DFS stack
        const DFSEntry = struct {
            idx: usize,
            parent: Handle,
        };
        var stack = std.ArrayList(DFSEntry).init(self.allocator);
        // mark leaf nodes
        var leafs = try std.DynamicBitSet.initEmpty(self.allocator, data.nodes_count);
        for (nodes[0..data.nodes_count]) |node| {
            const children = node.children orelse continue;
            for (children[0..node.children_count]) |child| {
                const base = @intFromPtr(nodes);
                const offset = @intFromPtr(child) - base;
                const i = offset / @sizeOf(zcgltf.Node);
                leafs.set(i);
            }
        }
        for(0..data.nodes_count) |i| {
            if (!leafs.isSet(i)) {
                try stack.append(DFSEntry{ .idx = i, .parent = self.scene.root });
            }
        }
        std.debug.print("DFS start\n", .{});
        while (stack.pop()) |item| {
            const handle = try self.processGltfNode(data, &nodes[item.idx], item.parent);
            self.parentNode(item.parent, handle);
            ret[item.idx] = handle;
            const children = nodes[item.idx].children orelse continue;
            for (0..nodes[item.idx].children_count) |i| {
                const base = @intFromPtr(nodes);
                const offset = @intFromPtr(children[i]) - base;
                const j = offset / @sizeOf(zcgltf.Node);
                try stack.append(DFSEntry { .idx = j, .parent = handle });
            }
        }
        return ret;
    }

    fn processGltfNode(self: *Engine, data: *zcgltf.Data, node: *zcgltf.Node, parent: Handle) !Handle {
        std.debug.print("Processing GLTF node {s} (parent handle: {d}) \n", .{node.name orelse "unknown", parent.index});
        if (node.parent) |parent_node| {
            std.debug.print("This node has parent node {s}\n", .{parent_node.name orelse "unknown"});
        }
        const handle = self.spawn().build();
        const engine_node = self.nodes.get(handle) orelse return handle;
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
            if (node.skin) |skin| {
                try self.processGltfSkinnedMesh(mesh, skin, handle, data);
            } else {
                try self.processGltfMesh(mesh, handle);
            }
        }
        // std.debug.print("Parenting node {d} to {d}\n", .{ handle.index, parent.index });

        return handle;
    }

    fn processGltfSkinnedMesh(self: *Engine, mesh: *zcgltf.Mesh, skin: *zcgltf.Skin, node: Handle, data: *zcgltf.Data) !void {
        std.debug.print("Processing GLTF skinned mesh with {d} primitives\n", .{mesh.primitives_count});
        for (mesh.primitives[0..mesh.primitives_count]) |*primitive| {
            try self.processSkinnedPrimitive(skin, primitive, node, data);
        }
    }

    fn processGltfMesh(self: *Engine, mesh: *zcgltf.Mesh, node: Handle) !void {
        std.debug.print("Processing GLTF mesh with {d} primitives\n", .{mesh.primitives_count});
        for (mesh.primitives[0..mesh.primitives_count]) |*primitive| {
            try self.processStaticPrimitive(primitive, node);
        }
    }

    fn processStaticPrimitive(self: *Engine, primitive: *zcgltf.Primitive, node: Handle) !void {
        const material_handle = self.makeMaterial().build();
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
        std.debug.print("Creating new static mesh...\n", .{});
        const mesh_handle = self.makeMesh()
            .withGeometry(Geometry.make(vertices.items, indices.items))
            .withMaterial(material_handle)
            .build();
        if (self.nodes.get(node)) |engine_node| {
            engine_node.data = .{ .static_mesh = mesh_handle };
        }
        try self.loadMaterialTextures(primitive, material);
    }

    fn processSkinnedPrimitive(self: *Engine, skin: *zcgltf.Skin, primitive: *zcgltf.Primitive, node: Handle, data: *zcgltf.Data) !void {
        const bones = try self.allocator.alloc(Bone, skin.joints_count);
        errdefer self.allocator.free(bones);
        var bone_lookup = std.AutoHashMap(*zcgltf.Node, u32).init(self.allocator);
        defer bone_lookup.deinit();
        var is_child = try std.DynamicBitSet.initEmpty(self.allocator, skin.joints_count);
        defer is_child.deinit();
        if (skin.inverse_bind_matrices) |matrices| {
            const inverse_matrices = try self.unpackAccessorFloats(16, matrices);
            defer self.allocator.free(inverse_matrices);
            for (inverse_matrices, skin.joints[0..skin.joints_count],0..) |matrix, joint, i| {
                try bone_lookup.put(joint, @intCast(i));
                bones[i].inverse_bind_matrix = zm.loadMat(&matrix);
                bones[i].bind_transform.position = zm.loadArr3(joint.translation);
                bones[i].bind_transform.rotation = zm.loadArr4(joint.rotation);
                bones[i].bind_transform.scale = zm.loadArr3(joint.scale);
                // std.debug.print("Load Bone {d}: Translation = {d}, Rotation = {d} inverse bind matrix = {d}\n", .{ i, bones[i].bind_transform.position, bones[i].bind_transform.rotation, bones[i].inverse_bind_matrix });
            }
        }
        // Second pass: setup children and transforms, track child bones
        for (skin.joints[0..skin.joints_count], 0..) |joint, i| {
            bones[i].children = try self.allocator.alloc(u32, joint.children_count);
            const children = joint.children orelse continue;
            for (children[0..joint.children_count], 0..) |child, j| {
                const idx = bone_lookup.get(child) orelse std.debug.panic("something went wrong bone {any} does not exist in the skin", .{child});
                bones[i].children[j] = idx;
                is_child.set(idx); // Mark this bone as being a child
            }
        }
        // Find the root bone (the one that isn't a child of any other bone)
        var root_bone: ?u16 = null;
        for (0..skin.joints_count) |i| {
            if (!is_child.isSet(@intCast(i))) {
                if (root_bone != null) {
                    std.debug.print("Warning: Multiple root bones found, using first one\n", .{});
                    continue;
                }
                root_bone = @intCast(i);
            }
        }
        // If no root was found (cyclic hierarchy), use bone 0 as root
        if (root_bone == null) {
            std.debug.print("Warning: No root bone found, using bone 0\n", .{});
            root_bone = 0;
        }
        const material_handle = self.makeSkinnedMaterial().build();
        var vertices = std.ArrayList(SkinnedVertex).init(self.allocator);
        defer vertices.deinit();
        var indices = std.ArrayList(u32).init(self.allocator);
        defer indices.deinit();
        const vertex_count = blk: {
            for (primitive.attributes[0..primitive.attributes_count]) |attribute| {
                if (attribute.type == .position) {
                    break :blk attribute.data.count;
                }
            }
            break :blk 0;
        };
        try vertices.resize(vertex_count);
        for (primitive.attributes[0..primitive.attributes_count]) |attribute| {
            const accessor = attribute.data;
            if (attribute.type == .position) {
                const positions = try self.unpackAccessorFloats(3, accessor);
                defer self.allocator.free(positions);
                for (positions, 0..) |pos, i| {
                    vertices.items[i].position = pos;
                }
            } else if (attribute.type == .normal) {
                const normals = try self.unpackAccessorFloats(3, accessor);
                defer self.allocator.free(normals);
                for (normals, 0..) |normal, i| {
                    vertices.items[i].normal = normal;
                }
            } else if (attribute.type == .texcoord) {
                const uvs = try self.unpackAccessorFloats(2, accessor);
                defer self.allocator.free(uvs);
                for (uvs, 0..) |uv, i| {
                    vertices.items[i].uv = .{ uv[0], uv[1] };
                }
            } else if (attribute.type == .joints) {
                const joints = try self.unpackAccessorUint(4, accessor);
                defer self.allocator.free(joints);
                for (joints, 0..) |joint, i| {
                    vertices.items[i].joints = joint;
                }
            } else if (attribute.type == .weights) {
                const weights = try self.unpackAccessorFloats(4, accessor);
                defer self.allocator.free(weights);
                for (weights, 0..) |weight, i| {
                    vertices.items[i].weights = weight;
                }
            }
        }
        if (primitive.indices) |accessor| {
            const index_count = accessor.count;
            try indices.resize(index_count);
            _ = accessor.unpackIndices(indices.items);
        }
        std.debug.print("Creating skeletal mesh\n", .{});
        const mesh_handle = self.makeSkeletalMesh()
            .withGeometry(SkinnedGeometry.make(vertices.items, indices.items))
            .withMaterial(material_handle)
            .build();
        if (self.skeletal_meshes.get(mesh_handle)) |mesh| {
            mesh.bones = bones;
            mesh.root_bone = root_bone.?;
        }
        // std.debug.print("Processing animations\n", .{});
        try self.processAnimationsForMesh(data, skin, mesh_handle);
        const engine_node = self.nodes.get(node).?;
        // std.debug.print("Setting up node data for skeletal mesh\n", .{});
        var pose: Pose = .{
            .allocator = self.allocator,
        };
        try pose.init(@intCast(skin.joints_count));
        engine_node.data = .{
            .skeletal_mesh = .{
                .handle = mesh_handle,
                .pose = pose,
            },
        };
        // std.debug.print("Loading material textures\n", .{});
        try self.loadMaterialTextures(primitive, self.skinned_materials.get(material_handle).?);
    }

    fn loadMaterialTextures(self: *Engine, primitive: *zcgltf.Primitive, material: anytype) !void {
        const mtl = primitive.material orelse return;
        const tex = mtl.pbr_metallic_roughness.base_color_texture.texture orelse return;
        const img = tex.image orelse return;
        if (img.uri) |uri| {
            const texture_data = try std.fs.cwd().readFileAlloc(self.allocator, std.mem.sliceTo(uri, 0), std.math.maxInt(usize));
            defer self.allocator.free(texture_data);
            const texture_handle = self.makeTexture()
                .fromData(texture_data)
                .build();
            const texture_ptr = self.textures.get(texture_handle).?;
            material.updateTextures(texture_ptr, texture_ptr, texture_ptr);
        } else if (img.buffer_view) |buffer_view| {
            const buffer = buffer_view.buffer;
            const offset = buffer_view.offset;
            const size = buffer_view.size;
            const data_ptr: [*]u8 = @ptrCast(buffer.data);
            const data = data_ptr[offset .. offset + size];
            const texture_handle = self.makeTexture()
                .fromData(data)
                .build();
            const texture_ptr = self.textures.get(texture_handle).?;
            material.updateTextures(texture_ptr, texture_ptr, texture_ptr);
        }
    }

    fn unpackAccessorUint(self: *Engine, comptime components: usize, accessor: *zcgltf.Accessor) ![][components]u32 {
        const count = accessor.count;
        // std.debug.print("Unpacking accessor with {d} elements, {d} components\n", .{ count, components });
        const result = try self.allocator.alloc([components]u32, count);
        for (0..count) |i| {
            const success = accessor.readUint(i, &result[i]);
            if (!success) {
                return error.InvalidAccessorData;
            }
        }
        return result;
    }

    fn unpackAccessorFloats(self: *Engine, comptime components: usize, accessor: *zcgltf.Accessor) ![][components]f32 {
        const count = accessor.count;
        const float_count = count * components;
        // std.debug.print("Unpacking accessor with {d} elements, {d} components ({d} total floats)\n", .{ count, components, float_count });
        const floats = try self.allocator.alloc(f32, float_count);
        defer self.allocator.free(floats);
        const unpacked_count = accessor.unpackFloats(floats);
        if (unpacked_count.len != count * components) {
            return error.InvalidAccessorData;
        }
        const result = try self.allocator.alloc([components]f32, count);
        // std.debug.print("Repackaging {d} floats into {d} vectors of size {d}\n", .{ float_count, count, components });
        for (0..count) |i| {
            for (0..components) |j| {
                result[i][j] = floats[i * components + j];
            }
        }
        return result;
    }

    // Original playAnimation with improved error handling
    pub fn playAnimation(self: *Engine, node: Handle, name: []const u8, mode: animation.PlayMode) !void {
        const node_ptr = self.nodes.get(node) orelse return error.InvalidNode;
        if (node_ptr.data != .skeletal_mesh) {
            return error.NotASkeletalMesh;
        }
        var skeletal_mesh_node = &node_ptr.data.skeletal_mesh;
        const mesh = self.skeletal_meshes.get(skeletal_mesh_node.handle) orelse return error.InvalidMesh;
        skeletal_mesh_node.animation = try mesh.playAnimation(name, mode);
    }

    pub fn pauseAnimation(self: *Engine, node: Handle) !void {
        const node_ptr = self.nodes.get(node) orelse return error.InvalidNode;
        if (node_ptr.data != .skeletal_mesh) {
            return error.NotASkeletalMesh;
        }
        if (node_ptr.data.skeletal_mesh.animation) |*anim| {
            anim.pause();
        }
    }

    pub fn resumeAnimation(self: *Engine, node: Handle) !void {
        const node_ptr = self.nodes.get(node) orelse return error.InvalidNode;
        if (node_ptr.data != .skeletal_mesh) {
            return error.NotASkeletalMesh;
        }
        if (node_ptr.data.skeletal_mesh.animation) |*anim| {
            anim.unpause();
        }
    }

    pub fn stopAnimation(self: *Engine, node: Handle) !void {
        const node_ptr = self.nodes.get(node) orelse return error.InvalidNode;
        if (node_ptr.data != .skeletal_mesh) {
            return error.NotASkeletalMesh;
        }
        if (node_ptr.data.skeletal_mesh.animation) |*anim| {
            anim.stop();
        }
    }

    fn processAnimationsForMesh(self: *Engine, data: *zcgltf.Data, skin: *zcgltf.Skin, mesh_handle: Handle) !void {
        // std.debug.print("Starting processAnimationsForMesh for mesh handle {d}\n", .{mesh_handle.index});
        const mesh = self.skeletal_meshes.get(mesh_handle) orelse {
            // std.debug.print("Error: Invalid mesh handle {d}\n", .{mesh_handle.index});
            return error.InvalidMesh;
        };
        if (data.animations_count == 0) {
            // std.debug.print("No animations found in GLTF data\n", .{});
            return;
        }
        // std.debug.print("Processing {d} animations\n", .{data.animations_count});
        const animations = data.animations.?[0..data.animations_count];
        var clips = try self.allocator.alloc(animation.Clip, data.animations_count);
        errdefer self.allocator.free(clips);
        // std.debug.print("Allocated space for {d} animation clips\n", .{data.animations_count});
        for (animations, 0..) |*gltf_anim, i| {
            // std.debug.print("Processing animation {d}/{d}\n", .{ i + 1, data.animations_count });
            var clip = &clips[i];
            if (std.mem.span(gltf_anim.name)) |name| {
                // std.debug.print("Animation name: {s}\n", .{name});
                clip.name = try self.allocator.dupe(u8, name);
            } else {
                // std.debug.print("Unnamed animation\n", .{});
                clip.name = try self.allocator.dupe(u8, "unnamed");
            }
            // std.debug.print("Allocating space for {d} bone channels\n", .{mesh.bones.len});
            clip.animations = try self.allocator.alloc(animation.Channel, mesh.bones.len);
            // Initialize all channels with empty arrays
            for (clip.animations) |*channel| {
                channel.position = &[_]animation.Keyframe(zm.Vec){};
                channel.rotation = &[_]animation.Keyframe(zm.Quat){};
                channel.scale = &[_]animation.Keyframe(zm.Vec){};
            }
            var max_time: f32 = 0;
            // std.debug.print("Processing {d} animation channels\n", .{gltf_anim.channels_count});
            // Process animation channels
            for (gltf_anim.channels[0..gltf_anim.channels_count], 0..) |*channel, chan_idx| {
                _ = chan_idx;
                // std.debug.print("Processing channel {d}/{d}\n", .{ chan_idx + 1, gltf_anim.channels_count });
                const target_node = channel.target_node orelse continue;
                const sampler = channel.sampler;
                const input_accessor = sampler.input;
                const output_accessor = sampler.output;
                // std.debug.print("Unpacking time values for channel {d}\n", .{chan_idx});
                const times = try self.unpackAccessorFloats(1, input_accessor);
                defer self.allocator.free(times);
                // Update max time if needed
                for (times) |time| {
                    if (time[0] > max_time) max_time = time[0];
                }
                const target_bone = std.mem.indexOfScalar(
                    *zcgltf.Node,
                    skin.joints[0..skin.joints_count],
                    target_node) orelse continue;
                switch (channel.target_path) {
                    .translation => {
                        // std.debug.print("Processing translation channel for bone {d}\n", .{target_bone.?});
                        const values = try self.unpackAccessorFloats(3, output_accessor);
                        defer self.allocator.free(values);
                        var keyframes = try self.allocator.alloc(animation.Keyframe(zm.Vec), times.len);
                        // std.debug.print("Creating {d} translation keyframes\n", .{times.len});
                        for (times, values, 0..) |time, value, j| {
                            keyframes[j] = .{
                                .time = time[0],
                                .value = zm.loadArr3w(value, 1.0),
                            };
                        }
                        clip.animations[target_bone].position = keyframes;
                    },
                    .rotation => {
                        // std.debug.print("Processing rotation channel for bone {d}\n", .{target_bone.?});
                        const values = try self.unpackAccessorFloats(4, output_accessor);
                        defer self.allocator.free(values);
                        var keyframes = try self.allocator.alloc(animation.Keyframe(zm.Quat), times.len);
                        // std.debug.print("Creating {d} rotation keyframes\n", .{times.len});
                        for (times, values, 0..) |time, value, j| {
                            keyframes[j] = .{
                                .time = time[0],
                                .value = zm.loadArr4(value),
                            };
                        }
                        clip.animations[target_bone].rotation = keyframes;
                    },
                    .scale => {
                        // std.debug.print("Processing scale channel for bone {d}\n", .{target_bone.?});
                        const values = try self.unpackAccessorFloats(3, output_accessor);
                        defer self.allocator.free(values);
                        var keyframes = try self.allocator.alloc(animation.Keyframe(zm.Vec), times.len);
                        // std.debug.print("Creating {d} scale keyframes\n", .{times.len});
                        for (times, values, 0..) |time, value, j| {
                            keyframes[j] = .{
                                .time = time[0],
                                .value = zm.loadArr3w(value, 1.0),
                            };
                        }
                        clip.animations[target_bone].scale = keyframes;
                    },
                    else => {
                        std.debug.print("Skipping unsupported animation channel type\n", .{});
                    },
                }
            }
            clip.duration = max_time;
            std.debug.print("Animation {d} completed. Duration: {d}s\n", .{ i, max_time });
        }
        mesh.animations = clips;
        std.debug.print("Successfully processed all animations for mesh {d}\n", .{mesh_handle.index});
    }
};

fn glfwErrorCallback(error_code: c_int, description: ?[*:0]const u8) callconv(.C) void {
    std.debug.print("GLFW error({x}): {s}\n", .{ error_code, description orelse "No description provided" });
}
