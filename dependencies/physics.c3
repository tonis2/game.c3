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

fn Aabb3 Aabb3.translate(&self, Vec3f position) {

    Vec3f len = self.max - self.min;

    return {
        position,
        position - len
    };
}

fn Aabb3 Aabb3.transform(&self, Matrix4f matrix)
{
    Vec3f first_col = (Vec3f){...matrix.m[0..2]};
    Vec3f second_col = (Vec3f){...matrix.m[2..4]};
    Vec3f third_col = (Vec3f){...matrix.m[4..6]};

    // compute column multiplies for the AABB min
    Vec3f min_c1 = first_col * self.min.x;
    Vec3f min_c2 = second_col * self.min.y;
    Vec3f min_c3 = third_col * self.min.z + third_col; // place 4th column add here for free add (MAD)

    // compute column multiplies for the AABB max
    Vec3f max_c1 = first_col * self.max.x;
    Vec3f max_c2 = second_col * self.max.y;
    Vec3f max_c3 = third_col * self.max.z + third_col; // place 4th column add here for free add (MAD)

    // minimize and maximize the resulting transforms
    Vec3f tmin = math::min(min_c1,max_c1) + math::min(min_c2, max_c2) + math::min(min_c3, max_c3);
    Vec3f tmax = math::max(min_c1,max_c1) + math::max(min_c2, max_c2) + math::max(min_c3, max_c3);

    return {
        tmin,
        tmax
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
    Vec3f[] vertices;
    ushort[] indices;
}

fn Mesh create_cube() {
    Vec3f[] vertices = {
        {-1.0, -1.0, 1.0},
        {1.0, -1.0, 1.0},
        {1.0, 1.0, 1.0},
        {-1.0, 1.0, 1.0},

        {-1.0, -1.0, -1.0},
        {-1.0, 1.0, -1.0},
        {1.0, 1.0, -1.0},
        {1.0, -1.0, -1.0},

        {-1.0, 1.0, -1.0},
        {-1.0, 1.0, 1.0},
        {1.0, 1.0, 1.0},
        {1.0, 1.0, -1.0},

        {-1.0, -1.0, -1.0},
        {1.0, -1.0, -1.0},
        {1.0, -1.0, 1.0},
        {-1.0, -1.0, 1.0},

        {1.0, -1.0, -1.0},
        {1.0, 1.0, -1.0},
        {1.0, 1.0, 1.0},
        {1.0, -1.0, 1.0},

        {-1.0, -1.0, -1.0},
        {-1.0, -1.0, 1.0},
        {-1.0, 1.0, 1.0},
        {-1.0, 1.0, -1.0},
    };

    ushort[] indices = {
        0,  1,  2,      0,  2,  3,    // front
        4,  5,  6,      4,  6,  7,    // back
        8,  9,  10,     8,  10, 11,   // top
        12, 13, 14,     12, 14, 15,   // bottom
        16, 17, 18,     16, 18, 19,   // right
        20, 21, 22,     20, 22, 23    // left
    };

    return {
        vertices,
        indices
    };
}