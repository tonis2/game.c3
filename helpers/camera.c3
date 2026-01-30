module helpers;
import std::math;
import std::math::matrix;
import std::io;
import gltf;
import main;


 struct Camera {
    Vec3f position;
    Matrix4f view;
    Vec3f target;
    float distance;
    float yaw;
    float pitch;
    float aspect_ratio;
    float y_fov;
    float z_far;
    float z_near;
}

struct CameraData @tag("BUFFER", Buffers.CPU_GPU) {
    Matrix4f perspective;
    Matrix4f view;
    Vec4f eye;
}

fn void Camera.rotate(&self, float x_offset, float y_offset) {
    self.yaw -= x_offset * 0.01;
    self.pitch -= y_offset * 0.01;

    // Clamp pitch to avoid gimbal lock
    self.pitch = math::clamp(self.pitch, -1.5f, 1.5f);

    self.update_view();
}

fn void Camera.zoom(&self, float value) {
    self.distance -= value;
    if (self.distance < 1.0f) self.distance = 1.0f;

    self.update_view();
}

fn void Camera.update_view(&self) {
    // Calculate camera position on sphere around target
    float cos_pitch = math::cos(self.pitch);
    float sin_pitch = math::sin(self.pitch);
    float cos_yaw = math::cos(self.yaw);
    float sin_yaw = math::sin(self.yaw);

    self.position = {
        self.target.x + self.distance * cos_pitch * cos_yaw,
        self.target.y + self.distance * cos_pitch * sin_yaw,
        self.target.z + self.distance * sin_pitch
    };

    self.view = matrix::look_at{float}(self.position, self.target, {0.0, 0.0, 1.0});
}

fn CameraData Camera.data(&self) {
    return {
        matrix::perspective{float}(self.y_fov, self.aspect_ratio, self.z_near, self.z_far),
        self.view,
        (Vec4f){...self.position, 1.0}
    };
}

