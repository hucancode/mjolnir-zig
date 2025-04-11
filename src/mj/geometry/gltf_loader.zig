const std = @import("std");
const zmesh = @import("zmesh");
const vk = @import("vulkan");
const zstbi = @import("zstbi");
const zm = @import("zmath");

const Engine = @import("../engine/engine.zig").Engine;
const Handle = @import("../engine/resource.zig").Handle;
const StaticMesh = @import("static_mesh.zig").StaticMesh;
const SkeletalMesh = @import("skeletal_mesh.zig").SkeletalMesh;
const Animation = @import("animation.zig").Animation;
const AnimationTrack = @import("animation.zig").AnimationTrack;
const PositionKeyframe = @import("animation.zig").PositionKeyframe;
const RotationKeyframe = @import("animation.zig").RotationKeyframe;
const ScaleKeyframe = @import("animation.zig").ScaleKeyframe;
const AnimationPlayMode = @import("animation.zig").AnimationPlayMode;
const AnimationStatus = @import("animation.zig").AnimationStatus;
const Node = @import("../scene/node.zig").Node;
const Vertex = @import("static_mesh.zig").Vertex;
const SkinnedVertex = @import("skeletal_mesh.zig").SkinnedVertex;

pub const GltfLoadOptions = struct {
    load_textures: bool = true,
    load_animations: bool = true,
    scale: f32 = 1.0,
};

pub const GltfModel = struct {
    root_node: Handle,
    mesh_nodes: []Handle,
    all_nodes: []Handle,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GltfModel) void {
        // Nodes are freed via the engine's resource pool
        self.allocator.free(self.mesh_nodes);
        self.allocator.free(self.all_nodes);
    }
};

/// Load a GLTF model file into the engine
pub fn loadGltfModel(engine: *Engine, filepath: [:0]const u8, default_material: Handle, options: GltfLoadOptions) !GltfModel {
    // Parse the GLTF file
    zmesh.init(engine.allocator);
    defer zmesh.deinit();

    var data = try zmesh.io.zcgltf.parseAndLoadFile(filepath);
    defer zmesh.io.zcgltf.freeData(data);

    std.debug.print("GLTF loaded, meshes: {d} accessors: {d} buffers: {d} images: {d} materials: {d}\n", .{data.meshes_count, data.accessors_count, data.buffers_count, data.images_count, data.materials_count});
    // Create model result
    var result = GltfModel{
        .root_node = undefined,
        .mesh_nodes = try engine.allocator.alloc(Handle, data.meshes_count),
        .all_nodes = try engine.allocator.alloc(Handle, data.nodes_count),
        .allocator = engine.allocator,
    };

    // Load textures first if needed
    var texture_handles = std.AutoHashMap(u32, Handle).init(engine.allocator);
    defer texture_handles.deinit();

    if (options.load_textures) {
        try loadTextures(engine, data, &texture_handles);
    }

    // Create materials for each GLTF material
    var material_handles = std.AutoHashMap(u32, Handle).init(engine.allocator);
    defer material_handles.deinit();

    try loadMaterials(engine, data, &material_handles, &texture_handles, default_material);

    // Create skeletal data structures
    var skin_handles = std.AutoHashMap(u32, []Handle).init(engine.allocator);
    defer {
        var it = skin_handles.iterator();
        while (it.next()) |entry| {
            engine.allocator.free(entry.value_ptr.*);
        }
        skin_handles.deinit();
    }

    // Load nodes first, without linking parent-child relationships
    var node_handles = try loadNodesFirst(engine, data, options);

    // Now load meshes
    try loadMeshes(engine, data, @ptrCast(&node_handles), @ptrCast(&material_handles), default_material, options);

    // Setup skins if any
    if (data.skins_count > 0) {
        try loadSkins(engine, data, @ptrCast(&node_handles), @ptrCast(&skin_handles));
    }

    // Setup node hierarchy
    try setupNodeHierarchy(engine, data, @ptrCast(&node_handles));

    // Load animations if requested
    if (options.load_animations and data.animations_count > 0) {
        try loadAnimations(engine, data, @ptrCast(&node_handles), @ptrCast(&skin_handles));
    }

    // Copy node handles to result
    for (node_handles, 0..) |handle, i| {
        result.all_nodes[i] = handle;
    }

    // Find the root node (should be the scene's root)
    if (data.scene) |scene| {
        if (scene.nodes_count > 0 and scene.nodes != null) {
            // Use the first scene node as the root
            const scene_node_idx = @intFromPtr(scene.nodes.?[0]) - @intFromPtr(data.nodes.?);
            result.root_node = node_handles[scene_node_idx / @sizeOf(zmesh.io.zcgltf.Node)];
        } else {
            // If no scene nodes, use the first node
            result.root_node = node_handles[0];
        }
    } else {
        // No scene defined, use the first node
        result.root_node = node_handles[0];
    }

    // Collect mesh nodes
    var mesh_node_count: usize = 0;
    for (data.nodes.?[0..data.nodes_count]) |node| {
        if (node.mesh != null) {
            mesh_node_count += 1;
        }
    }

    result.mesh_nodes = try engine.allocator.alloc(Handle, mesh_node_count);
    var mesh_idx: usize = 0;
    for (data.nodes.?[0..data.nodes_count], 0..) |node, i| {
        if (node.mesh != null) {
            result.mesh_nodes[mesh_idx] = node_handles[i];
            mesh_idx += 1;
        }
    }

    return result;
}

