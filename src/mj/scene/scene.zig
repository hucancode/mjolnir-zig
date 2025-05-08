const std = @import("std");
const vk = @import("vulkan");
const zm = @import("zmath");
const context = @import("../engine/context.zig").get();
const Camera = @import("camera.zig").Camera;
const Handle = @import("../engine/resource.zig").Handle;
const Frustum = @import("frustum.zig").Frustum;

pub const Scene = struct {
    root: Handle,
    camera: Camera,

    pub fn init(self: *Scene) !void {
        self.camera = Camera.initOrbitMode(
            std.math.pi * 0.5,
            16.0 / 9.0,
            0.1,
            10000.0,
        );
    }

    pub fn deinit(self: *Scene) void {
        _ = self;
    }

    pub fn viewMatrix(self: *const Scene) zm.Mat {
        return self.camera.calculateViewMatrix();
    }

    pub fn projectionMatrix(self: *const Scene) zm.Mat {
        return self.camera.calculateProjectionMatrix();
    }

    pub fn rotateOrbitCamera(self: *Scene, delta_yaw: f32, delta_pitch: f32) void {
        if (self.camera.mode == .orbit) {
            self.camera.rotateOrbit(delta_yaw, delta_pitch);
        }
    }

    pub fn zoomOrbitCamera(self: *Scene, delta: f32) void {
        if (self.camera.mode == .orbit) {
            self.camera.zoomOrbit(delta);
        }
    }

    pub fn setOrbitTarget(self: *Scene, target: zm.Vec) void {
        if (self.camera.mode == .orbit) {
            self.camera.setOrbitTarget(target);
        }
    }

    pub fn setCameraMode(self: *Scene, mode: Camera.CameraMode) void {
        switch (mode) {
            .free => self.camera.switchToFreeMode(),
            .orbit => self.camera.switchToOrbitMode(null, null),
        }
    }

    pub fn getCameraFrustum(self: *const Scene, do_normalize_planes: bool) Frustum {
        return self.camera.getFrustum(do_normalize_planes);
    }
};
