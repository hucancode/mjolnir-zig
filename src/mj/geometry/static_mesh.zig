const std = @import("std");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;

const context = @import("../engine/context.zig").get();
const DataBuffer = @import("../engine/data_buffer.zig").DataBuffer;
const Handle = @import("../engine/resource.zig").Handle;
const Vertex = @import("geometry.zig").Vertex;
const Geometry = @import("geometry.zig").Geometry;

/// Static mesh structure
pub const StaticMesh = struct {
    material: Handle,
    vertices_len: u32 = 0,
    indices_len: u32 = 0,
    simple_vertex_buffer: DataBuffer,
    vertex_buffer: DataBuffer,
    index_buffer: DataBuffer,

    pub fn deinit(self: *StaticMesh) void {
        self.vertex_buffer.deinit();
        self.simple_vertex_buffer.deinit();
        self.index_buffer.deinit();
    }

    pub fn init(
        self: *StaticMesh,
        geometry: Geometry,
        allocator: std.mem.Allocator,
    ) !void {
        self.vertices_len = @intCast(geometry.vertices.len);
        self.indices_len = @intCast(geometry.indices.len);
        self.simple_vertex_buffer = try context.*.createLocalBuffer(std.mem.sliceAsBytes(geometry.extractPositions(allocator)), .{ .vertex_buffer_bit = true });
        self.vertex_buffer = try context.*.createLocalBuffer(std.mem.sliceAsBytes(geometry.vertices), .{ .vertex_buffer_bit = true });
        self.index_buffer = try context.*.createLocalBuffer(std.mem.sliceAsBytes(geometry.indices), .{ .index_buffer_bit = true });
    }
};
