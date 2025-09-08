module collision;

import std::collections::elastic_array;
import std::io;
import std::math;
import std::collections::list;
import std::time;


struct PhysicsWorld {
    List{Rigidbody} bodies;
    List{Collision} collisions;

    SpatialHash3D spatial_map;
    List{BVHNode} bvh_nodes;
}

struct Collision {
    usz a;
    usz b;
    Vec3f normal;
    Vec3f[2] contact;
    float depth;
}

enum PhysicsCombine {
    AVERAGE,
    MINIMUM,
    MAXIMUM,
    MULTIPLY
}

struct Material {
    float static_friction;
    float dynamic_friction;
    float restitution;
    PhysicsCombine friction_combine;
    PhysicsCombine restitution_combine;
}

struct Motion {
    bool is_kinematic;
    float mass;
    float inverse_mass;
    float gravity_factor;

    Vec3f mass_center;
    Vec3f inertia_diagonal;
    Quaternionf inertia_orientation;
    Matrix3f inverse_inertia_tensor;

    Vec3f linear_velocity;
    Vec3f angular_velocity;

    Vec3f torque;
    Vec3f force;
}

struct Rigidbody {
    int bvh_node;
    uint id;
    uint spatial_index;

    Aabb3 aabb;
    Aabb3 old_aabb;
    
    TransformedConvex collider;
    Material material;

    Motion motion;
    bool dirty;
}

fn void PhysicsWorld.free(&self) {
    self.bodies.free();
    self.collisions.free();
    self.spatial_map.free();
    self.bvh_nodes.free();
}

struct PhysicsWorldConfig {
    float cell_size;
}

fn PhysicsWorld create_world(PhysicsWorldConfig config) {
    PhysicsWorld world;
    world.spatial_map.cell_size = config.cell_size;
    return world;
}

<*
 @require self.bodies.len() > 0 : `Must have rigid bodies`
*>
fn Rigidbody* PhysicsWorld.find_body(self, uint id) {
   foreach (&body: self.bodies) {
     if (body.id == id) return body;
   }

   return null;
}


fn void? PhysicsWorld.add_body(&self, Rigidbody body) {
    uint spatial_index = (uint)self.bodies.len();
    body.spatial_index = spatial_index;
    body.motion.inverse_mass = body.motion.mass > 0 ? 1.0f / body.motion.mass : 0;
    body.old_aabb = body.get_transformed_aabb();

    if (body.motion.inverse_mass > 0) {
        body.motion.inverse_inertia_tensor = body.old_aabb.inverse_inertia_tensor(body.motion.mass);
    }

    self.bodies.push(body);
    self.spatial_map.insert(body.old_aabb, spatial_index)!;
}

fn void? PhysicsWorld.add_bvh_node(&self, Rigidbody body, Aabb3 aabb) {
    self.bodies.push(body);
    self.spatial_map.insert(aabb, body.id)!;
}

fn Aabb3 Rigidbody.get_transformed_aabb(&self) => self.aabb.transform(to_matrix(self.collider.translation, self.collider.scale, self.collider.rotation));

fn void Rigidbody.apply_force(&self, Vec3f force) => self.motion.force += force;
fn void Rigidbody.apply_force_at_point(&self, Vec3f force, Vec3f point) {
    self.motion.force += force;
    Vec3f r = point - self.collider.translation;
    self.motion.torque += r.cross(force);
}


fn void Rigidbody.apply_linear_impulse(&self, Vec3f force) => self.motion.linear_velocity += force * self.motion.inverse_mass;
fn void Rigidbody.apply_angular_impulse(&self, Vec3f force) => self.motion.angular_velocity += self.motion.inverse_inertia_tensor * force;


// fn void Rigidbody.apply_inertia(&self, Vec3f force) {}
// fn void Rigidbody.rotate(&self, Quaternionf rotation) {}

<*
 @require self.bodies.len() > 0 : `Must have some bodies to simulate`
