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
const StaticMesh = @import("../geometry/static_mesh.zig").StaticMesh;
const Material = @import("../material/pbr.zig").Material;
const SkinnedMaterial = @import("../material/skinned_pbr.zig").SkinnedMaterial;
const Texture = @import("../material/texture.zig").Texture;
const createDepthImage = @import("../material/texture.zig").createDepthImage;
const Light = @import("../scene/light.zig").Light;
const Node = @import("../scene/node.zig").Node;
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
const TextureBuilder = @import("builder.zig").TextureBuilder;
const MaterialBuilder = @import("builder.zig").MaterialBuilder;
const SkinnedMaterialBuilder = @import("builder.zig").SkinnedMaterialBuilder;
const MeshBuilder = @import("builder.zig").MeshBuilder;
const SkeletalMeshBuilder = @import("builder.zig").SkeletalMeshBuilder;
const NodeBuilder = @import("builder.zig").NodeBuilder;
const GLTFLoader = @import("../loader/gltf.zig").GLTFLoader;

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

    pub fn loadGltf(self: *Engine) *GLTFLoader {
        const loader = self.allocator.create(GLTFLoader) catch unreachable;
        loader.init(self);
        return loader;
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
        self.unparentNode(child);
        const parent_node = self.nodes.get(parent) orelse return;
        const child_node = self.nodes.get(child) orelse return;
        child_node.parent = parent;
        parent_node.children.append(child) catch |err| {
            std.debug.print("Failed to append child to parent: {any}\n", .{err});
        };
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
};

fn glfwErrorCallback(error_code: c_int, description: ?[*:0]const u8) callconv(.C) void {
    std.debug.print("GLFW error({x}): {s}\n", .{ error_code, description orelse "No description provided" });
}
