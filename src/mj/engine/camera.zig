const std = @import("std");
const zm = @import("zmath");

pub const Camera = union(enum) {
    perspective: struct {
        fov: f32,
        aspect_ratio: f32,
        near: f32,
        far: f32,
        up: zm.Vec,
        position: zm.Vec,
        rotation: zm.Quat,
    },
    orthographic: struct {
        width: f32,
        height: f32,
        near: f32,
        far: f32,
        up: zm.Vec,
        position: zm.Vec,
        rotation: zm.Quat,
    },

    pub fn calculateProjectionMatrix(self: *const Camera) zm.Mat {
        return switch (self.*) {
            .perspective => |persp| zm.perspectiveFovRhGl(
                persp.fov,
                persp.aspect_ratio,
                persp.near,
                persp.far
            ),
            .orthographic => |ortho| zm.orthographicRhGl(
                ortho.width,
                ortho.height,
                ortho.near,
                ortho.far
            ),
        };
    }

    pub fn calculateLookatMatrix(self: *const Camera, target: zm.Vec) zm.Mat {
        return switch (self.*) {
            .perspective => |persp| zm.lookAtRh(
                persp.position,
                target,
                persp.up
            ),
            .orthographic => |ortho| zm.lookAtRh(
                ortho.position,
                target,
                ortho.up
            ),
        };
    }

    pub fn calculateViewMatrix(self: *const Camera) zm.Mat {
        const forward = switch (self.*) {
            .perspective => |persp| zm.normalize3(
                zm.mul(zm.f32x4(0.0, 0.0, 1.0, 0.0), zm.matFromQuat(persp.rotation))
            ),
            .orthographic => |ortho| zm.normalize3(
                zm.mul(zm.f32x4(0.0, 0.0, 1.0, 0.0), zm.matFromQuat(ortho.rotation))
            ),
        };

        const position = switch (self.*) {
            .perspective => |persp| persp.position,
            .orthographic => |ortho| ortho.position,
        };

        const up = switch (self.*) {
            .perspective => |persp| persp.up,
            .orthographic => |ortho| ortho.up,
        };
        const target = position + forward;
        return zm.lookAtRh(position, target, up);
    }
};
