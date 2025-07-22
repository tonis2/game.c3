import std::io;
import std::math;
import std::collections::list;
import std::time;
import std::thread;
import std::collections::map;

import vk;
import stb;
import gltf;
import c3w;
import helpers;
import ecs;
import collision;

const ANIMATION_FPS = 40;
const MAX_FPS = 60;
NanoDuration min_frame_time = 100_000_00_00 / MAX_FPS;

alias Vec2f @private = float[<2>];
alias Vec3f @private = float[<3>];
alias Vec4f @private = float[<4>];

struct MoveEvent {
    EventKey key;
    Vec3f move;
}

struct PushConstantData {
    uint draw_index;
    bool collides;
}

struct Material @tag("BUFFER", 3) {
    float emissiveStrength;
    float metallicFactor;
    float roughnessFactor;
    Vec4f emissiveFactor;
    Vec4f baseColorFactor;

    int normalTexture;
    int occlusionTexture;
    int emissiveTexture;
    int baseColorTexture;
    int metallicRoughnessTexture;
}

struct Render @tag("BUFFER", 1) {
    uint indexCount;
    uint instanceCount;
    uint firstIndex;
    int vertexOffset;
    uint firstInstance;
    uint instance_offset;
    int skin_offset;
    int material;
    uint node_index;
}

typedef Collider @tag("BUFFER", 1) = Render;

struct SceneData @tag("BUFFER", 2) {
    vk::DeviceAddress vertices;
    vk::DeviceAddress draw_cmds;
    vk::DeviceAddress materials;
    vk::DeviceAddress nodes;
    vk::DeviceAddress animations;
    vk::DeviceAddress instances;
}

struct CollisionData @tag("BUFFER", 0) {
    Vec3f velocity;
    Vec3f force;
    Vec3f mass;
    Aabb3 aabb;
    uint node_index;
    bool collides;
    bool is_player;
    ConvexShape collider;
}

struct AnimationData {
    int skin_index;
    uint animation_index;
    usz buffer_offset;
    uint joints_len;
    uint frames;
    double max_time;
    double min_time;
    Component data;
}

macro bool AnimationData.equals(self, AnimationData b) @operator(==) => self.animation_index == b.animation_index;

struct Animation {
   uint animation_index;
   double active_time;
   bool repeat;
}

typedef SkinAnimation = Animation;
typedef WorldAnimation = Animation;
typedef SceneLight @tag("BUFFER", 2) = Light;

// Used to send buffer device addresses to GPU
DescriptorImages descriptor_images;

Vec2f window_size = {1280, 620};

char[*] shader = $embed("./shaders/shader.spv");

DeviceContext context;

Entity player;
Gltf gltf;

List{AnimationData} animation_list;
NodeComponent nodes;
MeshContainer meshes;

SpatialHash3D spatial_map;
BVHNode terrain_map;


fn void stageToGPU(ecs::Allocator target_buffer, void* data, usz size, usz offset) {
    vk::Device device = context.device;
    Memory stage_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_TRANSFER_SRC_BIT,
        &context.local_allocation,
        data,
        data_size: size
    )!!;

    device.@single_time_command(queue: context.graphics_queue; CommandBuffer command_buffer) {
        vk::cmdCopyBuffer(command_buffer, stage_buffer.buffer, (vk::Buffer)target_buffer.get_buffer(), 1, &&(BufferCopy){
            .srcOffset = 0,
            .dstOffset = offset,
            .size = size
        });
    }!!;

    stage_buffer.free();
}

const float SPEED = 0.05;

const MoveEvent[] MOVE_EVENTS = {
    {W, {0, 0, -SPEED}},
    {S, {0, 0, SPEED}},
    {A, {-SPEED, 0, 0}},
    {D, {SPEED, 0, 0}},
    {UP_ARROW, {0, SPEED, 0}},
    {DOWN_ARROW, {0, -SPEED, 0}},
};

const float GRAVITY = -9.8;

