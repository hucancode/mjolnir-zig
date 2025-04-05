const std = @import("std");
const zm = @import("zmath");
pub const LightType = enum {
    point,
    directional,
    spot,
};

pub const Light = struct {
    color: zm.Vec = .{ 1.0, 1.0, 1.0, 1.0 },
    type: LightType = .point,
    intensity: f32 = 1.0,
    pub fn init() Light {
        return .{};
    }
    pub fn initWithColor(color: zm.Vec, light_type: LightType, intensity: f32) Light {
        return .{
            .color = color,
            .type = light_type,
            .intensity = intensity,
        };
    }
    pub fn setColor(self: *Light, r: f32, g: f32, b: f32, a: f32) void {
        self.color = .{ r, g, b, a };
    }
};
