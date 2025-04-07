const std = @import("std");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

pub const Handle = struct {
    index: u24 = 0,
    generation: u8 = 1,
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
            if (entry.generation != handle.generation or !entry.active) {
                return;
            }
            self.entries.items[handle.index].active = false;
            self.entries.items[handle.index].generation += 1;
            self.free_indices.append(handle.index) catch {};
        }

        pub fn get(self: *Self, handle: Handle) ?*T {
            if (handle.index >= self.entries.items.len) {
                // std.debug.print("ResourcePool.get: index ({d}) out of bounds ({d})\n", .{ handle.index, self.entries.items.len });
                return null;
            }
            if (!self.entries.items[handle.index].active) {
                // std.debug.print("ResourcePool.get: index ({d}) has been freed\n", .{handle.index});
                return null;
            }
            if (self.entries.items[handle.index].generation != handle.generation) {
                // std.debug.print("ResourcePool.get: index ({d}) has been deallocated, its generation is changed from {d} to {d}\n", .{ handle.index, handle.generation, self.entries.items[handle.index].generation });
                return null;
            }
            return &self.entries.items[handle.index].item;
        }
    };
}
