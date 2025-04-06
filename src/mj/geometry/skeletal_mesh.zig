const std = @import("std");
const zm = @import("zmath");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

const VulkanContext = @import("../engine/context.zig").VulkanContext;
const DataBuffer = @import("../engine/data_buffer.zig").DataBuffer;
const Handle = @import("../engine/resource.zig").Handle;
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
    vertices: []SkinnedVertex,
    indices: []u32,
    bones: []Handle,
    animations: StringHashMap(AnimationTrack),
    vertex_buffer: DataBuffer,
    index_buffer: DataBuffer,
    bone_buffer: DataBuffer,
    material: Handle,
    allocator: Allocator,

    pub fn init(allocator: Allocator) SkeletalMesh {
        return .{
            .vertices = &[_]SkinnedVertex{},
            .indices = &[_]u32{},
            .bones = &[_]Handle{},
            .animations = StringHashMap(AnimationTrack).init(allocator),
            .vertex_buffer = undefined,
            .index_buffer = undefined,
            .bone_buffer = undefined,
            .material = undefined,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SkeletalMesh, context: *VulkanContext) void {
        self.vertex_buffer.deinit(context);
        self.index_buffer.deinit(context);

        if (self.bones.len > 0) {
            self.bone_buffer.deinit(context);
        }

        var animation_iter = self.animations.iterator();
        while (animation_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.animations.deinit();

        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
        self.allocator.free(self.bones);
    }
};

/// Create a segmented cube with skeletal animation support
pub fn buildSegmentedCube(
    engine: *Engine,
    mesh: *SkeletalMesh,
    material: Handle,
    segments: u32,
    color: zm.Vec,
) !void {
    const actual_segments = if (segments < 2) 2 else segments;
    const bones = try engine.allocator.alloc(Handle, actual_segments);
    defer engine.allocator.free(bones);

    for (bones, 0..) |*bone, i| {
        bone.* = engine.resource.initNode(NodeType.bone);
        if (engine.resource.getNode(bone.*)) |node| {
            node.transform.position = .{
                .x = 0.0,
                .y = @as(f32, @floatFromInt(i)) * 2.0 / (@as(f32, @floatFromInt(actual_segments)) - 1.0),
                .z = 0.0,
            };
        }
    }

    const segment_height = 2.0 / @as(f32, @floatFromInt(actual_segments));
    // const half_segment = segment_height / 2.0;

    // Calculate vertex and index counts
    const vertex_count = actual_segments * 8;
    const index_count = actual_segments * 36; // 6 faces * 2 triangles * 3 vertices

    // Allocate vertices and indices
    var vertices = try engine.allocator.alloc(SkinnedVertex, vertex_count);
    defer engine.allocator.free(vertices);

    var indices = try engine.allocator.alloc(u32, index_count);
    defer engine.allocator.free(indices);

    var vertex_idx: usize = 0;
    var index_idx: usize = 0;

    // Create vertices and indices for each segment
    var s: u32 = 0;
    while (s < actual_segments) : (s += 1) {
        const y_bottom = -1.0 + @as(f32, @floatFromInt(s)) * segment_height;
        const y_top = y_bottom + segment_height;

        // Calculate bone weights
        const primary_bone = s;
        var secondary_bone = if (s < actual_segments - 1) s + 1 else s;
        var primary_weight: f32 = 1.0;
        var secondary_weight: f32 = 0.0;

        // For segments after the first one, blend with previous bone
        if (s > 0) {
            secondary_bone = s - 1;
            secondary_weight = 0.3;
            primary_weight = 0.7;
        }

        // Create vertices for this segment
        // Bottom face vertices
        vertices[vertex_idx] = .{
            .position = .{ .x = -1.0, .y = y_bottom, .z = -1.0 },
            .normal = .{ .x = 0.0, .y = -1.0, .z = 0.0 },
            .color = color,
            .uv = .{ .x = 0.0, .y = 0.0 },
            .joints = .{ .x = primary_bone, .y = secondary_bone, .z = 0, .w = 0 },
            .weights = .{ .x = primary_weight, .y = secondary_weight, .z = 0.0, .w = 0.0 },
        };
        vertex_idx += 1;

        vertices[vertex_idx] = .{
            .position = .{ .x = 1.0, .y = y_bottom, .z = -1.0 },
            .normal = .{ .x = 0.0, .y = -1.0, .z = 0.0 },
            .color = color,
            .uv = .{ .x = 1.0, .y = 0.0 },
            .joints = .{ .x = primary_bone, .y = secondary_bone, .z = 0, .w = 0 },
            .weights = .{ .x = primary_weight, .y = secondary_weight, .z = 0.0, .w = 0.0 },
        };
        vertex_idx += 1;

        vertices[vertex_idx] = .{
            .position = .{ .x = 1.0, .y = y_bottom, .z = 1.0 },
            .normal = .{ .x = 0.0, .y = -1.0, .z = 0.0 },
            .color = color,
            .uv = .{ .x = 1.0, .y = 1.0 },
            .joints = .{ .x = primary_bone, .y = secondary_bone, .z = 0, .w = 0 },
            .weights = .{ .x = primary_weight, .y = secondary_weight, .z = 0.0, .w = 0.0 },
        };
        vertex_idx += 1;

        vertices[vertex_idx] = .{
            .position = .{ .x = -1.0, .y = y_bottom, .z = 1.0 },
            .normal = .{ .x = 0.0, .y = -1.0, .z = 0.0 },
            .color = color,
            .uv = .{ .x = 0.0, .y = 1.0 },
            .joints = .{ .x = primary_bone, .y = secondary_bone, .z = 0, .w = 0 },
            .weights = .{ .x = primary_weight, .y = secondary_weight, .z = 0.0, .w = 0.0 },
        };
        vertex_idx += 1;

        // Top face vertices
        vertices[vertex_idx] = .{
            .position = .{ .x = -1.0, .y = y_top, .z = -1.0 },
            .normal = .{ .x = 0.0, .y = 1.0, .z = 0.0 },
            .color = color,
            .uv = .{ .x = 0.0, .y = 0.0 },
            .joints = .{ .x = primary_bone, .y = secondary_bone, .z = 0, .w = 0 },
            .weights = .{ .x = primary_weight, .y = secondary_weight, .z = 0.0, .w = 0.0 },
        };
        vertex_idx += 1;

        vertices[vertex_idx] = .{
            .position = .{ .x = 1.0, .y = y_top, .z = -1.0 },
            .normal = .{ .x = 0.0, .y = 1.0, .z = 0.0 },
            .color = color,
            .uv = .{ .x = 1.0, .y = 0.0 },
            .joints = .{ .x = primary_bone, .y = secondary_bone, .z = 0, .w = 0 },
            .weights = .{ .x = primary_weight, .y = secondary_weight, .z = 0.0, .w = 0.0 },
        };
        vertex_idx += 1;

        vertices[vertex_idx] = .{
            .position = .{ .x = 1.0, .y = y_top, .z = 1.0 },
            .normal = .{ .x = 0.0, .y = 1.0, .z = 0.0 },
            .color = color,
            .uv = .{ .x = 1.0, .y = 1.0 },
            .joints = .{ .x = primary_bone, .y = secondary_bone, .z = 0, .w = 0 },
            .weights = .{ .x = primary_weight, .y = secondary_weight, .z = 0.0, .w = 0.0 },
        };
        vertex_idx += 1;

        vertices[vertex_idx] = .{
            .position = .{ .x = -1.0, .y = y_top, .z = 1.0 },
            .normal = .{ .x = 0.0, .y = 1.0, .z = 0.0 },
            .color = color,
            .uv = .{ .x = 0.0, .y = 1.0 },
            .joints = .{ .x = primary_bone, .y = secondary_bone, .z = 0, .w = 0 },
            .weights = .{ .x = primary_weight, .y = secondary_weight, .z = 0.0, .w = 0.0 },
        };
        vertex_idx += 1;

        // Create indices for this segment
        const base = s * 8;

        // Bottom face
        indices[index_idx] = base + 0;
        index_idx += 1;
        indices[index_idx] = base + 2;
        index_idx += 1;
        indices[index_idx] = base + 1;
        index_idx += 1;
        indices[index_idx] = base + 0;
        index_idx += 1;
        indices[index_idx] = base + 3;
        index_idx += 1;
        indices[index_idx] = base + 2;
        index_idx += 1;

        // Top face
        indices[index_idx] = base + 4;
        index_idx += 1;
        indices[index_idx] = base + 5;
        index_idx += 1;
        indices[index_idx] = base + 6;
        index_idx += 1;
        indices[index_idx] = base + 4;
        index_idx += 1;
        indices[index_idx] = base + 6;
        index_idx += 1;
        indices[index_idx] = base + 7;
        index_idx += 1;

        // Front face
        indices[index_idx] = base + 3;
        index_idx += 1;
        indices[index_idx] = base + 7;
        index_idx += 1;
        indices[index_idx] = base + 6;
        index_idx += 1;
        indices[index_idx] = base + 3;
        index_idx += 1;
        indices[index_idx] = base + 6;
        index_idx += 1;
        indices[index_idx] = base + 2;
        index_idx += 1;

        // Back face
        indices[index_idx] = base + 0;
        index_idx += 1;
        indices[index_idx] = base + 1;
        index_idx += 1;
        indices[index_idx] = base + 5;
        index_idx += 1;
        indices[index_idx] = base + 0;
        index_idx += 1;
        indices[index_idx] = base + 5;
        index_idx += 1;
        indices[index_idx] = base + 4;
        index_idx += 1;

        // Left face
        indices[index_idx] = base + 0;
        index_idx += 1;
        indices[index_idx] = base + 4;
        index_idx += 1;
        indices[index_idx] = base + 7;
        index_idx += 1;
        indices[index_idx] = base + 0;
        index_idx += 1;
        indices[index_idx] = base + 7;
        index_idx += 1;
        indices[index_idx] = base + 3;
        index_idx += 1;

        // Right face
        indices[index_idx] = base + 1;
        index_idx += 1;
        indices[index_idx] = base + 2;
        index_idx += 1;
        indices[index_idx] = base + 6;
        index_idx += 1;
        indices[index_idx] = base + 1;
        index_idx += 1;
        indices[index_idx] = base + 6;
        index_idx += 1;
        indices[index_idx] = base + 5;
        index_idx += 1;
    }

    // Build the mesh
    try engine.buildSkeletalMesh(mesh, vertices[0..vertex_idx], indices[0..index_idx], bones, material);

    // Create a simple wiggle animation
    const animation_tracks = try engine.allocator.alloc(Animation, actual_segments);
    errdefer engine.allocator.free(animation_tracks);

    for (animation_tracks, 0..) |*anim, i| {
        anim.* = Animation{
            .bone_idx = @intCast(i),
            .positions = &[_]PositionKeyframe{},
            .rotations = undefined,
            .scales = &[_]ScaleKeyframe{},
        };

        // Create rotation keyframes to wiggle the bones
        var rotations = try engine.allocator.alloc(RotationKeyframe, 3);
        errdefer engine.allocator.free(rotations);

        const start_rot = zm.Quat{ 0.0, 0.0, 0.0, 1.0 };
        var mid_rot = zm.Quat{ 0.0, 0.0, 0.0, 1.0 };
        var end_rot = zm.Quat{ 0.0, 0.0, 0.0, 1.0 };

        if (i > 0) { // Don't animate the root bone
            // Create "wiggle" by rotating around X axis
            const axis = zm.Vec{ 1.0, 0.0, 0.0, 1.0 };
            mid_rot = zm.quatFromNormAxisAngle(axis, 0.3);
            end_rot = zm.quatFromNormAxisAngle(axis, 0.0);
        }

        rotations[0] = .{ .time = 0.0, .value = start_rot };
        rotations[1] = .{ .time = 1.0, .value = mid_rot };
        rotations[2] = .{ .time = 2.0, .value = end_rot };

        anim.rotations = rotations;
    }

    // Add animation to mesh
    try mesh.animations.put("Wiggle", AnimationTrack{
        .animations = animation_tracks,
        .duration = 2.0,
    });
}
