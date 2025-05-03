const std = @import("std");
const zm = @import("zmath");
const vk = @import("vulkan");
const Engine = @import("engine.zig").Engine;
const Handle = @import("resource.zig").Handle;
const Node = @import("../scene/node.zig").Node;
const Transform = @import("../scene/node.zig").Transform;
const Vertex = @import("../geometry/geometry.zig").Vertex;
const Geometry = @import("../geometry/geometry.zig").Geometry;
const SkinnedGeometry = @import("../geometry/geometry.zig").SkinnedGeometry;
const Pose = @import("../geometry/animation.zig").Pose;
const Bone = @import("../geometry/skeletal_mesh.zig").Bone;
const context = @import("context.zig").get();

pub const TextureBuilder = struct {
    engine: *Engine,
    handle: Handle,

    pub fn init(self: *TextureBuilder, engine: *Engine) void {
        self.engine = engine;
        self.handle = engine.textures.malloc();
    }

    pub fn fromPath(self: *TextureBuilder, path: []const u8) *TextureBuilder {
        const texture = self.engine.textures.get(self.handle).?;
        texture.initFromPath(path) catch unreachable;
        return self;
    }

    pub fn fromData(self: *TextureBuilder, data: []const u8) *TextureBuilder {
        const texture = self.engine.textures.get(self.handle).?;
        texture.initFromData(data) catch unreachable;
        return self;
    }

    pub fn build(self: *TextureBuilder) Handle {
        defer self.engine.allocator.destroy(self);
        const texture = self.engine.textures.get(self.handle).?;
        texture.initBuffer() catch unreachable;
        return self.handle;
    }
};

const VERTEX_CODE align(@alignOf(u32)) = @embedFile("shaders/pbr/vert.spv").*;
const FRAGMENT_CODE align(@alignOf(u32)) = @embedFile("shaders/pbr/frag.spv").*;

pub const MaterialBuilder = struct {
    engine: *Engine,
    handle: Handle,
    vertex_shader: []align(@alignOf(u32)) const u8 = undefined,
    fragment_shader: []align(@alignOf(u32)) const u8 = undefined,
    albedo: ?Handle = null,
    metallic: ?Handle = null,
    roughness: ?Handle = null,

    pub fn init(self: *MaterialBuilder, engine: *Engine) void {
        self.* = .{
            .engine = engine,
            .handle = engine.materials.malloc(),
            .vertex_shader = &VERTEX_CODE,
            .fragment_shader = &FRAGMENT_CODE,
        };
    }

    pub fn withCode(self: *MaterialBuilder, vertex: []align(@alignOf(u32)) const u8, fragment: []align(@alignOf(u32)) const u8) *MaterialBuilder {
        self.vertex_shader = vertex;
        self.fragment_shader = fragment;
        return self;
    }

    pub fn withAlbedo(self: *MaterialBuilder, texture: Handle) *MaterialBuilder {
        self.albedo = texture;
        return self;
    }

    pub fn withMetallic(self: *MaterialBuilder, texture: Handle) *MaterialBuilder {
        self.metallic = texture;
        return self;
    }

    pub fn withRoughness(self: *MaterialBuilder, texture: Handle) *MaterialBuilder {
        self.roughness = texture;
        return self;
    }

    pub fn withTexture(self: *MaterialBuilder, texture: Handle) *MaterialBuilder {
        self.albedo = texture;
        self.metallic = texture;
        self.roughness = texture;
        return self;
    }

    pub fn build(self: *MaterialBuilder) Handle {
        defer self.engine.allocator.destroy(self);
        const ptr = self.engine.materials.get(self.handle).?;
        ptr.initDescriptorSet() catch unreachable;

        if (self.albedo != null and self.metallic != null and self.roughness != null) {
            const albedo_tex = self.engine.textures.get(self.albedo.?).?;
            const metallic_tex = self.engine.textures.get(self.metallic.?).?;
            const roughness_tex = self.engine.textures.get(self.roughness.?).?;
            ptr.updateTextures(albedo_tex, metallic_tex, roughness_tex);
        }

        ptr.build(self.engine, self.vertex_shader, self.fragment_shader) catch unreachable;
        return self.handle;
    }
};

const SKINNED_VERTEX_CODE align(@alignOf(u32)) = @embedFile("shaders/skinned_pbr/vert.spv").*;
const SKINNED_FRAGMENT_CODE align(@alignOf(u32)) = @embedFile("shaders/skinned_pbr/frag.spv").*;