fn loadTextures(engine: *Engine, data: *zmesh.io.zcgltf.Data, texture_handles: *std.AutoHashMap(u32, Handle)) !void {
    if (data.textures_count == 0) return;

    zstbi.init(engine.allocator);
    defer zstbi.deinit();

    for (data.textures.?[0..data.textures_count], 0..) |texture, texture_idx| {
        if (texture.image) |image| {
            var img_data: []const u8 = undefined;
            var owned_img_data: ?[]u8 = null;
            defer if (owned_img_data) |buf| engine.allocator.free(buf);

            if (image.buffer_view) |buffer_view| {
                // Image data is in a buffer
                const buffer_data = @as([*]const u8, @ptrCast(buffer_view.buffer.data)) +
                                    buffer_view.offset;
                img_data = buffer_data[0..buffer_view.size];
            } else if (image.uri) |uri| {
                // Image data is in a URI (external file or data URI)
                const uri_str = std.mem.span(uri);
                if (std.mem.startsWith(u8, uri_str, "data:")) {
                    // Handle data URI
                    if (std.mem.indexOf(u8, uri_str, ";base64,")) |base64_start| {
                        const base64_data = uri_str[base64_start + 8..];
                        const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(base64_data);
                        owned_img_data = try engine.allocator.alloc(u8, decoded_size);
                        try std.base64.standard.Decoder.decode(owned_img_data.?, base64_data);
                        img_data = owned_img_data.?;
                    } else {
                        // Skip non-base64 data URIs
                        continue;
                    }
                } else {
                    // It's a relative file path - we would need the base path of the model
                    // For now, skip it as we don't have the path resolution mechanism
                    continue;
                }
            } else {
                continue; // Skip if no valid source
            }

            // Create texture from data
            var img = try zstbi.Image.loadFromMemory(img_data, 4); // Force 4 components (RGBA)
            defer img.deinit();

            // Create a texture from the loaded image
            const texture_handle = try engine.createTexture(img.data);
            try texture_handles.put(@intCast(texture_idx), texture_handle);
        }
    }
}

fn loadMaterials(
    engine: *Engine,
    data: *zmesh.io.zcgltf.Data,
    material_handles: *std.AutoHashMap(u32, Handle),
    texture_handles: *std.AutoHashMap(u32, Handle),
    default_material: Handle
) !void {
    if (data.materials_count == 0) return;

    for (data.materials.?[0..data.materials_count], 0..) |material, material_idx| {
        const mat_handle = try engine.createMaterial();
        const mat = engine.materials.get(mat_handle) orelse continue;

        // Setup textures if they exist
        var albedo_handle = default_material;
        var metallic_handle = default_material;
        var roughness_handle = default_material;

        if (material.has_pbr_metallic_roughness == 1) {
            const pbr = material.pbr_metallic_roughness;

            // Handle base color texture
            if (pbr.base_color_texture.texture) |texture| {
                const tex_idx = @intFromPtr(texture) - @intFromPtr(data.textures.?);
                const tex_idx_u32: u32 = @intCast(tex_idx / @sizeOf(zmesh.io.zcgltf.Texture));

                if (texture_handles.get(tex_idx_u32)) |handle| {
                    albedo_handle = handle;
                }
            }

            // Handle metallic/roughness texture
            if (pbr.metallic_roughness_texture.texture) |texture| {
                const tex_idx = @intFromPtr(texture) - @intFromPtr(data.textures.?);
                const tex_idx_u32: u32 = @intCast(tex_idx / @sizeOf(zmesh.io.zcgltf.Texture));

                if (texture_handles.get(tex_idx_u32)) |handle| {
                    metallic_handle = handle;
                    roughness_handle = handle; // Same texture in GLTF
                }
            }
        }

        // Update the material with textures
        if (engine.textures.get(albedo_handle) != null and
            engine.textures.get(metallic_handle) != null and
            engine.textures.get(roughness_handle) != null) {

            mat.updateTextures(
                &engine.context,
                engine.textures.get(albedo_handle).?,
                engine.textures.get(metallic_handle).?,
                engine.textures.get(roughness_handle).?
            );
        }

        try material_handles.put(@intCast(material_idx), mat_handle);
    }
}

