module ecs;

import std::math;
import std::io;
import std::collections::list;
import std::collections::map;

// collision primitives: Sphere, Circle, Rectangle, Cuboid, Particle, Convex Polygon, Convex Polyhedra

struct Aabb3 {
    Vec3f min;
    Vec3f max;
}

struct Obb3 {
    Vec3f min;
    Vec3f max;
}

// macro bool Aabb3.@intersects(self, Aabb3 target) {
//     return self.min.x < target.min.x && self.max.x > target.max.x;
// }

fn bool Aabb3.is_empty(self) {
    return self.max.xyz == (Vec3f){0,0,0};
}

fn bool Aabb3.intersectsX(self, Aabb3 target) {
    return self.min.x < target.min.x && self.max.x > target.max.x;
}

fn bool Aabb3.intersectsY(self, Aabb3 target) {
    return self.min.y < target.min.y && self.max.y > target.max.y;
}

fn bool Aabb3.intersectsZ(self, Aabb3 target) {
    return self.min.z < target.min.z && self.max.z > target.max.z;
}

fn bool Aabb3.collides(self, Aabb3 target) {
    return self.min.x <= target.max.x &&
           self.max.x >= target.min.x &&
           self.min.y <= target.max.y &&
           self.max.y >= target.min.y &&
           self.min.z <= target.max.z &&
           self.max.z >= target.min.z;
}

fn void Aabb3.expand_min(&self, Vec3f point) {
    self.min.x = math::min(self.min.x, point.x);
    self.min.y = math::min(self.min.y, point.y);
    self.min.z = math::min(self.min.z, point.z);
}

fn void Aabb3.expand_max(&self, Vec3f point) {
    self.max.x = math::max(self.max.x, point.x);
    self.max.y = math::max(self.max.y, point.y);
    self.max.z = math::max(self.max.z, point.z);
}

fn void Aabb3.expand_by_point(&self, Vec3f point) {
    self.expand_max(point);
    self.expand_min(point);
}

fn Aabb3 Aabb3.scale(self, Vec3f scale) {
    Vec3f center = (self.min + self.max) * 0.5f;
    Vec3f halfExtents = (self.max - self.min) * 0.5f;
    Vec3f newHalfExtents = halfExtents * scale;

    return {
        center - newHalfExtents,
        center + newHalfExtents
    };
}

fn Aabb3 Aabb3.transform2(self, Matrix4f matrix)
{
    Aabb3 aabb;
    Vec3f[] corners = {
        { self.min.x, self.min.y, self.min.z},
        { self.max.x, self.min.y, self.min.z},
        { self.min.x, self.max.y, self.min.z},
        { self.max.x, self.max.y, self.min.z},
        { self.min.x, self.min.y, self.max.z},
        { self.max.x, self.min.y, self.max.z},
        { self.min.x, self.max.y, self.max.z},
        { self.max.x, self.max.y, self.max.z}
    };

    foreach (i, corner: corners) {
        corners[i] = (matrix * (Vec4f){corner, 1.0}).xyz;
        aabb.expand_by_point(corners[i]);
    }

    io::printfn("%s %s", aabb.min, aabb.max);

    return aabb;
}

fn Mesh create_bounding_box(Aabb3 box)
{
    return {
        .vertices = {
            { box.min.x, box.min.y, box.min.z},
            { box.max.x, box.min.y, box.min.z},
            { box.min.x, box.max.y, box.min.z},
            { box.max.x, box.max.y, box.min.z},
            { box.min.x, box.min.y, box.max.z},
            { box.max.x, box.min.y, box.max.z},
            { box.min.x, box.max.y, box.max.z},
            { box.max.x, box.max.y, box.max.z}
        },
        .indices = {
            0, 1, 1, 3, 3, 2, 2, 0, 
            4, 5, 5, 7, 7, 6, 6, 4,
            0, 4, 1, 5, 2, 6, 3, 7 
        }
    };
}

