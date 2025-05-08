const std = @import("std");
const zm = @import("zmath");
const Camera = @import("camera.zig").Camera;
const Frustum = @import("frustum.zig").Frustum;

pub const OrbitCamera = struct {
    camera: Camera,
    target: zm.Vec = .{ 0.0, 0.0, 0.0, 0.0 },
    distance: f32 = 3.0,
    yaw: f32 = 0.0, // Rotation around Y-axis
    pitch: f32 = 0.0, // Rotation around X-axis
    min_distance: f32 = 1.0,
    max_distance: f32 = 20.0,
    min_pitch: f32 = -0.2 * std.math.pi,
    max_pitch: f32 = 0.45 * std.math.pi,

    pub fn init(fov: f32, aspect_ratio: f32, near: f32, far: f32) OrbitCamera {
        return .{
            .camera = .{
                .projection = .{
                    .perspective = .{
                        .fov = fov,
                        .aspect_ratio = aspect_ratio,
                        .near = near,
                        .far = far,
                    },
                },
            },
        };
    }

    pub fn rotate(self: *OrbitCamera, delta_yaw: f32, delta_pitch: f32) void {
        self.yaw += delta_yaw;
        self.pitch = std.math.clamp(
            self.pitch + delta_pitch,
            self.min_pitch,
            self.max_pitch,
        );
        // self.yaw = 0;
        self.updateCameraPosition();
    }

    pub fn zoom(self: *OrbitCamera, delta: f32) void {
        self.distance = std.math.clamp(
            self.distance + delta,
            self.min_distance,
            self.max_distance,
        );
        self.updateCameraPosition();
    }

    pub fn setTarget(self: *OrbitCamera, new_target: zm.Vec) void {
        self.target = new_target;
        self.updateCameraPosition();
    }

    fn updateCameraPosition(self: *OrbitCamera) void {
        const sin_pitch = @sin(self.pitch);
        const cos_pitch = @cos(self.pitch);
        const sin_yaw = @sin(self.yaw);
        const cos_yaw = @cos(self.yaw);
        const x = cos_pitch * cos_yaw;
        const y = sin_pitch;
        const z = cos_pitch * sin_yaw;
        self.camera.position = self.target + zm.f32x4(x, y, z, 0.0) * zm.f32x4s(self.distance);
        self.camera.lookAt(self.target);
    }

    pub fn getViewMatrix(self: *const OrbitCamera) zm.Mat {
        return self.camera.calculateViewMatrix();
    }

    pub fn getProjectionMatrix(self: *const OrbitCamera) zm.Mat {
        return self.camera.calculateProjectionMatrix();
    }

    pub fn getFrustum(self: *const OrbitCamera, do_normalize_planes: bool) Frustum {
        return self.camera.getFrustum(do_normalize_planes);
    }
};
