//
//  Shaders.metal
//  tether2
//
//  Created by Zack Radisic on 05/06/2023.
//

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position  [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct Uniforms {
    float4x4 modelViewMatrix;
    float4x4 projectionMatrix;
    float3 colorIn;
    float3 colorOut;
    float time;
};

struct FragmentUniforms {

};

struct InstanceData {
    float top;
    float bot;
    float left;
    float right;
};

vertex VertexOut vertex_main(VertexIn vertexIn [[stage_in]], uint vertex_id [[vertex_id]], uint instance_id [[instance_id]], constant InstanceData *instanceData [[buffer(1)]], constant Uniforms &uniforms [[buffer(2)]])
{
    VertexOut vertexOut;
    InstanceData instance = instanceData[instance_id];
    float2 position;
    float2 uv;
    switch (vertex_id) {
        // top left
        case 0:
            position = float2(instance.left, instance.top);
            uv = float2(0, 1);
            break;
        // top right
        case 1:
            position = float2(instance.right, instance.top);
            uv = float2(1, 1);
            break;
        // bot right
        case 2:
            position = float2(instance.right, instance.bot);
            uv = float2(1, 0);
            break;
        // bot right
        case 3:
            position = float2(instance.right, instance.bot);
            uv = float2(1, 0);
            break;
        // bot left
        case 4:
            position = float2(instance.left, instance.bot);
            uv = float2(0, 0);
            break;
        // top left
        case 5:
            position = float2(instance.left, instance.top);
            uv = float2(0, 1);
            break;
        default:
            position = float2(0, 0);
            uv = float2(0, 0);
            break;
    }
    vertexOut.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(position, 0.9, 1);
    vertexOut.uv = uv;
    return vertexOut;
}

fragment float4 fragment_main(VertexOut fragmentIn [[stage_in]], constant Uniforms &uniforms [[buffer(0)]]) {
    float2 uv = fragmentIn.uv;
    uv.y = 1.0 - uv.y;

    // float curve = 0.1 * sin((20.0 * uv.x) + (5.0 * uniforms.time));
    float curve = sin(uniforms.time * 5.0) * 0.1 * sin((20.0 * uv.x));
    
    float distance = abs((curve + uv.y) - 0.5);
    // float lineAShape = smoothstep(1.0 - clamp(distance * 1.0, 0.0, 1.0), 1.0, 0.998);
    float lineAShape = smoothstep(1.0 - clamp(distance * 1.0, 0.0, 1.0), 1.0, 0.98);
    float4 lineACol = float4(mix(float4(uniforms.colorIn, 1.0), float4(uniforms.colorOut, 0.0), lineAShape));
    return float4(lineACol);
}
