#include <metal_stdlib>
using namespace metal;

// Define the structures that will be used for vertex inputs and outputs
struct VertexInput {
    float2 position [[attribute(0)]];
};

struct InstanceInput {
    float4 color [[attribute(1)]];
    float2 offset [[attribute(2)]];
};

struct Uniforms {
    float4x4 projection_matrix;
    float2 screen_shake_ndc;
    float2 screen_shake;
};

// Vertex output structure
struct VertexOut {
    float4 clip_position [[position]];
    float4 color;
};


inline float2 init_rand(uint invocation_id, float4 seed) {
    float2 rand_seed = seed.xz;
    rand_seed = fract(rand_seed * cos(35.456 + float(invocation_id) * seed.yw));
    rand_seed = fract(rand_seed * cos(41.235 + float(invocation_id) * seed.xw));
    return rand_seed;
}

inline float rand(float2 rand_seed) {
    rand_seed.x = fract(cos(dot(rand_seed, float2(23.14077926, 232.61690225))) * 136.8168);
    rand_seed.y = fract(cos(dot(rand_seed, float2(54.47856553, 345.84153136))) * 534.7645);
    return rand_seed.y;
}

inline float rand_range(float2 rand_seed, float min, float max) {
    return min + rand(rand_seed) * (max - min);
}

inline float4x4 scale_matrix(float sx, float sy, float sz) {
    return float4x4(
        float4(sx, 0.0, 0.0, 0.0),
        float4(0.0, sy, 0.0, 0.0),
        float4(0.0, 0.0, sz, 0.0),
        float4(0.0, 0.0, 0.0, 1.0)
    );
}

inline float4x4 translate_matrix(float tx, float ty, float tz) {
    return float4x4(
        float4(1.0, 0.0, 0.0, 0.0),
        float4(0.0, 1.0, 0.0, 0.0),
        float4(0.0, 0.0, 1.0, 0.0),
        float4(tx, ty, tz, 1.0)
    );
}

// Vertex shader
vertex VertexOut vs_main(VertexInput model [[stage_in]],
                         constant InstanceInput* instances [[buffer(1)]],
                         uint instanceIndex [[instance_id]],
                         constant Uniforms &uniforms [[buffer(2)]]) {
    InstanceInput instance = instances[instanceIndex];
    init_rand(instanceIndex, float4(0.0, 0.0, 0.0, 0.0));

    VertexOut out;
    float2 rand_seed = init_rand(instanceIndex, float4(0));
    float x = rand(rand_seed);
    float scale = instance.color.w * mix(0.75, 1.5, x);

    out.clip_position = uniforms.projection_matrix *
                        translate_matrix(instance.offset.x + uniforms.screen_shake_ndc.x,
                                         instance.offset.y + uniforms.screen_shake_ndc.y,
                                         0.0) *
                        scale_matrix(scale, scale, scale) *
                        float4(model.position.xy, 0.9, 1.0);

    out.color = float4(instance.color.rgb * mix(4.0, 8.0, x), instance.color.a);
    // out.color = float4(instance.color.rgb * mix(4.0, 16.0, x), instance.color.a);

    return out;
}

// Fragment shader
fragment float4 fs_main(VertexOut input [[stage_in]]) {
    return input.color;
}
