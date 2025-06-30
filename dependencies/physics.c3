module ecs;

import std::math;
import std::io;
import std::collections::list;
import std::collections::elastic_array;
import std::collections::map;


fn Matrix3f Matrix4f.to_mat3(self) => { .m = self.m[0..8] };
// collision primitives: Sphere, Circle, Rectangle, Cuboid, Particle, Convex Polygon, Convex Polyhedra
fn float radians(float value) => value * (float)math::PI / 180;

struct Aabb3 (Printable, ConvexShape) {
    Vec3f min;
    Vec3f max;
}

struct Obb3 {
    Vec3f min;
    Vec3f max;
}

fn usz? Aabb3.to_format(&self, Formatter* formatter) @dynamic => formatter.printf("min %s max %s", self.min, self.max)!;

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


struct Mesh {
    Vec3f[8] vertices;
    ushort[24] indices;
}

 ecs::Mesh cube = {
    .vertices = {
        {-1.0, -1.0, 1.0},
        {1.0, -1.0, 1.0},
        {1.0, 1.0, 1.0},
        {-1.0, 1.0, 1.0},
        {-1.0, -1.0, -1.0},
        {-1.0, 1.0, -1.0},
        {1.0, 1.0, -1.0},
        {1.0, -1.0, -1.0},
    },
    .indices = {
        0, 1, 1, 3, 3, 2, 2, 0, 
        4, 5, 5, 7, 7, 6, 6, 4,
        0, 4, 1, 5, 2, 6, 3, 7 
    }
};

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
    
    return {
        b_min,
        b_max
    };
}

fn Vec3f Aabb3.len(self) => self.max - self.min;

fn Vec3f Aabb3.length_ratios(&self, Aabb3 second) {
    Vec3f current_length = self.max - self.min;
    Vec3f second_length = second.max - second.min;
    Vec3f ratios = current_length / second_length;
    return ratios;
}

interface ConvexShape
{
    fn Vec3f support(Vec3f direction);
}

struct TransformedConvex (ConvexShape) {
    Vec3f position;
    Vec3f scale;
    Quaternionf rotation;
    ConvexShape shape;
}

struct ConvexPolyhedron (ConvexShape) {
    Vec3f[] vertices;
}

struct SupportPoint {
    Vec3f point;  // A - B
    Vec3f support_a;
    Vec3f support_b;
}

alias Simplex = ElasticArray{SupportPoint, 4};

<*
 @require array.len > 0 : `Array should not be empty`
*>
fn void Simplex.replace_array(&self, SupportPoint[] array, usz start_index = 0)
{
    self.size = array.len;
	foreach (index, &value : array) {self.entries[start_index + index] = *value;}
}

fn void Simplex.push_start(&self, SupportPoint point)
{
    self.entries = {point, self.entries[0], self.entries[1], self.entries[2]};
    self.size = math::min((usz)(self.size + 1), (usz)4);
}

fn Vec3f Quaternionf.rotate_point(&self, Vec3f direction) @dynamic {
    Vec3f u = {self.i, self.j, self.k};
    float s = self.l;

    return 2.0f * u.dot(direction) * u
            + (s*s - u.dot(u)) * direction
            + 2.0f * s * u.cross(direction);
}

fn Quaternionf Quaternionf.inverse(&self) => {self.l, -self.j, -self.k, -self.l};
fn Vec3f TransformedConvex.transform_point(&self, Vec3f point) => self.position + self.rotation.rotate_point(point * self.scale);
fn Vec3f TransformedConvex.inverse_transform_point(&self, Vec3f point) => self.rotation.inverse().rotate_point(point);

fn Vec3f TransformedConvex.support(&self, Vec3f direction) @dynamic {
    // Vec3f point = self.shape.support(self.inverse_transform_point(direction));
    // return self.transform_point(point);
    return self.shape.support(direction * self.scale + self.position);
}

fn Vec3f Aabb3.support(&self, Vec3f direction) @dynamic {
    Vec3f point = {
        (direction.x > 0) ? self.max.x : self.min.x,
        (direction.y > 0) ? self.max.y : self.min.y,
        (direction.z > 0) ? self.max.z : self.min.z
    };
    return point;
}

fn Vec3f ConvexPolyhedron.support(&self, Vec3f direction) @dynamic {
    Vec3f furthest_point;
    float max_dot_a = -float.max;
    
    foreach (pos : self.vertices) {
        float d = pos.dot(direction);
        if (d > max_dot_a) {
            max_dot_a = d;
            furthest_point = pos;
        }
    }
  
    return furthest_point;
}


