const std = @import("std");
const zm = @import("zmath");

pub const Light = struct {
    color: [3]f32 = .{ 1.0, 0.0, 1.0 },
    intensity: f32 = 1.0,
    data: union(enum) {
        point: void,
        directional: zm.Vec,
        spot: struct {
            direction: zm.Vec,
            angle: f32,
        },
    },
};
