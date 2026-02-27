module helpers;
import std::math;
import std::math::matrix;
import std::io;
import gltf;
import main;


struct Camera
{
	Vec3f position;
	Matrix4f view;
	Vec3f translation;
	Vec3f scale;
	Quaternionf rotation;
	float zoom_value;
	float aspect_ratio;
	float y_fov;
	float z_far;
	float z_near;
}

struct CameraData @tag("BUFFER", Buffers.CPU_GPU)
{
	Matrix4f perspective;
	Matrix4f view;
	Vec4f eye;
}

fn void Camera.zoom(&self, float value)
{
	self.zoom_value += value;
	self.view.m23 += value;
}

fn void Camera.rotate(&self, float x_offset, float y_offset)
{
	float sensitivity = 0.005f;

	// Create rotation quaternions for yaw (around Z axis) and pitch (around local X axis)
	Quaternionf yaw_rot = quaternion::from_axis_angle({ 0, 0, 1 }, -x_offset * sensitivity);
	Quaternionf pitch_rot = quaternion::from_axis_angle({ 1, 0, 0 }, -y_offset * sensitivity);

	// Apply yaw globally, pitch locally
	self.rotation = (yaw_rot * self.rotation * pitch_rot).normalize();

	// Rebuild view matrix from rotation and translation
	self.update_view();
}

fn void Camera.update_view(&self)
{
	// Convert rotation to matrix
	Matrix4f rot_matrix = self.rotation.to_matrixf();

	// Transform translation by rotation
	Vec3f trans = self.rotation * (-self.translation);

	// Build view matrix
	self.view = {
		rot_matrix.m00,
		rot_matrix.m01,
		rot_matrix.m02,
		trans.x,
		rot_matrix.m10,
		rot_matrix.m11,
		rot_matrix.m12,
		trans.y,
		rot_matrix.m20,
		rot_matrix.m21,
		rot_matrix.m22,
		trans.z,
		0.0,
		0.0,
		0.0,
		1.0,
	};

	// Apply zoom offset
	self.view.m23 += self.zoom_value;
}

fn CameraData Camera.data(&self)
{
	return {
		matrix::perspective {float}(self.y_fov, self.aspect_ratio, self.z_near, self.z_far),
		self.view,
		(Vec4f) { ... self.position, 1.0 }
	};
}

// Convert rotation matrix to quaternion (Shepperd method for numerical stability)
fn Quaternionf quaternion_from_matrix(Matrix4f m)
{
	float trace = m.m00 + m.m11 + m.m22;
	Quaternionf q;

	if (trace > 0)
	{
		float s = 0.5f / math::sqrt(trace + 1.0f);
		q.v.w = 0.25f / s;
		q.v.x = (m.m21 - m.m12) * s;
		q.v.y = (m.m02 - m.m20) * s;
		q.v.z = (m.m10 - m.m01) * s;
	}
	else if (m.m00 > m.m11 && m.m00 > m.m22)
	{
		float s = 2.0f * math::sqrt(1.0f + m.m00 - m.m11 - m.m22);
		q.v.w = (m.m21 - m.m12) / s;
		q.v.x = 0.25f * s;
		q.v.y = (m.m01 + m.m10) / s;
		q.v.z = (m.m02 + m.m20) / s;
	}
	else if (m.m11 > m.m22)
	{
		float s = 2.0f * math::sqrt(1.0f + m.m11 - m.m00 - m.m22);
		q.v.w = (m.m02 - m.m20) / s;
		q.v.x = (m.m01 + m.m10) / s;
		q.v.y = 0.25f * s;
		q.v.z = (m.m12 + m.m21) / s;
	}
	else
	{
		float s = 2.0f * math::sqrt(1.0f + m.m22 - m.m00 - m.m11);
		q.v.w = (m.m10 - m.m01) / s;
		q.v.x = (m.m02 + m.m20) / s;
		q.v.y = (m.m12 + m.m21) / s;
		q.v.z = 0.25f * s;
	}

	return q.normalize();
}