// Handles the line case (2 points in simplex)
fn bool line_case(Simplex* simplex, Vec3f* direction) {
    SupportPoint first = simplex.get(0);
    SupportPoint second = simplex.get(1);

    Vec3f a = first.point;
    Vec3f b = second.point;
    Vec3f ab = b - a;
    Vec3f ao = -a;

    if (ab.dot(ao) > 0) {
        direction = &&ab.cross(ao).cross(ab);
    } else {
        simplex.replace_array({ first });
        direction = &&ao;
    }
    return false;
}


// Handles the triangle case (3 points in simplex)
fn bool triangle_case(Simplex* simplex, Vec3f* direction) {
    SupportPoint first = simplex.get(0);
    SupportPoint second = simplex.get(1);
    SupportPoint third = simplex.get(2);

    Vec3f a = first.point;
    Vec3f b = second.point;
    Vec3f c = third.point;

    Vec3f ab = b - a;
    Vec3f ac = c - a;
    Vec3f ao = -a;

    Vec3f abc = ab.cross(ac);

    if (abc.cross(ac).dot(ao) > 0) {
        if (ac.dot(ao) > 0) {
            simplex.replace_array({ first, second });
            direction = &&ac.cross(ao).cross(ac);
        } else {
            return line_case(simplex, direction);
        }
    } else {
        if (ab.cross(abc).dot(ao) > 0) {
             return line_case(simplex, direction);
        } else {
            if (abc.dot(ao) > 0) {
                direction = &&abc;
            } else {
                simplex.replace_array({ first, second, third });
                direction = &&-abc;
            }
        }
    }
    return false;
}

// Handles the tetrahedron case (4 points in simplex)
fn bool tetrahedron_case(Simplex* simplex, Vec3f* direction) {
    SupportPoint first = simplex.get(0);
    SupportPoint second = simplex.get(1);
    SupportPoint third = simplex.get(2);
    SupportPoint fourth = simplex.get(3);

    Vec3f a = first.point;
    Vec3f b = second.point;
    Vec3f c = third.point;
    Vec3f d = fourth.point;

    Vec3f ao = -a;
    Vec3f ab = b - a;
    Vec3f ac = c - a;
    Vec3f ad = d - a;

    Vec3f abc = ab.cross(ac);
    Vec3f acd = ac.cross(ad);
    Vec3f adb = ad.cross(ab);

    if (abc.dot(ao) > 0) {
        simplex.replace_array({ first, second, third });
        return triangle_case(simplex, direction);
    }
    if (acd.dot(ao) > 0) {
        simplex.replace_array({ first, third, fourth });
        return triangle_case(simplex, direction);
    }
    if (adb.dot(ao) > 0) {
        simplex.replace_array({ first, fourth, third });
        return triangle_case(simplex, direction);
    }

    return true; // Origin is inside tetrahedron
}

fn bool next_simplex(Simplex* simplex, Vec3f* direction) {
    switch (simplex.len()) {
        case 2: return line_case(simplex, direction);
        case 3: return triangle_case(simplex, direction);
        case 4: return tetrahedron_case(simplex, direction);
    }
    return false; // Should not be reached
}

const usz GJK_MAX_ITERATION = 42;
// GJK algorithm to find, if shapes collide
fn CollisionInfo check_collision(ConvexShape shape_1, ConvexShape shape_2) {
    // Initial direction (arbitrary)
    Vec3f direction = {1, 0, 0};
    
    Simplex simplex;
    {
        Vec3f a_support = shape_1.support(direction);
        Vec3f b_support = shape_2.support(direction);
        Vec3f point = a_support - b_support;

        // Initial simplex point
        simplex.push_start({
            point,
            a_support,
            b_support
        });
    }

    // New search direction is towards origin
    direction = -simplex[0].point;

    // Main GJK loop
    for (usz i = 0; i < GJK_MAX_ITERATION; ++i) {
        // Get new support point
        Vec3f a_support = shape_1.support(direction);
        Vec3f b_support = shape_2.support(direction);
        Vec3f new_point = a_support - b_support;
        // If we didn't reach the origin, no collision
        if (new_point.dot(direction) < 0) {
            return { .collided = false };
        }

        // Add new point to simplex
        simplex.push_start({
            new_point,
            a_support,
            b_support
        });
   
        if (next_simplex(&simplex, &direction)) {
            return { .collided = true, .simplex = simplex };
        }
    }

    return { .collided = false };
}

struct Face {
    Vec3f a,b,c;
    Vec3f normal;
    usz[3] indices;
    float distance;
}

struct CollisionInfo {
    Simplex simplex;
    Vec3f normal;
    Vec3f[2] contact_points;
    float depth;
    bool collided;
}