fn Aabb3 Aabb3.transform(self, Matrix4f matrix)
{   
    Vec3f transform = (Vec3f){matrix.m03, matrix.m13, matrix.m23};

    Vec3f b_min = transform;
    Vec3f b_max = transform;

    Matrix3f new_matrix = {
        matrix.m00, matrix.m01, matrix.m02,
        matrix.m10, matrix.m11, matrix.m12,
        matrix.m20, matrix.m21, matrix.m22,
    };
 
    foreach (uint i, value: new_matrix.m) {
        uint index = i % 3;

        float a = value * self.min[index];
        float b = value * self.max[index];

        b_min[index] += math::min(a, b);
        b_max[index] += math::max(a, b);
    }
    

    Aabb3 new_aabb = {
        b_min,
        b_max
    };

    return new_aabb;
}

fn Vec3f Aabb3.len(self) => self.max - self.min;

fn Vec3f Aabb3.length_ratios(&self, Aabb3 second) {
    Vec3f current_length = self.max - self.min;
    Vec3f second_length = second.max - second.min;
    Vec3f ratios = current_length / second_length;
    return ratios;
}

fn Matrix4f Aabb3.to_matrix(&self)
{
    Vec3f len = (self.max - self.min);
    Vec3f center = self.max - (len / 2);
    return {
        1, 0, 0, center.x,
		0, 1, 0, center.y,
		0, 0, 1, center.z,
		0, 0, 0, 1,
    };
}

// Code done thanks to https://github.com/kevinmoran/GJK

interface Collider
{
    fn Vec3f support(Vec3f direction);
    fn ColliderInfo _info();
}

struct ColliderInfo {
    Vec3f position; 
    Matrix3f matrix;
    Matrix3f inverse_matrix; 
}

struct BBox (Collider) {
    inline ColliderInfo info;
    Aabb3 aabb;
}

struct Cylinder (Collider) {
    inline ColliderInfo info;
    float radius; 
    float y_base; 
    float y_cap;
}

struct Capsule (Collider) {
    inline ColliderInfo info;
    float radius; 
    float y_base; 
    float y_cap;
}

struct Sphere (Collider) {
    inline ColliderInfo info;
    float radius; 
}

struct Polytope (Collider) {
    inline ColliderInfo info;
    List{Vec3f} points; 
}

fn ColliderInfo BBox._info(&self) @dynamic => self.info;
fn ColliderInfo Cylinder._info(&self) @dynamic => self.info;
fn ColliderInfo Capsule._info(&self) @dynamic => self.info;
fn ColliderInfo Sphere._info(&self) @dynamic => self.info;
fn ColliderInfo Polytope._info(&self) @dynamic => self.info;

//BBox: AABB + Orientation matrix
fn Vec3f BBox.support(&self, Vec3f direction) @dynamic {
    Vec3f dir = self.info.inverse_matrix * direction;

    Vec3f result = {
        (dir.x > 0) ? self.aabb.max.x : self.aabb.min.x,
        (dir.y > 0) ? self.aabb.max.y : self.aabb.min.y,
        (dir.z > 0) ? self.aabb.max.z : self.aabb.min.z
    };

    return self.info.matrix * result + self.info.position;
}

fn Vec3f Cylinder.support(&self, Vec3f direction) @dynamic {
    return {1.0, 1.0, 1.0};
}

fn Vec3f Capsule.support(&self, Vec3f direction) @dynamic {
    Vec3f dir = self.info.inverse_matrix * direction;
    Vec3f result = dir.normalize() * self.radius;

    result.y += (dir.y > 0) ? self.y_cap : self.y_base;
    return self.info.matrix * result + self.info.position;
}

fn Vec3f Sphere.support(&self, Vec3f direction) @dynamic {
    return direction.normalize() * self.radius + self.info.position;
}

fn Vec3f Polytope.support(&self, Vec3f direction) @dynamic {
    return {1.0, 1.0, 1.0};
}

const GJK_MAX_NUM_ITERATIONS = 64;

