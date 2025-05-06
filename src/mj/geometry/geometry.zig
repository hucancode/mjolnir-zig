const std = @import("std");
const vk = @import("vulkan");

pub const Vertex = struct {
    position: [3]f32,
    normal: [3]f32,
    color: [4]f32,
    uv: [2]f32,
};

/// Vertex input binding description for static vertices
pub const VERTEX_DESCRIPTION = [_]vk.VertexInputBindingDescription{
    .{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    },
};

/// Vertex attribute description for static vertices
pub const VERTEX_ATTR_DESCRIPTION = [_]vk.VertexInputAttributeDescription{
    // Position
    .{
        .binding = 0,
        .location = 0,
        .format = .r32g32b32_sfloat,
        .offset = @offsetOf(Vertex, "position"),
    },
    // Normal
    .{
        .binding = 0,
        .location = 1,
        .format = .r32g32b32_sfloat,
        .offset = @offsetOf(Vertex, "normal"),
    },
    // Color
    .{
        .binding = 0,
        .location = 2,
        .format = .r32g32b32a32_sfloat,
        .offset = @offsetOf(Vertex, "color"),
    },
    // UV
    .{
        .binding = 0,
        .location = 3,
        .format = .r32g32_sfloat,
        .offset = @offsetOf(Vertex, "uv"),
    },
};
const VEC_FORWARD = [3]f32{ 0.0, 0.0, 1.0 };
const VEC_BACKWARD = [3]f32{ 0.0, 0.0, -1.0 };
const VEC_UP = [3]f32{ 0.0, 1.0, 0.0 };
const VEC_DOWN = [3]f32{ 0.0, -1.0, 0.0 };
const VEC_LEFT = [3]f32{ -1.0, 0.0, 0.0 };
const VEC_RIGHT = [3]f32{ 1.0, 0.0, 0.0 };

