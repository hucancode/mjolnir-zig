const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const DynamicBitSet = std.DynamicBitSet;
const HashMap = std.AutoHashMap;
const zcgltf = @import("zmesh").io.zcgltf;
const zm = @import("zmath");
const animation = @import("../geometry/animation.zig");
const Engine = @import("../engine/engine.zig").Engine;
const Handle = @import("../engine/resource.zig").Handle;
const Bone = @import("../geometry/skeletal_mesh.zig").Bone;
const SkinnedVertex = @import("../geometry/geometry.zig").SkinnedVertex;
const Vertex = @import("../geometry/geometry.zig").Vertex;
const SkinnedGeometry = @import("../geometry/geometry.zig").SkinnedGeometry;
const Geometry = @import("../geometry/geometry.zig").Geometry;

pub const GLTFLoader = struct {
    engine: *Engine,
    path: [:0]const u8,
    allocator: Allocator,

    pub fn init(self: *GLTFLoader, engine: *Engine) void {
        self.engine = engine;
        self.allocator = engine.allocator;
    }

    pub fn withPath(self: *GLTFLoader, path: [:0]const u8) *GLTFLoader {
        self.path = path;
        return self;
    }

    pub fn submit(self: *GLTFLoader) ![]Handle {
        defer self.allocator.destroy(self);
        const options = zcgltf.Options{};
        const data = try zcgltf.parseFile(options, self.path);
        defer zcgltf.free(data);
        if (data.buffers_count > 0) {
            try zcgltf.loadBuffers(options, data, self.path);
        }
        var ret = ArrayList(Handle).init(self.allocator);
        const nodes = data.nodes orelse return ret.toOwnedSlice();
        const TraverseEntry = struct {
            idx: usize,
            parent: Handle,
        };
        var stack = ArrayList(TraverseEntry).init(self.allocator);
        defer stack.deinit();
        // mark leaf nodes
        var leafs = try DynamicBitSet.initEmpty(self.allocator, data.nodes_count);
        defer leafs.deinit();
        for (nodes[0..data.nodes_count]) |node| {
            const children = node.children orelse continue;
            for (children[0..node.children_count]) |child| {
                const base = @intFromPtr(nodes);
                const pos = @intFromPtr(child);
                const i = (pos - base) / @sizeOf(zcgltf.Node);
                leafs.set(i);
            }
        }
        for (0..data.nodes_count) |i| {
            if (!leafs.isSet(i)) {
                try stack.append(TraverseEntry{ .idx = i, .parent = self.engine.scene.root });
            }
        }
        while (stack.pop()) |item| {
            const handle = try self.processGltfNode(data, &nodes[item.idx], item.parent);
            self.engine.parentNode(item.parent, handle);
            if (!leafs.isSet(item.idx)) {
                try ret.append(handle);
            }
            const children = nodes[item.idx].children orelse continue;
            for (0..nodes[item.idx].children_count) |i| {
                const base = @intFromPtr(nodes);
                const pos = @intFromPtr(children[i]);
                const j = (pos - base) / @sizeOf(zcgltf.Node);
                try stack.append(TraverseEntry{ .idx = j, .parent = handle });
            }
        }
        return ret.toOwnedSlice();
    }

    fn processGltfNode(self: *GLTFLoader, data: *zcgltf.Data, node: *zcgltf.Node, parent: Handle) !Handle {
        std.debug.print("Processing GLTF node {s} (parent handle: {d}) \n", .{ node.name orelse "unknown", parent.index });
        if (node.parent) |parent_node| {
            std.debug.print("This node has parent node {s}\n", .{parent_node.name orelse "unknown"});
        }
        const handle = self.engine.spawn().build();
        const engine_node = self.engine.nodes.get(handle) orelse return handle;
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

    fn processGltfSkinnedMesh(self: *GLTFLoader, mesh: *zcgltf.Mesh, skin: *zcgltf.Skin, node: Handle, data: *zcgltf.Data) !void {
        std.debug.print("Processing GLTF skinned mesh with {d} primitives\n", .{mesh.primitives_count});
        for (mesh.primitives[0..mesh.primitives_count]) |*primitive| {
            try self.processSkinnedPrimitive(skin, primitive, node, data);
        }
    }

    fn processGltfMesh(self: *GLTFLoader, mesh: *zcgltf.Mesh, node: Handle) !void {
        std.debug.print("Processing GLTF mesh with {d} primitives\n", .{mesh.primitives_count});
        for (mesh.primitives[0..mesh.primitives_count]) |*primitive| {
            try self.processStaticPrimitive(primitive, node);
        }
    }

    fn processStaticPrimitive(self: *GLTFLoader, primitive: *zcgltf.Primitive, node: Handle) !void {
        const material_handle = self.engine.makeMaterial().build();
        const material = self.engine.materials.get(material_handle) orelse return error.ResourceAllocationFailed;
        var vertices = ArrayList(Vertex).init(self.allocator);
        defer vertices.deinit();
        var indices = ArrayList(u32).init(self.allocator);
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
        const mesh_handle = self.engine.makeMesh()
            .withGeometry(Geometry.make(vertices.items, indices.items))
            .withMaterial(material_handle)
            .build();
        if (self.engine.nodes.get(node)) |engine_node| {
            engine_node.data = .{ .static_mesh = mesh_handle };
        }
        try self.loadMaterialTextures(primitive, material);
    }

    fn processSkinnedPrimitive(self: *GLTFLoader, skin: *zcgltf.Skin, primitive: *zcgltf.Primitive, node: Handle, data: *zcgltf.Data) !void {
        const bones = try self.allocator.alloc(Bone, skin.joints_count);
        errdefer self.allocator.free(bones);
        var bone_lookup = HashMap(*zcgltf.Node, u32).init(self.allocator);
        defer bone_lookup.deinit();
        var is_child = try DynamicBitSet.initEmpty(self.allocator, skin.joints_count);
        defer is_child.deinit();
        if (skin.inverse_bind_matrices) |matrices| {
            const inverse_matrices = try self.unpackAccessorFloats(16, matrices);
            defer self.allocator.free(inverse_matrices);
            for (inverse_matrices, skin.joints[0..skin.joints_count], 0..) |matrix, joint, i| {
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
        const material_handle = self.engine.makeSkinnedMaterial().build();
        var vertices = ArrayList(SkinnedVertex).init(self.allocator);
        defer vertices.deinit();
        var indices = ArrayList(u32).init(self.allocator);
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
        const mesh_handle = self.engine.makeSkeletalMesh()
            .withGeometry(SkinnedGeometry.make(vertices.items, indices.items))
            .withMaterial(material_handle)
            .build();
        if (self.engine.skeletal_meshes.get(mesh_handle)) |mesh| {
            mesh.bones = bones;
            mesh.root_bone = root_bone.?;
        }
        // std.debug.print("Processing animations\n", .{});
        try self.processAnimationsForMesh(data, skin, mesh_handle);
        const engine_node = self.engine.nodes.get(node).?;
        // std.debug.print("Setting up node data for skeletal mesh\n", .{});
        var pose: animation.Pose = .{
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
        try self.loadMaterialTextures(primitive, self.engine.skinned_materials.get(material_handle).?);
    }

    fn loadMaterialTextures(self: *GLTFLoader, primitive: *zcgltf.Primitive, material: anytype) !void {
        const mtl = primitive.material orelse return;
        const tex = mtl.pbr_metallic_roughness.base_color_texture.texture orelse return;
        const img = tex.image orelse return;
        if (img.uri) |uri| {
            const texture_data = try std.fs.cwd().readFileAlloc(self.allocator, std.mem.sliceTo(uri, 0), std.math.maxInt(usize));
            defer self.allocator.free(texture_data);
            const texture_handle = self.engine.makeTexture()
                .fromData(texture_data)
                .build();
            const texture_ptr = self.engine.textures.get(texture_handle).?;
            material.updateTextures(texture_ptr, texture_ptr, texture_ptr);
        } else if (img.buffer_view) |buffer_view| {
            const buffer = buffer_view.buffer;
            const offset = buffer_view.offset;
            const size = buffer_view.size;
            const data_ptr: [*]u8 = @ptrCast(buffer.data);
            const data = data_ptr[offset .. offset + size];
            const texture_handle = self.engine.makeTexture()
                .fromData(data)
                .build();
            const texture_ptr = self.engine.textures.get(texture_handle).?;
            material.updateTextures(texture_ptr, texture_ptr, texture_ptr);
        }
    }

    fn unpackAccessorUint(self: *GLTFLoader, comptime components: usize, accessor: *zcgltf.Accessor) ![][components]u32 {
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

    fn unpackAccessorFloats(self: *GLTFLoader, comptime components: usize, accessor: *zcgltf.Accessor) ![][components]f32 {
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
    fn processAnimationsForMesh(self: *GLTFLoader, data: *zcgltf.Data, skin: *zcgltf.Skin, mesh_handle: Handle) !void {
        const mesh = self.engine.skeletal_meshes.get(mesh_handle) orelse {
            return error.InvalidMesh;
        };
        if (data.animations_count == 0) {
            return;
        }
        const animations = data.animations.?[0..data.animations_count];
        var clips = try self.allocator.alloc(animation.Clip, data.animations_count);
        errdefer self.allocator.free(clips);
        for (animations, 0..) |*gltf_anim, i| {
            var clip = &clips[i];
            if (std.mem.span(gltf_anim.name)) |name| {
                clip.name = try self.allocator.dupe(u8, name);
            } else {
                clip.name = try self.allocator.dupe(u8, "unnamed");
            }
            clip.animations = try self.allocator.alloc(animation.Channel, mesh.bones.len);
            for (clip.animations) |*channel| {
                channel.position = &[_]animation.Keyframe(zm.Vec){};
                channel.rotation = &[_]animation.Keyframe(zm.Quat){};
                channel.scale = &[_]animation.Keyframe(zm.Vec){};
            }
            var max_time: f32 = 0;
            // std.debug.print("Processing {d} animation channels\n", .{gltf_anim.channels_count});
            for (gltf_anim.channels[0..gltf_anim.channels_count], 0..) |*channel, chan_idx| {
                _ = chan_idx;
                const target_node = channel.target_node orelse continue;
                const sampler = channel.sampler;
                const input_accessor = sampler.input;
                const output_accessor = sampler.output;
                const times = try self.unpackAccessorFloats(1, input_accessor);
                defer self.allocator.free(times);
                for (times) |time| {
                    if (time[0] > max_time) max_time = time[0];
                }
                const target_bone = std.mem.indexOfScalar(*zcgltf.Node, skin.joints[0..skin.joints_count], target_node) orelse continue;
                switch (channel.target_path) {
                    .translation => {
                        const values = try self.unpackAccessorFloats(3, output_accessor);
                        defer self.allocator.free(values);
                        var keyframes = try self.allocator.alloc(animation.Keyframe(zm.Vec), times.len);
                        for (times, values, 0..) |time, value, j| {
                            keyframes[j] = .{
                                .time = time[0],
                                .value = zm.loadArr3w(value, 1.0),
                            };
                        }
                        clip.animations[target_bone].position = keyframes;
                    },
                    .rotation => {
                        const values = try self.unpackAccessorFloats(4, output_accessor);
                        defer self.allocator.free(values);
                        var keyframes = try self.allocator.alloc(animation.Keyframe(zm.Quat), times.len);
                        for (times, values, 0..) |time, value, j| {
                            keyframes[j] = .{
                                .time = time[0],
                                .value = zm.loadArr4(value),
                            };
                        }
                        clip.animations[target_bone].rotation = keyframes;
                    },
                    .scale => {
                        const values = try self.unpackAccessorFloats(3, output_accessor);
                        defer self.allocator.free(values);
                        var keyframes = try self.allocator.alloc(animation.Keyframe(zm.Vec), times.len);
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
        }
        mesh.animations = clips;
    }
};