fn void physics_system(EntityManager manager, EventMap key_map, double time) {    
    // Handle gravity
    manager.@query("CollisionData"; Entity entity) {
        CollisionData collider = ecs::@get(manager, entity, CollisionData);
        ecs::Node* node = nodes[collider.node_index];

        if (collider.collider != null) {
            Aabb3 old_aabb = collider.aabb.transform(nodes.global_matrix(collider.node_index));
            Vec3f old_translation = node.translation;

            if (collider.is_player) {
                foreach (event: MOVE_EVENTS) {
                    if (key_map.is_pressed(event.key)) {
                        node.translation += event.move;
                    };
                }
            }

            HitInfo hit;
            bool ground_collision = terrain_map.ray_intersects({node.translation, (Vec3f){0, -1, 0}.normalize()}, &hit);
            
            float offset = 0.3;

            // io::printfn("collision %s", ground_collision);
            if (hit.depth > offset || ground_collision == false) {
                node.translation.y += (float)(time * GRAVITY);
            } else if (hit.depth < offset && ground_collision) {
                node.translation.y += (offset - hit.depth) - offset / 2;

                Vec3f axis = (Vec3f){0, 1, 0}.cross(hit.normal);
                float angle = (Vec3f){0, 1, 0}.angle(hit.normal);
                node.rotation = node.rotation.rotate_by_axis_angle(axis, angle);
            }

            if (old_translation != node.translation) node.dirty = (uint)true;
            if (node.dirty) {
                Aabb3 new_aabb = collider.aabb.transform(nodes.global_matrix(collider.node_index));
                spatial_map.update(old_aabb, new_aabb, entity.id)!!;
            }
        };
    };

    nodes.recalculate();
    spatial_map.@get_pairs(;Pair pair) {
        CollisionData* first = ecs::@get_ref(manager, (Entity)pair.first, CollisionData)!!;
        CollisionData* second = ecs::@get_ref(manager, (Entity)pair.second, CollisionData)!!;
        
        // ecs::Node* first_node = nodes[first.node_index];
        // ecs::Node* second_node = nodes[second.node_index];

        // Aabb3 first_collider = first.aabb.transform(first_node.matrix);
        // Aabb3 second_collider = second.aabb.transform(second_node.matrix);

        // if (first_collider.collides(second_collider)) {
        //     TransformedConvex transformed_shape_1 = {
        //         .position = first_node.translation,
        //         .shape = first.collider, 
        //         .scale = first_node.scale, 
        //     };
            
        //     TransformedConvex transformed_shape_2 = {
        //         .position = second_node.translation,
        //         .shape = second.collider,
        //         .scale = second_node.scale, 
        //     };
            
        //     // GJK collision detection for complex meshes
        //     CollisionInfo collision_info = collision::check_collision(&transformed_shape_1, &transformed_shape_2);
        //     // collision::epa(&collision_info, &transformed_shape_1, &transformed_shape_2);

        //     if (collision_info.collided) {
        //         first.collides = true;
        //         second.collides = true;
        //     }
        // }   
    };
}

fn void skin_animation_player(EntityManager manager, Entity entity, EventMap key_map, double time) {
    Render* entity_render = ecs::@get_ref(manager, entity, Render)!!;
    SkinAnimation* animation = ecs::@get_ref(manager, entity, SkinAnimation)!!;

    AnimationData data = animation_list[animation.animation_index];
    assert(data.data.size != 0, "Please initialize animation component");

    double new_time = animation.active_time + time;
    animation.active_time = new_time < data.max_time ? new_time : 0;

    double frame_index = animation.active_time * ANIMATION_FPS;
    entity_render.skin_offset = (uint)data.buffer_offset + (uint)data.joints_len * (uint)frame_index;
}

fn void world_animation_player(EntityManager manager, Entity entity, EventMap key_map, double time) {
    WorldAnimation* animation = ecs::@get_ref(manager, entity, WorldAnimation)!!;
    gltf::Animation data = gltf.animations[animation.animation_index];

    double new_time = animation.active_time + (time);
    animation.active_time = new_time < data.max_time ? new_time : 0;
    
    gltf.@run_animation_channels(
        frame_time: animation.active_time,
        animation: data;
        uint node_index,
        AnimationProperty property,
        Vec4f value
    ) {
            ecs::Node* node = nodes[node_index];
            node.dirty = (uint)true;

            switch (property) {
                case TRANSLATION: node.translation = value.xyz;
                case ROTATION: node.rotation = (Quaternionf){.v = value };
                case SCALE: node.scale = value.xyz;
                default: {}
            }
    };

    nodes.recalculate();
}