pub const Geometry = struct {
    vertices: []const Vertex,
    indices: []const u32,

    pub fn extractPositions(self: *const Geometry, allocator: std.mem.Allocator) []const [4]f32 {
        var positions = allocator.alloc([4]f32, self.vertices.len) catch unreachable;
        for (0..self.vertices.len) |i| {
            positions[i][0] = self.vertices[i].position[0];
            positions[i][1] = self.vertices[i].position[1];
            positions[i][2] = self.vertices[i].position[2];
            positions[i][3] = 1.0;
        }
        return positions;
    }

    pub fn make(vertices: []const Vertex, indices: []const u32) Geometry {
        return .{
            .vertices = vertices,
            .indices = indices,
        };
    }

    pub fn cube(comptime color: [4]f32) Geometry {
        // Define cube corners
        const A = comptime [3]f32{ -1.0, -1.0, 1.0 };
        const B = comptime [3]f32{ 1.0, -1.0, 1.0 };
        const C = comptime [3]f32{ 1.0, 1.0, 1.0 };
        const D = comptime [3]f32{ -1.0, 1.0, 1.0 };
        const E = comptime [3]f32{ -1.0, 1.0, -1.0 };
        const F = comptime [3]f32{ 1.0, 1.0, -1.0 };
        const G = comptime [3]f32{ 1.0, -1.0, -1.0 };
        const H = comptime [3]f32{ -1.0, -1.0, -1.0 };

        // Create vertices for all 6 faces
        const vertices = comptime [_]Vertex{
            // Front face
            .{ .position = A, .color = color, .normal = VEC_FORWARD, .uv = .{ 0.0, 1.0 } },
            .{ .position = B, .color = color, .normal = VEC_FORWARD, .uv = .{ 1.0, 1.0 } },
            .{ .position = C, .color = color, .normal = VEC_FORWARD, .uv = .{ 1.0, 0.0 } },
            .{ .position = D, .color = color, .normal = VEC_FORWARD, .uv = .{ 0.0, 0.0 } },

            // Back face
            .{ .position = E, .color = color, .normal = VEC_BACKWARD, .uv = .{ 1.0, 1.0 } },
            .{ .position = F, .color = color, .normal = VEC_BACKWARD, .uv = .{ 0.0, 1.0 } },
            .{ .position = G, .color = color, .normal = VEC_BACKWARD, .uv = .{ 0.0, 0.0 } },
            .{ .position = H, .color = color, .normal = VEC_BACKWARD, .uv = .{ 1.0, 0.0 } },

            // Top face
            .{ .position = F, .color = color, .normal = VEC_UP, .uv = .{ 0.0, 1.0 } },
            .{ .position = E, .color = color, .normal = VEC_UP, .uv = .{ 1.0, 1.0 } },
            .{ .position = D, .color = color, .normal = VEC_UP, .uv = .{ 1.0, 0.0 } },
            .{ .position = C, .color = color, .normal = VEC_UP, .uv = .{ 0.0, 0.0 } },

            // Bottom face
            .{ .position = B, .color = color, .normal = VEC_DOWN, .uv = .{ 0.0, 1.0 } },
            .{ .position = A, .color = color, .normal = VEC_DOWN, .uv = .{ 1.0, 1.0 } },
            .{ .position = H, .color = color, .normal = VEC_DOWN, .uv = .{ 1.0, 0.0 } },
            .{ .position = G, .color = color, .normal = VEC_DOWN, .uv = .{ 0.0, 0.0 } },

            // Right face
            .{ .position = G, .color = color, .normal = VEC_RIGHT, .uv = .{ 0.0, 1.0 } },
            .{ .position = F, .color = color, .normal = VEC_RIGHT, .uv = .{ 1.0, 1.0 } },
            .{ .position = C, .color = color, .normal = VEC_RIGHT, .uv = .{ 1.0, 0.0 } },
            .{ .position = B, .color = color, .normal = VEC_RIGHT, .uv = .{ 0.0, 0.0 } },

            // Left face
            .{ .position = A, .color = color, .normal = VEC_LEFT, .uv = .{ 0.0, 1.0 } },
            .{ .position = D, .color = color, .normal = VEC_LEFT, .uv = .{ 1.0, 1.0 } },
            .{ .position = E, .color = color, .normal = VEC_LEFT, .uv = .{ 1.0, 0.0 } },
            .{ .position = H, .color = color, .normal = VEC_LEFT, .uv = .{ 0.0, 0.0 } },
        };

        // Define triangle indices for the cube
        const indices = comptime [_]u32{
            // Front face
            0,  1,  2,  2,  3,  0,
            // Back face
            4,  5,  6,  6,  7,  4,
            // Top face
            8,  9,  10, 10, 11, 8,
            // Bottom face
            12, 13, 14, 14, 15, 12,
            // Right face
            16, 17, 18, 18, 19, 16,
            // Left face
            20, 21, 22, 22, 23, 20,
        };
        return .{
            .vertices = &vertices,
            .indices = &indices,
        };
    }

    pub fn triangle(comptime color: [4]f32) Geometry {
        const vertices = comptime [_]Vertex{
            .{ .position = .{ 0.0, 0.0, 0.0 }, .color = color, .normal = VEC_FORWARD, .uv = .{ 0.0, 0.0 } },
            .{ .position = .{ 1.0, 0.0, 0.0 }, .color = color, .normal = VEC_FORWARD, .uv = .{ 1.0, 0.0 } },
            .{ .position = .{ 0.5, 1.0, 0.0 }, .color = color, .normal = VEC_FORWARD, .uv = .{ 0.5, 1.0 } },
        };
        const indices = comptime [_]u32{
            0, 1, 2,
        };
        return .{
            .vertices = &vertices,
            .indices = &indices,
        };
    }

    pub fn quad(comptime color: [4]f32) Geometry {
        const vertices = comptime [_]Vertex{
            .{ .position = .{ 0.0, 0.0, 0.0 }, .color = color, .normal = VEC_UP, .uv = .{ 0.0, 0.0 } },
            .{ .position = .{ 0.0, 0.0, 1.0 }, .color = color, .normal = VEC_UP, .uv = .{ 0.0, 1.0 } },
            .{ .position = .{ 1.0, 0.0, 1.0 }, .color = color, .normal = VEC_UP, .uv = .{ 1.0, 1.0 } },
            .{ .position = .{ 1.0, 0.0, 0.0 }, .color = color, .normal = VEC_UP, .uv = .{ 1.0, 0.0 } },
        };
        const indices = comptime [_]u32{
            0, 1, 2, 2, 3, 0,
        };
        return .{
            .vertices = &vertices,
            .indices = &indices,
        };
    }

    pub fn sphere(comptime segments: u32, comptime rings: u32) Geometry {
        // TODO: calculate sphere geometry here
        _ = segments;
        _ = rings;
        const vertices = comptime [_]Vertex{};
        const indices = comptime [_]u32{};
        return .{
            .vertices = &vertices,
            .indices = &indices,
        };
    }
};

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

pub const SkinnedGeometry = struct {
    vertices: []const SkinnedVertex,
    indices: []const u32,

    pub fn extractPositions(self: *const SkinnedGeometry, allocator: std.mem.Allocator) []const [4]f32 {
        var positions = allocator.alloc([4]f32, self.vertices.len) catch unreachable;
        for (0..self.vertices.len) |i| {
            positions[i][0] = self.vertices[i].position[0];
            positions[i][1] = self.vertices[i].position[1];
            positions[i][2] = self.vertices[i].position[2];
            positions[i][3] = 1.0;
        }
        return positions;
    }

    pub fn make(vertices: []const SkinnedVertex, indices: []const u32) SkinnedGeometry {
        return .{
            .vertices = vertices,
            .indices = indices,
        };
    }
};