struct Plane {
    Vec3f normal;
    float distance;
}

fn Plane plane_from_tri(Vec3f a, Vec3f b, Vec3f c) {
    Vec3f ab = b - c;
    Vec3f ac = c - a;
    Vec3f normal = ab.cross(ac).normalize();

    return {
        .distance = -ab.dot(normal),
        .normal = normal 
    };
}

fn Vec3f plane_project(Plane plane, Vec3f point) {
    Vec3f distance = point.dot(plane.normal) + plane.distance;
    return point - (plane.normal * distance);
}



// fn CollisionInfo collision_manifold(Face face) {
//     Vec3f a = face.points[0];
//     Vec3f b = face.points[1];
//     Vec3f c = face.points[2];

//     Vec3f projection_point = plane_project(plane_from_tri(a,b,c), {0,0,0});
//     Vec3f bary = projection_point.barycenter(a, b, c);

//     // Todo: Use SupportPoint points
//     Vec3f local_a = bary.x * face.points[0].x + bary.y * face.points[1].x + bary.z * face.points[2].x;
//     Vec3f local_b = bary.x * face.points[0].y + bary.y * face.points[1].y + bary.z * face.points[2].y;

//     return {
//         .depth = (local_a - local_b).length(),
//         .normal = (local_a - local_b).normalize(),
//         .contact_points = {local_a, local_b},
//     };
// }

const uint EPA_MAX_FACES = 65;
const uint EPA_MAX_LOOSE_EDGES = EPA_MAX_FACES / 2;
const uint EPA_MAX_ITER = 32;
const float EPA_TOLERANCE = 0.0001;

alias PolytopeArray = ElasticArray{Vec3f, EPA_MAX_LOOSE_EDGES};
alias FaceArray = ElasticArray{usz, EPA_MAX_FACES};
alias PairArray = ElasticArray{Pair, EPA_MAX_LOOSE_EDGES};

fn void FaceArray.replace_array(&self, usz[] array, usz start_index = 0)
{
    self.size = array.len + start_index;
	foreach (index, &value : array) {self.entries[start_index + index] = *value;}
}

fn void PairArray.add_edge_if_unique(&self, Pair pair) {
    if (!self.contains(pair)) {self.push(pair);}
    else { self.remove_item(pair); }
}

fn Face find_closest_face(PolytopeArray polytope, FaceArray faces) {
    Face closest_face = { .distance = float.max };

    for (usz i = 0; i < faces.len(); i += 3) {
        Vec3f a = polytope[faces[i]];
        Vec3f b = polytope[faces[i + 1]];
        Vec3f c = polytope[faces[i + 2]];

        Vec3f normal = (b - a).cross(c - a).normalize();
        float dist = normal.dot(a);

        // io::printfn("%s %s %s", a, b, c);

        if (dist < 0) {
            dist *= -1;
            normal = -normal;
        }

        if (dist < closest_face.distance) {
            closest_face.distance = dist;
            closest_face.normal = normal;
            closest_face.a = a;
            closest_face.b = b;
            closest_face.c = c;
            closest_face.indices[0] = faces[i];
            closest_face.indices[1] = faces[i+1];
            closest_face.indices[2] = faces[i+2];
        }
    }

    return closest_face;
}

fn CollisionInfo epa(Simplex simplex, ConvexShape shape_1, ConvexShape shape_2) {
    FaceArray faces;
    PolytopeArray polytope;

    foreach (item: simplex) polytope.push(item.point);
   
    faces.add_array({
        0, 1, 2,
        0, 3, 1,
        0, 2, 3,
        1, 3, 2
    });

    for (int i = 0; i < EPA_MAX_ITER; ++i) {
        Face closest_face = find_closest_face(polytope, faces);

        Vec3f new_point = shape_1.support(closest_face.normal) - shape_2.support(closest_face.normal);
        float new_dist = closest_face.normal.dot(new_point);

        if (math::abs(new_dist - closest_face.distance) < EPA_TOLERANCE) {
            return {
                .normal = closest_face.normal,
                .depth = closest_face.distance
            };
        }

        polytope.push(new_point);

        PairArray edges;
        FaceArray new_faces;

        for (usz j = 0; j < faces.len(); j += 3) {
            Vec3f a = polytope[faces[j]];
            Vec3f b = polytope[faces[j+1]];
            Vec3f c = polytope[faces[j+2]];
            Vec3f face_normal = (b-a).cross(c-a);

            // Can see the new point
            if (face_normal.dot(new_point - a) > 0) {
                edges.add_edge_if_unique({faces[j], faces[j+1]});
                edges.add_edge_if_unique({faces[j+1], faces[j+2]});
                edges.add_edge_if_unique({faces[j+2], faces[j]});
            } else {
                new_faces.push(faces[j]);
                new_faces.push(faces[j+1]);
                new_faces.push(faces[j+2]);
            }
        }

        foreach (edge : edges) {
            new_faces.push(edge.first);
            new_faces.push(edge.second);
            new_faces.push(polytope.len() - 1);
        }

        faces.replace_array(new_faces.array_view());
    }

    Face final_face = find_closest_face(polytope, faces);

    return {
        .normal = final_face.normal,
        .depth = final_face.distance
    };
}

