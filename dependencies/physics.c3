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

alias SimplexArray = ElasticArray{SupportPoint, 4};

// fn Vec3f TransformedConvex.to_point(&self, Vec3f local_point) => self.rotation * local_point + self.position;
// fn Vec3f TransformedConvex.inverse_to_direction(&self, Vec3f world_dir) => self.rotation.transpose() * world_dir;

//TODO: not working
fn Vec3f TransformedConvex.support(&self, Vec3f direction) @dynamic { 
    return self.shape.support(direction.rotate_quat(self.rotation.invert())).rotate_quat(self.rotation) + self.position;
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
    Vec3f point_a = self.vertices[0];
    float max_dot_a = point_a.dot(direction);

    foreach (v : self.vertices) {
        Vec3f pos = v;

        float d = pos.dot(direction);
        if (d > max_dot_a) {
            max_dot_a = d;
            point_a = pos;
        }
    }
    return point_a;
}

fn void SimplexArray.replace_values(&self, SupportPoint[] array)
{
	if (!array.len) return;
	foreach (index, &value : array)
	{
		self.entries[index] = *value;
	}
}

fn bool contains_origin(SimplexArray* simplex, Vec3f* direction) {
    switch (simplex.len()) {
        case 2: {
            // Line segment case
            SupportPoint a = simplex.get(1);
            SupportPoint b = simplex.get(0);
            Vec3f ab = b.point - a.point;
            Vec3f ao = -a.point;

            if (ab.dot(ao) > 0) {
                // New direction is perpendicular to AB towards origin
                direction = &&ab.cross(ao).cross(ab);
            } else {
                simplex.replace_values({a});
                direction = &ao;
            }
        }
        case 3: {
            // Triangle case
            SupportPoint a = simplex.get(2);
            SupportPoint b = simplex.get(1);
            SupportPoint c = simplex.get(0);
            Vec3f ab = b.point - a.point;
            Vec3f ac = c.point- a.point;
            Vec3f ao = -a.point;
            Vec3f abc = ab.cross(ac);

            // Edge AB
            if (ab.cross(abc).dot(ao) > 0) {
                simplex.replace_values({a, b});
                direction = &&ab.cross(ao).cross(ab);
                return false;
            }
            
            // Edge AC
            if (abc.cross(ac).dot(ao) > 0) {
                simplex.replace_values({a, c});
                direction = &&ac.cross(ao).cross(ac);
                return false;
            }
            
            // Above/below triangle
            if (abc.dot(ao) > 0) {
                direction = &&abc;
            } else {
                direction = &&-abc;
            }
        }
        case 4: {
            // Tetrahedron case
            SupportPoint a = simplex.get(3);
            SupportPoint b = simplex.get(2);
            SupportPoint c = simplex.get(1);
            SupportPoint d = simplex.get(0);
            Vec3f ao = -a.point;
            
            Vec3f ab = b.point-a.point;
            Vec3f ac = c.point-a.point;
            Vec3f ad = d.point-a.point;
            
            Vec3f abc = ab.cross(ac);
            Vec3f acd = ac.cross(ad);
            Vec3f adb = ad.cross(ab);

            // ABC face
            if (abc.dot(ao) > 0) {
                simplex.replace_values({a, b, c});
                direction = &abc;
                return false;
            }
            
            // ACD face
            if (acd.dot(ao) > 0) {
                simplex.replace_values({a, c, d});
                direction = &acd;
                return false;
            }
            
            // ADB face
            if (adb.dot(ao) > 0) {
                simplex.replace_values({a, d, b});
                direction = &adb;
                return false;
            }
            
            // Origin is inside tetrahedron
            return true;
        }
    }    
    return false;
}

fn bool check_collision(ConvexShape shape_1, ConvexShape shape_2) {
    // Initial direction (arbitrary)
    Vec3f direction = {1, 0, 0};
    
    SimplexArray simplex;
    
    {
        Vec3f a_support = shape_1.support(direction);
        Vec3f b_support = shape_2.support(direction);

        // Initial simplex point
        simplex.push({
            a_support - b_support,
            a_support,
            b_support
        });
    }

    // New search direction is towards origin
    direction = -simplex.get(0).point;
    // Main GJK loop
    uint max_iterations = 50;

    for (uint i = 0; i < max_iterations; ++i) {

        // Get new support point
        Vec3f a_support = shape_1.support(direction);
        Vec3f b_support = shape_2.support(direction);
        Vec3f new_point = a_support - b_support;
        
        // If we didn't reach the origin, no collision
        if (new_point.dot(direction) < 0) {
            return false;
        }
        
        // Add new point to simplex
        simplex.push({
            new_point,
            a_support,
            b_support
        });

        // Check if simplex contains origin
        if (contains_origin(&simplex, &direction)) {
            return true;
        }
    }

    return false;
}

struct Face {
    Vec3f[3] points;
    Vec3f normal;
}

