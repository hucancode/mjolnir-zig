const std = @import("std");
const zm = @import("zmath");
const Allocator = std.mem.Allocator;
const ResourcePool = @import("../engine/resource.zig").ResourcePool;
const Handle = @import("../engine/resource.zig").Handle;
const Node = @import("../scene/node.zig").Node;

/// Generic keyframe type for animations
pub fn Keyframe(comptime T: type) type {
    return struct {
        time: f32,
        value: T,
    };
}

/// Generic sample type for interpolation
pub fn Sample(comptime T: type) type {
    return struct {
        alpha: f32,
        a: T,
        b: T,
    };
}

/// Function type for merging values during interpolation
pub fn MergeProc(comptime T: type) type {
    return fn (a: T, b: T, alpha: f32) T;
}

/// Sample a value from keyframes at a specific time
pub fn sample(comptime T: type, frames: []const Keyframe(T), t: f32, merge: MergeProc(T)) T {
    if (frames.len == 0 or t - frames[0].time < 1e-6) {
        return std.mem.zeroes(T);
    }
    if (t >= frames[frames.len - 1].time) {
        return frames[frames.len - 1].value;
    }
    const i = std.sort.lowerBound(Keyframe(T), frames, t, compareKeyframes(T));
    const a = frames[i - 1];
    const b = frames[i];
    const alpha = (t - a.time) / (b.time - a.time);
    return merge(a.value, b.value, alpha);
}

fn compareKeyframes(comptime T: type) fn (f32, Keyframe(T)) std.math.Order {
    const S = struct {
        fn predicate(target: f32, item: Keyframe(T)) std.math.Order {
            return std.math.order(target, item.time);
        }
    };
    return S.predicate;
}

// Animation-specific types
pub const PositionKeyframe = Keyframe(zm.Vec);
pub const ScaleKeyframe = Keyframe(zm.Vec);
pub const RotationKeyframe = Keyframe(zm.Quat);

// Animation status and modes
pub const AnimationStatus = enum {
    playing,
    paused,
    stopped,
};

pub const AnimationPlayMode = enum {
    loop,
    once,
    pingpong,
};

// Instance of an animation being played
pub const AnimationInstance = struct {
    mode: AnimationPlayMode,
    status: AnimationStatus,
    name: []const u8,
    time: f32,
};

// Animation for a single bone/node
pub const Animation = struct {
    bone_idx: u32,
    positions: []PositionKeyframe,
    rotations: []RotationKeyframe,
    scales: []ScaleKeyframe,

    pub fn deinit(self: *Animation, allocator: Allocator) void {
        allocator.free(self.positions);
        allocator.free(self.rotations);
        allocator.free(self.scales);
    }

    fn lerp_vector(a: zm.Vec, b: zm.Vec, t: f32) zm.Vec {
        return zm.lerp(a, b, t);
    }

    fn lerp_quat(a: zm.Quat, b: zm.Quat, t: f32) zm.Quat {
        return zm.slerp(a, b, t);
    }

    pub fn update(self: *Animation, t: f32, node_pool: *ResourcePool(Node), bones: []const Handle) void {
        const target = node_pool.get(bones[self.bone_idx]) orelse return;
        if (self.positions.len > 0) {
            target.transform.position = sample(zm.Vec, self.positions, t, Animation.lerp_vector);
        }
        if (self.rotations.len > 0) {
            target.transform.rotation = sample(zm.Quat, self.rotations, t, Animation.lerp_quat);
        }
        if (self.scales.len > 0) {
            target.transform.scale = sample(zm.Vec, self.scales, t, Animation.lerp_vector);
        }
    }
};

// Track containing multiple animations with the same duration
pub const AnimationTrack = struct {
    animations: []Animation,
    duration: f32,

    pub fn deinit(self: *AnimationTrack, allocator: Allocator) void {
        for (self.animations) |*animation| {
            animation.deinit(allocator);
        }
        allocator.free(self.animations);
    }

    pub fn update(self: *AnimationTrack, t: f32, node_pool: *ResourcePool(Node), bones: []const Handle) void {
        for (self.animations) |*animation| {
            animation.update(t, node_pool, bones);
        }
    }
};
