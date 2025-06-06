module helpers;
import std::math;
import std::math::matrix;
import std::io;

fn float radians(float value) {
    return value * (float)math::PI / 180;
}

struct Camera {
    Vec3f target;
    Vec3f eye;
    Matrix4f perspective;
    Matrix4f view;
    float pitch;
    float yaw;
    float zoom_value;
}

fn Camera new_camera(Vec3f target = {0.0, 0.0, 0.0}, Vec3f eye = {0.0, 0.0, 0.0}, float aspect = 0.8, float view = 45, float min_zoom = 0.1, float max_zoom = 500) {
    return {
        target,
        eye,
        matrix::perspective{float}(radians(view), aspect, min_zoom, max_zoom),
        matrix::look_at{float}(eye, target, {0.0, 1.0, 0.0}),
        0,
        0,
        -eye.z
    };
}

fn void Camera.rotate (Camera* self, float x_offset, float y_offset) {
    self.yaw += x_offset;
    self.pitch += y_offset;

    if (self.pitch > 89.0) self.pitch = 89.0;
    if (self.pitch < -89.0) self.pitch = -89.0;

    self.eye = { math::cos(radians(self.yaw)) * math::cos(radians(self.pitch)),
                 math::sin(radians(self.pitch)),
                 math::sin(radians(self.yaw)) * math::cos(radians(self.pitch))};

    self.view = matrix::look_at{float}(self.eye, self.target, {0.0, 1.0, 0.0});
    self.view.m23 = self.zoom_value;
}

fn void Camera.zoom(Camera* self, float value) {
    if (self.zoom_value + value > 0) return;
    self.zoom_value += value;
    self.view.m23 += value;
}

fn CameraData Camera.data(Camera* self) {
    return {
        self.perspective,
        self.view,
        (Vec4f){self.eye, 1.0}
    };
}

struct CameraData @tag("BUFFER", 2) {
    Matrix4f perspective;
    Matrix4f view;
    Vec4f eye;
}