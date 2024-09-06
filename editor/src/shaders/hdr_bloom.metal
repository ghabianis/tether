#include <metal_stdlib>
using namespace metal;

vertex float4 vs_main(const device float2* pos [[buffer(0)]], uint vertexIndex [[vertex_id]]) {
    float2 positions[6] = {
        float2(-1.0, -1.0),
        float2(1.0, -1.0),
        float2(-1.0, 1.0),
        float2(-1.0, 1.0),
        float2(1.0, -1.0),
        float2(1.0, 1.0)
    };

    return float4(positions[vertexIndex], 0.0, 1.0);
}

float3 aces_tone_map(float3 hdr) {
    float3x3 m1 = float3x3(
        float3(0.59719, 0.07600, 0.02840),
        float3(0.35458, 0.90834, 0.13383),
        float3(0.04823, 0.01566, 0.83777)
    );
    float3x3 m2 = float3x3(
        float3(1.60475, -0.10208, -0.00327),
        float3(-0.53108, 1.10813, -0.07276),
        float3(-0.07367, -0.00605, 1.07602)
    );
    float3 v = m1 * hdr;
    float3 a = v * (v + 0.0245786) - 0.000090537;
    float3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return clamp(m2 * (a / b), float3(0.0), float3(1.0));
}

fragment float4 chromatic_aberration(float2 uv, texture2d<float> tex, sampler inputSampler1) {
    float roff = 0.009;
    float goff = 0.004;
    float boff = -0.003;

    float2 direction = (uv - float2(0.5)) * 1.0;

    float4 color = tex.sample(inputSampler1, uv);
    color.r = 1 * tex.sample(inputSampler1, uv + direction * roff).r;
    color.g = tex.sample(inputSampler1, uv + direction * goff).g;
    color.b = tex.sample(inputSampler1, uv + direction * boff).b;

    return color;
}

fragment float4 fs_main(float4 fragCoord [[position]], texture2d<float> bloom_texture [[texture(0)]], sampler inputSampler1 [[sampler(0)]], texture2d<float> actual_texture [[texture(1)]], sampler inputSampler2 [[sampler(1)]]) {
    float2 uv = fragCoord.xy / float2(bloom_texture.get_width(), bloom_texture.get_height());
    // uv.y = 1.0 - uv.y;

    float4 color1 = bloom_texture.sample(inputSampler1, uv);
    float4 color2 = actual_texture.sample(inputSampler2, uv);
    float4 blendedColor = float4(color1.xyz + color2.xyz, 1.0);
    // return float4(aces_tone_map(blendedColor.xyz).xyz, blendedColor.w);
    return blendedColor;
}
