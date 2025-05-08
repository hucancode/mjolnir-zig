const std = @import("std");
const zm = @import("zmath");
const Frustum = @import("frustum.zig").Frustum;

pub const Camera = struct {
    pub const CameraMode = enum {
        free,
        orbit,
    };

    movement_data: union(CameraMode) {
        free: void, // Placeholder for any free-camera specific data
        orbit: struct {
            target: zm.Vec = .{ 0.0, 0.0, 0.0, 0.0 },
            distance: f32 = 3.0,
            yaw: f32 = 0.0, // Rotation around Y-axis
            pitch: f32 = 0.0, // Rotation around X-axis
            min_distance: f32 = 1.0,
            max_distance: f32 = 20.0,
            min_pitch: f32 = -0.2 * std.math.pi,
            max_pitch: f32 = 0.45 * std.math.pi,
        },
    } = .{ .free = {} },

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

    mode: CameraMode = .free,

    pub fn initPerspective(fov: f32, aspect_ratio: f32, near: f32, far: f32) Camera {
        return .{
            .projection = .{
                .perspective = .{
                    .fov = fov,
                    .aspect_ratio = aspect_ratio,
                    .near = near,
                    .far = far,
                },
            },
        };
    }

    pub fn initOrthographic(width: f32, height: f32, near: f32, far: f32) Camera {
        return .{
            .projection = .{
                .orthographic = .{
                    .width = width,
                    .height = height,
                    .near = near,
                    .far = far,
                },
            },
        };
    }

    pub fn initOrbitMode(fov: f32, aspect_ratio: f32, near: f32, far: f32) Camera {
        return .{
            .projection = .{
                .perspective = .{
                    .fov = fov,
                    .aspect_ratio = aspect_ratio,
                    .near = near,
                    .far = far,
                },
            },
            .mode = .orbit,
            .movement_data = .{ .orbit = .{} }, // Initialize with default orbit parameters
        };
    }

    pub fn switchToOrbitMode(self: *Camera, target: ?zm.Vec, distance: ?f32) void {
        self.mode = .orbit;
        var orbit_data = Camera.movement_data.orbit{}; // Default values
        if (target) |t| orbit_data.target = t;
        if (distance) |d| orbit_data.distance = d;
        // Reset yaw and pitch, or carry them over if that makes sense
        orbit_data.yaw = 0.0;
        orbit_data.pitch = 0.0;
        self.movement_data = .{ .orbit = orbit_data };
        self.updateOrbitCameraPosition();
    }

    pub fn switchToFreeMode(self: *Camera) void {
        self.mode = .free;
        self.movement_data = .{ .free = {} };
        // Position and rotation remain as they were
    }

    // Orbit mode methods
    pub fn rotateOrbit(self: *Camera, delta_yaw: f32, delta_pitch: f32) void {
        if (self.mode != .orbit) return;
        var orbit_params = &self.movement_data.orbit;
        orbit_params.yaw += delta_yaw;
        orbit_params.pitch = std.math.clamp(
            orbit_params.pitch + delta_pitch,
            orbit_params.min_pitch,
            orbit_params.max_pitch,
        );
        self.updateOrbitCameraPosition();
    }

    pub fn zoomOrbit(self: *Camera, delta: f32) void {
        if (self.mode != .orbit) return;
        var orbit_params = &self.movement_data.orbit;
        orbit_params.distance = std.math.clamp(
            orbit_params.distance + delta,
            orbit_params.min_distance,
            orbit_params.max_distance,
        );
        self.updateOrbitCameraPosition();
    }

    pub fn setOrbitTarget(self: *Camera, new_target: zm.Vec) void {
        if (self.mode != .orbit) return;
        self.movement_data.orbit.target = new_target;
        self.updateOrbitCameraPosition();
    }

    fn updateOrbitCameraPosition(self: *Camera) void {
        if (self.mode != .orbit) return;
        const orbit_params = self.movement_data.orbit;
        const sin_pitch = @sin(orbit_params.pitch);
        const cos_pitch = @cos(orbit_params.pitch);
        const sin_yaw = @sin(orbit_params.yaw);
        const cos_yaw = @cos(orbit_params.yaw);
        const x = cos_pitch * cos_yaw;
        const y = sin_pitch;
        const z = cos_pitch * sin_yaw;
        self.position = orbit_params.target + zm.f32x4(x, y, z, 0.0) * zm.f32x4s(orbit_params.distance);
        self.lookAt(orbit_params.target);
    }

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