fn loadNodesFirst(engine: *Engine, data: *zmesh.io.zcgltf.Data, options: GltfLoadOptions) ![]Handle {
    var node_handles = try engine.allocator.alloc(Handle, data.nodes_count);

    // First create all nodes without setting relationships
    for (data.nodes.?[0..data.nodes_count], 0..) |_, i| {
        node_handles[i] = engine.initNode();
    }

    // Set transform data for each node
    for (data.nodes.?[0..data.nodes_count], 0..) |node, i| {
        const handle = node_handles[i];
        if (engine.nodes.get(handle)) |engine_node| {

            // Handle node transform
            if (node.has_translation == 1) {
                engine_node.transform.position = .{
                    node.translation[0] * options.scale,
                    node.translation[1] * options.scale,
                    node.translation[2] * options.scale,
                    1.0
                };
            }

            if (node.has_rotation == 1) {
                engine_node.transform.rotation = .{
                    node.rotation[0],
                    node.rotation[1],
                    node.rotation[2],
                    node.rotation[3],
                };
            }

            if (node.has_scale == 1) {
                engine_node.transform.scale = .{
                    node.scale[0],
                    node.scale[1],
                    node.scale[2],
                    1.0,
                };
            }

            // If node has a matrix, use that instead
            if (node.has_matrix == 1) {
                var mat = zm.identity();
                for (0..4) |row| {
                    for (0..4) |col| {
                        mat[row][col] = node.matrix[row * 4 + col];
                    }
                }

                // TODO: Extract TRS from matrix
                // This would require decomposing the matrix into translation, rotation, scale
            }
        }
    }

    return node_handles;
}

fn loadMeshes(
    engine: *Engine,
    data: *zmesh.io.zcgltf.Data,
    node_handles: *[]Handle,
    material_handles: *std.AutoHashMap(u32, Handle),
    default_material: Handle,
    options: GltfLoadOptions
) !void {
    for (data.nodes.?[0..data.nodes_count], 0..) |node, node_idx| {
        if (node.mesh) |mesh| {
            const node_handle = node_handles.*[node_idx];
            const engine_node = engine.nodes.get(node_handle) orelse continue;
            _ = engine_node;

            const mesh_idx = @intFromPtr(mesh) - @intFromPtr(data.meshes.?);
            const mesh_idx_normalized = mesh_idx / @sizeOf(zmesh.io.zcgltf.Mesh);

            // Get the mesh data
            const gltf_mesh = data.meshes.?[mesh_idx_normalized];

            // See if this node has skin (skeletal mesh)
            const has_skin = node.skin != null;

            if (has_skin) {
                // Load as skeletal mesh
                try loadSkeletalMesh(engine, data, &gltf_mesh, @intCast(mesh_idx_normalized), node_handle, material_handles, default_material, options);
            } else {
                // Load as static mesh
                try loadStaticMesh(engine, data, &gltf_mesh, @intCast(mesh_idx_normalized), node_handle, material_handles, default_material, options);
            }
        }
    }
}

fn loadStaticMesh(
    engine: *Engine,
    data: *zmesh.io.zcgltf.Data,
    mesh: *const zmesh.io.zcgltf.Mesh,
    node_idx: u32,
    node_handle: Handle,
    material_handles: *std.AutoHashMap(u32, Handle),
    default_material: Handle,
    options: GltfLoadOptions
) !void {
    // For simplicity, we'll only load the first primitive
    if (mesh.primitives_count == 0) return;
    std.debug.print("name: {s}, primitives {d}, weights {d}\n", .{mesh.name orelse "unknown", mesh.primitives_count, mesh.weights_count});

    // Get primitive data
    const primitive = mesh.primitives[0];
    const material_handle = default_material;
    if (primitive.material) |material| {
        const material_idx = @intFromPtr(material) - @intFromPtr(data.materials.?);
        const material_idx_u32: u32 = @intCast(material_idx / @sizeOf(zmesh.io.zcgltf.Material));
        if (material_handles.get(material_idx_u32)) |handle| {
            _ = handle;
        }
    }
    var indices = std.ArrayList(u32).init(engine.allocator);
    defer indices.deinit();
    var positions = std.ArrayList([3]f32).init(engine.allocator);
    defer positions.deinit();
    var normals = std.ArrayList([3]f32).init(engine.allocator);
    defer normals.deinit();
    var uvs = std.ArrayList([2]f32).init(engine.allocator);
    defer uvs.deinit();

    try zmesh.io.zcgltf.appendMeshPrimitive(
        data,
        node_idx,
        0,
        &indices,
        &positions,
        &normals,
        &uvs,
        null
    );

    var vertices = std.ArrayList(Vertex).init(engine.allocator);
    defer vertices.deinit();
    for (positions.items, normals.items, uvs.items) |position, normal, uv| {
        vertices.append(Vertex{
            .position = .{
                position[0] * options.scale,
                position[1] * options.scale,
                position[2] * options.scale
            },
            .normal = normal,
            .color = .{ 1.0, 1.0, 1.0, 1.0 },
            .uv = uv
        }) catch return error.OutOfMemory;
    }

    // Create the static mesh
    const mesh_handle = engine.meshes.malloc();
    const engine_mesh = engine.meshes.get(mesh_handle).?;

    try engine_mesh.buildMesh(
        &engine.context,
        vertices.items,
        indices.items,
        material_handle
    );

    // Set the node type to mesh
    const engine_node = engine.nodes.get(node_handle) orelse return;
    engine_node.data = .{ .static_mesh = mesh_handle };
}

