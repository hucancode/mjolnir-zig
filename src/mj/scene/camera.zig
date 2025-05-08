const std = @import("std");
const zm = @import("zmath");
const Frustum = @import("frustum.zig").Frustum;

pub const Camera = struct {
    up: zm.Vec = .{ 0.0, 1.0, 0.0, 0.0 },
    position: zm.Vec = .{ 0.0, 0.0, 0.0, 0.0 },
    rotation: zm.Quat = .{ 0.0, 0.0, 0.0, 1.0 },
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
        const forward = zm.normalize3(target - self.position);
        const right = zm.normalize3(zm.cross3(self.up, forward));
        const up = zm.cross3(forward, right);
        const rot_mat = zm.Mat{
            .{ right[0], right[1], right[2], 0.0 },
            .{ up[0], up[1], up[2], 0.0 },
            .{ forward[0], forward[1], forward[2], 0.0 },
            .{ 0.0, 0.0, 0.0, 1.0 },
        };
        self.rotation = zm.quatFromMat(rot_mat);
    }

    pub fn calculateViewMatrix(self: *const Camera) zm.Mat {
        const rotmat = zm.matFromQuat(self.rotation);
        const forward = zm.Vec{ rotmat[2][0], rotmat[2][1], rotmat[2][2], 0.0 };
        return zm.lookToLh(self.position, forward, self.up);
    }

    pub fn getForwardVector(self: *const Camera) zm.Vec {
        const rotmat = zm.matFromQuat(self.rotation);
        return .{ rotmat[2][0], rotmat[2][1], rotmat[2][2], 0.0 };
    }

    pub fn getFrustum(self: *const Camera, do_normalize_planes: bool) Frustum {
        const view_proj = zm.mul(
            self.calculateViewMatrix(),
            self.calculateProjectionMatrix(),
        );
        // Assuming Vulkan/Direct3D style projection (Z in [0, 1]) as per perspectiveFovLh
        return Frustum.extractPlanes(view_proj, do_normalize_planes);
    }
};
