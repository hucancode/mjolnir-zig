const std = @import("std");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const VulkanContext = @import("../engine/context.zig").VulkanContext;
const StaticMesh = @import("../geometry/static_mesh.zig").StaticMesh;
const SkeletalMesh = @import("../geometry/skeletal_mesh.zig").SkeletalMesh;
const Material = @import("../material/pbr.zig").Material;
const SkinnedMaterial = @import("../material/skinned_pbr.zig").SkinnedMaterial;
const Texture = @import("../material/texture.zig").Texture;
const Light = @import("../scene/light.zig").Light;
const Node = @import("../scene/node.zig").Node;
const NodeType = @import("../scene/node.zig").NodeType;

pub const Handle = struct {
    index: u24,
    generation: u8,
};

/// Entry in a resource pool
fn Entry(comptime T: type) type {
    return struct {
        generation: u8,
        active: bool,
        item: T,
    };
}

/// Generic resource pool for managing resources
pub fn ResourcePool(comptime T: type) type {
    const EntryType = Entry(T);
    return struct {
        const Self = @This();
        entries: ArrayList(EntryType),
        free_indices: ArrayList(u24),
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .entries = ArrayList(EntryType).init(allocator),
                .free_indices = ArrayList(u24).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit();
            self.free_indices.deinit();
        }

        pub fn malloc(self: *Self) Handle {
            if (self.free_indices.pop()) |index| {
                const gen = self.entries.items[index].generation + 1;
                self.entries.items[index].generation = gen;
                self.entries.items[index].active = true;
                return .{ .index = index, .generation = gen };
            } else {
                const index = @as(u24, @intCast(self.entries.items.len));
                self.entries.append(.{
                    .generation = 1,
                    .active = true,
                    .item = undefined,
                }) catch unreachable;
                return .{ .index = index, .generation = 1 };
            }
        }

        pub fn free(self: *Self, handle: Handle) void {
            if (handle.index >= self.entries.items.len) {
                return;
            }
            const entry = &self.entries.items[handle.index];
            if (entry.generation != handle.generation) {
                return;
            }
            self.entries.items[handle.index].generation += 1;
            self.free_indices.append(handle.index) catch {};
        }

        pub fn get(self: *Self, handle: Handle) ?*T {
            if (handle.index >= self.entries.items.len) {
                std.debug.print("ResourcePool.get: index ({d}) out of bounds ({d})\n", .{
                    handle.index, self.entries.items.len,
                });
                return null;
            }
            if (!self.entries.items[handle.index].active) {
                std.debug.print("ResourcePool.get: index ({d}) has been freed\n", .{handle.index});
                return null;
            }
            if (self.entries.items[handle.index].generation != handle.generation) {
                std.debug.print(
                    "ResourcePool.get: index ({d}) has been allocated to other resource, its generation is changed from {d} to {d}\n",
                    .{
                        handle.index,
                        handle.generation,
                        self.entries.items[handle.index].generation,
                    },
                );
                return null;
            }
            return &self.entries.items[handle.index].item;
        }
    };
}

