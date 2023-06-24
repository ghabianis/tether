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
    float4 color     [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 texCoords;
};

vertex VertexOut vertex_main(VertexIn vertexIn [[stage_in]])
{
    VertexOut vertexOut;
    vertexOut.position = float4(vertexIn.position.xy, 0, 1);
    vertexOut.texCoords = vertexIn.texCoords.xy;
    vertexOut.color = vertexIn.color;
    return vertexOut;
}

fragment float4 fragment_main(VertexOut fragmentIn [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
    // return fragmentIn.color;
    return tex.sample(smp, fragmentIn.texCoords.xy);
}
