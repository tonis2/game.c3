// Shader written in Slang https://github.com/shader-slang/slang

struct Material
{
    float emissiveStrength;
    float metallicFactor;
    float roughnessFactor;
    int normalTexture;
    int occlusionTexture;
    int emissiveTexture;
    int baseColorTexture;
    int metallicRoughnessTexture;
    float4 emissiveFactor;
    float4 baseColorFactor;
};

struct Vertex
{
    float2 tex_cord;
    float3 normal;
    float3 position;
    float4 tangent;
    uint[4] skin_pos;
    float4 weights;
};

struct Light
{
    float3 position;      // position as scalars (12 bytes, no padding)
    float3 color; // color as scalars (12 bytes, no padding)
    uint type;
    float intensity;
    float range;
    float inner_angle;
    float outer_angle;
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

    float3 position;
    float3 scale;
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
    float4 pad;
    uint8_t* draw_buffer;
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
    float3 world_pos;
    float3 normal;
    float3 tangent;
    float3 bitangent;
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

    Vertex vertex = ((Vertex*)(draw_buffer + draw.vertexOffset))[input.vertID];

    float4x4 skin_matrix = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    };

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
    node_matrix = mul(node_matrix, skin_matrix);

    if (input.instanceID > 0) {
        node_matrix = mul(node_matrix, instances[draw.instance_offset + input.instanceID]);
    }

    float4 frag_pos = mul(node_matrix, float4(vertex.position.xyz, 1.0));
    float4 vertex_pos = mul(mul(perspective, view), frag_pos);

    // Transform normal and tangent to world space (using upper-left 3x3 of matrix)
    float3x3 normal_matrix = float3x3(
        node_matrix[0].xyz,
        node_matrix[1].xyz,
        node_matrix[2].xyz
    );
    float3 world_normal = normalize(mul(normal_matrix, vertex.normal));
    float3 world_tangent = normalize(mul(normal_matrix, vertex.tangent.xyz));
    float3 world_bitangent = cross(world_normal, world_tangent) * vertex.tangent.w;

    FragmentData output = {
        vertex.tex_cord.xy,
        draw.material,
        frag_pos.xyz,
        world_normal,
        world_tangent,
        world_bitangent,
        vertex_pos
    };

    return output;
}

// PBR Helper Functions
static const float PI = 3.14159265359;

// Normal Distribution Function (GGX/Trowbridge-Reitz)
float distributionGGX(float3 N, float3 H, float roughness)
{
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;

    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;

    return a2 / denom;
}

