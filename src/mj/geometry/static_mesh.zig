const std = @import("std");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;

const VulkanContext = @import("../engine/context.zig").VulkanContext;
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
    vertices: []const Vertex,
    indices: []const u32,
    vertex_buffer: DataBuffer,
    index_buffer: DataBuffer,
    allocator: Allocator,

    pub fn init(allocator: Allocator) StaticMesh {
        return .{
            .material = undefined,
            .vertices = &[_]Vertex{},
            .indices = &[_]u32{},
            .vertex_buffer = undefined,
            .index_buffer = undefined,
            .allocator = allocator,
        };
    }

    pub fn destroy(self: *StaticMesh, context: *VulkanContext) void {
        self.vertex_buffer.destroy(context);
        self.index_buffer.destroy(context);
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
    }
};

/// Build a static mesh with custom vertex and index data
pub fn buildMesh(
    context: *VulkanContext,
    mesh: *StaticMesh,
    vertices: []const Vertex,
    indices: []const u32,
    material: Handle,
) !void {
    mesh.material = material;
    mesh.vertices = vertices;
    mesh.indices = indices;

    std.debug.print("Building mesh with {d} vertices {d} indices\n", .{ vertices.len, indices.len });

    mesh.vertex_buffer = try context.createLocalBuffer(std.mem.sliceAsBytes(mesh.vertices), .{ .vertex_buffer_bit = true });

    mesh.index_buffer = try context.createLocalBuffer(std.mem.sliceAsBytes(mesh.indices), .{ .index_buffer_bit = true });

    std.debug.print("Mesh indices and vertices built\n", .{});
}

/// Build a cube mesh
pub fn buildCube(
    context: *VulkanContext,
    mesh: *StaticMesh,
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

    try buildMesh(context, mesh, &vertices, &indices, material);
}