fn loadSkeletalMesh(
    engine: *Engine,
    data: *zmesh.io.zcgltf.Data,
    mesh: *const zmesh.io.zcgltf.Mesh,
    node_idx: u32,
    node_handle: Handle,
    material_handles: *std.AutoHashMap(u32, Handle),
    default_material: Handle,
    options: GltfLoadOptions
) !void {
    // TODO: Implement skeletal mesh loading
    // This is more complex and requires handling skin data, joints, etc.
    // For now, we'll load it as a static mesh
    try loadStaticMesh(engine, data, mesh, node_idx, node_handle, material_handles, default_material, options);
}

fn loadSkins(
    engine: *Engine,
    data: *zmesh.io.zcgltf.Data,
    node_handles: *[]const Handle,
    skin_handles: *std.AutoHashMap(u32, []Handle)
) !void {
    if (data.skins_count == 0) return;

    for (data.skins.?[0..data.skins_count], 0..) |skin, skin_idx| {
        // Collect joint nodes
        var joints = try engine.allocator.alloc(Handle, skin.joints_count);

        for (0..skin.joints_count) |i| {
            const joint_node = skin.joints[i];
            const joint_idx = @intFromPtr(joint_node) - @intFromPtr(data.nodes.?);
            const joint_idx_normalized = joint_idx / @sizeOf(zmesh.io.zcgltf.Node);

            joints[i] = node_handles.*[joint_idx_normalized];
        }

        try skin_handles.put(@intCast(skin_idx), joints);
    }
}

fn setupNodeHierarchy(
    engine: *Engine,
    data: *zmesh.io.zcgltf.Data,
    node_handles: *[]const Handle
) !void {
    // Set parent-child relationships for nodes
    for (data.nodes.?[0..data.nodes_count], 0..) |node, node_idx| {
        if (node.children_count > 0 and node.children != null) {
            const parent_handle = node_handles.*[node_idx];

            for (0..node.children_count) |i| {
                const child_node = node.children.?[i];
                const child_idx = @intFromPtr(child_node) - @intFromPtr(data.nodes.?);
                const child_idx_normalized = child_idx / @sizeOf(zmesh.io.zcgltf.Node);

                const child_handle = node_handles.*[child_idx_normalized];

                // Set parent-child relationship
                engine.parentNode(parent_handle, child_handle);
            }
        }
    }
}

fn loadAnimations(
    engine: *Engine,
    data: *zmesh.io.zcgltf.Data,
    node_handles: *[]const Handle,
    skin_handles: *std.AutoHashMap(u32, []Handle)
) !void {
    _ = skin_handles;
    // Animation loading is complex, implementing a simplified version
    for (data.animations.?[0..data.animations_count], 0..) |animation, anim_idx| {
        const anim_name = if (animation.name) |name|
            std.mem.span(name)
        else
            try std.fmt.allocPrint(engine.allocator, "Animation_{d}", .{anim_idx});
        defer if (animation.name == null) engine.allocator.free(anim_name);

        // For each channel in the animation
        for (0..animation.channels_count) |channel_idx| {
            const channel = animation.channels[channel_idx];

            if (channel.target_node) |target_node| {
                const node_idx = @intFromPtr(target_node) - @intFromPtr(data.nodes.?);
                const node_idx_normalized = node_idx / @sizeOf(zmesh.io.zcgltf.Node);

                const target_handle = node_handles.*[node_idx_normalized];
                const target_engine_node = engine.nodes.get(target_handle) orelse continue;
                _ = target_engine_node;
                // TODO: Process animation channels into keyframes for the node

                // This is quite involved and would need to:
                // 1. Read the input accessor (timestamps)
                // 2. Read the output accessor (transform data)
                // 3. Create the appropriate keyframes for position, rotation, or scale
                // 4. Set up the animation on the target node
            }
        }
    }
}