/// Resource manager to handle all game assets
pub const ResourceManager = struct {
    meshes: ResourcePool(StaticMesh),
    skeletal_meshes: ResourcePool(SkeletalMesh),
    materials: ResourcePool(Material),
    skinned_materials: ResourcePool(SkinnedMaterial),
    textures: ResourcePool(Texture),
    lights: ResourcePool(Light),
    nodes: ResourcePool(Node),
    allocator: Allocator,

    pub fn init(allocator: Allocator) ResourceManager {
        return .{
            .meshes = ResourcePool(StaticMesh).init(allocator),
            .skeletal_meshes = ResourcePool(SkeletalMesh).init(allocator),
            .materials = ResourcePool(Material).init(allocator),
            .skinned_materials = ResourcePool(SkinnedMaterial).init(allocator),
            .textures = ResourcePool(Texture).init(allocator),
            .lights = ResourcePool(Light).init(allocator),
            .nodes = ResourcePool(Node).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResourceManager) void {
        self.meshes.deinit();
        self.skeletal_meshes.deinit();
        self.materials.deinit();
        self.skinned_materials.deinit();
        self.textures.deinit();
        self.lights.deinit();
        self.nodes.deinit();
    }

    // Static mesh methods
    pub fn mallocMesh(self: *ResourceManager) Handle {
        return self.meshes.malloc();
    }

    pub fn getMesh(self: *ResourceManager, handle: Handle) ?*StaticMesh {
        return self.meshes.get(handle);
    }

    // Skeletal mesh methods
    pub fn mallocSkeletalMesh(self: *ResourceManager) Handle {
        return self.skeletal_meshes.malloc();
    }

    pub fn getSkeletalMesh(self: *ResourceManager, handle: Handle) ?*SkeletalMesh {
        return self.skeletal_meshes.get(handle);
    }

    // Material methods
    pub fn mallocMaterial(self: *ResourceManager) Handle {
        return self.materials.malloc();
    }

    pub fn getMaterial(self: *ResourceManager, handle: Handle) ?*Material {
        return self.materials.get(handle);
    }

    // Skinned material methods
    pub fn createSkinnedMaterial(self: *ResourceManager) Handle {
        return self.skinned_materials.malloc();
    }

    pub fn getSkinnedMaterial(self: *ResourceManager, handle: Handle) ?*SkinnedMaterial {
        return self.skinned_materials.get(handle);
    }

    // Texture methods
    pub fn mallocTexture(self: *ResourceManager) Handle {
        return self.textures.malloc();
    }

    pub fn getTexture(self: *ResourceManager, handle: Handle) ?*Texture {
        return self.textures.get(handle);
    }

    // Light methods
    pub fn createLight(self: *ResourceManager) Handle {
        const handle = self.lights.malloc();
        if (self.getLight(handle)) |light| {
            light.color = .{ 0.0, 0.5, 1.0, 1.0 };
            light.intensity = 1.0;
        }
        return handle;
    }

    pub fn getLight(self: *ResourceManager, handle: Handle) ?*Light {
        return self.lights.get(handle);
    }

    // Node methods
    pub fn createNode(self: *ResourceManager, node_type: NodeType) Handle {
        const handle = self.nodes.malloc();
        if (self.getNode(handle)) |node| {
            node.init(self.allocator);
            node.type = node_type;
            node.parent = handle;
        }
        return handle;
    }

    pub fn getNode(self: *ResourceManager, handle: Handle) ?*Node {
        return self.nodes.get(handle);
    }

    pub fn createMeshNode(self: *ResourceManager, mesh: Handle) Handle {
        const handle = self.createNode(NodeType.static_mesh);
        if (self.getNode(handle)) |node| {
            node.mesh = mesh;
        }
        return handle;
    }

    pub fn createSkeletalMeshNode(self: *ResourceManager, mesh: Handle) Handle {
        const handle = self.createNode(NodeType.skeletal_mesh);
        if (self.getNode(handle)) |node| {
            node.skeletal_mesh = mesh;
        }
        return handle;
    }

    pub fn createLightNode(self: *ResourceManager, light: Handle) Handle {
        const handle = self.createNode(NodeType.light);
        if (self.getNode(handle)) |node| {
            node.light = light;
        }
        return handle;
    }

    pub fn destroyNode(self: *ResourceManager, handle: Handle) void {
        if (self.getNode(handle)) |node| {
            self.unparentNode(handle);
            node.deinit();
        }
        self.nodes.free(handle);
    }

    pub fn destroyMesh(self: *ResourceManager, handle: Handle, context: *VulkanContext) void {
        if (self.getMesh(handle)) |mesh| {
            mesh.destroy(context);
        }
        self.meshes.free(handle);
    }

    pub fn destroySkeletalMesh(self: *ResourceManager, handle: Handle, context: *VulkanContext) void {
        if (self.getSkeletalMesh(handle)) |mesh| {
            mesh.destroy(context);
        }
        self.skeletal_meshes.free(handle);
    }

    pub fn destroyTexture(self: *ResourceManager, handle: Handle, context: *VulkanContext) void {
        if (self.getTexture(handle)) |texture| {
            texture.destroy(context);
        }
        self.textures.free(handle);
    }

    pub fn destroyMaterial(self: *ResourceManager, handle: Handle, context: *VulkanContext) void {
        if (self.getMaterial(handle)) |material| {
            material.destroy(context);
        }
        self.materials.free(handle);
    }

    pub fn destroySkinnedMaterial(self: *ResourceManager, handle: Handle, context: *VulkanContext) void {
        if (self.getSkinnedMaterial(handle)) |material| {
            material.destroy(context);
        }
        self.skinned_materials.free(handle);
    }

    pub fn destroyLight(self: *ResourceManager, handle: Handle) void {
        self.lights.free(handle);
    }

    pub fn destroy(self: *ResourceManager, context: *VulkanContext) void {
        for (self.nodes.entries.items, 0..) |entry, i| {
            self.destroyNode(.{ .index = @intCast(i), .generation = entry.generation });
        }
        for (self.meshes.entries.items, 0..) |entry, i| {
            self.destroyMesh(.{ .index = @intCast(i), .generation = entry.generation }, context);
        }
        for (self.skeletal_meshes.entries.items, 0..) |entry, i| {
            self.destroySkeletalMesh(.{ .index = @intCast(i), .generation = entry.generation }, context);
        }
        for (self.textures.entries.items, 0..) |entry, i| {
            self.destroyTexture(.{ .index = @intCast(i), .generation = entry.generation }, context);
        }
        for (self.materials.entries.items, 0..) |entry, i| {
            self.destroyMaterial(.{ .index = @intCast(i), .generation = entry.generation }, context);
        }
        for (self.skinned_materials.entries.items, 0..) |entry, i| {
            self.destroySkinnedMaterial(.{ .index = @intCast(i), .generation = entry.generation }, context);
        }
        for (self.lights.entries.items, 0..) |entry, i| {
            self.destroyLight(.{ .index = @intCast(i), .generation = entry.generation });
        }
        self.deinit();
    }

    pub fn unparentNode(self: *ResourceManager, node: Handle) void {
        const child_node = self.getNode(node) orelse return;
        const parent_handle = child_node.parent;
        const parent_node = self.getNode(parent_handle) orelse return;
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

    pub fn parentNode(self: *ResourceManager, parent: Handle, child: Handle) void {
        self.unparentNode(child);
        const parent_node = self.getNode(parent) orelse return;
        const child_node = self.getNode(child) orelse return;
        std.debug.print("Parenting node {x} type {any} to {x} type {any}\n", .{ &child_node, child_node.type, &parent_node, parent_node.type });
        child_node.parent = parent;
        parent_node.children.append(child) catch |err| {
            std.debug.print("Failed to append child to parent: {any}\n", .{err});
        };
    }
};
