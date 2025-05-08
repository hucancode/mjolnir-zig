const std = @import("std");
const zm = @import("zmath");
const Aabb = @import("../geometry/geometry.zig").Aabb;

const Vec = zm.Vec;
const Mat = zm.Mat;
const f32x4 = zm.f32x4;
const f32x4s = zm.f32x4s;

// A Plane is represented as a Vec (F32x4), where xyz are the normal components
// and w is the D component of the plane equation Ax + By + Cz + D = 0.
// The normal is assumed to point "inwards" for a convex volume like a frustum,
// meaning points P for which Ax + By + Cz + D >= 0 are considered "inside" or "on" the plane.
pub const Plane = Vec;

pub const Frustum = struct {
    planes: [6]Plane,

    /// Extracts the 6 frustum planes from a combined view-projection matrix.
    /// This version is for projection matrices like zmath.perspectiveFovLh (Direct3D/Vulkan style, Z in [0, 1]).
    pub fn extractPlanes(m: Mat, do_normalize: bool) Frustum {
        var frustum: Frustum = undefined;

        // The matrix m is row-major
        const c0 = f32x4(m[0][0], m[1][0], m[2][0], m[3][0]);
        const c1 = f32x4(m[0][1], m[1][1], m[2][1], m[3][1]);
        const c2 = f32x4(m[0][2], m[1][2], m[2][2], m[3][2]);
        const c3 = f32x4(m[0][3], m[1][3], m[2][3], m[3][3]);

        frustum.planes[0] = c3 + c0; // Left plane
        frustum.planes[1] = c3 - c0; // Right plane
        frustum.planes[2] = c3 + c1; // Bottom plane
        frustum.planes[3] = c3 - c1; // Top plane
        frustum.planes[4] = c2; // Near plane (for Z in [0,1])
        frustum.planes[5] = c3 - c2; // Far plane: row3 - row2

        if (do_normalize) {
            for (&frustum.planes) |*p| {
                p.* = normalizePlane(p.*);
            }
        }
        return frustum;
    }

    /// Extracts the 6 frustum planes from a combined view-projection matrix.
    /// This version is for projection matrices like zmath.perspectiveFovLhGl (OpenGL style, Z in [-1, 1]).
    pub fn extractPlanesGL(m: Mat, do_normalize: bool) Frustum {
        var frustum: Frustum = undefined;

        // The matrix m is row-major. These are the columns of m.
        // See comment in extractPlanes for rationale.
        const c0 = f32x4(m[0][0], m[1][0], m[2][0], m[3][0]);
        const c1 = f32x4(m[0][1], m[1][1], m[2][1], m[3][1]);
        const c2 = f32x4(m[0][2], m[1][2], m[2][2], m[3][2]);
        const c3 = f32x4(m[0][3], m[1][3], m[2][3], m[3][3]);

        frustum.planes[0] = c3 + c0; // Left plane
        frustum.planes[1] = c3 - c0; // Right plane
        frustum.planes[2] = c3 + c1; // Bottom plane
        frustum.planes[3] = c3 - c1; // Top plane
        frustum.planes[4] = c3 + c2; // Near plane (GL style: w_clip + z_clip >= 0)
        frustum.planes[5] = c3 - c2; // Far plane  (GL style: w_clip - z_clip >= 0)

        if (do_normalize) {
            for (&frustum.planes) |*p| {
                p.* = normalizePlane(p.*);
            }
        }
        return frustum;
    }
};

/// Normalizes a plane equation (Ax + By + Cz + D = 0) stored in a Vec.
/// The normal (A,B,C) becomes unit length. D is scaled accordingly.
pub fn normalizePlane(plane_vec: Plane) Plane {
    const normal_part = f32x4(plane_vec[0], plane_vec[1], plane_vec[2], 0.0);
    const mag = zm.length3(normal_part)[0];
    if (mag == 0.0) return plane_vec;
    return zm.mulAdd(plane_vec, zm.f32x4s(1.0 / mag), zm.f32x4s(0.0));
}

