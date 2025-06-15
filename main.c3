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


const ANIMATION_FPS = 50;
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

struct State {
    uint index;
    bool collides;
    bool check_collision;
}

struct Render @tag("BUFFER", 1) {
    uint indexCount;
    uint instanceCount;
    uint firstIndex;
    int vertexOffset;
    uint firstInstance;
    uint instance_offset;
    int animation_offset;
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
    uint material_count;
}

struct AnimationData {
    int skin_index;
    usz buffer_offset;
    uint joints_len;
    uint frames;
    double max_time;
    double min_time;
    Component data;
}

struct Animation {
   uint animation_index;
   double active_time;
   bool repeat;
}

typedef SkinAnimation = Animation;
typedef SceneLight @tag("BUFFER", 2) = Light;

// Used to send buffer device addresses to GPU
DescriptorImages descriptor_images;

Vec2f window_size = {1280, 620};
char[*] shader = $embed("./shaders/shader.spv");

DeviceContext context;

Entity player;
Gltf gltf;
HashMap{String, List{MeshData}} mesh_list;
List{AnimationData} animation_list;

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

fn void physics_system(EntityManager manager, Entity entity, EventMap key_map, double time) {
    State state = ecs::@get(manager, entity, State);

    Aabb3 entity_collider = ecs::@get(manager, entity, Aabb3);
    Render entity_render = ecs::@get(manager, entity, Render);

    Aabb3 player_collider = ecs::@get(manager, player, Aabb3);
    Render player_render = ecs::@get(manager, player, Render);
    Collider collider_render = ecs::@get(manager, player, Collider);

    bool is_dirty = false;
    // foreach (item: MOVE_EVENTS) {
    //     if (key_map.is_pressed(item.key)) {
    //         player_render.node_matrix = player_render.node_matrix.translate(item.move);
    //         collider_render.node_matrix = player_render.node_matrix;
    //         is_dirty = true;
    //     }
    // }

    // if (is_dirty && state.check_collision) {
    //     if (player_collider.transform(player_render.node_matrix).collides(entity_collider)) {
    //         state.collides = true;
    //     } else {
    //         state.collides = false;
    //     }

    //     ecs::@upload(manager, entity, state);
    //     ecs::@upload(manager, player, player_render);
    //     ecs::@upload(manager, player, collider_render);
    // }
}

fn void skin_animation_player(EntityManager manager, Entity entity, EventMap key_map, double time) {
    Render entity_render = ecs::@get(manager, entity, Render);
    SkinAnimation animation = ecs::@get(manager, entity, SkinAnimation);

    AnimationData data = animation_list[animation.animation_index];
    assert(data.data.size != 0, "Please initialize animation component");

    double new_time = animation.active_time + time;
    animation.active_time = new_time < data.max_time ? new_time : 0;

    double frame_index = animation.active_time * ANIMATION_FPS;
    entity_render.animation_offset = (uint)data.buffer_offset + (uint)data.joints_len * (uint)frame_index;

    ecs::@upload(manager, entity, entity_render);
    ecs::@upload(manager, entity, animation);
}

fn void world_animation_player(EntityManager manager, Entity entity, EventMap key_map, double time) {
    // Render entity_render = ecs::@get(manager, entity, Render);
    // MeshAnimation animation = ecs::@get(manager, entity, MeshAnimation);

    // AnimationData data = animation_list[animation.animation_index];
    // assert(data.data.size != 0, "Please initialize animation component");

    // double new_time = animation.active_time + time;
    // animation.active_time = new_time < data.max_time ? new_time : 0.1;

    // usz skin_len = gltf.skins[data.skin_index].joints.len();

    // double frame_index = (animation.active_time / data.max_time) * ANIMATION_FPS * data.max_time;
    // entity_render.animation_offset = (uint)data.buffer_offset + (uint)skin_len * (uint)frame_index;

    // ecs::@upload(manager, entity, entity_render);
    // ecs::@upload(manager, entity, animation);
}