struct GridAabb3 {
    Vec3f min;
    Vec3f max;
    usz id;
}

struct GridCoord {
    int x, y, z;
}

fn bool GridCoord.equals(&self, GridCoord other) => self.x == other.x && self.y == other.y && self.z == other.z;

fn usz GridCoord.hash(&self) {
    usz h1 = self.x.hash();
    usz h2 = self.y.hash();
    usz h3 = self.z.hash();
    return h1 ^ (h2 << 1) ^ (h3 << 2);
}

alias CellList = List{usz};
alias SpatialMap = HashMap{usz, CellList};

struct Pair (Printable) {
    usz first;
    usz second;
}

fn usz? Pair.to_format(&self, Formatter* formatter) @dynamic => formatter.printf("%s, %s", self.first, self.second)!;
macro bool Pair.equals(self, Pair b) @operator(==) => self.first == b.first && self.second == b.second;
macro uint Pair.hash(Pair self) => builtin::@generic_hash(self.first) | builtin::@generic_hash(self.second);

struct SpatialHash3D {
    double cell_size;
    SpatialMap table;
    HashMap{usz, bool} unique_map;
}

fn void SpatialHash3D.free(&self) {
    self.table.@each(; usz id, CellList cells) {
        cells.free();
    };
    self.table.free();
    self.unique_map.free();
}

fn GridCoord SpatialHash3D.world_to_grid(&self, Vec3f pos) {
    return (GridCoord) {
        (int)(math::floor(pos.x / self.cell_size)),
        (int)(math::floor(pos.y / self.cell_size)),
        (int)(math::floor(pos.z / self.cell_size)),
    };
}

fn void? SpatialHash3D.insert(&self, GridAabb3 box) {
    GridCoord min_cell = self.world_to_grid(box.min);
    GridCoord max_cell = self.world_to_grid(box.max);

    for (int x = min_cell.x; x <= max_cell.x; ++x) {
        for (int y = min_cell.y; y <= max_cell.y; ++y) {

            for (int z = min_cell.z; z <= max_cell.z; ++z) {
                usz cell_id = (GridCoord){x, y, z}.hash();

                if (!self.table.has_key(cell_id)) {
                    self.table.set(cell_id, {});
                };

                self.table.get_ref(cell_id)!.push(box.id);
            }
        }
    }
}

macro void SpatialHash3D.@get_pairs(&self; @callback(Pair pair)) {
    self.table.@each(;usz id, CellList cells) {
        for (usz i = 0; i < cells.len(); ++i) {
            for (usz j = i + 1; j < cells.len(); ++j) {
                usz a = cells[i];
                usz b = cells[j];

                Pair pair = {math::min(a, b), math::max(a, b)};
                usz pair_hash = pair.hash();

                if (!self.unique_map.has_key(pair_hash)) {
                    @callback(pair);
                    self.unique_map.set(pair_hash, true);
                }
            }
        }
    };

    self.unique_map.clear();
}

macro void SpatialHash3D.@get_pairs_in_region(&self, Vec3f min, Vec3f max ; @callback(Pair pair)) {
    GridCoord min_cell = self.world_to_grid(box.min);
    GridCoord max_cell = self.world_to_grid(box.max);

    for (uint x = min_cell.x; x <= max_cell.x; ++x) {
    for (uint y = min_cell.y; y <= max_cell.y; ++y) {
            for (uint z = min_cell.z; z <= max_cell.z; ++z) {
                usz cell_id = (GridCoord){x, y, z}.hash();
                CellList cells = self.table.get(cell_id);
                
                for (usz i = 0; i < cells.len(); ++i) {
                    for (usz j = i + 1; j < cells.len(); ++j) {
                        usz a = cells[i];
                        usz b = cells[j];
                        Pair pair = {math::min(a, b), math::max(a, b)};
                        usz pair_hash = pair.hash();

                        if (!self.unique_map.has_key(pair_hash)) {
                            @callback(pair);
                            self.unique_map.set(pair_hash, true);
                        }
                    }
                }
            }
        }
    }

    self.unique_map.clear();
}

