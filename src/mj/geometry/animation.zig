const std = @import("std");
const zm = @import("zmath");
const Allocator = std.mem.Allocator;
const ResourcePool = @import("../engine/resource.zig").ResourcePool;
const Handle = @import("../engine/resource.zig").Handle;
const Node = @import("../scene/node.zig").Node;
const Transform = @import("../scene/node.zig").Transform;
const DataBuffer = @import("../engine/data_buffer.zig").DataBuffer;

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
pub fn sampleKeyframe(comptime T: type, frames: []const Keyframe(T), t: f32, merge: MergeProc(T)) T {
    if (frames.len == 0) {
        std.debug.panic("no frames to sample from", .{});
        return std.mem.zeroes(T);
    }
    if (t - frames[0].time < 1e-6) {
        return frames[0].value;
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
pub const Pose = struct {
    bone_matrices: []zm.Mat,
    bone_buffer: DataBuffer = undefined,

    pub fn deinit(self: *Pose) void {
        self.bone_buffer.deinit();
    }

    pub fn flush(self: *Pose) void {
        self.bone_buffer.write(std.mem.sliceAsBytes(self.bone_matrices));
    }
};

pub const AnimationInstance = struct {
    clip: u32,
    mode: AnimationPlayMode,
    status: AnimationStatus,
    time: f32,
    duration: f32,

    pub fn update(self: *AnimationInstance, delta_time: f32) void {
        switch (self.mode) {
            .loop => {
                self.time += delta_time;
                self.time = @rem(self.time, self.duration);
            },
            .once => {
                self.time += delta_time;
                if (self.time >= self.duration) {
                    self.status = .stopped;
                }
            },
            .pingpong => {
                self.time += delta_time;
                if (self.time >= self.duration) {
                    self.time = self.duration - self.time;
                    self.status = .stopped;
                }
            },
        }
    }
};

pub const AnimationClip = struct {
    name: []const u8,
    duration: f32,
    animations: []AnimationChannel,
};

pub const AnimationChannel = struct {
    position: []Keyframe(zm.Vec) = undefined,
    rotation: []Keyframe(zm.Quat) = undefined,
    scale: []Keyframe(zm.Vec),

    pub fn deinit(self: *AnimationChannel, allocator: Allocator) void {
        allocator.free(self.position);
        allocator.free(self.rotation);
        allocator.free(self.scale);
    }

    fn lerp_vector(a: zm.Vec, b: zm.Vec, t: f32) zm.Vec {
        return zm.lerp(a, b, t);
    }

    fn lerp_quat(a: zm.Quat, b: zm.Quat, t: f32) zm.Quat {
        return zm.slerp(a, b, t);
    }

    pub fn update(self: *AnimationChannel, t: f32, target: *Transform) void {
        if (self.position.len > 0) {
            target.position = sampleKeyframe(zm.Vec, self.position, t, AnimationChannel.lerp_vector);
        }
        if (self.rotation.len > 0) {
            target.rotation = sampleKeyframe(zm.Quat, self.rotation, t, AnimationChannel.lerp_quat);
        }
        if (self.scale.len > 0) {
            target.scale = sampleKeyframe(zm.Vec, self.scale, t, AnimationChannel.lerp_vector);
        }
    }

    pub fn calculate(self: *AnimationChannel, t: f32, output: *Transform) void {
        if (self.position.len > 0) {
            output.position = sampleKeyframe(zm.Vec, self.position, t, AnimationChannel.lerp_vector);
        }
        if (self.rotation.len > 0) {
            output.rotation = sampleKeyframe(zm.Quat, self.rotation, t, AnimationChannel.lerp_quat);
        }
        if (self.scale.len > 0) {
            output.scale = sampleKeyframe(zm.Vec, self.scale, t, AnimationChannel.lerp_vector);
        }
    }
};
