#include <metal_stdlib>
using namespace metal;

struct VertexInput {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

struct VertexOutput {
    float4 clip_position [[position]];
    float2 texcoord;
};

vertex VertexOutput vs_main(VertexInput input [[stage_in]]) {
    VertexOutput out;
    out.clip_position = float4(input.position, 0.0, 1.0);
    out.texcoord = input.texcoord;
    return out;
}

struct FragmentInput {
    float2 texcoord;
};

struct ImageResolution {
    float2 resolution;
};

fragment float4 fs_main(FragmentInput input [[stage_in]],
                        texture2d<float> inputImage [[texture(0)]],
                        sampler sampler_ [[sampler(1)]],
                        constant float &FilterRadius [[buffer(2)]],
                        constant ImageResolution &ImageRes [[buffer(3)]]) {
    float aspect = ImageRes.resolution.x / ImageRes.resolution.y;
    float x = (1.0 / ImageRes.resolution.x) * FilterRadius;
    float y = (1.0 / ImageRes.resolution.y) * FilterRadius;

    float4 a = inputImage.sample(sampler_, float2(input.texcoord.x - x, input.texcoord.y + y));
    float4 b = inputImage.sample(sampler_, float2(input.texcoord.x, input.texcoord.y + y));
    float4 c = inputImage.sample(sampler_, float2(input.texcoord.x + x, input.texcoord.y + y));

    float4 d = inputImage.sample(sampler_, float2(input.texcoord.x - x, input.texcoord.y));
    float4 e = inputImage.sample(sampler_, float2(input.texcoord.x, input.texcoord.y));
    float4 f = inputImage.sample(sampler_, float2(input.texcoord.x + x, input.texcoord.y));

    float4 g = inputImage.sample(sampler_, float2(input.texcoord.x - x, input.texcoord.y - y));
    float4 h = inputImage.sample(sampler_, float2(input.texcoord.x, input.texcoord.y - y));
    float4 i = inputImage.sample(sampler_, float2(input.texcoord.x + x, input.texcoord.y - y));

    // Weighted box filter
    //  1   | 1 2 1 |
    // -- * | 2 4 2 |
    // 16   | 1 2 1 |
    float4 calculated_color = e * 4.0;
    calculated_color += (b + d + f + h) * 2.0;
    calculated_color += (a + c + g + i) * 1.0;
    calculated_color *= 1.0 / 16.0;

    return float4(calculated_color.xyz, 1.0);
}

// fragment float4 fs_main(float4 fragCoord [[position]], FragmentInput input) {
//     float2 uv = input.texcoord.xy;
//     float4 color1 = inputImage.sample(sampler_, uv);
//     return color1;
// }
