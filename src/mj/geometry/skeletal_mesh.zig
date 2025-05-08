const std = @import("std");
const zm = @import("zmath");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const context = @import("../engine/context.zig").get();
const DataBuffer = @import("../engine/data_buffer.zig").DataBuffer;
const Handle = @import("../engine/resource.zig").Handle;
const Transform = @import("../scene/node.zig").Transform;
const animation = @import("animation.zig");
const Pose = @import("animation.zig").Pose;
const SkinnedVertex = @import("geometry.zig").SkinnedVertex;
const SkinnedGeometry = @import("geometry.zig").SkinnedGeometry;
const Aabb = @import("geometry.zig").Aabb;

pub const Bone = struct {
    bind_transform: Transform = .{},
    children: []u32 = undefined,
    inverse_bind_matrix: zm.Mat = zm.identity(),
};

/// Skeletal mesh with skinning support
pub const SkeletalMesh = struct {
    root_bone: u16 = 0,
    bones: []Bone,
    animations: []animation.Clip,
    vertices_len: u32 = 0,
    indices_len: u32 = 0,
    vertex_buffer: DataBuffer = undefined,
    simple_vertex_buffer: DataBuffer = undefined,
    index_buffer: DataBuffer = undefined,
    material: Handle = undefined,
    aabb: Aabb = .{},

    pub fn init(
        self: *SkeletalMesh,
        geometry: SkinnedGeometry,
        allocator: std.mem.Allocator,
    ) !void {
        self.vertices_len = @intCast(geometry.vertices.len);
        self.indices_len = @intCast(geometry.indices.len);
        self.simple_vertex_buffer = try context.*.createLocalBuffer(std.mem.sliceAsBytes(geometry.extractPositions(allocator)), .{ .vertex_buffer_bit = true });
        self.vertex_buffer = try context.*.createLocalBuffer(std.mem.sliceAsBytes(geometry.vertices), .{ .vertex_buffer_bit = true });
        self.index_buffer = try context.*.createLocalBuffer(std.mem.sliceAsBytes(geometry.indices), .{ .index_buffer_bit = true });
        self.aabb = geometry.aabb;
    }

    pub fn playAnimation(self: *SkeletalMesh, animation_name: []const u8, mode: animation.PlayMode) !animation.Instance {
        for (self.animations, 0..) |clip, i| {
            if (std.mem.eql(u8, clip.name, animation_name)) {
                return .{
                    .clip = @intCast(i),
                    .mode = mode,
                    .status = .playing,
                    .time = 0,
                    .duration = self.animations[i].duration,
                };
            }
        }
        return error.AnimationNotFound;
    }

    pub fn calculateAnimationTransform(self: *SkeletalMesh, allocator: Allocator, anim: *animation.Instance, pose: *Pose) void {
        var transform_stack = std.ArrayList(zm.Mat).init(allocator);
        defer transform_stack.deinit();
        var bone_stack = std.ArrayList(u32).init(allocator);
        defer bone_stack.deinit();
        transform_stack.append(zm.identity()) catch unreachable;
        bone_stack.append(self.root_bone) catch unreachable;
        while (bone_stack.pop()) |bone_index| {
            const parent_matrix = transform_stack.pop().?;
            var animated_transform: Transform = .{};
            self.animations[anim.clip].animations[bone_index].calculate(anim.time, &animated_transform);
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
        self.simple_vertex_buffer.deinit();
        self.index_buffer.deinit();
    }
};