struct CollisionInfo {
    Vec3f normal;
    Vec3f[2] contact_points;
    float depth;
}

struct Plane {
    Vec3f normal;
    float distance;
}

fn Face new_face(Vec3f a, Vec3f b, Vec3f c) {
    Vec3f normal = (b - a).cross(c - a).normalize();
    return {
        .points = {a, b, c},
        .normal = normal
    };
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

fn Vec3f triple_product(Vec3f a, Vec3f b, Vec3f c) => b * a.dot(c) - c * a.dot(b);

fn CollisionInfo collision_manifold(Face face) {
    Vec3f a = face.points[0];
    Vec3f b = face.points[1];
    Vec3f c = face.points[2];

    Vec3f projection_point = plane_project(plane_from_tri(a,b,c), {0,0,0});
    Vec3f bary = projection_point.barycenter(a, b, c);

    // Todo: Use SupportPoint points
    Vec3f local_a = bary.x * face.points[0].x + bary.y * face.points[1].x + bary.z * face.points[2].x;
    Vec3f local_b = bary.x * face.points[0].y + bary.y * face.points[1].y + bary.z * face.points[2].y;

    return {
        .depth = (local_a - local_b).length(),
        .normal = (local_a - local_b).normalize(),
        .contact_points = {local_a, local_b},
    };
}

const uint EPA_MAX_FACES = 65;
const uint EPA_MAX_LOOSE_EDGES = EPA_MAX_FACES / 2;
const uint EPA_MAX_ITER = 64;
const float EPA_TOLERANCE = 0.0001;

fn CollisionInfo epa(SimplexArray simplex, ConvexShape shape_1, ConvexShape shape_2) {

    ElasticArray{Face, EPA_MAX_FACES} faces;
    ElasticArray{Vec3f, EPA_MAX_LOOSE_EDGES} loose_edges;

    {
        // Create starting faces
        Vec3f a = simplex[0].point;
        Vec3f b = simplex[1].point;
        Vec3f c = simplex[2].point;
        Vec3f d = simplex[3].point;

        faces.push(new_face(a, b, c));
        faces.push(new_face(a, c, d));
        faces.push(new_face(a, d, b));
        faces.push(new_face(b, d, c));
    }

    int closest_face = -1;
    for (uint iteration = 0; iteration < EPA_MAX_ITER; iteration++) {

        float min_distance = faces[0].points[0].dot(faces[0].normal);
        foreach (uint i, face: faces) {
            float dist = face.points[0].dot(face.normal);

            if (dist < min_distance) {
                min_distance = dist;
                closest_face = i;
            }
        }

        Vec3f direction = faces[closest_face].normal;
        Vec3f support_point = shape_1.support(direction) - shape_2.support(direction);

        if (support_point.dot(direction) - min_distance < EPA_TOLERANCE) {
            //collision_manifold()
            return (CollisionInfo){.normal = direction, .depth = min_distance };
        }

        loose_edges.clear();

        foreach (uint i, face: faces) {
            if (face.normal.dot(support_point - face.points[0]) > 0)  {

            }
        }
    }



    return (CollisionInfo){.depth = -1 };
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
    //rotate_y(radians(45));

    aabb = aabb.transform(matrix);
    assert(aabb.min == {-2, 4, 0});
    assert(aabb.max == {4, 6, 2});

    ///
    Vec3f[] cube = {
      {0,0,0}, {1,0,0}, {0,1,0}, {0,0,1},
      {1,1,0}, {1,0,1}, {0,1,1}, {1,1,1}
    };

    Vec3f[] cube2 = cube;
    Vec3f[] cube3 = cube;

    foreach (pos : &cube2) {
        pos[0] += 0.5;
        pos[1] += 0.5;
        pos[2] += 0.5;
    }

    foreach (pos : &cube3) {
        pos[0] += 5.0;
        pos[1] += 5.0;
        pos[2] += 5.0;
    }

    assert(check_collision(&&(ConvexPolyhedron){cube}, &&(ConvexPolyhedron){cube2}));
    assert(check_collision(&&(ConvexPolyhedron){cube}, &&(ConvexPolyhedron){cube3}));
    
    Aabb3[] boxes = {
        {{0,0,0}, {1,1,1}},
        {{1,1,1}, {2.5,2.5,2.5}},
        {{5,5,5}, {6,6,6}},
    };

    SpatialHash3D spatial_map = { .cell_size = 1.0 };
    defer spatial_map.free();

    // foreach (usz i, item: boxes) spatial_map.insert({.min = item.min, .max = item.max, .id = i })!!;

    // spatial_map.@get_pairs(;usz first, usz second) {
    //     io::printfn("first %s second %s", first, second);
    // };

    // {
    //     Aabb3 aabb = {
    //         {3.486510, 1693.368896, 2.556290},
    //         {3.537758, 1698.706421, 2.556290}
    //     };
    // }
}