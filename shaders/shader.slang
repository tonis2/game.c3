// Shader written in Slang https://github.com/shader-slang/slang

struct Material
{
    float emissiveStrength;
    float metallicFactor;
    float roughnessFactor;
    float pad;
    float4 emissiveFactor;
    float4 baseColorFactor;
    int normalTexture;
    int occlusionTexture;
    int emissiveTexture;
    int baseColorTexture;
    int metallicRoughnessTexture;
    float3 pad2;
};

// struct Vertex
// {
//     float4 position;
//     float4 normal;
//     float4 tex_cord;
//     float4 tangent;
//     uint4 skin_pos;
//     float4 skin_weight;
// };

struct Light
{
    float4 position;
    float4 color;
    uint type;
    float intensity;
    float range;
    float inner_angle;
    float outer_angle;
    float3 pad;
}

struct DrawCommand
{
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

struct PushData
{
    uint draw_index;
    uint8_t collides;
};

struct Node {
    bool dirty;
    int parent;
    float2 pad;
    float4 position;
    float4 scale;
    float4 rotation;
    row_major float4x4 matrix;
}

[vk_push_constant]
const PushData push_constant;

[vk_binding(0)]
cbuffer Scene
{
    row_major float4x4 perspective;
    row_major float4x4 view;
    float4 eye;
    Light light;
    uint64_t* draw_buffer;
    DrawCommand* draw_cmds;
    Material* materials;
    Node* nodes;
    row_major float4x4* skin_data;
    row_major float4x4* instances;
}

[vk_binding(1)]
uniform Sampler2D image_samplers[];

[vk_binding(2)]
uniform Sampler2D shadow_samplers[];

// Output of the fragment shader
struct FragmentData
{
    float2 tex_cord;
    int material;
    float4 sv_position : SV_Position;
};

struct VertexInput {
    uint32_t vertID : SV_VertexID;
    uint32_t instanceID : SV_InstanceID;
}

[shader("vertex")]
FragmentData vertexMain(VertexInput input)
{
    DrawCommand draw = draw_cmds[push_constant.draw_index];
    float3 position = ((float3*)draw_buffer)[draw.vertexOffset + input.vertID];

    // float4x4 skin_matrix = {
    //     1, 0, 0, 0,
    //     0, 1, 0, 0,
    //     0, 0, 1, 0,
    //     0, 0, 0, 1
    // };

    // if (draw.skin_offset > -1)
    // {
    //     float4x4* skin_matrixes = skin_data + draw.skin_offset;

    //     skin_matrix =
    //     vertex.skin_weight[0] * skin_matrixes[vertex.skin_pos[0]] +
    //     vertex.skin_weight[1] * skin_matrixes[vertex.skin_pos[1]] +
    //     vertex.skin_weight[2] * skin_matrixes[vertex.skin_pos[2]] +
    //     vertex.skin_weight[3] * skin_matrixes[vertex.skin_pos[3]];
    // }


    row_major float4x4 node_matrix = nodes[draw.node_index].matrix;
    // node_matrix = mul(node_matrix, skin_matrix);

    // if (draw.animation_offset > -1)
    // {
    //     float4x4* animation_data = skin_data + draw.skin_offset;
    //     node_matrix = mul(node_matrix, (instances + draw.instance_offset)[input.instanceID]);
    // }

    if (input.instanceID > 0) {
        node_matrix = mul(node_matrix, (instances + draw.instance_offset)[input.instanceID]);
    }

    float4 frag_pos = mul(node_matrix, float4(position, 1.0));
    float4 vertex_pos = mul(mul(perspective, view), frag_pos);

    FragmentData output = {
        {0, 0},
        draw.material,
        vertex_pos
    };

    return output;
}

// Fragment Shader
[shader("fragment")]
float4 fragmentMain(FragmentData input)
    : SV_Target
{
    if (push_constant.collides == 1) return float4(0.8, 0.4, 0.7, 1.0);

    if (input.material > -1)
    {
        Material material = materials[input.material];
        if (material.baseColorTexture > -1) {
            return image_samplers[material.baseColorTexture].Sample(input.tex_cord) * material.baseColorFactor;
        } else {
            return material.baseColorFactor;
        }
    }

    return float4(0.5, 0.5, 0.5, 1.0);
}