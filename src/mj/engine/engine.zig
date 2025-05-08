const std = @import("std");
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;
const ArrayList = std.ArrayList;

const glfw = @import("zglfw");
const vk = @import("vulkan");
const zcgltf = @import("zmesh").io.zcgltf;
const zm = @import("zmath");
const zstbi = @import("zstbi");
const zgui = @import("zgui");
const context = @import("context.zig").get();
const PlayMode = @import("../geometry/animation.zig").PlayMode;
const SkeletalMesh = @import("../geometry/skeletal_mesh.zig").SkeletalMesh;
const StaticMesh = @import("../geometry/static_mesh.zig").StaticMesh;
const Material = @import("../material/pbr.zig").Material;
const Aabb = @import("../geometry/geometry.zig").Aabb; // Added
const Frustum = @import("../scene/frustum.zig").Frustum; // Added
const testAabbFrustum = @import("../scene/frustum.zig").testAabbFrustum; // Added
const transformAabb = @import("../scene/frustum.zig").transformAabb; // Added
const SkinnedMaterial = @import("../material/skinned_pbr.zig").SkinnedMaterial;
const Texture = @import("../material/texture.zig").Texture;
const createDepthImage = @import("../material/texture.zig").createDepthImage;
const Light = @import("../scene/light.zig").Light;
const Node = @import("../scene/node.zig").Node;
const Transform = @import("../scene/node.zig").Transform;
const Scene = @import("../scene/scene.zig").Scene;
const Handle = @import("resource.zig").Handle;
const LightUniform = @import("renderer.zig").SingleLightUniform;
const MAX_LIGHTS = @import("renderer.zig").MAX_LIGHTS;
const MAX_SHADOW_MAPS = @import("renderer.zig").MAX_SHADOW_MAPS;
const QueueFamilyIndices = @import("context.zig").QueueFamilyIndices;
const Renderer = @import("renderer.zig").Renderer;
const ResourcePool = @import("resource.zig").ResourcePool;
const SceneUniform = @import("renderer.zig").SceneUniform;
const SceneLightUniform = @import("renderer.zig").SceneLightUniform;
const SwapchainSupport = @import("context.zig").SwapchainSupport;
const TextureBuilder = @import("builder.zig").TextureBuilder;
const MaterialBuilder = @import("builder.zig").MaterialBuilder;
const SkinnedMaterialBuilder = @import("builder.zig").SkinnedMaterialBuilder;
const MeshBuilder = @import("builder.zig").MeshBuilder;
const SkeletalMeshBuilder = @import("builder.zig").SkeletalMeshBuilder;
const NodeBuilder = @import("builder.zig").NodeBuilder;
const GLTFLoader = @import("../loader/gltf.zig").GLTFLoader;
const ImGui = @import("gui.zig").ImGui;

const RENDER_FPS = 60.0;
const FRAME_TIME = 1.0 / RENDER_FPS;
const FRAME_TIME_NANO: u64 = @intFromFloat(FRAME_TIME * 1_000_000_000.0);
const UPDATE_FPS = 60.0;
const UPDATE_FRAME_TIME = 1.0 / UPDATE_FPS;
const UPDATE_FRAME_TIME_NANO: u64 = @intFromFloat(UPDATE_FRAME_TIME * 1_000_000_000.0);

// Helper struct for collecting lights during scene traversal
const CollectLightsContext = struct {
    engine: *Engine,
    light_uniform: *SceneLightUniform,
};

// Helper struct for rendering main scene meshes
const RenderMeshesContext = struct {
    engine: *Engine,
    command_buffer: vk.CommandBuffer,
    camera_frustum: Frustum,
    rendered_count: *u32,
    scene_descriptor_set: vk.DescriptorSet,
};

// Helper struct for rendering shadow map meshes
const ShadowRenderContext = struct {
    engine: *Engine,
    command_buffer: vk.CommandBuffer,
    obstacles_count: *u32,
};

