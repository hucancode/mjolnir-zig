const std = @import("std");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;

const context = @import("../engine/context.zig").get();
const DataBuffer = @import("../engine/data_buffer.zig").DataBuffer;
const Handle = @import("../engine/resource.zig").Handle;

/// Vertex structure for static meshes
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

/// Static mesh structure
pub const StaticMesh = struct {
    material: Handle,
    vertices_len: u32 = 0,
    indices_len: u32 = 0,
    vertex_buffer: DataBuffer,
    index_buffer: DataBuffer,

    pub fn deinit(self: *StaticMesh) void {
        self.vertex_buffer.deinit();
        self.index_buffer.deinit();
    }
    pub fn buildMesh(
        self: *StaticMesh,
        vertices: []const Vertex,
        indices: []const u32,
        material: Handle,
    ) !void {
        self.material = material;
        self.vertices_len = @intCast(vertices.len);
        self.indices_len = @intCast(indices.len);
        std.debug.print("Building mesh with {d} vertices {d} indices\n", .{ vertices.len, indices.len });
        self.vertex_buffer = try context.*.createLocalBuffer(std.mem.sliceAsBytes(vertices), .{ .vertex_buffer_bit = true });
        self.index_buffer = try context.*.createLocalBuffer(std.mem.sliceAsBytes(indices), .{ .index_buffer_bit = true });
        std.debug.print("Mesh indices and vertices built\n", .{});
    }
    /// Build a cube mesh
    pub fn buildCube(
        self: *StaticMesh,
        material: Handle,
        color: [4]f32,
    ) !void {
        // Define cube corners
        const A = [3]f32{ -1.0, -1.0, 1.0 };
        const B = [3]f32{ 1.0, -1.0, 1.0 };
        const C = [3]f32{ 1.0, 1.0, 1.0 };
        const D = [3]f32{ -1.0, 1.0, 1.0 };
        const E = [3]f32{ -1.0, 1.0, -1.0 };
        const F = [3]f32{ 1.0, 1.0, -1.0 };
        const G = [3]f32{ 1.0, -1.0, -1.0 };
        const H = [3]f32{ -1.0, -1.0, -1.0 };
        const VEC_FORWARD = [3]f32{ 0.0, 0.0, 1.0 };
        const VEC_BACKWARD = [3]f32{ 0.0, 0.0, -1.0 };
        const VEC_UP = [3]f32{ 0.0, 1.0, 0.0 };
        const VEC_DOWN = [3]f32{ 0.0, -1.0, 0.0 };
        const VEC_LEFT = [3]f32{ -1.0, 0.0, 0.0 };
        const VEC_RIGHT = [3]f32{ 1.0, 0.0, 0.0 };

        // Create vertices for all 6 faces
        const vertices = [_]Vertex{
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
        const indices = [_]u32{
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

        try self.buildMesh(&vertices, &indices, material);
    }
};