*>
fn void PhysicsWorld.run_step(&self, float time, Vec3f gravity = {0.0f, 0.0f, -9.8f}) {

    // Apply mass
    foreach (&body: self.bodies) {
        body.apply_force(gravity * body.motion.mass);
    }

    foreach (&body: self.bodies) {
        if (body.motion.is_kinematic == false) continue;

        Vec3f linear_acceleration = body.motion.force * body.motion.inverse_mass;
        body.motion.linear_velocity += linear_acceleration * time;
        body.collider.translation += body.motion.linear_velocity * time;

        body.motion.angular_velocity += body.motion.inverse_inertia_tensor * body.motion.torque * time;

        // Quaternionf dq = {...body.motion.angular_velocity, 0.0f};
   
        //


        // float angle = body.motion.angular_velocity.sq_magnitude();


        float angular_speed = body.motion.angular_velocity.sq_magnitude();
  
        if (angular_speed > 0.0001f) {
            Vec3f axis = body.motion.angular_velocity / angular_speed;
            float angular_increment = angular_speed * time;
            body.collider.rotation = {...(math::sin(angular_increment / 2f) * axis), math::cos(angular_increment / 2f)};
        }

        body.motion.force = {0, 0, 0};
        body.motion.torque = {0, 0, 0};
    }
    

    // for (uint i; i < self.bodies.len(); i++) {
    //     for (uint j = i+1; j < self.bodies.len(); j++) {
    //             Rigidbody* body_a = self.bodies.get_ref(i);
    //             Rigidbody* body_b = self.bodies.get_ref(j);
        
    //             TransformedConvex transformed_shape_1 = collision::transformed_shape_from(
    //                 shape: body_a.collider, 
    //                 translation: body_a.translation,
    //                 scale: body_a.scale,
    //                 rotation: body_a.rotation
    //             );

    //             TransformedConvex transformed_shape_2 = collision::transformed_shape_from(
    //                 shape: body_b.collider, 
    //                 translation: body_b.translation,
    //                 scale: body_b.scale,
    //                 rotation: body_b.rotation
    //             );

    //             CollisionInfo collision_info = collision::check_collision(&transformed_shape_1, &transformed_shape_2);

    //             if (collision_info.collided) {
    //                 collision::epa(&collision_info, &transformed_shape_1, &transformed_shape_2);

    //                 self.collisions.push({
    //                     body_a,
    //                     body_b,
    //                     collision_info.normal,
    //                     collision_info.contact_points,
    //                     collision_info.depth,
    //                 });

    //                 body_a.dirty = true;
    //                 body_b.dirty = true;
    //             }   
    //     }
    // }

    self.spatial_map.@get_pairs(;Pair pair) {
        Rigidbody* body_a = self.bodies.get_ref(pair.first);
        Rigidbody* body_b = self.bodies.get_ref(pair.second);
  
        CollisionInfo collision_info = collision::check_collision(&body_a.collider, &body_b.collider);
      
        if (collision_info.collided) {
            collision::epa(&collision_info, &body_a.collider, &body_b.collider);
        
            self.collisions.push({
                .a = pair.first,
                .b = pair.second,
                .normal = collision_info.normal,
                .contact = collision_info.contact_points,
                .depth = collision_info.depth,
            });
        }
    };

    foreach (collision : self.collisions) {
        self.resolve_collision(collision);
    }

    // Update spatial map AABB boxes 
    foreach (&body: self.bodies) {
        if (body.motion.is_kinematic == false) {
            continue;
        };

        Aabb3 new_aabb = body.get_transformed_aabb();
        self.spatial_map.update(body.old_aabb, new_aabb, body.spatial_index)!!;
        body.old_aabb = new_aabb;
        body.dirty = false;
    }
            
    self.collisions.clear();
}

const float EPSILON = 1e-6f;

<*
 @require collision.a != collision.b : `Collision bodies must not reference same body`
*>
fn void PhysicsWorld.resolve_collision(&self, Collision collision) {
    Rigidbody* a = self.bodies.get_ref(collision.a);
    Rigidbody* b = self.bodies.get_ref(collision.b);

    float inverse_mass_sum = a.motion.inverse_mass + b.motion.inverse_mass;
    float total_mass = a.motion.mass + b.motion.mass;

    //Correction
    // float slop = 0.01f;
    // float percent = 0.6f;

    Vec3f correction = collision.normal * collision.depth;
    //Vec3f correction = collision.normal * math::max(collision.depth + slop, 0.0f) * percent;

    a.collider.translation -= correction * a.motion.inverse_mass;
    b.collider.translation += correction * b.motion.inverse_mass;

    Vec3f full_velocity_a = a.motion.linear_velocity + a.motion.angular_velocity;
    Vec3f full_velocity_b = b.motion.linear_velocity + b.motion.angular_velocity;

    Vec3f ra = collision.contact[0] - a.collider.translation;
    Vec3f rb = collision.contact[1] - b.collider.translation;

    Vec3f inertia_a = (a.motion.inverse_inertia_tensor * ra.cross(collision.normal)).cross(ra);
    Vec3f inertia_b = (b.motion.inverse_inertia_tensor * rb.cross(collision.normal)).cross(rb);

    float angular_effect = (inertia_a + inertia_b).dot(collision.normal);

    Vec3f contact_velocity = full_velocity_b - full_velocity_a;

    float impulse_force = contact_velocity.dot(collision.normal);
    if (impulse_force > 0 || angular_effect == 0) return;

    float restitution = a.material.restitution + b.material.restitution;

    float j = -(1.0f + restitution * impulse_force) / inverse_mass_sum;

    Vec3f impulse = collision.normal * j;
    
    if (a.motion.inverse_mass > 0) {
        a.apply_linear_impulse(-impulse);
        // a.apply_angular_impulse(ra.cross(-impulse));
    }

    if (b.motion.inverse_mass > 0) {
        b.apply_linear_impulse(impulse);
        // b.apply_angular_impulse(rb.cross(impulse));
    }
}   