macro void SpatialHash3D.@get_neighbor_cells(&self, GridCoord cell; @callback(Vec3f position)) {
    for (int dx = -1; dx <= 1; ++dx) {
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dz = -1; dz <= 1; ++dz) {
                @callback({cell.x + dx, cell.y + dy, cell.z + dz});
            }
        }
    }
}

macro void SpatialHash3D.@get_nearby_objects(&self, Vec3f pos; @callback(usz id)) {
    GridCoord cell = self.world_to_grid(pos);

    self.@get_neighbor_cells(cell; Vec3f position) {
        usz cell_id = (GridCoord){position.x, position.y, position.z}.hash();
        CellList cells = self.table.get(cell_id);
        foreach (cell: cells) @callback(cell);
    };
}

fn void test_physics() @test {
    Aabb3 aabb = {
        {-1.0, -1.0, -1.0},
        {1.0, 1.0, 1.0}
    };

    Matrix4f matrix = MATRIX4F_IDENTITY.translate({1, 5, 1}).scale({3.0, 1.0, 1.0});

    aabb = aabb.transform(matrix);
    assert(aabb.min == {-2, 4, 0});
    assert(aabb.max == {4, 6, 2});

    SpatialHash3D spatial_map = { .cell_size = 1.0 };
    defer spatial_map.free();

    Aabb3[] boxes = {
        {{0,0,0}, {1,1,1}},
        {{1,1,1}, {2.5,2.5,2.5}},
        {{5,5,5}, {6,6,6}},
    };

    foreach (usz i, item: boxes) spatial_map.insert({.min = item.min, .max = item.max, .id = i })!!;
    spatial_map.@get_pairs(;Pair pair) { assert(pair.first == 0 && pair.second == 1); };

    ///
    Vec3f[] cube = {
        {-0.5, -0.5, -0.5}, {0.5, -0.5, -0.5}, {0.5, 0.5, -0.5}, {-0.5, 0.5, -0.5},
        {-0.5, -0.5, 0.5}, {0.5, -0.5, 0.5}, {0.5, 0.5, 0.5}, {-0.5, 0.5, 0.5}
    };

    ConvexPolyhedron shape_1 = (ConvexPolyhedron){cube};

    TransformedConvex transformed_shape_1 = {
        .shape = &shape_1, 
        .position = {-2.0, 0, 0}, 
        .scale = {1, 1, 1},
    };
    
    TransformedConvex transformed_shape_2 = {
        .shape = &shape_1, 
        .position = {2.0, 0, 0}, 
        .scale = {1, 1, 1},
    };

    TransformedConvex transformed_shape_3 = {
        .shape = &shape_1, 
        .position = {-0.5, 0, 0}, 
        .scale = {1, 1, 1},
    };
    
    TransformedConvex transformed_shape_4 = {
        .shape = &shape_1, 
        .position = {0.5, 0, 0}, 
        .scale = {1, 1, 1},
    };

    TransformedConvex transformed_shape_5 = {
        .shape = &shape_1, 
        .position = {0.0, 0, 0}, 
        .scale = {1, 1, 1},
    };
    
    TransformedConvex transformed_shape_6 = {
        .shape = &shape_1, 
        .position = {0.8, 0, 0}, 
        .scale = {1, 1, 1},
        .rotation = {0, 0.8, 0, 0.92388 }
    };

    TransformedConvex transformed_shape_7 = {
        .shape = &shape_1, 
        .position = {-1.0, 0, 0}, 
        .scale = {1, 1, 1},
        .rotation = {0, 0.5, 0, 1 }
    };
    
    TransformedConvex transformed_shape_8 = {
        .shape = &shape_1, 
        .position = {1.0, 0, 0}, 
        .scale = {1, 1, 1},
        .rotation = {0, -0.5, 0, 1 }
    };

    assert(!check_collision(&transformed_shape_1, &transformed_shape_2).collided);
    assert(check_collision(&transformed_shape_3, &transformed_shape_4).collided);
    assert(check_collision(&transformed_shape_5, &transformed_shape_6).collided);
    assert(!check_collision(&transformed_shape_7, &transformed_shape_8).collided);
    
    // CollisionInfo epa_result = epa(collision_result.simplex, &shape_1, &shape_2);

    // {
    //     Aabb3 aabb = {
    //         {3.486510, 1693.368896, 2.556290},
    //         {3.537758, 1698.706421, 2.556290}
    //     };
    // }
}