// GJK intersect algorithm
fn bool intersects(Collider first, Collider second, Vec3f* minimum_translation = null) {
    Vec3f a,b,c,d;
    Vec3f search_dir = first._info().position - second._info().position;

    c = second.support(search_dir) - first.support(-search_dir);
    search_dir = -c;

    b = second.support(search_dir) - first.support(-search_dir);
    if (b.dot(search_dir) < 0) return false;

    search_dir = ((c-b).cross(-b)).cross(c-b);

    if (search_dir == {0,0,0}){
        search_dir = (c-b).cross({1,0,0}); //normal with x-axis
        if (search_dir == {0,0,0}) search_dir = (c-b).cross({0,0,-1}); //normal with z-axis
    }

    int simp_dim = 2;

    for (int iterations = 0; iterations < GJK_MAX_NUM_ITERATIONS; iterations++)
    {
        a = second.support(search_dir) - first.support(-search_dir);
        if (a.dot(search_dir) < 0) return false;
        simp_dim++;

        if (simp_dim == 3) {
            // simplex3 Triangle case
            
            Vec3f n = (b - a).cross(c - a); 
            Vec3f ao = -a.xyz;
            simp_dim = 2;

            if ((b-a).cross(n).dot(ao) > 0) {
                c = a;
                search_dir = (b-a).cross(ao).cross(b-a);
                break;
            }

            if (n.cross(c-a).dot(ao) > 0) {
                b = a;
                search_dir = (c-a).cross(ao).cross(c-a);
                break;
            }

            simp_dim = 3;

            if (n.dot(ao) > 0) {
                d = c;
                c = b;
                b = a;
                search_dir = n;
                break;
            }

            d = b;
            b = a;
            search_dir = -n;
        } else {
            // simplex4
            Vec3f abc = (b-a).cross(c-a);
            Vec3f acd = (c-a).cross(d-a);
            Vec3f adb = (d-a).cross(b-a);

            Vec3f ao = -a;
            simp_dim = 3; 

            if (abc.dot(ao) > 0) {
                d = c;
                c = b;
                b = a;
                search_dir = abc;
                continue;
            }

            if (acd.dot(ao) > 0) {
                b = a;
                search_dir = acd;
                continue;
            }

            if (adb.dot(ao) > 0) {
                c = d;
                d = b;
                b = a;
                search_dir = adb;
                continue;
            }

            return true;
        };
    }

    return false;
}

struct Mesh {
    Vec3f[8] vertices;
    ushort[24] indices;
}

//  ecs::Mesh cube = {
//     .vertices = {
//         {-1.0, -1.0, 1.0},
//         {1.0, -1.0, 1.0},
//         {1.0, 1.0, 1.0},
//         {-1.0, 1.0, 1.0},
//         {-1.0, -1.0, -1.0},
//         {-1.0, 1.0, -1.0},
//         {1.0, 1.0, -1.0},
//         {1.0, -1.0, -1.0},
//     },
//     .indices = {
//         0, 1, 1, 3, 3, 2, 2, 0, 
//         4, 5, 5, 7, 7, 6, 6, 4,
//         0, 4, 1, 5, 2, 6, 3, 7 
//     }
// };

fn Matrix3f Matrix4f.to_mat3(self) => { .m = self.m[0..8] };

fn float radians(float value) => value * (float)math::PI / 180;

fn void test_physics() @test {
    Aabb3 aabb = {
        {-1.0, -1.0, -1.0},
        {1.0, 1.0, 1.0}
    };

    Matrix4f matrix = MATRIX4F_IDENTITY.translate({1, 5, 1}).scale({3.0, 1.0, 1.0});
    //rotate_y(radians(45));

    aabb = aabb.transform(matrix);
    assert(aabb.min == {-2, 4, 0});
    assert(aabb.max == {4, 6, 2});


    // {
    //     Aabb3 aabb = {
    //         {3.486510, 1693.368896, 2.556290},
    //         {3.537758, 1698.706421, 2.556290}
    //     };
    // }
}