pub const SkinnedMaterialBuilder = struct {
    engine: *Engine,
    handle: Handle,
    vertex_shader: []align(@alignOf(u32)) const u8,
    fragment_shader: []align(@alignOf(u32)) const u8,
    albedo: ?Handle = null,
    metallic: ?Handle = null,
    roughness: ?Handle = null,

    pub fn init(self: *SkinnedMaterialBuilder, engine: *Engine) void {
        self.* = .{
            .engine = engine,
            .handle = engine.skinned_materials.malloc(),
            .vertex_shader = &SKINNED_VERTEX_CODE,
            .fragment_shader = &SKINNED_FRAGMENT_CODE,
        };
    }

    pub fn withCode(self: *SkinnedMaterialBuilder, vertex: []align(@alignOf(u32)) const u8, fragment: []align(@alignOf(u32)) const u8) *SkinnedMaterialBuilder {
        self.vertex_shader = vertex;
        self.fragment_shader = fragment;
        return self;
    }

    pub fn withAlbedo(self: *SkinnedMaterialBuilder, texture: Handle) *SkinnedMaterialBuilder {
        self.albedo = texture;
        return self;
    }

    pub fn withMetallic(self: *SkinnedMaterialBuilder, texture: Handle) *SkinnedMaterialBuilder {
        self.metallic = texture;
        return self;
    }

    pub fn withRoughness(self: *SkinnedMaterialBuilder, texture: Handle) *SkinnedMaterialBuilder {
        self.roughness = texture;
        return self;
    }

    pub fn withTexture(self: *SkinnedMaterialBuilder, texture: Handle) *SkinnedMaterialBuilder {
        self.albedo = texture;
        self.metallic = texture;
        self.roughness = texture;
        return self;
    }

    pub fn build(self: *SkinnedMaterialBuilder) Handle {
        defer self.engine.allocator.destroy(self);
        const ptr = self.engine.skinned_materials.get(self.handle).?;
        ptr.initDescriptorSet() catch unreachable;
        if (self.albedo != null and self.metallic != null and self.roughness != null) {
            const albedo_tex = self.engine.textures.get(self.albedo.?).?;
            const metallic_tex = self.engine.textures.get(self.metallic.?).?;
            const roughness_tex = self.engine.textures.get(self.roughness.?).?;
            ptr.updateTextures(albedo_tex, metallic_tex, roughness_tex);
        }
        ptr.build(self.engine, self.vertex_shader, self.fragment_shader) catch unreachable;
        return self.handle;
    }
};

pub const MeshBuilder = struct {
    engine: *Engine,
    handle: Handle,

    pub fn init(self: *MeshBuilder, engine: *Engine) void {
        self.engine = engine;
        self.handle = engine.meshes.malloc();
    }

    pub fn withGeometry(self: *MeshBuilder, geometry: Geometry) *MeshBuilder {
        const mesh = self.engine.meshes.get(self.handle).?;
        mesh.init(geometry) catch unreachable;
        return self;
    }

    pub fn withMaterial(self: *MeshBuilder, material: Handle) *MeshBuilder {
        const mesh = self.engine.meshes.get(self.handle).?;
        mesh.material = material;
        return self;
    }

    pub fn build(self: *MeshBuilder) Handle {
        defer self.engine.allocator.destroy(self);
        return self.handle;
    }
};

pub const SkeletalMeshBuilder = struct {
    engine: *Engine,
    handle: Handle,

    pub fn init(self: *SkeletalMeshBuilder, engine: *Engine) void {
        self.engine = engine;
        self.handle = engine.skeletal_meshes.malloc();
    }

    pub fn withGeometry(self: *SkeletalMeshBuilder, geometry: SkinnedGeometry) *SkeletalMeshBuilder {
        const mesh = self.engine.skeletal_meshes.get(self.handle).?;
        mesh.init(geometry) catch unreachable;
        return self;
    }

    pub fn withMaterial(self: *SkeletalMeshBuilder, material: Handle) *SkeletalMeshBuilder {
        const mesh = self.engine.skeletal_meshes.get(self.handle).?;
        mesh.material = material;
        return self;
    }

    pub fn withBones(self: *SkeletalMeshBuilder, bones: []const Bone, root_bone: u16) *SkeletalMeshBuilder {
        const mesh = self.engine.skeletal_meshes.get(self.handle).?;
        mesh.bones = bones;
        mesh.root_bone = root_bone;
        return self;
    }

    pub fn build(self: *SkeletalMeshBuilder) Handle {
        defer self.engine.allocator.destroy(self);
        return self.handle;
    }
};

