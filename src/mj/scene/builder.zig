const std = @import("std");
const zm = @import("zmath");
const Node = @import("node.zig").Node;
const Handle = @import("../engine/resource.zig").Handle;
const Engine = @import("../engine/engine.zig").Engine;
const Transform = @import("node.zig").Transform;
const AnimationPlayMode = @import("../geometry/animation.zig").AnimationPlayMode;

/// Builder for creating and configuring nodes
pub const NodeBuilder = struct {
    engine: *Engine,
    node: Handle,
    name: ?[]const u8,

    pub fn init(engine: *Engine) NodeBuilder {
        return .{
            .engine = engine,
            .node = engine.createNode(),
            .name = null,
        };
    }

    pub fn withTransform(self: *NodeBuilder, transform: Transform) *NodeBuilder {
        if (self.engine.nodes.get(self.node)) |node| {
            node.transform = transform;
        }
        return self;
    }

    pub fn withPosition(self: *NodeBuilder, x: f32, y: f32, z: f32) *NodeBuilder {
        if (self.engine.nodes.get(self.node)) |node| {
            node.transform.position = .{ x, y, z, 0.0 };
        }
        return self;
    }

    pub fn withScale(self: *NodeBuilder, x: f32, y: f32, z: f32) *NodeBuilder {
        if (self.engine.nodes.get(self.node)) |node| {
            node.transform.scale = .{ x, y, z, 0.0 };
        }
        return self;
    }

    pub fn withRotation(self: *NodeBuilder, x: f32, y: f32, z: f32, w: f32) *NodeBuilder {
        if (self.engine.nodes.get(self.node)) |node| {
            node.transform.rotation = .{ x, y, z, w };
        }
        return self;
    }

    pub fn withPointLight(self: *NodeBuilder, color: zm.Vec) *NodeBuilder {
        const light = self.engine.createPointLight(color);
        if (self.engine.nodes.get(self.node)) |node| {
            node.data = .{ .light = light };
        }
        return self;
    }

    pub fn withDirectionalLight(self: *NodeBuilder, color: zm.Vec) *NodeBuilder {
        const light = self.engine.createDirectionalLight(color);
        if (self.engine.nodes.get(self.node)) |node| {
            node.data = .{ .light = light };
        }
        return self;
    }

    pub fn withMesh(self: *NodeBuilder, mesh: Handle) *NodeBuilder {
        if (self.engine.nodes.get(self.node)) |node| {
            node.data = .{ .static_mesh = mesh };
        }
        return self;
    }

    pub fn withSkeletalMesh(self: *NodeBuilder, mesh: Handle) *NodeBuilder {
        if (self.engine.nodes.get(self.node)) |node| {
            node.data = .{ .skeletal_mesh = mesh };
        }
        return self;
    }

    pub fn withAnimation(self: *NodeBuilder, name: []const u8, mode: AnimationPlayMode) *NodeBuilder {
        self.engine.playAnimation(self.node, name, mode) catch {};
        return self;
    }

    pub fn withName(self: *NodeBuilder, name: []const u8) *NodeBuilder {
        if (self.engine.nodes.get(self.node)) |_| {
            // Store the name in the builder for now
            self.name = name;
        }
        return self;
    }

    pub fn build(self: *NodeBuilder) Handle {
        self.engine.addToRoot(self.node);
        return self.node;
    }
};

/// Builder for creating and configuring materials
pub const MaterialBuilder = struct {
    engine: *Engine,
    material: Handle,

    pub fn init(engine: *Engine) !MaterialBuilder {
        return .{
            .engine = engine,
            .material = try engine.createMaterial(),
        };
    }

    pub fn withTexture(self: *MaterialBuilder, texture: Handle) !*MaterialBuilder {
        if (self.engine.materials.get(self.material)) |material| {
            if (self.engine.textures.get(texture)) |texture_ptr| {
                material.albedo = texture;
                material.updateTextures(texture_ptr, texture_ptr, texture_ptr);
            }
        }
        return self;
    }

    pub fn withAlbedo(self: *MaterialBuilder, texture: Handle) !*MaterialBuilder {
        if (self.engine.materials.get(self.material)) |material| {
            material.albedo = texture;
        }
        return self;
    }

    pub fn withMetallic(self: *MaterialBuilder, texture: Handle) !*MaterialBuilder {
        if (self.engine.materials.get(self.material)) |material| {
            material.metallic = texture;
        }
        return self;
    }

    pub fn withRoughness(self: *MaterialBuilder, texture: Handle) !*MaterialBuilder {
        if (self.engine.materials.get(self.material)) |material| {
            material.roughness = texture;
        }
        return self;
    }

    pub fn build(self: *MaterialBuilder) Handle {
        return self.material;
    }
};

/// Builder for creating and configuring scenes
pub const SceneBuilder = struct {
    engine: *Engine,

    pub fn init(engine: *Engine) SceneBuilder {
        return .{
            .engine = engine,
        };
    }

    pub fn spawn(self: *SceneBuilder) NodeBuilder {
        return NodeBuilder.init(self.engine);
    }

    pub fn addLight(self: *SceneBuilder, config: struct {
        type: enum { point, directional },
        color: zm.Vec = zm.f32x4(1.0, 1.0, 1.0, 1.0),
        position: ?zm.Vec = null,
        scale: ?zm.Vec = null,
    }) !Handle {
        var builder = self.spawn();
        switch (config.type) {
            .point => builder.withPointLight(config.color),
            .directional => builder.withDirectionalLight(config.color),
        }
        if (config.position) |pos| {
            builder.withPosition(pos[0], pos[1], pos[2]);
        }
        if (config.scale) |scale| {
            builder.withScale(scale[0], scale[1], scale[2]);
        }
        return builder.build();
    }
};

/// Animation controller for fluent animation APIs
pub const Animator = struct {
    engine: *Engine,
    node: Handle,

    pub fn init(engine: *Engine, node: Handle) Animator {
        return .{
            .engine = engine,
            .node = node,
        };
    }

    pub fn play(self: *Animator, name: []const u8) *Animator {
        self.engine.playAnimation(self.node, name, .once) catch {};
        return self;
    }

    pub fn playLooped(self: *Animator, name: []const u8) *Animator {
        self.engine.playAnimation(self.node, name, .loop) catch {};
        return self;
    }

    pub fn pause(self: *Animator) *Animator {
        self.engine.pauseAnimation(self.node) catch {};
        return self;
    }

    pub fn unpause(self: *Animator) *Animator {
        self.engine.resumeAnimation(self.node) catch {};
        return self;
    }

    pub fn stop(self: *Animator) *Animator {
        self.engine.stopAnimation(self.node) catch {};
        return self;
    }

    pub fn setLooping(self: *Animator, looping: bool) *Animator {
        self.engine.setAnimationMode(self.node, if (looping) .loop else .once) catch {};
        return self;
    }
};