// Bake skin animations
fn void bake_skin_animations(Component skin_animations) {
    foreach (uint skin_index, skin: gltf.skins) {
        List{uint} animation_indexes = gltf.find_skin_animations(skin_index);
        defer animation_indexes.free();

        foreach (index: animation_indexes) {
            gltf::Animation animation = gltf.animations[index];
            List{Matrix4f} skin_matrixes;
            
            uint frame_count = (uint)(ANIMATION_FPS * animation.max_time);
            AnimationData data = {
                .joints_len = (uint)skin.joints.len(),
                .buffer_offset = skin_animations.used_size / Matrix4f.sizeof,
                .data = skin_animations,
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

                gltf.@build_skin_matrixes(gltf.skins[skin_index]; uint joint, Matrix4f matrix) {
                    skin_matrixes.push(matrix);
                };
            }
            
            skin_animations.@push(skin_matrixes.entries, size: skin_matrixes.byte_size());
            animation_list.push(data);
            skin_matrixes.free();
        };
    }
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

    // Create camera
    helpers::Camera camera = helpers::new_camera(eye: {0.0, 5.0, 10}, aspect: window_size.x/window_size.y, min_zoom: 0.01, max_zoom: 1000);

    gltf = gltf::loadFile("assets/animation_2.glb")!!;
    defer gltf.free();

    // Create allocator of 150MB - DEVICE_ONLY memory
    context.device_allocation = (vk::Allocation){
        .device = context.device,
        .pdevice = context.pdevice,
        .properties = vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
        .size = 150_000_000
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
        data_size: 25_000_000
    )!!;

    Memory gpu_only_memory = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT | vk::BUFFER_USAGE_INDEX_BUFFER_BIT,
        &context.device_allocation,
        null,
        data_size: 40_000_000,
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

    NodeComponent nodes = manager.@create_component(size: (uint)(gltf.nodes.len() * NodeMatrix.sizeof), buffer_index: 2)!!;
    Component skin_animations = manager.@create_component(size: 5_000_000, buffer_index: 3)!!;
    Component vertices = manager.@create_component(size: 2_000_000, buffer_index: 3)!!;
    Component indices = manager.@create_component(size: 2_000_000, buffer_index: 3)!!;
    Component instances = manager.@create_component(size: 5_000_000, buffer_index: 3)!!;
    Component materials = manager.@create_component(size: 1_000_000, buffer_index: 3)!!;

    foreach (node: gltf.nodes) {
        nodes.@push((NodeMatrix) {
            .matrix = node.global_matrix(),
            .parent = node.parent != null ? (int)gltf.nodes.index_of(*node.parent)!! : -1,
        });
    }

    bake_skin_animations(skin_animations);
  
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
            .nodes = ecs::@get_address(manager, nodes),
            .material_count = (uint)materials.used_size / Material.sizeof
        },
    )!!;

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

    manager.add_system({
        .query = {"Render", "Aabb3", "State", "Collider"}, 
        .callback = &physics_system
    });

    manager.add_system({
        .query = {"Render", "SkinAnimation"}, 
        .callback = &skin_animation_player
    });

    // manager.add_system({
    //     .query = {"WorldAnimation"}, 
    //     .callback = &world_animation_player
    // });

    // io::printfn("animations size %f mb", animations.used_size * 0.00_0001);

    defer {
        mesh_list.@each_entry(;entry) { entry.value.free(); };
        mesh_list.free();
        animation_list.free();
    };

    // mesh_list.set("collider", ecs::load_mesh(
    //         manager: manager,
    //         vertices: &vertices,
    //         indices: &indices,
    //         mesh: ecs::create_bounding_box({.min = {-1.0, -1.0, -1.0}, .max = {1, 1, 1}})
    //     )!!
    // );

    // Load meshes from gltf
    foreach (mesh: gltf.meshes) {
         List{MeshData} meshes = ecs::parse_gltf_mesh(
            gltf: gltf,
            vertices: &vertices,
            indices: &indices,
            mesh: mesh
        )!!;
        mesh_list.set(mesh.name, meshes);
    }

    io::printfn("%s", nodes.manager.buffers.len());
    // Build draw commands for Vulkan
    foreach (uint node_index, node : gltf.nodes) {
        if (node.has_mesh()) {
            gltf::Mesh mesh = gltf.meshes[node.mesh];
            List{MeshData} meshes = mesh_list[mesh.name]!!;
         
            foreach (mesh_data: meshes) {
                Entity node_entity = manager.@create_entity()!!;
                // if (node.name == "Player") player = node_entity;
                Render render_data = {
                    .indexCount = mesh_data.indexCount,
                    .firstIndex = mesh_data.firstIndex,
                    .vertexOffset = mesh_data.vertexOffset,
                    .instanceCount = 1,
                    .firstInstance = 0,
                    .instance_offset = (uint)instances.used_size,
                    .animation_offset = -1,
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
                
                if (node.has_skin()) {
                    node_entity.@add((SkinAnimation) {
                        .animation_index = node.name == "Fox" ? 4 : 0,
                        .active_time = 0.0,
                        .repeat = true
                    }, &manager)!!;
                }

                // if (node.extras.has_key("animation")) {
                //     String animation_name = node.extras["animation"]!!;
                //     uint animation_index = gltf.find_animation_index(animation_name)!!;

               
                //     io::printfn("%s %s", animation_name, animation_index);
                //     // if (node.has_skin()) {
                        
                //     // } else {

                //     // }
                    
                // };

                node_entity.@add((State) {
                    .collides = false,
                    .index = node_index,
                    .check_collision = node.name != "Player" ? true : false
                }, &manager)!!;

                node_entity.@add(render_data, &manager)!!;
            }

            // Add physics box           
            // if (!mesh_data.aabb.is_empty()) {
            //     Aabb3 mesh_aabb = mesh_data.aabb;

            //     MeshData collider_mesh = mesh_list["collider"]!!;
            
            //     Collider collider = {
            //         .indexCount = collider_mesh.indexCount,
            //         .firstIndex = collider_mesh.firstIndex,
            //         .vertexOffset = collider_mesh.vertexOffset,
            //         .instanceCount = 1,
            //         .node_matrix = rmatrix,
            //         .animation_offset = -1
            //     };

            //     node_entity.@add(collider, &manager)!!;

            //     if (node.name != "Player") {
            //         node_entity.@add(mesh_aabb.transform(matrix), &manager)!!;
            //     } else {
            //         node_entity.@add(mesh_aabb, &manager)!!;
            //     }
            // }
        }
    }

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

        // Create vulkan texture image
        if (catch err = descriptor_images.addImageTexture(image_data, &context)) {
            io::printfn("GPU allocator is too small for textures");
            return;
        };

        image_data.free();
    }

    descriptor_images.addDepthTexture(&context.device_allocation, context.graphics_queue, {win.width, win.height}, context.depth_format)!!;

    defer {
        foreach (texture: descriptor_images) texture.free(context.device);
        descriptor_images.free();
    }

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
    // .setInputAssemblyState(&&vk::pipelineInputAssemblyStateCreateInfo().setTopology(vk::PRIMITIVE_TOPOLOGY_TRIANGLE_LIST))
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
    Vec2f prev_mouse;
    
    Clock animation_time = clock::now();
    Clock render_time = clock::now();

    double time = 0;
    while (running) {
        NanoDuration start_time = render_time.mark();

        EventMap event = win.getEvent();
       
        if (event.is_pressed(LEFT_MOUSE)) {
            Vec2f mouse_pos = win.getMousePos();
            camera.rotate(mouse_pos.x - prev_mouse.x, (mouse_pos.y - prev_mouse.y));
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

        manager.@query("Render", "State"; Entity entity) {
            uint offset = ecs::@get_offset(manager, entity, "Render")!!;
            State state = ecs::@get(manager, entity, State);
            PushConstantData constant_data = {
                .draw_index = offset / Render.sizeof,
                .collides = state.collides
            };

            vk::cmdSetPrimitiveTopology(command_buffer, vk::PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
            vk::cmdPushConstants(command_buffer, pipeline_layout.layout, vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT, 0, PushConstantData.sizeof, &constant_data);
            vk::cmdDrawIndexedIndirect(command_buffer, draw_memory.buffer, offset, 1, Render.sizeof);
        };

        // manager.@query("Collider"; Entity entity) {
        //     uint offset = ecs::@get_offset(manager, entity, "Collider")!!;
      
        //     PushConstantData constant_data = {
        //         .draw_index = offset / Collider.sizeof,
        //     };

        //     vk::cmdSetPrimitiveTopology(command_buffer, vk::PRIMITIVE_TOPOLOGY_LINE_LIST);
        //     vk::cmdPushConstants(command_buffer, pipeline_layout.layout, vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT, 0, PushConstantData.sizeof, &constant_data);
        //     vk::cmdDrawIndexedIndirect(command_buffer, draw_memory.buffer, offset, 1, Collider.sizeof);
        // };

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