pub const Engine = struct {
    window: *glfw.Window,
    renderer: Renderer,
    scene: Scene,
    gui: ImGui,
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

    // New generic scene traversal method
    fn traverseScene(
        self: *Engine,
        root_node_handle: Handle,
        initial_parent_matrix: zm.Mat,
        comptime ContextType: type,
        user_context: *ContextType,
        comptime callback: fn (
            engine: *Engine,
            node: *const Node,
            world_matrix: zm.Mat,
            user_context: *ContextType,
        ) anyerror!void,
    ) !void {
        var node_stack = ArrayList(Handle).init(self.allocator);
        defer node_stack.deinit();
        var transform_stack = ArrayList(zm.Mat).init(self.allocator);
        defer transform_stack.deinit();

        try node_stack.append(root_node_handle);
        try transform_stack.append(initial_parent_matrix);

        while (node_stack.pop()) |current_node_handle| {
            const current_node = self.nodes.get(current_node_handle) orelse continue;
            const parent_world_matrix = transform_stack.pop() orelse zm.identity(); // Should always have a matrix from the stack

            const local_matrix = current_node.transform.toMatrix();
            const world_matrix = zm.mul(local_matrix, parent_world_matrix);

            try callback(self, current_node, world_matrix, user_context);

            for (current_node.children.items) |child_handle| {
                try node_stack.append(child_handle);
                try transform_stack.append(world_matrix); // Children inherit the current node's world matrix as their parent matrix
            }
        }
    }

    fn collectLightsCallback(
        engine: *Engine,
        node: *const Node,
        world_matrix: zm.Mat,
        ctx: *CollectLightsContext,
    ) !void {
        if (node.data == .light) {
            const light_h = node.data.light;
            const light_ptr = engine.lights.get(light_h) orelse return;
            var uniform = LightUniform{
                .color = light_ptr.color,
                .radius = light_ptr.radius,
                .has_shadow = if (light_ptr.cast_shadow) 1 else 0,
            };
            switch (light_ptr.data) {
                .point => {
                    uniform.kind = 0;
                    uniform.position = zm.mul(zm.f32x4(0.0, 0.0, 0.0, 1.0), world_matrix);
                },
                .directional => {
                    uniform.kind = 1;
                    // For directional lights, position is part of the light node's world_matrix,
                    // but the uniform typically expects a direction.
                    // The direction is often fixed or derived from the node's orientation.
                    uniform.position = zm.mul(zm.f32x4(0.0, 0.0, 0.0, 1.0), world_matrix); // Store light position
                    uniform.direction = zm.normalize3(zm.mul(zm.f32x4(0.0, 0.0, 1.0, 0.0), world_matrix));
                },
                .spot => |angle_data| {
                    uniform.kind = 2;
                    uniform.angle = angle_data;
                    uniform.position = zm.mul(zm.f32x4(0.0, 0.0, 0.0, 1.0), world_matrix);
                    // Not sure why but if I use -Y direction (0, -1, 0) the shadow will stop working
                    // TODO: investigate this
                    uniform.direction = zm.normalize3(zm.mul(zm.f32x4(0.0, -1.0, 0.01, 0.0), world_matrix));
                },
            }
            ctx.light_uniform.pushLight(uniform);
        }
    }

    fn renderSceneNodeCallback(
        engine: *Engine,
        node: *const Node,
        world_matrix: zm.Mat,
        ctx: *RenderMeshesContext,
    ) !void {
        const vkd = context.vkd;
        switch (node.data) {
            .skeletal_mesh => |*skeletal_mesh_data| {
                const mesh = engine.skeletal_meshes.get(skeletal_mesh_data.handle) orelse return;
                const material = engine.skinned_materials.get(mesh.material) orelse return;

                const world_aabb = transformAabb(mesh.aabb, world_matrix);
                if (!testAabbFrustum(world_aabb.min, world_aabb.max, ctx.camera_frustum)) {
                    return;
                }

                const descriptor_sets = [_]vk.DescriptorSet{
                    ctx.scene_descriptor_set,
                    material.descriptor_set,
                };
                material.updateBoneBuffer(skeletal_mesh_data.pose.bone_buffer.buffer, skeletal_mesh_data.pose.bone_buffer.size);
                vkd.cmdBindPipeline(ctx.command_buffer, .graphics, material.pipeline);
                vkd.cmdBindDescriptorSets(ctx.command_buffer, .graphics, material.pipeline_layout, 0, descriptor_sets.len, &descriptor_sets, 0, undefined);
                vkd.cmdPushConstants(ctx.command_buffer, material.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(zm.Mat), &world_matrix);
                const offset: vk.DeviceSize = 0;
                vkd.cmdBindVertexBuffers(ctx.command_buffer, 0, 1, @ptrCast(&mesh.vertex_buffer.buffer), @ptrCast(&offset));
                vkd.cmdBindIndexBuffer(ctx.command_buffer, mesh.index_buffer.buffer, 0, .uint32);
                vkd.cmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0);
                ctx.*.rendered_count.* += 1;
            },
            .static_mesh => |mesh_handle_data| {
                const mesh = engine.meshes.get(mesh_handle_data) orelse return;
                const material = engine.materials.get(mesh.material) orelse return;

                const world_aabb = transformAabb(mesh.aabb, world_matrix);
                if (!testAabbFrustum(world_aabb.min, world_aabb.max, ctx.camera_frustum)) {
                    return;
                }

                vkd.cmdBindPipeline(ctx.command_buffer, .graphics, material.pipeline);
                const descriptor_sets = [_]vk.DescriptorSet{
                    ctx.scene_descriptor_set,
                    material.descriptor_set,
                };
                vkd.cmdBindDescriptorSets(ctx.command_buffer, .graphics, material.pipeline_layout, 0, descriptor_sets.len, &descriptor_sets, 0, undefined);
                vkd.cmdPushConstants(ctx.command_buffer, material.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(zm.Mat), &world_matrix);
                const offset: vk.DeviceSize = 0;
                vkd.cmdBindVertexBuffers(ctx.command_buffer, 0, 1, @ptrCast(&mesh.vertex_buffer.buffer), @ptrCast(&offset));
                vkd.cmdBindIndexBuffer(ctx.command_buffer, mesh.index_buffer.buffer, 0, .uint32);
                vkd.cmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0);
                ctx.*.rendered_count.* += 1;
            },
            else => {},
        }
    }

    fn renderShadowNodeCallback(
        engine: *Engine,
        node: *const Node,
        world_matrix: zm.Mat,
        ctx: *ShadowRenderContext,
    ) !void {
        const vkd = context.vkd;
        const shadow_pass_material = &engine.renderer.shadow_pass_material;
        switch (node.data) {
            .static_mesh => |mesh_h| {
                const mesh = engine.meshes.get(mesh_h) orelse return;
                vkd.cmdPushConstants(ctx.command_buffer, shadow_pass_material.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(zm.Mat), &world_matrix);
                const offset: vk.DeviceSize = 0;
                vkd.cmdBindVertexBuffers(ctx.command_buffer, 0, 1, @ptrCast(&mesh.simple_vertex_buffer.buffer), @ptrCast(&offset));
                vkd.cmdBindIndexBuffer(ctx.command_buffer, mesh.index_buffer.buffer, 0, .uint32);
                vkd.cmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0);
                ctx.*.obstacles_count.* += 1;
            },
            .skeletal_mesh => |*sk_mesh_data| {
                const mesh = engine.skeletal_meshes.get(sk_mesh_data.handle) orelse return;
                vkd.cmdPushConstants(ctx.command_buffer, shadow_pass_material.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(zm.Mat), &world_matrix);
                const offset: vk.DeviceSize = 0;
                vkd.cmdBindVertexBuffers(ctx.command_buffer, 0, 1, @ptrCast(&mesh.simple_vertex_buffer.buffer), @ptrCast(&offset));
                vkd.cmdBindIndexBuffer(ctx.command_buffer, mesh.index_buffer.buffer, 0, .uint32);
                vkd.cmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0);
                ctx.*.obstacles_count.* += 1;
            },
            else => {},
        }
    }

    pub fn beginTransaction(self: *Engine) void {
        self.in_transaction = true;
    }

    pub fn commitTransaction(self: *Engine) void {
        self.in_transaction = false;
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
        try self.gui.init(self);
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
        try self.renderer.init(self.allocator);
        try self.renderer.buildSwapchain(support.capabilities, support.formats, support.present_modes, indices.graphics_family, indices.present_family);
        try self.renderer.buildCommandBuffers();
        try self.renderer.buildSynchronizers();
        self.renderer.depth_buffer = try createDepthImage(self.renderer.extent.width, self.renderer.extent.height);
    }

    pub fn tryRender(self: *Engine) !void {
        const now = try Instant.now();
        const elapsed_seconds = @as(f64, @floatFromInt(now.since(self.start_timestamp))) / 1000_000_000.0;
        var scene_uniform = SceneUniform{
            .view = self.scene.viewMatrix(),
            .projection = self.scene.projectionMatrix(),
        };
        var light_uniform = SceneLightUniform{};
        scene_uniform.time = @floatCast(elapsed_seconds);

        const camera_frustum = self.scene.getCameraFrustum(true);

        // Collect lights
        var collect_lights_ctx = CollectLightsContext{
            .engine = self,
            .light_uniform = &light_uniform,
        };
        try self.traverseScene(self.scene.root, zm.identity(), CollectLightsContext, &collect_lights_ctx, collectLightsCallback);
        std.debug.print("Collected {d} lights\n", .{light_uniform.light_count});

        const command_buffer = self.renderer.getCommandBuffer();
        try self.renderShadowMaps(&light_uniform, command_buffer);
        const image_idx = try self.renderer.begin();

        var rendered_count: u32 = 0;
        var render_meshes_ctx = RenderMeshesContext{
            .engine = self,
            .command_buffer = command_buffer,
            .camera_frustum = camera_frustum,
            .rendered_count = &rendered_count,
            .scene_descriptor_set = self.renderer.getSceneDescriptorSet(),
        };
        try self.traverseScene(self.scene.root, zm.identity(), RenderMeshesContext, &render_meshes_ctx, renderSceneNodeCallback);

        self.renderer.getSceneUniform().write(std.mem.asBytes(&scene_uniform));
        self.renderer.getLightUniform().write(std.mem.asBytes(&light_uniform));
        zgui.backend.newFrame(self.renderer.extent.width, self.renderer.extent.height);
        _ = zgui.DockSpaceOverViewport(0, zgui.getMainViewport(), .{ .passthru_central_node = true });
        var showdemo = true;
        zgui.showDemoWindow(&showdemo);
        _ = zgui.begin("Scene", .{});
        zgui.text("Rendered {d} objects", .{rendered_count});
        zgui.end();
        zgui.backend.render(@intFromEnum(command_buffer));
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

    pub fn renderShadowMaps(self: *Engine, light_uniform: *SceneLightUniform, command_buffer: vk.CommandBuffer) !void {
        var total_obstacles_rendered_in_shadows: u32 = 0; // To sum up obstacles from all shadow maps
        for (0..light_uniform.light_count) |i| {
            var light = &light_uniform.lights[i]; // Get mutable light to store view_proj
            if (light.has_shadow == 0 or i >= MAX_SHADOW_MAPS) continue;
            const shadow_map = self.renderer.getShadowMap(@intCast(i));

            // Calculate light's view-projection matrix
            if (light.kind == 0) { // Point light
                const light_pos = light.position;
                const look_dir = zm.f32x4(0.0, -1.0, 0.0, 0.0);
                const up_dir = zm.f32x4(0.0, 1.0, 0.0, 0.0);
                const light_view = zm.lookToLh(light_pos, look_dir, up_dir);
                const fov = std.math.pi / 2.0;
                const aspect = 1.0;
                const near = 0.1;
                const far = light.radius;
                const light_proj = zm.perspectiveFovLh(fov, aspect, near, far);
                light.view_proj = zm.mul(light_view, light_proj);
            } else if (light.kind == 1) { // Directional light
                const light_dir = light.direction;
                const light_pos = light.position;
                const up_dir = zm.f32x4(0.0, 1.0, 0.0, 0.0);
                const light_view = zm.lookToLh(light_pos, light_dir, up_dir);
                const light_proj = zm.orthographicLh(20.0, 20.0, 0.1, light.radius); // Consider making ortho size configurable
                light.view_proj = zm.mul(light_view, light_proj);
            } else if (light.kind == 2) { // Spot light
                const light_pos = light.position;
                const light_dir = light.direction;
                const up_dir = zm.f32x4(0.0, 1.0, 0.0, 0.0);
                const light_view = zm.lookToLh(light_pos, light_dir, up_dir);
                const fov = light.angle * 2.0;
                const aspect = 1.0;
                const near = 0.1;
                const far = light.radius;
                const light_proj = zm.perspectiveFovLh(fov, aspect, near, far);
                light.view_proj = zm.mul(light_view, light_proj);
            } else {
                continue;
            }

            // This command buffer is the main command buffer from tryRender,
            // it should be reset and begun for each shadow pass if we are re-using it.
            // However, the original code implies the command_buffer passed in is ready.
            // For shadow passes, it's common to use a dedicated command buffer or re-record.
            // The original code resets and begins the command buffer *inside* this loop.
            // This is fine if the command_buffer is submitted and waited on per light.

            try context.*.vkd.resetCommandBuffer(command_buffer, .{});
            try context.*.vkd.beginCommandBuffer(command_buffer, &.{
                .flags = .{ .one_time_submit_bit = true },
            });

            // Transition image layout to depth attachment optimal
            const initial_barrier = vk.ImageMemoryBarrier{
                .old_layout = .undefined,
                .new_layout = .depth_stencil_attachment_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = shadow_map.*.buffer.image,
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

            context.*.vkd.cmdPipelineBarrier(
                command_buffer,
                .{ .top_of_pipe_bit = true },
                .{ .early_fragment_tests_bit = true },
                .{},
                0,
                null,
                0,
                null,
                1,
                @ptrCast(&initial_barrier),
            );

            const depth_attachment = vk.RenderingAttachmentInfoKHR{
                .image_view = shadow_map.*.buffer.view,
                .image_layout = .depth_stencil_attachment_optimal,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{
                    .depth_stencil = .{
                        .depth = 1.0,
                        .stencil = 0,
                    },
                },
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
            };
            const render_info = vk.RenderingInfoKHR{
                .render_area = .{
                    .offset = .{ .x = 0, .y = 0 },
                    .extent = .{
                        .width = shadow_map.*.buffer.width,
                        .height = shadow_map.*.buffer.height,
                    },
                },
                .layer_count = 1,
                .view_mask = 0,
                .p_depth_attachment = @ptrCast(&depth_attachment),
            };
            context.*.vkd.cmdBeginRenderingKHR(command_buffer, &render_info);
            const viewport = vk.Viewport{
                .x = 0.0,
                .y = 0.0,
                .width = @floatFromInt(shadow_map.*.buffer.width),
                .height = @floatFromInt(shadow_map.*.buffer.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
            };
            const scissor = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{
                    .width = shadow_map.*.buffer.width,
                    .height = shadow_map.*.buffer.height,
                },
            };
            context.*.vkd.cmdSetViewport(command_buffer, 0, 1, @ptrCast(&viewport));
            context.*.vkd.cmdSetScissor(command_buffer, 0, 1, @ptrCast(&scissor));
            context.*.vkd.cmdBindPipeline(command_buffer, .graphics, self.renderer.shadow_pass_material.pipeline);
            context.*.vkd.cmdBindDescriptorSets(
                command_buffer,
                .graphics,
                self.renderer.shadow_pass_material.pipeline_layout,
                0,
                1,
                @ptrCast(&self.renderer.getShadowDescriptorSet()), // This set should contain the light's view_proj
                0,
                null,
            );
            // Update the uniform buffer that the shadow descriptor set points to
            self.renderer.getLightViewProjUniform().write(std.mem.asBytes(&light.view_proj));

            var obstacles_for_this_light: u32 = 0;
            var shadow_render_ctx = ShadowRenderContext{
                .engine = self,
                .command_buffer = command_buffer,
                .obstacles_count = &obstacles_for_this_light,
            };
            try self.traverseScene(self.scene.root, zm.identity(), ShadowRenderContext, &shadow_render_ctx, renderShadowNodeCallback);
            total_obstacles_rendered_in_shadows += obstacles_for_this_light;
            std.debug.print("Rendered {d} obstacles in shadow map\n", .{obstacles_for_this_light});

            context.*.vkd.cmdEndRenderingKHR(command_buffer);

            // Transition image layout to shader read optimal for sampling in main pass
            const final_barrier = vk.ImageMemoryBarrier{
                .old_layout = .depth_stencil_attachment_optimal,
                .new_layout = .shader_read_only_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = shadow_map.*.buffer.image,
                .subresource_range = .{
                    .aspect_mask = .{ .depth_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .src_access_mask = .{ .depth_stencil_attachment_write_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true }, // Access mask for shader reading
            };
            context.*.vkd.cmdPipelineBarrier(command_buffer, .{ .late_fragment_tests_bit = true }, // Source stage: depth/stencil writes must complete
                .{ .fragment_shader_bit = true }, // Destination stage: fragment shader will read
                .{}, // No dependency flags
                0, null, // No memory barriers
                0, null, // No buffer memory barriers
                1, @ptrCast(&final_barrier) // The image memory barrier
            );

            try context.*.vkd.endCommandBuffer(command_buffer);
            const wait_stage = vk.PipelineStageFlags{ .top_of_pipe_bit = true };
            const submit_info = vk.SubmitInfo{
                .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
                .command_buffer_count = 1,
                .p_command_buffers = @ptrCast(&command_buffer),
            };
            try context.*.vkd.queueSubmit(context.*.graphics_queue, 1, @ptrCast(&submit_info), .null_handle);
            try context.*.vkd.deviceWaitIdle(); // Wait for each shadow map to complete
        }
        // Optionally log total_obstacles_rendered_in_shadows if needed for debugging
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
        const builder = self.allocator.create(SkinnedMaterialBuilder) catch unreachable;
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
    pub fn playAnimation(self: *Engine, node: Handle, name: []const u8, mode: PlayMode) !void {
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
