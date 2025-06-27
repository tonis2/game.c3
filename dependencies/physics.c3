module ecs;

import std::math;
import std::io;
import std::collections::list;
import std::collections::map;


fn Matrix3f Matrix4f.to_mat3(self) => { .m = self.m[0..8] };
// collision primitives: Sphere, Circle, Rectangle, Cuboid, Particle, Convex Polygon, Convex Polyhedra
fn float radians(float value) => value * (float)math::PI / 180;

struct Aabb3 (Printable) {
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


fn Vec3f support(Vec3f[] first, Vec3f[] second, Vec3f direction) {
    // Find farthest point in shapeA along direction
    Vec3f point_a = first[0];
    float max_dot_a = point_a.dot(direction);

    foreach (v : first) {
        float d = v.dot(direction);
        if (d > max_dot_a) {
            max_dot_a = d;
            point_a = v;
        }
    }
    
    // Find farthest point in shapeB along opposite direction
    Vec3f point_b = second[0];
    float max_dot_b = point_b.dot(-direction);

    foreach (v : second) {
        float d = v.dot(-direction);
        if (d > max_dot_b) {
            max_dot_b = d;
            point_b = v;
        }
    }
    
    // Return Minkowski difference point
    return point_a - point_b;
}

fn bool contains_origin(Vec3f[] simplex, Vec3f direction) {
    if (simplex.len == 2) {
        // Line segment case
        Vec3f a = simplex[1];
        Vec3f b = simplex[0];
        Vec3f ab = b - a;
        Vec3f ao = -a;
        
        if (ab.dot(ao) > 0) {
            // New direction is perpendicular to AB towards origin
            direction = ab.cross(ao).cross(ab);
        } else {
            simplex = {a};
            direction = ao;
        }
    } 
    else if (simplex.len == 3) {
        // Triangle case
        Vec3f a = simplex[2];
        Vec3f b = simplex[1];
        Vec3f c = simplex[0];
        Vec3f ab = b - a;
        Vec3f ac = c - a;
        Vec3f ao = -a;
        Vec3f abc = ab.cross(ac);
        
        // Edge AB
        if (ab.cross(abc).dot(ao) > 0) {
            simplex = {a, b};
            direction = ab.cross(ao).cross(ab);
            return false;
        }
        
        // Edge AC
        if (abc.cross(ac).dot(ao) > 0) {
            simplex = {a, c};
            direction = ac.cross(ao).cross(ac);
            return false;
        }
        
        // Above/below triangle
        if (abc.dot(ao) > 0) {
            direction = abc;
        } else {
            direction = -abc;
        }
    }
    else if (simplex.len == 4) {
        // Tetrahedron case
        Vec3f a = simplex[3];
        Vec3f b = simplex[2];
        Vec3f c = simplex[1];
        Vec3f d = simplex[0];
        Vec3f ao = -a;
        
        Vec3f ab = b-a;
        Vec3f ac = c-a;
        Vec3f ad = d-a;
        
        Vec3f abc = ab.cross(ac);
        Vec3f acd = ac.cross(ad);
        Vec3f adb = ad.cross(ab);
        
        // ABC face
        if (abc.dot(ao) > 0) {
            simplex = {a, b, c};
            direction = abc;
            return false;
        }
        
        // ACD face
        if (acd.dot(ao) > 0) {
            simplex = {a, c, d};
            direction = acd;
            return false;
        }
        
        // ADB face
        if (adb.dot(ao) > 0) {
            simplex = {a, d, b};
            direction = adb;
            return false;
        }
        
        // Origin is inside tetrahedron
        return true;
    }
    
    return false;
}

struct Edge {
    uint a;
    uint b;
    Vec3f normal;
    float distance;
}

struct CollisionInfo {
    bool colliding;
    Vec3f normal;
    float depth;
}

alias Triangle = uint[3];

fn Edge find_closest_edge(Vec3f[] polytope, Triangle[] faces) {
    Edge closest = {
        .distance = float.max
    };

    foreach (face : faces) {
        Vec3f a = polytope[face[0]];
        Vec3f b = polytope[face[1]];
        Vec3f c = polytope[face[2]];

        Vec3f normal = (a-b).cross(c-a).normalize();
        float distance = normal.dot(a);

        if (distance < closest.distance) {
            closest.distance = distance;
            closest.normal = normal;
            closest.a = face[0];
            closest.b = face[1];
        }
    }

    return closest;
}

// EPA implementation
fn CollisionInfo epa(Vec3f[] first, Vec3f[] second, Vec3f[] simplex) {
    // std::vector<Vec3> polytope = simplex;
    // std::vector<Triangle> faces = {
    //     {0, 1, 2}, // ABC
    //     {0, 3, 1}, // ADB
    //     {0, 2, 3}, // ACD
    //     {1, 3, 2}  // BDC
    // };

    // const size_t maxIterations = 50;
    // CollisionInfo result;
    // result.colliding = true;

    // for (size_t i = 0; i < maxIterations; ++i) {
    //     Edge edge = findClosestEdge(polytope, faces);
    //     Vec3 support = support(shapeA, shapeB, edge.normal);
    //     float distance = dot(support, edge.normal);

    //     if (std::abs(distance - edge.distance) < 0.001f) {
    //         result.normal = edge.normal;
    //         result.depth = distance;
    //         return result;
    //     }

    //     // Add new vertex to polytope
    //     size_t newIndex = polytope.size();
    //     polytope.push_back(support);

    //     // Remove faces that can see the new point
    //     std::vector<Triangle> newFaces;
    //     for (const auto& face : faces) {
    //         Vec3 a = polytope[face[0]];
    //         Vec3 b = polytope[face[1]];
    //         Vec3 c = polytope[face[2]];

    //         Vec3 normal = normalize(cross(subtract(b, a), subtract(c, a)));
    //         if (dot(normal, subtract(support, a)) > 0) {
    //             // Face can see the point, remove it
    //             continue;
    //         }
    //         newFaces.push_back(face);
    //     }

    //     // Create new faces from the edge horizon
    //     std::vector<Edge> edges;
    //     for (const auto& face : newFaces) {
    //         edges.push_back({face[0], face[1], Vec3(), 0});
    //         edges.push_back({face[1], face[2], Vec3(), 0});
    //         edges.push_back({face[2], face[0], Vec3(), 0});
    //     }

    //     // Remove duplicate edges
    //     std::vector<Edge> uniqueEdges;
    //     for (size_t j = 0; j < edges.size(); ++j) {
    //         bool isUnique = true;
    //         for (size_t k = j + 1; k < edges.size(); ++k) {
    //             if ((edges[j].a == edges[k].b && edges[j].b == edges[k].a) ||
    //                 (edges[j].a == edges[k].a && edges[j].b == edges[k].b)) {
    //                 isUnique = false;
    //                 break;
    //             }
    //         }
    //         if (isUnique) {
    //             uniqueEdges.push_back(edges[j]);
    //         }
    //     }

    //     // Create new faces from unique edges
    //     for (const auto& edge : uniqueEdges) {
    //         newFaces.push_back({edge.a, edge.b, newIndex});
    //     }

    //     faces = newFaces;
    // }

    // // If we reach max iterations, return best estimate
    // Edge edge = findClosestEdge(polytope, faces);
    // result.normal = edge.normal;
    // result.depth = edge.distance;
    // return result;

    return {};
}


struct Gjk {
    List{Vec3f} simplex;
}

fn void Gjk.free(&self) {
    self.simplex.free();
}

fn bool Gjk.check_collision(&self, Vec3f[] first, Vec3f[] second) {
    // Initial direction (arbitrary)
    Vec3f direction = {1, 0, 0};
    
    // Initial simplex point

    self.simplex.push(support(first, second, direction));
    // New search direction is towards origin
    direction = -self.simplex[0];
    // Main GJK loop
    uint max_iterations = 50;

    for (uint i = 0; i < max_iterations; ++i) {
        // Get new support point
        Vec3f new_point = support(first, second, direction);
        
        // If we didn't reach the origin, no collision
        if (new_point.dot(direction) < 0) {
            return false;
        }
        
        // Add new point to simplex
        self.simplex.push(new_point);
        
        // Check if simplex contains origin
        if (contains_origin(self.simplex.array_view(), direction)) {
            return true;
        }
    }

    self.simplex.clear();
    return false;
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
    Vec3f[] shapeA = {
        {0, 0, 0},
        {1, 0, 0},
        {0, 1, 0},
        {0, 0, 1}
    };
    
    Vec3f[] shapeB = {
        {0.5, 0.5, 0.5},
        {1.5, 0.5, 0.5},
        {0.5, 1.5, 0.5},
        {0.5, 0.5, 1.5}
    };

    Gjk gjk = {};
    defer gjk.free();

    assert(gjk.check_collision(shapeA, shapeB));
    ///

    Aabb3[] boxes = {
        {{0,0,0}, {1,1,1}},
        {{1,1,1}, {2.5,2.5,2.5}},
        {{5,5,5}, {6,6,6}},
    };

    SpatialHash3D spatial_map = { .cell_size = 2.0 };
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