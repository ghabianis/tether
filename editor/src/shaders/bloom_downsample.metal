#include <metal_stdlib>
using namespace metal;

// Structures for vertex input and output
struct VertexInput {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

struct VertexOutput {
    float4 clip_position [[position]];
    float2 texcoord;
};

// Vertex shader function
vertex VertexOutput vs_main(VertexInput input [[stage_in]]) {
    VertexOutput out;
    // Adjusting for Metal's NDC range [-1, 1] on z-axis
    out.clip_position = float4(input.position, 0.0, 1.0);
    out.texcoord = input.texcoord;
    return out;
}

// Fragment input structure
struct FragmentInput {
    float2 texcoord;
};


fragment float4 fs_main(FragmentInput input [[stage_in]],
                        texture2d<float> inputImage [[texture(0)]],
                        sampler sampler_ [[sampler(1)]],
                        constant float2 &ImageRes [[buffer(2)]]) {
    float2 pixelSize = float2(1.0) / (ImageRes * 1.0);
    float x = pixelSize.x;
    float y = pixelSize.y;

    // float4 a = inputImage.sample(sampler_, float2(input.texcoord.x, input.texcoord.y));
    // return float4(a.xyz, 1.0);
    // return float4(1.0, 0.0, 0.0, 1.0);

    float4 a = inputImage.sample(sampler_, float2(input.texcoord.x - 2.0 * x, input.texcoord.y + 2.0 * y));
    float4 b = inputImage.sample(sampler_, float2(input.texcoord.x, input.texcoord.y + 2.0 * y));
    float4 c = inputImage.sample(sampler_, float2(input.texcoord.x + 2.0 * x, input.texcoord.y + 2.0 * y));

    float4 d = inputImage.sample(sampler_, float2(input.texcoord.x - 2.0 * x, input.texcoord.y));
    float4 e = inputImage.sample(sampler_, float2(input.texcoord.x, input.texcoord.y));
    float4 f = inputImage.sample(sampler_, float2(input.texcoord.x + 2.0 * x, input.texcoord.y));

    float4 g = inputImage.sample(sampler_, float2(input.texcoord.x - 2.0 * x, input.texcoord.y - 2.0 * y));
    float4 h = inputImage.sample(sampler_, float2(input.texcoord.x, input.texcoord.y - 2.0 * y));
    float4 i = inputImage.sample(sampler_, float2(input.texcoord.x + 2.0 * x, input.texcoord.y - 2.0 * y));

    float4 j = inputImage.sample(sampler_, float2(input.texcoord.x - x, input.texcoord.y + y));
    float4 k = inputImage.sample(sampler_, float2(input.texcoord.x + x, input.texcoord.y + y));
    float4 l = inputImage.sample(sampler_, float2(input.texcoord.x - x, input.texcoord.y - y));
    float4 m = inputImage.sample(sampler_, float2(input.texcoord.x + x, input.texcoord.y - y));

    float4 calculated_color = float4(0.0);
    calculated_color += e * 0.125;
    calculated_color += (a + c + g + i) * 0.03125; // 0.125
    calculated_color += (b + d + f + h) * 0.0625;  // 0.25
    calculated_color += (j + k + l + m) * 0.125;   // 0.5

    return float4(calculated_color.xyz, 1.0);
}


// #include <metal_stdlib>
// using namespace metal;

// struct VertexInput {
//     float2 position [[attribute(0)]];
//     float2 texcoord [[attribute(1)]];
// };

// struct VertexOutput {
//     float4 clip_position [[position]];
//     float2 texcoord [[user(locn0)]];
// };

// vertex VertexOutput vs_main(VertexInput input [[stage_in]]) {
//     VertexOutput out;
//     out.clip_position = float4(input.position, 0.0, 1.0);
//     out.texcoord = input.texcoord;
//     return out;
// }

// struct FragmentInput {
//     float2 texcoord [[user(locn0)]];
// };

// fragment float4 fs_main(FragmentInput input,
//                         texture2d<float> inputImage [[texture(0)]],
//                         sampler sampler_ [[sampler(1)]],
//                         constant float2 &ImageRes [[buffer(2)]]) {
//     float2 pixelSize = 1.0 / ImageRes;
//     float x = pixelSize.x;
//     float y = pixelSize.y;

//     float4 a = inputImage.sample(sampler_, float2(input.texcoord.x - 2.0 * x, input.texcoord.y + 2.0 * y));
//     float4 b = inputImage.sample(sampler_, float2(input.texcoord.x, input.texcoord.y + 2.0 * y));
//     float4 c = inputImage.sample(sampler_, float2(input.texcoord.x + 2.0 * x, input.texcoord.y + 2.0 * y));

//     float4 d = inputImage.sample(sampler_, float2(input.texcoord.x - 2.0 * x, input.texcoord.y));
//     float4 e = inputImage.sample(sampler_, float2(input.texcoord.x, input.texcoord.y));
//     float4 f = inputImage.sample(sampler_, float2(input.texcoord.x + 2.0 * x, input.texcoord.y));

//     float4 g = inputImage.sample(sampler_, float2(input.texcoord.x - 2.0 * x, input.texcoord.y - 2.0 * y));
//     float4 h = inputImage.sample(sampler_, float2(input.texcoord.x, input.texcoord.y - 2.0 * y));
//     float4 i = inputImage.sample(sampler_, float2(input.texcoord.x + 2.0 * x, input.texcoord.y - 2.0 * y));

//     float4 j = inputImage.sample(sampler_, float2(input.texcoord.x - x, input.texcoord.y + y));
//     float4 k = inputImage.sample(sampler_, float2(input.texcoord.x + x, input.texcoord.y + y));
//     float4 l = inputImage.sample(sampler_, float2(input.texcoord.x - x, input.texcoord.y - y));
//     float4 m = inputImage.sample(sampler_, float2(input.texcoord.x + x, input.texcoord.y - y));

//     float4 calculated_color = float4(0.0);
//     calculated_color += e * 0.125;
//     calculated_color += (a + c + g + i) * 0.03125; // 0.125
//     calculated_color += (b + d + f + h) * 0.0625;  // 0.25
//     calculated_color += (j + k + l + m) * 0.125;   // 0.5

//     return float4(calculated_color.xyz, 1.0);
// }
