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
    float2 texCoords [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoords;
};

struct Uniforms {
    float4x4 modelViewMatrix;
    float4x4 projectionMatrix;
};

struct InstanceData {
    float2 position [[attribute(2)]];
    float2 texOffset [[attribute(3)]];
    float4 hehe;
};

vertex VertexOut vertex_main(VertexIn vertexIn [[stage_in]], uint instance_id [[instance_id]], constant InstanceData *instanceData [[buffer(1)]], constant Uniforms &uniforms [[buffer(2)]])
{
    VertexOut vertexOut;
    vertexOut.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(vertexIn.position.xy + instanceData[instance_id].position, 0.9, 1);
    vertexOut.texCoords = vertexIn.texCoords + instanceData[instance_id].texOffset;
    return vertexOut;
}

fragment float4 fragment_main(VertexOut fragmentIn [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
    return tex.sample(smp, fragmentIn.texCoords.xy);
}
