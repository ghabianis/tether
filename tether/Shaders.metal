//
//  Shaders.metal
//  tether2
//
//  Created by Zack Radisic on 05/06/2023.
//

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position  [[attribute(0)]];
    float3 normal    [[attribute(1)]];
    float2 texCoords [[attribute(2)]];
};
 
struct VertexOut {
    float4 position [[position]];
    float4 eyeNormal;
    float4 eyePosition;
    float2 texCoords;
};

struct Uniforms {
    float4x4 modelViewMatrix;
    float4x4 projectionMatrix;
};

vertex VertexOut vertex_main(VertexIn vertexIn [[stage_in]],
                             constant Uniforms &uniforms [[buffer(1)]])
{
    VertexOut vertexOut;
    vertexOut.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(vertexIn.position, 1);
    // note that this will be fucked up if we do non-uniform scaling because of the nuances of normals
    vertexOut.texCoords = vertexIn.texCoords.xy;
    return vertexOut;
}

fragment float4 fragment_main(VertexOut fragmentIn [[stage_in]],
                                        texture2d<float> tex [[texture(0)]],
                                        sampler smp [[sampler(0)]]) {
//    return tex.sample(smp, fragmentIn.texCoords.xy);
    return float4(1, 0, 0, 1);
}

//
//  TextShader.metal
//  tether
//
//  Created by Zack Radisic on 08/06/2023.
//
//
//#include <metal_stdlib>
//using namespace metal;
//
//struct VertexIn {
//    float2 position [[attribute(0)]];
//    float2 texCoords [[attribute(1)]];
//    float3 color [[attribute(2)]];
//};
//
//struct VertexOut {
//    float4 position [[position]];
//    float3 color;
//    float2 texCoords;
//};
//
//vertex VertexOut vertex_main(VertexIn vertexIn [[stage_in]])
//{
//    VertexOut vertexOut;
//    vertexOut.position = float4(vertexIn.position.xy, 0, 1);
//    vertexOut.texCoords = vertexIn.texCoords.xy;
//    vertexOut.color = vertexIn.color;
//    return vertexOut;
//}
//
//fragment float4 fragment_main(VertexOut fragmentIn [[stage_in]]) {
//    return float4(1, 0, 0, 1);
//}