pub const NodeBuilder = struct {
    engine: *Engine,
    handle: Handle,

    pub fn init(self: *NodeBuilder, engine: *Engine) void {
        self.engine = engine;
        self.handle = engine.nodes.malloc();
        var node = engine.nodes.get(self.handle).?;
        node.init(engine.allocator);
        node.parent = self.handle;
        node.data = .none;
    }

    pub fn withTransform(self: *NodeBuilder, transform: Transform) *NodeBuilder {
        if (self.engine.nodes.get(self.handle)) |node| {
            node.transform = transform;
        }
        return self;
    }

    pub fn withPosition(self: *NodeBuilder, position: zm.Vec) *NodeBuilder {
        if (self.engine.nodes.get(self.handle)) |node| {
            node.transform.position = position;
        }
        return self;
    }

    pub fn withRotation(self: *NodeBuilder, rotation: zm.Quat) *NodeBuilder {
        if (self.engine.nodes.get(self.handle)) |node| {
            node.transform.rotation = rotation;
        }
        return self;
    }

    pub fn withScale(self: *NodeBuilder, scale: zm.Vec) *NodeBuilder {
        if (self.engine.nodes.get(self.handle)) |node| {
            node.transform.scale = scale;
        }
        return self;
    }

    pub fn withNewPointLight(self: *NodeBuilder, color: zm.Vec) *NodeBuilder {
        const handle = self.engine.lights.malloc();
        const light_ptr = self.engine.lights.get(handle).?;
        light_ptr.data = .point;
        light_ptr.color = color;
        return self.withLight(handle);
    }

    pub fn withNewDirectionalLight(self: *NodeBuilder, color: zm.Vec) *NodeBuilder {
        const handle = self.engine.lights.malloc();
        const light_ptr = self.engine.lights.get(handle).?;
        light_ptr.data = .directional;
        light_ptr.color = color;
        return self.withLight(handle);
    }

    pub fn withNewSpotLight(self: *NodeBuilder, color: zm.Vec) *NodeBuilder {
        const handle = self.engine.lights.malloc();
        const light_ptr = self.engine.lights.get(handle).?;
        light_ptr.data = .{
            .spot = std.math.pi / 4.0,
        };
        light_ptr.color = color;
        std.debug.print("create new spot light\n", .{});
        return self.withLight(handle);
    }

    pub fn withLightRadius(self: *NodeBuilder, radius: f32) *NodeBuilder {
        if (self.engine.nodes.get(self.handle)) |node| {
            if (node.data == .light) {
                // TODO: set radius for this light
                _ = radius;
            }
        }
        return self;
    }

    pub fn withLightAngle(self: *NodeBuilder, angle: f32) *NodeBuilder {
        if (self.engine.nodes.get(self.handle)) |node| {
            if (node.data == .light) {
                // TODO: set angle for this light
                _ = angle;
            }
        }
        return self;
    }

    pub fn withLight(self: *NodeBuilder, light: Handle) *NodeBuilder {
        if (self.engine.nodes.get(self.handle)) |node| {
            node.data = .{ .light = light };
        }
        return self;
    }

    pub fn withStaticMesh(self: *NodeBuilder, mesh: Handle) *NodeBuilder {
        if (self.engine.nodes.get(self.handle)) |node| {
            node.data = .{ .static_mesh = mesh };
        }
        return self;
    }

    pub fn withSkeletalMesh(self: *NodeBuilder, mesh: Handle) *NodeBuilder {
        if (self.engine.nodes.get(self.handle)) |node| {
            const mesh_ptr = self.engine.skeletal_meshes.get(mesh).?;
            const pose: Pose = .{ .allocator = self.engine.allocator };
            pose.init(mesh_ptr.bones.len);
            node.data = .{ .skeletal_mesh = .{
                .handle = mesh,
                .pose = pose,
            } };
        }
        return self;
    }

    pub fn withNewStaticMesh(self: *NodeBuilder, geometry: Geometry, material: Handle) *NodeBuilder {
        const mesh = self.engine.makeMesh()
            .withGeometry(geometry)
            .withMaterial(material)
            .build();
        return self.withStaticMesh(mesh);
    }

    pub fn withNewSkeletalMesh(self: *NodeBuilder, geometry: Geometry, material: Handle) *NodeBuilder {
        const mesh = self.engine.createSkeletalMesh(geometry, material);
        self.withSkeletalMesh(mesh);
        return self;
    }

    pub fn atRoot(self: *NodeBuilder) *NodeBuilder {
        self.engine.parentNode(self.engine.scene.root, self.handle);
        return self;
    }

    pub fn asChildOf(self: *NodeBuilder, parent: Handle) *NodeBuilder {
        self.engine.parentNode(parent, self.handle);
        return self;
    }

    pub fn withChildren(self: *NodeBuilder, children: []Handle) *NodeBuilder {
        for (children) |child| {
            self.engine.parentNode(self.handle, child);
        }
        return self;
    }

    pub fn withName(self: *NodeBuilder, name: []const u8) *NodeBuilder {
        if (self.engine.nodes.get(self.handle)) |node| {
            node.name = name;
        }
        return self;
    }

    pub fn build(self: *NodeBuilder) Handle {
        defer self.engine.allocator.destroy(self);
        return self.handle;
    }
};
