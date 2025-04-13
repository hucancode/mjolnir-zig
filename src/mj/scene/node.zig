const std = @import("std");
const zm = @import("zmath");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const Handle = @import("../engine/resource.zig").Handle;
const AnimationInstance = @import("../geometry/animation.zig").AnimationInstance;

/// Transform component for nodes
pub const Transform = struct {
    position: zm.Vec = zm.f32x4s(0.0),
    rotation: zm.Quat = zm.qidentity(),
    scale: zm.Vec = zm.f32x4s(1.0),
    is_dirty: bool = false,
    local_matrix: zm.Mat = zm.identity(),
    world_matrix: zm.Mat = zm.identity(),
    pub fn toMatrix(self: *const Transform) zm.Mat {
        return zm.mul(zm.mul(zm.matFromQuat(self.rotation), zm.translationV(self.position)), zm.scalingV(self.scale));
    }
    pub fn fromMatrix(self: *Transform, m: zm.Mat) void {
        std.debug.print("load matrix {any}\n", .{m});
        self.position = zm.Vec{ m[0][3], m[1][3], m[2][3], 1.0 };
        const x_scale = zm.length3(m[0])[0];
        const y_scale = zm.length3(m[1])[0];
        const z_scale = zm.length3(m[2])[0];
        self.scale = zm.f32x4(x_scale, y_scale, z_scale, 1.0);
        const safe_x_scale = if (x_scale == 0.0) 1.0 else x_scale;
        const safe_y_scale = if (y_scale == 0.0) 1.0 else y_scale;
        const safe_z_scale = if (z_scale == 0.0) 1.0 else z_scale;
        const rotation_matrix = zm.Mat{
            zm.f32x4(m[0][0] / safe_x_scale, m[0][1] / safe_x_scale, m[0][2] / safe_x_scale, 0.0),
            zm.f32x4(m[1][0] / safe_y_scale, m[1][1] / safe_y_scale, m[1][2] / safe_y_scale, 0.0),
            zm.f32x4(m[2][0] / safe_z_scale, m[2][1] / safe_z_scale, m[2][2] / safe_z_scale, 0.0),
            zm.f32x4(0.0, 0.0, 0.0, 1.0),
        };
        self.rotation = zm.quatFromMat(rotation_matrix);
    }
};
/// Scene node
pub const Node = struct {
    parent: Handle,
    children: ArrayList(Handle),
    allocator: Allocator,
    transform: Transform,
    data: union(enum) {
        light: Handle,
        skeletal_mesh: struct {
            handle: Handle,
            animation: AnimationInstance,
        },
        static_mesh: Handle,
        none,
    },

    pub fn init(self: *Node, allocator: Allocator) void {
        self.children = ArrayList(Handle).init(allocator);
        self.allocator = allocator;
        self.transform = .{};
    }

    pub fn deinit(self: *Node) void {
        self.children.deinit();
    }
};

/// Node pool methods for managing the parent-child hierarchy
pub fn unparentNode(pool: anytype, node: Handle) void {
    const child_node = pool.get(node) orelse return;
    const parent_handle = child_node.parent;

    // If no parent or parent is self, nothing to do
    if (parent_handle.index == 0 or (parent_handle.index == node.index and parent_handle.generation == node.generation)) {
        return;
    }

    const parent_node = pool.get(parent_handle) orelse return;
    if (parent_node == child_node) return;

    // Find and remove child from parent's children
    for (parent_node.children.items, 0..) |child, i| {
        if (child.index == node.index and child.generation == node.generation) {
            // Replace with last item and pop
            if (i < parent_node.children.items.len - 1) {
                parent_node.children.items[i] = parent_node.children.items[parent_node.children.items.len - 1];
            }
            _ = parent_node.children.pop();
            break;
        }
    }

    // Set node's parent to itself (no parent)
    child_node.parent = node;
}

pub fn parentNode(pool: anytype, parent: Handle, child: Handle) void {
    // First unparent the child
    unparentNode(pool, child);

    const parent_node = pool.get(parent) orelse return;
    const child_node = pool.get(child) orelse return;

    std.debug.print("Parenting node {*} type {any} to {*} type {any}\n", .{ child_node, child_node.data, parent_node, parent_node.data });

    // Set parent-child relationship
    child_node.parent = parent;
    parent_node.children.append(child) catch |err| {
        std.debug.print("Failed to append child: {any}\n", .{err});
    };
}
