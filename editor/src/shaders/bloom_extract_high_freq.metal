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
//     out.clip_position = float4(input.position, 0.0, 0.5);
//     out.texcoord = input.texcoord;
//     return out;
// }

// struct FragmentInput {
//     float2 texcoord [[user(locn0)]];
// };

// fragment float4 fs_main(float4 fragCoord [[position]], FragmentInput input,
//                         texture2d<float> inputImage [[texture(0)]],
//                         sampler sampler_ [[sampler(1)]],
//                         constant float &BrightnessThreshold [[buffer(2)]]) {
//     float threshold = BrightnessThreshold;

//     float2 uv = input.texcoord.xy;
//     float4 FragColor = inputImage.sample(sampler_, uv);
//     float brightness = dot(FragColor.rgb, float3(0.2126, 0.7152, 0.0722));

//     if (brightness > threshold) {
//         return float4(FragColor.xyz, 1.0);
//     } else {
//         return float4(0.0, 0.0, 0.0, 0.0);
//     }
// }

// // fragment float4 fs_main(float4 fragCoord [[position]], FragmentInput input) {
// //     float2 uv = input.texcoord;
// //     return float4(1.0, 0.0, 0.0, 1.0);
// // }

#include <metal_stdlib>
using namespace metal;

// Vertex Input structure
struct VertexInput {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

// Vertex Output structure
struct VertexOutput {
    float4 clip_position [[position]];
    float2 texcoord;
};

// Vertex shader function
vertex VertexOutput vs_main(VertexInput input [[stage_in]]) {
    VertexOutput out;
    // Flip the Y-coordinate to match Metal's coordinate system
    out.clip_position = float4(input.position.x, input.position.y, 0.0, 1.0);
    out.texcoord = input.texcoord;
    return out;
}

struct FragmentInput {
    float2 texcoord;
};

fragment float4 fs_main(FragmentInput input [[stage_in]],
                        float4 fragCoord [[position]],
                        texture2d<float> inputImage [[texture(0)]],
                        sampler sampler_ [[sampler(1)]],
                        constant float &BrightnessThreshold [[buffer(2)]]) {
    
    float threshold = BrightnessThreshold;

    // Use the texcoord directly for sampling
    float2 uv = input.texcoord;
    
    // Sample the texture
    float4 FragColor = inputImage.sample(sampler_, uv);
    
    // Calculate the brightness using the luminance formula
    float brightness = dot(FragColor, float4(0.2126, 0.7152, 0.0722, 1.0));

    // Apply the brightness threshold
    if (brightness > threshold) {
        return float4(FragColor.xyz, 1.0);
        // return float4(FragColor.xyzw);
    } else {
        return float4(0.0, 0.0, 0.0, 0.0);
    }
}
