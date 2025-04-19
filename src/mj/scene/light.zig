const std = @import("std");
const zm = @import("zmath");

pub const Light = struct {
    color: zm.Vec = .{ 1.0, 1.0, 1.0, 1.0 },
    data: union(enum) {
        point: void,
        directional: void,
        spot: f32, // angle
    },
};
