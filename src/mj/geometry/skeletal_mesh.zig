const std = @import("std");
const zm = @import("zmath");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const context = @import("../engine/context.zig").get();

const VulkanContext = @import("../engine/context.zig").VulkanContext;
const DataBuffer = @import("../engine/data_buffer.zig").DataBuffer;
const Handle = @import("../engine/resource.zig").Handle;
const Transform = @import("../scene/node.zig").Transform;
const ResourcePool = @import("../engine/resource.zig").ResourcePool;
const Node = @import("../scene/node.zig").Node;
const NodeType = @import("../scene/node.zig").NodeType;
const Engine = @import("../engine/engine.zig").Engine;
const AnimationClip = @import("animation.zig").AnimationClip;
const AnimationInstance = @import("animation.zig").AnimationInstance;
const Pose = @import("animation.zig").Pose;

/// Vertex structure for skinned meshes
pub const SkinnedVertex = struct {
    position: [3]f32,
    normal: [3]f32,
    color: [4]f32,
    uv: [2]f32,
    joints: [4]u32,
    weights: [4]f32,
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

pub const Bone = struct {
    bind_transform: Transform = .{},
    children: []u32 = undefined,
    inverse_bind_matrix: zm.Mat = zm.identity(),
};

/// Skeletal mesh with skinning support
pub const SkeletalMesh = struct {
    root_bone: u32 = 0,
    bones: []Bone,
    animations: []AnimationClip,
    vertices_len: u32 = 0,
    indices_len: u32 = 0,
    vertex_buffer: DataBuffer = undefined,
    index_buffer: DataBuffer = undefined,
    material: Handle = undefined,

    pub fn calculateAnimationTransform(self: *SkeletalMesh, allocator: Allocator, animation: *AnimationInstance, pose: *Pose) void {
        var transform_stack = std.ArrayList(zm.Mat).init(allocator);
        defer transform_stack.deinit();
        var bone_stack = std.ArrayList(u32).init(allocator);
        defer bone_stack.deinit();
        transform_stack.append(zm.identity()) catch unreachable;
        bone_stack.append(self.root_bone) catch unreachable;
        while (bone_stack.pop()) |bone_index| {
            const parent_matrix = transform_stack.pop().?;
            var animated_transform: Transform = .{};
            self.animations[animation.clip].animations[bone_index].calculate(animation.time, &animated_transform);
            const local_matrix = animated_transform.toMatrix();
            const world_matrix = zm.mul(local_matrix, parent_matrix);
            pose.bone_matrices[bone_index] = zm.mul(self.bones[bone_index].inverse_bind_matrix, world_matrix);
            for (self.bones[bone_index].children) |i| {
                transform_stack.append(world_matrix) catch unreachable;
                bone_stack.append(i) catch unreachable;
            }
        }
    }

    pub fn deinit(self: *SkeletalMesh) void {
        self.vertex_buffer.deinit();
        self.index_buffer.deinit();
    }
};
