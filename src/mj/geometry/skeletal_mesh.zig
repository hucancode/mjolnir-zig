const std = @import("std");
const zm = @import("zmath");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

const VulkanContext = @import("../engine/context.zig").VulkanContext;
const DataBuffer = @import("../engine/data_buffer.zig").DataBuffer;
const Handle = @import("../engine/resource.zig").Handle;
const Transform = @import("../scene/node.zig").Transform;
const ResourcePool = @import("../engine/resource.zig").ResourcePool;
const Node = @import("../scene/node.zig").Node;
const NodeType = @import("../scene/node.zig").NodeType;
const AnimationTrack = @import("animation.zig").AnimationTrack;
const Animation = @import("animation.zig").Animation;
const Engine = @import("../engine/engine.zig").Engine;
const PositionKeyframe = @import("animation.zig").PositionKeyframe;
const RotationKeyframe = @import("animation.zig").RotationKeyframe;
const ScaleKeyframe = @import("animation.zig").ScaleKeyframe;

/// Vertex structure for skinned meshes
pub const SkinnedVertex = struct {
    position: [3]f32,
    normal: [3]f32,
    color: [4]f32,
    uv: [2]f32,
    joints: [4]u32,
    weights: [4]f32,
};

pub const Bone = struct {
    children: std.ArrayList(u32),
    transform: Transform,
};

/// Vertex input binding description for skinned vertices
pub const SKINNED_VERTEX_DESCRIPTION = [_]vk.VertexInputBindingDescription{
    .{
        .binding = 0,
        .stride = @sizeOf(SkinnedVertex),
        .input_rate = .vertex,
    },
};

/// Vertex attribute descriptions for skinned vertices
pub const SKINNED_VERTEX_ATTR_DESCRIPTION = [_]vk.VertexInputAttributeDescription{
    // Position
    .{
        .binding = 0,
        .location = 0,
        .format = .r32g32b32_sfloat,
        .offset = @offsetOf(SkinnedVertex, "position"),
    },
    // Normal
    .{
        .binding = 0,
        .location = 1,
        .format = .r32g32b32_sfloat,
        .offset = @offsetOf(SkinnedVertex, "normal"),
    },
    // Color
    .{
        .binding = 0,
        .location = 2,
        .format = .r32g32b32a32_sfloat,
        .offset = @offsetOf(SkinnedVertex, "color"),
    },
    // UV
    .{
        .binding = 0,
        .location = 3,
        .format = .r32g32_sfloat,
        .offset = @offsetOf(SkinnedVertex, "uv"),
    },
    // Joints
    .{
        .binding = 0,
        .location = 4,
        .format = .r32g32b32a32_uint,
        .offset = @offsetOf(SkinnedVertex, "joints"),
    },
    // Weights
    .{
        .binding = 0,
        .location = 5,
        .format = .r32g32b32a32_sfloat,
        .offset = @offsetOf(SkinnedVertex, "weights"),
    },
};

/// Skeletal mesh with skinning support
pub const SkeletalMesh = struct {
    bones: []Bone,
    vertices_len: u32 = 0,
    indices_len: u32 = 0,
    animations: StringHashMap(AnimationTrack),
    vertex_buffer: DataBuffer,
    index_buffer: DataBuffer,
    bone_buffer: DataBuffer,
    material: Handle,
    allocator: Allocator,

    pub fn init(allocator: Allocator) SkeletalMesh {
        return .{
            .bones = &[_]Handle{},
            .vertices_len = 0,
            .indices_len = 0,
            .animations = StringHashMap(AnimationTrack).init(allocator),
            .vertex_buffer = undefined,
            .index_buffer = undefined,
            .bone_buffer = undefined,
            .material = undefined,
            .allocator = allocator,
        };
    }

    pub fn buildBoneBuffer(self: *SkeletalMesh) !void {
        self.bone_buffer = try DataBuffer.init(self.allocator, self.bones.len * @sizeOf(zm.Mat));
    }

    pub fn update(self: *SkeletalMesh) !void {
        // TODO: update animations, etc
        if (self.bone_buffer.mapped) |raw_ptr| {
            const ptr: *[self.bones.len]zm.Mat = @ptrCast(raw_ptr);
            for (self.bones, 0..) |bone, i| {
                ptr[i] = bone.transform.toMatrix();
            }
        }
    }

    pub fn deinit(self: *SkeletalMesh) void {
        self.vertex_buffer.deinit();
        self.index_buffer.deinit();
        if (self.bones.len > 0) {
            self.bone_buffer.deinit();
        }
        var animation_iter = self.animations.iterator();
        while (animation_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.animations.deinit();
        self.allocator.free(self.bones);
    }
};