// Bake skin animations
fn void bake_skin_animations(Component animations, uint skin_index) {
    gltf::Skin skin = gltf.skins[skin_index];

    List{uint} animation_indexes = gltf.find_skin_animations(skin_index);
    defer animation_indexes.free();

    foreach (index: animation_indexes) {
        gltf::Animation animation = gltf.animations[index];
        io::printfn("animation loaded: %s", animation.name);
        
        List{Matrix4f} skin_matrixes;
        defer skin_matrixes.free();

        uint frame_count = (uint)(ANIMATION_FPS * animation.max_time);
        AnimationData data = {
            .joints_len = (uint)skin.joints.len(),
            .buffer_offset = animations.used_size / Matrix4f.sizeof,
            .data = animations,
            .max_time = animation.max_time,
            .min_time =  animation.min_time,
            .frames = frame_count,
            .skin_index = skin_index,
        };

        for (usz i = 0; i < frame_count; i++) {
            double time = i / (double)ANIMATION_FPS;
            gltf.@run_animation_channels(
                frame_time: time,
                animation: animation;
                uint node_index,
                AnimationProperty property,
                Vec4f value
            ) {
                gltf::Node* node = gltf.nodes.get_ref(node_index);
                switch (property) {
                    case TRANSLATION: node.translation = value.xyz;
                    case ROTATION: node.rotation = (Quaternionf){.v = value };
                    case SCALE: node.scale = value.xyz;
                    default: {}
                }
            };

            gltf.@build_skin_matrixes(skin; uint j, Matrix4f matrix) {
                skin_matrixes.push(matrix);
            };
        }

        animations.@push(skin_matrixes.entries, size: skin_matrixes.byte_size());        
        animation_list.push(data);
    };
}