// Geometry function (Schlick-GGX)
float geometrySchlickGGX(float NdotV, float roughness)
{
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

// Smith's method for geometry
float geometrySmith(float3 N, float3 V, float3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx1 = geometrySchlickGGX(NdotV, roughness);
    float ggx2 = geometrySchlickGGX(NdotL, roughness);
    return ggx1 * ggx2;
}

// Fresnel-Schlick approximation
float3 fresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// Fragment Shader
[shader("fragment")]
float4 fragmentMain(FragmentData input)
    : SV_Target
{
    if (push_constant.collides == 1) return float4(0.8, 0.4, 0.7, 1.0);

    // Default material values
    float4 albedo = float4(0.5, 0.5, 0.5, 1.0);
    float metallic = 0.0;
    float roughness = 0.5;
    float ao = 1.0;
    float3 emissive = float3(0.0, 0.0, 0.0);
    float3 N = normalize(input.normal);

    if (input.material > -1)
    {
        Material material = materials[input.material];

        // Sample base color
        if (material.baseColorTexture > -1) {
            albedo = image_samplers[material.baseColorTexture].Sample(input.tex_cord) * material.baseColorFactor;
        } else {
            albedo = material.baseColorFactor;
        }

        // Sample metallic-roughness
        metallic = material.metallicFactor;
        roughness = material.roughnessFactor;
        if (material.metallicRoughnessTexture > -1) {
            float4 mr = image_samplers[material.metallicRoughnessTexture].Sample(input.tex_cord);
            metallic *= mr.b;   // Blue channel = metallic
            roughness *= mr.g;  // Green channel = roughness
        }

        // Sample normal map
        if (material.normalTexture > -1) {
            float3 tangent_normal = image_samplers[material.normalTexture].Sample(input.tex_cord).xyz;
            tangent_normal = tangent_normal * 2.0 - 1.0;
            float3x3 TBN = float3x3(
                normalize(input.tangent),
                normalize(input.bitangent),
                normalize(input.normal)
            );
            N = normalize(mul(tangent_normal, TBN));
        }

        // Sample ambient occlusion
        if (material.occlusionTexture > -1) {
            ao = image_samplers[material.occlusionTexture].Sample(input.tex_cord).r;
        }

        // Sample emissive
        if (material.emissiveTexture > -1) {
            emissive = image_samplers[material.emissiveTexture].Sample(input.tex_cord).rgb * material.emissiveFactor.rgb * material.emissiveStrength;
        } else {
            emissive = material.emissiveFactor.rgb * material.emissiveStrength;
        }
    }

    // Clamp roughness to avoid division issues
    roughness = clamp(roughness, 0.04, 1.0);

    // View direction
    float3 V = normalize(eye.xyz - input.world_pos);

    // Base reflectivity (F0) - dielectrics use 0.04, metals use albedo
    float3 F0 = lerp(float3(0.04, 0.04, 0.04), albedo.rgb, metallic);

    // Calculate light contribution
    float3 Lo = float3(0.0, 0.0, 0.0);

    // Light direction and attenuation based on light type
    float3 L;
    float attenuation = 1.0;

    // Reconstruct float3 from scalar fields

    // Light types: 0 = directional, 1 = point, 2 = spot
    if (light.type == 0) {
        // Directional light - position is direction
        L = normalize(-light.position);
    } else {
        // Point or spot light
        float3 light_vec = light.position - input.world_pos;
        float distance = length(light_vec);
        L = normalize(light_vec);

        // Distance attenuation
        if (light.range > 0.0) {
            attenuation = clamp(1.0 - pow(distance / light.range, 4.0), 0.0, 1.0);
            attenuation = attenuation * attenuation / (distance * distance + 1.0);
        } else {
            attenuation = 1.0 / (distance * distance + 1.0);
        }

        // Spot light cone attenuation
        if (light.type == 2) {
            float cos_outer = cos(light.outer_angle);
            float cos_inner = cos(light.inner_angle);
            float theta = dot(L, normalize(-light.position));
            float epsilon = cos_inner - cos_outer;
            float spot_intensity = clamp((theta - cos_outer) / epsilon, 0.0, 1.0);
            attenuation *= spot_intensity;
        }
    }

    // Half vector
    float3 H = normalize(V + L);

    // Cook-Torrance BRDF
    float NDF = distributionGGX(N, H, roughness);
    float G = geometrySmith(N, V, L, roughness);
    float3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);

    // Specular component
    float3 numerator = NDF * G * F;
    float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.0001;
    float3 specular = numerator / denominator;

    // Energy conservation
    float3 kS = F;
    float3 kD = (1.0 - kS) * (1.0 - metallic);

    // Final radiance
    float NdotL = max(dot(N, L), 0.0);
    float3 radiance = light.color * light.intensity * attenuation;
    Lo += (kD * albedo.rgb / PI + specular) * radiance * NdotL;

    // Ambient lighting (simple approximation)
    float3 ambient = float3(0.03) * albedo.rgb * ao;

    // Final color
    float3 color = ambient + Lo + emissive;

    // HDR tone mapping (Reinhard)
    color = color / (color + 1.0);

    // Gamma correction
    color = pow(color, float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));

    return float4(color, albedo.a);
}