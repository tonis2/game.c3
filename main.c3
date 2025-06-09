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

const MAX_FPS = 90;
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
   vk::DeviceAddress animation;
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
    vk::DeviceAddress animation;
    vk::DeviceAddress material;
    vk::DeviceAddress instances;
    Matrix4f node_matrix;
}

typedef Collider @tag("BUFFER", 1) = Render;

struct SceneData @tag("BUFFER", 2) {
    vk::DeviceAddress vertices;
    vk::DeviceAddress draw_cmds;
}

struct AnimationInfo {
   uint animation;
   uint skin;
   float max_time;
   uint active_time;
   bool repeat;
}

typedef SceneLight @tag("BUFFER", 2) = Light;

// Used to send buffer device addresses to GPU
DescriptorImages descriptor_images;

Vec2f window_size = {1280, 620};
char[*] shader = $embed("./shaders/shader.spv");

DeviceContext context;

Entity player;

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
    foreach (item: MOVE_EVENTS) {
        if (key_map.is_pressed(item.key)) {
            player_render.node_matrix = player_render.node_matrix.translate(item.move);
            collider_render.node_matrix = player_render.node_matrix;
            is_dirty = true;
        }
    }

    if (is_dirty && state.check_collision) {
        if (player_collider.transform(player_render.node_matrix).collides(entity_collider)) {
            state.collides = true;
        } else {
            state.collides = false;
        }

        ecs::@upload(manager, entity, state);
        ecs::@upload(manager, player, player_render);
        ecs::@upload(manager, player, collider_render);
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

    Gltf gltf = gltf::loadFile("assets/game.glb")!!;

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
        data_size: 15_000_000
    )!!;

    Memory gpu_only_memory = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT | vk::BUFFER_USAGE_INDEX_BUFFER_BIT,
        &context.device_allocation,
        null,
        data_size: 35_000_000,
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

    Component animations = manager.@create_component(size: 1_000_000, buffer_index: 2)!!;
    Component vertices = manager.@create_component(size: 5_000_000, buffer_index: 3)!!;
    Component indices = manager.@create_component(size: 5_000_000, buffer_index: 3)!!;
    Component instances = manager.@create_component(size: 5_000_000, buffer_index: 3)!!;

    List{Component} materials;
    HashMap{String, MeshData} mesh_list;

    foreach (material: gltf.materials) {
        materials.push(manager.@create_component(
            (Material) {
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
            }
        )!!);
    };

    manager.add_system({
        .query = {"Render", "Aabb3", "State", "Collider"}, 
        .callback = &physics_system
    });

    defer {
        materials.free();
        mesh_list.free();
    };

    mesh_list.set("collider", ecs::load_mesh(
        manager: manager,
        vertices: &vertices,
        indices: &indices,
        mesh: ecs::create_bounding_box({.min = {-1.0, -1.0, -1.0}, .max = {1, 1, 1}})
    )!!);

    foreach (uint index, node : gltf.nodes) {
        if (node.has_mesh()) {
            gltf::Mesh mesh = gltf.meshes[node.mesh];
    
            Matrix4f matrix = node.global_matrix();
            Entity node_entity = manager.@create_entity()!!;
            if (node.name == "Player") player = node_entity;

            if (!mesh_list.has_key(mesh.name)) {
                // Load mesh data from GLTF and save it as assets
                ecs::@parse_gltf_mesh(
                    gltf: gltf,
                    manager: manager,
                    vertices: &vertices,
                    indices: &indices,
                    mesh: mesh;
                    MeshData mesh_data
                ) { mesh_list.set(mesh.name, mesh_data); }!!;
            }

            MeshData mesh_data = mesh_list[mesh.name]!!;

            Render render_data = {
                .indexCount = mesh_data.indexCount,
                .firstIndex = mesh_data.firstIndex,
                .vertexOffset = mesh_data.vertexOffset,
                .material = mesh_data.has_material() ? ecs::@get_address(manager, materials[mesh_data.materialIndex]) : 0,
                .instances = ecs::@get_address(manager, instances) + instances.used_size,
                .node_matrix = matrix,
                .instanceCount = 1,
                .firstInstance = 0,
                .animation = node.has_skin() ? ecs::@get_address(manager, animations) : 0
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

                    ecs::@upload(manager, instances, &instance_matrix, size: Matrix4f.sizeof, offset: instances.used_size);
                    instances.used_size += Matrix4f.sizeof;
                }
            }


            if (node.has_skin()) {
                gltf::Animation animation = gltf.find_animation("zombie_walk")!!;

                AnimationInfo animation_info = {
                    .skin = node.skin,
                    .animation = (uint)gltf.animations.index_of(animation)!!,
                    .max_time = animation.max_time,
                    .active_time = 0,
                    .repeat = true
                };

                node_entity.@add(animation_info, &manager)!!;

                // ecs::build_joint_matrix(
                //     manager: manager,
                //     component: animations,
                //     gltf: gltf,
                //     frame_time: frame_time
                // )!!;
            }

            // if (node.extras.has_key("collider")) io::printfn("collider %s", node.extras["collider"]!!);


            // Add physics box           
            if (!mesh_data.aabb.is_empty()) {
                Aabb3 mesh_aabb = mesh_data.aabb;

                MeshData collider_mesh = mesh_list["collider"]!!;
            
                Collider collider = {
                    .indexCount = collider_mesh.indexCount,
                    .firstIndex = collider_mesh.firstIndex,
                    .vertexOffset = collider_mesh.vertexOffset,
                    .instanceCount = 1,
                    .node_matrix = render_data.node_matrix,
                };

                node_entity.@add(collider, &manager)!!;

                if (node.name != "Player") {
                    node_entity.@add(mesh_aabb.transform(render_data.node_matrix), &manager)!!;
                } else {
                    node_entity.@add(mesh_aabb, &manager)!!;
                }
             
                node_entity.@add((State) {
                    .collides = false,
                    .index = index,
                    .check_collision = node.name != "Player" ? true : false
                }, &manager)!!;
            }
      
            node_entity.@add(render_data, &manager)!!;
        }
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
            .vertices = ecs::@get_address(manager, vertices),
            .draw_cmds = draw_memory.address,
        },
    )!!;

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

    defer gltf.free();

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

    while (running) {
        NanoDuration start_time = render_time.mark();

        // if (frame_time > 5.5) animation_time = clock::now();

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
                .collides = state.collides,
            };

            vk::cmdSetPrimitiveTopology(command_buffer, vk::PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
            vk::cmdPushConstants(command_buffer, pipeline_layout.layout, vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT, 0, PushConstantData.sizeof, &constant_data);
            vk::cmdDrawIndexedIndirect(command_buffer, draw_memory.buffer, offset, 1, Render.sizeof);
        };

        manager.@query("Collider"; Entity entity) {
            uint offset = ecs::@get_offset(manager, entity, "Collider")!!;
      
            PushConstantData constant_data = {
                .draw_index = offset / Collider.sizeof,
            };

            vk::cmdSetPrimitiveTopology(command_buffer, vk::PRIMITIVE_TOPOLOGY_LINE_LIST);
            vk::cmdPushConstants(command_buffer, pipeline_layout.layout, vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT, 0, PushConstantData.sizeof, &constant_data);
            vk::cmdDrawIndexedIndirect(command_buffer, draw_memory.buffer, offset, 1, Collider.sizeof);
        };

        vk::cmdEndRendering(command_buffer);
        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo().setImageMemoryBarriers({ end_barrier }));
        vk::endCommandBuffer(command_buffer)!!;
         
        context.present_image(next_image, command_buffer)!!;

        NanoDuration time_delta = (start_time - render_time.mark());
        if (time_delta < min_frame_time) {
            std::thread::sleep_ns(min_frame_time - time_delta)!!;
            time_delta = (start_time - render_time.mark());
        }
    }
    
    context.device.waitIdle();
}