fn void main()
{
    c3w::Window win = c3w::new(
        params: {
            .width = (int)window_size.x,
            .height = (int)window_size.y,
            .x = 0,
            .y = 0
        },
        name: "GLTF animation"
    )!!;

    defer win.free();

    // Vulkan context
    context = helpers::createContext(win)!!;
    defer context.free();

    gltf = gltf::loadFile("assets/game.glb")!!;
    defer gltf.free();

    spatial_map = { .cell_size = 1.0 };
    defer spatial_map.free();

    // Create camera
    helpers::Camera camera;

    // Create allocator of 150MB - DEVICE_ONLY memory
    context.device_allocation = (vk::Allocation){
        .device = context.device,
        .pdevice = context.pdevice,
        .properties = vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
        .size = 256_000_000
    }.build()!!;

    // Allocation where data can be changed from CPU
    context.local_allocation = (vk::Allocation){
        .device = context.device,
        .pdevice = context.pdevice,
        .properties = vk::MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk::MEMORY_PROPERTY_HOST_CACHED_BIT,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
        .size = 50_000_000
    }.build()!!;

    Memory draw_memory = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_INDIRECT_BUFFER_BIT,
        &context.local_allocation,
        null,
        data_size: 5_000_000
    )!!;

    Memory cpu_and_gpu = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        &context.local_allocation,
        null,
        data_size: 20_000_000
    )!!;

    Memory gpu_only_memory = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT | vk::BUFFER_USAGE_INDEX_BUFFER_BIT,
        &context.device_allocation,
        null,
        data_size: 30_000_000,
    )!!;

    ecs::Buffer cpu_only;
    defer cpu_only.free();

    EntityManager manager = ecs::create_manager(
        buffers: {
            (ecs::Allocator)&cpu_only,
            (ecs::Allocator)&draw_memory,
            (ecs::Allocator)&cpu_and_gpu,
            (ecs::Allocator)&gpu_only_memory,
        },
        uploadFN: &stageToGPU,
    );

    defer manager.free();

    nodes = manager.@create_component(size: (uint)(gltf.nodes.len() * ecs::Node.sizeof), buffer_index: 2)!!;

    Component skin_animations = manager.@create_component(size: 5_000_000, buffer_index: 3)!!;
    Component vertices = manager.@create_component(size: 5_000_000, buffer_index: 3)!!;
    Component indices = manager.@create_component(size: 3_000_000, buffer_index: 3)!!;
    Component instances = manager.@create_component(size: 5_000_000, buffer_index: 3)!!;
    Component materials = manager.@create_component(size: 1_000_000, buffer_index: 3)!!;
    
    meshes = {
        .vertex_buffer = &vertices,
        .index_buffer = &indices,
    };

    defer meshes.free();

    // Load meshes from gltf
    foreach (mesh: gltf.meshes) {
        meshes.parse_gltf_mesh(gltf: gltf, mesh: mesh)!!;
    }

    foreach (index, node: gltf.nodes) {
        nodes.@push((ecs::Node) {
            .matrix = node.global_matrix(),
            .translation = node.translation,
            .rotation = node.rotation,
            .scale = node.scale,
            .dirty = (uint)false,
            .parent = node.parent != null ? (int)gltf.nodes.index_of(*node.parent)!! : -1,
        });
    }

    foreach (skin_index, skin: gltf.skins) bake_skin_animations(skin_animations, (uint)skin_index);
    foreach (index, material: gltf.materials) {
        materials.@push((Material) {
            .emissiveStrength = material.emissiveStrength,
            .metallicFactor = material.metallicFactor,
            .roughnessFactor = material.roughnessFactor,
            .emissiveFactor = material.emissiveFactor,
            .baseColorFactor = material.baseColorFactor,
            .normalTexture = material.normalTexture.source,
            .occlusionTexture = material.occlusionTexture.source,
            .emissiveTexture = material.emissiveTexture.source,
            .baseColorTexture = material.baseColorTexture.source,
            .metallicRoughnessTexture = material.metallicRoughnessTexture.source,
        });
    };

    manager.add_system({.query = {"Render", "SkinAnimation"}, .type = QUERY, .callback = &skin_animation_player});
    manager.add_system({.query = {"WorldAnimation"}, .type = QUERY, .callback = &world_animation_player});
    manager.add_system({.type = ON_FRAME, .callback = &physics_system});

    defer animation_list.free();

    List{Triangle} ground_triangles;
    List{Vec3f} mesh_positions;
    defer mesh_positions.free();

    // Build draw commands for Vulkan
    foreach (uint node_index, node : gltf.nodes) {
        if (node.has_camera()) {
            gltf::Camera camera_data = gltf.cameras[node.camera];

            Vec3f position = node.translation * node.scale;
            
            camera = {
                .target = {0, 0, 0},
                .up = {0.0, 1.0, 0.0},
                .position = position,
                .distance = 10,
                .aspect_ratio = camera_data.perspective.aspectRatio,
                .rotation = node.rotation,
                .z_near = 0.1,
                .z_far = 500,
                .y_fov = 40
            };
        }
        if (node.has_mesh() && node.name != "physicsMeshDataNode") {
            gltf::Mesh mesh = gltf.meshes[node.mesh];
            Entity node_entity = manager.@create_entity()!!;

            if (node.extras.has_key("animation")) {
                node_entity.@add((WorldAnimation) {
                    .animation_index = gltf.find_animation_index(node.extras.get("animation")!!)!!,
                    .active_time = 0,
                    .repeat = true
                }, &manager)!!;
            }
                
            if (node.extras.has_key("skin_clone")) {
                node_entity.@add((SkinAnimation) {
                    .animation_index = gltf.find_animation_index(node.extras.get("skin_clone")!!)!!,
                    .active_time = node_index * 0.05,
                    .repeat = true
                }, &manager)!!;
            }

            if (node.extras.has_key("skin_animation")) {
                node_entity.@add((SkinAnimation) {
                    .animation_index = gltf.find_animation_index(node.extras.get("skin_animation")!!)!!,
                    .active_time = 0.0,
                    .repeat = true
                }, &manager)!!;
            }

            meshes.@iter(mesh.name; uint mesh_index, MeshData* mesh_data) {
                Render render_data = {
                    .indexCount = mesh_data.indexCount,
                    .firstIndex = mesh_data.firstIndex,
                    .vertexOffset = mesh_data.vertexOffset,
                    .instanceCount = 1,
                    .firstInstance = 0,
                    .instance_offset = (uint)instances.used_size,
                    .skin_offset = -1,
                    .material = mesh_data.materialIndex,
                    .node_index = node_index,
                };

                if (node.attributes.len() > 0) {
                    Accessor translation_accessor = gltf.accessors[node.attributes["TRANSLATION"]!!];
                    Accessor rotation_accessor = gltf.accessors[node.attributes["ROTATION"]!!];
                    Accessor scale_accessor = gltf.accessors[node.attributes["SCALE"]!!];
                    render_data.instanceCount = translation_accessor.count;
                    render_data.firstInstance = 1;

                    for (uint i = 0; i < translation_accessor.count; i++) {
                        Matrix4f instance_matrix = gltf::to_matrix(
                            gltf.@cast_buffer(translation_accessor, i, Vec3f), 
                            gltf.@cast_buffer(scale_accessor, i, Vec3f), 
                            gltf.@cast_buffer(rotation_accessor, i, Quaternionf)
                        );
                        instances.@push(instance_matrix);
                    }
                }

                if (node.collider != null || node.motion != null) {
                    CollisionData collision_data = {
                        .collides = false,
                        .node_index = node_index,
                        .aabb = mesh_data.aabb,
                        .is_player = node.name == "player"
                    };

                    // Node is active compound shape, make collider from child meshes
                    if (node.motion != null && node.collider == null) {
                        usz vertex_offset = mesh_positions.len();
                        gltf.@get_compound_shape(node_index; Vec3f position) { mesh_positions.push(position); }!!;
                        usz vertex_len = mesh_positions.len() - vertex_offset;
                        collision_data.collider = &&(ConvexPolyhedron){mesh_positions.entries[vertex_offset..vertex_offset + vertex_len]};
                        spatial_map.insert(mesh_data.aabb.transform(node.global_matrix()), node_entity.id)!!;
                    }

                    if (node.collider != null && node.collider.has_shape()) {
                        Shape shape = gltf.shapes[node.collider.shape];

                        switch (shape.type) {
                            case BOX: collision_data.collider = &&mesh_data.aabb;
                            case SPHERE: collision_data.collider = &&(Sphere){node.translation, shape.radius};
                            case CYLINDER: collision_data.collider = &&(Cylinder){shape.height, shape.radius_top, shape.radius_bottom};
                            case CAPSULE: collision_data.collider = &&(Capsule){shape.height, shape.radius_top, shape.radius_bottom};
                        }
                    }

                    // Motion is null, collider is static
                    if (node.motion == null && node.collider != null && !node.collider.has_shape()) {
                        Matrix4f global_matrix = node.global_matrix();
                        gltf.@get_positions(gltf.find_mesh(mesh.name), Vec3f[3]; Vec3f[3] triangle) {
                            foreach (i, value: triangle) {
                                Vec4f item = global_matrix * (Vec4f){value.x, value.y, value.z, 1.0};
                                triangle[i] = item.xyz;
                            }
                            Triangle triangle_global = {
                                triangle[0],
                                triangle[1],
                                triangle[2]
                            };

                            ground_triangles.push(triangle_global);
                        }!!;
                    }

                    node_entity.@add(collision_data, &manager)!!;
                }

                node_entity.@add(render_data, &manager)!!;
            }!!;
        };
    }

    

    terrain_map.build_recursive(ground_triangles.array_view());
    ground_triangles.free();

    foreach (image : gltf.images) {
        stb::Image image_data;

        switch (image.type) {
            case ENCODED_BASE64: {
                image_data = stb::loadFromBuffer(image.data, image.data.len, stb::Channel.STBI_RGB_ALPHA)!!;
            };
            case ENCODED_BIN: {
                gltf::BufferView buffer_view = gltf.bufferViews[image.view];
                image_data = stb::loadFromBuffer(gltf.buffers[buffer_view.buffer].data[buffer_view.offset..], (uint)buffer_view.byteLength, stb::Channel.STBI_RGB_ALPHA)!!;
            };
            case EXTERNAL_BIN: image_data = stb::loadImage(image.uri, stb::Channel.STBI_RGB_ALPHA)!!;
            default: {}
        }

        io::printfn("image size %s MB", (usz)(image_data.width * image_data.height * 4) / 1_000_000);
        // Create vulkan texture image
        if (catch err = descriptor_images.addImageTexture(image_data, &context)) {
            io::printfn("GPU allocator is too small for textures %s", err);
            return;
        };

        image_data.free();
    }

    descriptor_images.addDepthTexture(&context.device_allocation, context.graphics_queue, {win.width, win.height}, context.depth_format)!!;

    defer {
        foreach (texture: descriptor_images) texture.free(context.device);
        descriptor_images.free();
    }

    Entity scene = manager.@create_entity(
        camera.data(),
        (SceneLight) {
            .position = {2, 12.0, 5},
            .color = {1, 1, 1},
            .intensity = 54351,
            .type = DIRECTIONAL
        },
        (SceneData) {
            .draw_cmds = draw_memory.address,
            .vertices = ecs::@get_address(manager, vertices),
            .materials = ecs::@get_address(manager, materials),
            .animations = ecs::@get_address(manager, skin_animations),
            .instances = ecs::@get_address(manager, instances),
            .nodes = ecs::@get_address(manager, nodes)
        },
    )!!;

    PipelineLayer pipeline_layout = helpers::createPipelineLayout(
        {
            vk::writeDescriptorSet()
            .setDescriptorType(vk::DESCRIPTOR_TYPE_UNIFORM_BUFFER)
            .setDstBinding(0)
            .setBufferInfo({
                {
                    .buffer = cpu_and_gpu.buffer,
                    .offset = ecs::@get_offset(manager, scene, "CameraData")!!,
                    .range = ecs::get_size(scene, manager),
                },
            }),
            vk::writeDescriptorSet()
            .setDstBinding(1)
            .setDescriptorType(vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
            .setImageInfo(descriptor_images.array_view())
        },
        (ShaderStageFlags[]){
            vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT,
            vk::SHADER_STAGE_FRAGMENT_BIT,
        },
        (PushConstantRange[]){
            {
                .offset = 0,
                .size = PushConstantData.sizeof,
                .stageFlags = vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT,
            },
        },
        context.device
    )!!;

    defer pipeline_layout.free(context.device);

    ShaderModule shader_module = vk::shaderModuleCreateInfo()
    .setCodeSize(shader.len)
    .setCode((uint*)&shader[0])
    .build(context.device)!!;

    defer shader_module.free(context.device);

    PipelineRenderingCreateInfo p_rendering_info = vk::pipelineRenderingCreateInfo()
    .setColorAttachmentFormats({context.surface_format.format})
    .setDepthAttachmentFormat(context.depth_format);

    PipelineMultisampleStateCreateInfo multi_sample_state = vk::pipelineMultisampleStateCreateInfo()
    .setSampleShadingEnable(vk::FALSE)
    .setRasterizationSamples(vk::SAMPLE_COUNT_1_BIT)
    .setMinSampleShading(1.0)
    .setAlphaToCoverageEnable(vk::FALSE)
    .setAlphaToOneEnable(vk::FALSE);

    PipelineColorBlendStateCreateInfo color_blend_state = vk::pipelineColorBlendStateCreateInfo()
    .setBlendConstants({ 1.0, 1.0, 1.0, 1.0 })
    .setLogicOp(vk::LOGIC_OP_COPY)
    .setLogicOpEnable(vk::FALSE)
    .setAttachments({
    {
        .colorWriteMask =
            vk::COLOR_COMPONENT_R_BIT |
            vk::COLOR_COMPONENT_G_BIT |
            vk::COLOR_COMPONENT_B_BIT |
            vk::COLOR_COMPONENT_A_BIT,  
        .blendEnable = vk::TRUE,
        .srcAlphaBlendFactor = vk::BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk::BLEND_FACTOR_ZERO,
        .srcColorBlendFactor = vk::BLEND_FACTOR_SRC_ALPHA,
        .dstColorBlendFactor = vk::BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = vk::BLEND_OP_ADD,
        .alphaBlendOp = vk::BLEND_OP_ADD,
    }});

    PipelineRasterizationStateCreateInfo rasterisation_state = vk::pipelineRasterizationStateCreateInfo()
    .setDepthClampEnable(vk::FALSE)
    .setRasterizerDiscardEnable(vk::FALSE)
    .setPolygonMode(vk::POLYGON_MODE_FILL)
    .setLineWidth(1.0)
    .setCullMode(vk::CULL_MODE_NONE)
    .setFrontFace(vk::FRONT_FACE_COUNTER_CLOCKWISE)
    .setDepthBiasEnable(vk::FALSE);

    PipelineViewportStateCreateInfo view_port_state = vk::pipelineViewportStateCreateInfo()
    .setViewports({{}})
    .setScissors({{}});

    PipelineDynamicStateCreateInfo dynamic_state = vk::pipelineDynamicStateCreateInfo()
    .setDynamicStates(
    {
        vk::DYNAMIC_STATE_VIEWPORT,
        vk::DYNAMIC_STATE_LINE_WIDTH,
        vk::DYNAMIC_STATE_SCISSOR,
        vk::DYNAMIC_STATE_PRIMITIVE_TOPOLOGY
    });

    PipelineDepthStencilStateCreateInfo stencil_state = vk::pipelineDepthStencilStateCreateInfo()
    .setDepthTestEnable(vk::TRUE)
    .setDepthWriteEnable(vk::TRUE)
    .setDepthCompareOp(vk::COMPARE_OP_LESS_OR_EQUAL)
    .setBack({.compareOp = vk::COMPARE_OP_ALWAYS});

    Pipeline pipeline = vk::graphicsPipelineCreateInfo()
    .setStages({
        vk::pipelineShaderStageCreateInfo()
        .setStage(vk::SHADER_STAGE_VERTEX_BIT)
        .setMod(shader_module)
        .setName("vertexMain"),
        vk::pipelineShaderStageCreateInfo()
        .setStage(vk::SHADER_STAGE_FRAGMENT_BIT)
        .setMod(shader_module)
        .setName("fragmentMain")
    })
    .setLayout(pipeline_layout.layout)
    .setInputAssemblyState(&&vk::pipelineInputAssemblyStateCreateInfo().setTopology(vk::PRIMITIVE_TOPOLOGY_TRIANGLE_LIST))
    .setVertexInputState(&&vk::pipelineVertexInputStateCreateInfo().setVertexAttributeDescriptionCount(0))
    .setDynamicState(&dynamic_state)
    .setRasterizationState(&rasterisation_state)
    .setMultisampleState(&multi_sample_state)
    .setColorBlendState(&color_blend_state)
    .setDepthStencilState(&stencil_state)
    .setViewportState(&view_port_state)
    .setNext(&p_rendering_info)
    .build(context.device)!!;

    defer pipeline.free(context.device);

    RenderingInfo rendering_info = vk::renderingInfo()
    .setLayerCount(1)
    .setRenderArea({
        .offset = { .x = 0, .y = 0 },
        .extent = context.extent,
    });

    bool running = true;
    Vec2f prev_mouse = {window_size.x / 2, window_size.y / 2};
    
    Clock animation_time = clock::now();
    Clock render_time = clock::now();

    double time = 0;
    while (running) {
        NanoDuration start_time = render_time.mark();

        EventMap event = win.getEvent();
       
        if (event.is_pressed(LEFT_MOUSE)) {
            Vec2f mouse_pos = win.getMousePos();
            camera.rotate(mouse_pos.x - prev_mouse.x, mouse_pos.y - prev_mouse.y);
            ecs::@upload(manager, scene, &&camera.data());
            prev_mouse = mouse_pos;
        }

        if (event.is_pressed(MOUSE_SCROLL_DOWN)) {
            camera.zoom(-2);
            ecs::@upload(manager, scene, &&camera.data());
        }

        if (event.is_pressed(MOUSE_SCROLL_UP)) {
            camera.zoom(2);
            ecs::@upload(manager, scene, &&camera.data());
        }

        if (event.is_pressed(ESCAPE)) {
            running = false;
        }

        manager.run_systems(event, animation_time.mark().to_sec());

        uint next_image = context.next_image()!!;
    
        ImageMemoryBarrier2 begin_barrier = {
            .sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .image = context.swapchain_images[next_image],
            .srcStageMask = vk::PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = vk::PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = vk::ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = vk::IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .subresourceRange = {
                .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            }
        };

        ImageMemoryBarrier2 end_barrier = {
            .sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .image = context.swapchain_images[next_image],
            .srcStageMask = vk::PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = vk::PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
            .srcAccessMask = vk::ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = 0,
            .oldLayout = vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .newLayout = vk::IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .subresourceRange = {
                .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            }
        };

       RenderingAttachmentInfo main_render_target = vk::renderingAttachmentInfo()
        .setImageView(context.swapchain_views[next_image])
        .setImageLayout(vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        .setStoreOp(vk::ATTACHMENT_STORE_OP_STORE)
        .setLoadOp(vk::ATTACHMENT_LOAD_OP_CLEAR)
        .setClearValue({
            .color = { .float32 = { 0.0, 0.0, 0.0, 1.0 }}
        });

        RenderingAttachmentInfo main_depth_target = vk::renderingAttachmentInfo()
        .setImageView(descriptor_images.last()!!.imageView)
        .setImageLayout(vk::IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
        .setStoreOp(vk::ATTACHMENT_STORE_OP_STORE)
        .setLoadOp(vk::ATTACHMENT_LOAD_OP_CLEAR)
        .setClearValue({ .depthStencil = { 1.0, 0 } });

        CommandBuffer command_buffer = context.command_buffers[next_image];
        vk::resetCommandBuffer(command_buffer, 0)!!;
        vk::beginCommandBuffer(command_buffer, &&vk::commandBufferBeginInfo())!!;
 
        vk::cmdSetLineWidth(command_buffer, 1.0);
        vk::cmdSetViewport(command_buffer, 0, 1, (Viewport[]){{.width = window_size.x, .height = -window_size.y, .minDepth = 0.0, .maxDepth = 1.0, .y = window_size.y}});
        vk::cmdSetScissor(command_buffer, 0, 1, (Rect2D[]){{.extent = context.extent, .offset = { .x = 0, .y = 0 }}});

        // Begin dynamic rendering
        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo().setImageMemoryBarriers({ begin_barrier }));
        vk::cmdPushDescriptorSetKHR(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline_layout.layout, 0, (uint)pipeline_layout.sets.len(), pipeline_layout.sets.entries);

        vk::cmdBindPipeline(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline);

        vk::cmdBindIndexBuffer(command_buffer, gpu_only_memory.buffer, indices.offset, vk::INDEX_TYPE_UINT16);
 
        rendering_info.setColorAttachments({ main_render_target });
        rendering_info.setDepthAttachment(&main_depth_target);

        vk::cmdBeginRendering(command_buffer, &rendering_info);

        manager.@query("Render"; Entity entity) {
            uint offset = ecs::@get_offset(manager, entity, "Render")!!;
            CollisionData*? state = ecs::@get_ref(manager, entity, CollisionData);
            PushConstantData constant_data = {
                .draw_index = offset / Render.sizeof,
            };

            if (try state) {
                constant_data.collides = state.collides;
                state.collides = false;
            }

            vk::cmdSetPrimitiveTopology(command_buffer, vk::PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
            vk::cmdPushConstants(command_buffer, pipeline_layout.layout, vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT, 0, PushConstantData.sizeof, &constant_data);
            vk::cmdDrawIndexedIndirect(command_buffer, draw_memory.buffer, offset, 1, Render.sizeof);
        };

        vk::cmdEndRendering(command_buffer);
        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo().setImageMemoryBarriers({ end_barrier }));
        vk::endCommandBuffer(command_buffer)!!;
         
        context.present_image(next_image, command_buffer)!!;

        NanoDuration time_delta = (start_time - render_time.mark());
        if (time_delta <= min_frame_time) {
            std::thread::sleep_ns(min_frame_time - time_delta)!!;
            time_delta = (start_time - render_time.mark());
        }
    }
    
    context.device.waitIdle();
}