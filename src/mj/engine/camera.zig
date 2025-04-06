const std = @import("std");
const zm = @import("zmath");

pub const Camera = struct {
    up: zm.Vec,
    position: zm.Vec,
    rotation: zm.Quat,
    projection: union(enum) {
        perspective: struct {
            fov: f32,
            aspect_ratio: f32,
            near: f32,
            far: f32,
        },
        orthographic: struct {
            width: f32,
            height: f32,
            near: f32,
            far: f32,
        },
    },

    pub fn calculateProjectionMatrix(self: *const Camera) zm.Mat {
        return switch (self.projection) {
            .perspective => |persp| zm.perspectiveFovLh(persp.fov, persp.aspect_ratio, persp.near, persp.far),
            .orthographic => |ortho| zm.orthographicLh(ortho.width, ortho.height, ortho.near, ortho.far),
        };
    }

    pub fn lookAt(self: *Camera, target: zm.Vec) void {
        const lookat_matrix = zm.lookAtLh(self.position, target, self.up);
        self.rotation = zm.quatFromMat(lookat_matrix);
    }

    pub fn calculateViewMatrix(self: *const Camera) zm.Mat {
        const forward = zm.rotate(self.rotation, .{ 0.0, 0.0, 1.0, 0.0 });
        return zm.lookToLh(self.position, forward, self.up);
    }
};
