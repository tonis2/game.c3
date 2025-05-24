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

fn void Aabb3.translate(&self, Vec3f position) {
    self.max += position;
    self.min += position;
    // self.min.x += position.x;
    // self.max.x += position.x;
    // self.min.y += position.y;
    // self.max.y += position.y;
    // self.min.z += position.z;
    // self.max.z += position.z;
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

