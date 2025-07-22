module helpers;
import std::math;
import std::math::matrix;
import std::io;
import gltf;

fn float radians(float value) => value * (float)math::PI / 180;

fn Quaternionf quaternion_from_matrix(Matrix3f matrix) {
    Quaternionf q;
    float trace = matrix.m00 + matrix.m11 + matrix.m22;
    if (trace > 0) {
        float t = math::sqrt(trace + (float)1.0) * 2.0;
        q.l = 0.25 * t;
        q.i = (matrix.m21 - matrix.m12) / t;
        q.j = (matrix.m02 - matrix.m20) / t;
        q.k = (matrix.m10 - matrix.m01) / t;
    } else if (matrix.m00 > matrix.m11 && matrix.m00 > matrix.m22) {
        float t = math::sqrt((float)1.0 + matrix.m00 - matrix.m11 - matrix.m22) * 2.0;
        q.l = (matrix.m21 - matrix.m12) / t;
        q.i = 0.25 * t;
        q.j = (matrix.m01 + matrix.m10) / t;
        q.k = (matrix.m02 + matrix.m20) / t;
    } else if (matrix.m11 > matrix.m22) {
        float t = math::sqrt((float)1.0 + matrix.m11 - matrix.m00 - matrix.m22) * 2.0;
        q.l = (matrix.m02 - matrix.m20) / t;
        q.i = (matrix.m01 + matrix.m10) / t;
        q.j = 0.25 * t;
        q.k = (matrix.m12 + matrix.m21) / t;
    } else {
        float t = math::sqrt((float)1.0 + matrix.m22 - matrix.m00 - matrix.m11) * 2.0;
        q.l = (matrix.m10 - matrix.m01) / t;
        q.i = (matrix.m02 + matrix.m20) / t;
        q.j = (matrix.m12 + matrix.m21) / t;
        q.k = 0.25 * t;
    }
    return q;
}

fn Quaternionf quaternion_look_at(Vec3f forward, Vec3f upwards) {
    Vec3f forward_norm = forward.normalize();
    Vec3f right = upwards.cross(forward_norm).normalize();

    if (right.sq_magnitude() < 1e-6f) {
        return {0.0, 0.0, 0.0, 1.0};
    }

    Vec3f up = forward_norm.cross(right);

    return quaternion_from_matrix({
        right.x, right.y, right.z,
        up.x, up.y, up.z,
        forward_norm.x, forward_norm.y, forward_norm.z
    });
}

struct Camera {
    Vec3f position;
    Matrix4f view;
    Vec3f translation;
    Vec3f scale;
    Quaternionf rotation;
    float zoom_value;
    float yaw;
    float pitch;
    float aspect_ratio;
    float y_fov;
    float z_far;
    float z_near;
}

struct CameraData @tag("BUFFER", 2) {
    Matrix4f perspective;
    Matrix4f view;
    Vec4f eye;
}

fn void Camera.rotate(&self, float x_offset, float y_offset) {
    self.yaw += x_offset / 100;
    self.pitch += y_offset / 100;

    self.pitch = math::clamp(self.pitch, -89, 89);

    Quaternionf y_axis = self.rotation.rotate_by_axis_angle({0, 1, 0}, radians(self.yaw)).normalize();
    Quaternionf x_axis = self.rotation.rotate_by_axis_angle({1, 0, 0}, radians(self.pitch)).normalize();

    self.view = gltf::to_matrix(
        self.translation,
        self.scale,
        self.rotation * x_axis
    ).inverse()!!;
}

fn void Camera.zoom(&self, float value) {
    self.zoom_value += value;
    self.view.m23 += value;
}

fn CameraData Camera.data(&self) {
    return {
        matrix::perspective{float}(self.y_fov, self.aspect_ratio, self.z_near, self.z_far),
        self.view,
        (Vec4f){self.position, 1.0}
    };
}

