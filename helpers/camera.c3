module helpers;
import std::math;
import std::math::matrix;
import std::io;
import gltf;
import main;


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

struct CameraData @tag("BUFFER", Buffers.CPU_GPU) {
    Matrix4f perspective;
    Matrix4f view;
    Vec4f eye;
}

fn void Camera.rotate(&self, float x_offset, float y_offset) {
    self.yaw += x_offset / 50;
    self.pitch += y_offset / 50;

    self.pitch = math::clamp(self.pitch, -89, 89);

    // QuaternionValue y_axis = self.rotation.rotate_by_axis_angle({0, 1, 0}, radians(self.yaw)).normalize();
    // QuaternionValue x_axis = self.rotation.rotate_by_axis_angle({1, 0, 0}, radians(self.pitch)).normalize();
    // if (self.zoom_value == 0) self.zoom_value = -15;

    // Vec3f offset = self.translation.rotate_by_quat(x_axis.mul2(y_axis));

    // self.view = gltf::to_matrix(
    //     self.translation,
    //     self.scale,
    //     self.rotation.mul2(y_axis.mul2(x_axis))
    // ).inverse()!!;
    
    self.view.m23 = self.zoom_value;
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