/// Calculates the signed distance from a point to a plane.
/// Assumes point.w is 1.0. Plane should be normalized for distance to be metric.
/// Positive distance means the point is on the side of the plane's normal.
pub fn signedDistanceToPlane(plane_vec: Plane, point: Vec) f32 {
    return zm.dot3(plane_vec, point)[0] + plane_vec[3];
}

/// Tests if an Axis-Aligned Bounding Box (AABB) intersects or is contained within a Frustum.
/// Assumes AABB is defined by min_point and max_point (Vec with x,y,z components).
/// Assumes Frustum planes have normals pointing inwards.
/// Returns true if the AABB is (at least partially) inside the frustum, false if completely outside.
pub fn testAabbFrustum(aabb_min: Vec, aabb_max: Vec, frustum: Frustum) bool {
    // std.debug.print("Testing AABB: min={any}, max={any}\n", .{ aabb_min, aabb_max });
    for (frustum.planes, 0..) |plane_vec, i| {
        _ = i;
        const nx = if (plane_vec[0] > 0.0) aabb_max[0] else aabb_min[0];
        const ny = if (plane_vec[1] > 0.0) aabb_max[1] else aabb_min[1];
        const nz = if (plane_vec[2] > 0.0) aabb_max[2] else aabb_min[2];
        const p_corner = f32x4(nx, ny, nz, 1.0); // This is the p-vertex (positive vertex)
        const dist = signedDistanceToPlane(plane_vec, p_corner);
        // if (std.math.abs(dist) < 0.001) {
        //     std.debug.print("  Plane {d}: p_corner={any} to plane={any}, dist={d} (NEAR MISS)\\n", .{ i, p_corner, plane_vec, dist });
        // }
        if (dist < 0.0) {
            // std.debug.print("  Culled by Plane {d}: p_corner={any} to plane={any}, dist={d}\n", .{ i, p_corner, plane_vec, dist });
            return false;
        }
    }
    // std.debug.print("  AABB Not Culled\n", .{});
    return true;
}

/// Tests if a Bounding Sphere intersects or is contained within a Frustum.
/// Assumes Frustum planes have normals pointing inwards and are normalized.
/// Returns true if the sphere is (at least partially) inside the frustum.
pub fn testSphereFrustum(sphere_center: Vec, sphere_radius: f32, frustum: Frustum) bool {
    for (frustum.planes) |plane_vec| {
        const dist = signedDistanceToPlane(plane_vec, sphere_center);
        if (dist < -sphere_radius) {
            return false;
        }
    }
    return true;
}

pub fn transformAabb(aabb: Aabb, matrix: Mat) Aabb {
    // Get the 8 corners of the AABB
    const corners = [_]Vec{
        zm.f32x4(aabb.min[0], aabb.min[1], aabb.min[2], 1.0),
        zm.f32x4(aabb.max[0], aabb.min[1], aabb.min[2], 1.0),
        zm.f32x4(aabb.min[0], aabb.max[1], aabb.min[2], 1.0),
        zm.f32x4(aabb.min[0], aabb.min[1], aabb.max[2], 1.0),
        zm.f32x4(aabb.max[0], aabb.max[1], aabb.min[2], 1.0),
        zm.f32x4(aabb.max[0], aabb.min[1], aabb.max[2], 1.0),
        zm.f32x4(aabb.min[0], aabb.max[1], aabb.max[2], 1.0),
        zm.f32x4(aabb.max[0], aabb.max[1], aabb.max[2], 1.0),
    };
    var new_aabb: Aabb = .{
        .min = zm.f32x4s(std.math.floatMax(f32)),
        .max = zm.f32x4s(std.math.floatMin(f32)),
    };
    for (corners) |corner| {
        const transformed_corner = zm.mul(corner, matrix);
        new_aabb.min = zm.min(new_aabb.min, transformed_corner);
        new_aabb.max = zm.max(new_aabb.max, transformed_corner);
    }
    return new_aabb;
}
