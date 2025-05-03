const std = @import("std");
const expect = std.testing.expect;

pub const Vec = @Vector(4, f32);
pub const Mat = [4]Vec;

pub const LightUniform = struct {
    color: Vec,
    position: Vec,
    direction: Vec,
    kind: u32,
    angle: f32,
    intensity: f32,
    // padding 4
};
pub const SceneUniform = struct {
    view: Mat,
    projection: Mat,
    lights: [10]LightUniform,
    time: f32,
    light_count: u32,
    // padding 4
    // padding 4
};
test "struct size" {
    try expect(@sizeOf(LightUniform) == 64);
    try expect(@offsetOf(LightUniform, "kind") == 48);
    try expect(@sizeOf(SceneUniform) == 64 + 64 + 640 + 16);
    try expect(@offsetOf(SceneUniform, "lights") == 64 + 64);
}
