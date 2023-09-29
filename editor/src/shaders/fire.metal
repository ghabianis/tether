#include <metal_stdlib>
using namespace metal;

struct Particle {
    float2 position;
    float3 color;
    float2 velocity;
    float2 gravity;
    float life;
    float fade;
};


// Simple hash function to generate a pseudo-random float from two integer inputs
// [0, 1)
float hash(int2 p) {
    p = int2(p.x<<13 ^ p.y, p.y<<13 ^ p.x);
    int m = (p.x*p.y*668265263) ^ (p.y*p.x*668265263);
   return metal::fract(float(m) * (1.0 / 4294967296.0)); // Convert to [0,1) range
    // return fmodf(float(m) * (1.0 / 4294967296.0), 1.0); // Convert to [0,1) range

}

kernel void compute_main(device Particle *particles [[ buffer(0) ]],
                            constant float &time [[ buffer(1) ]],
                            uint id [[ thread_position_in_grid ]])
{
    const float2 gravity = float2(0.0, 0.0);
    const float posX = 0.0;
    const float posY = -5.0;
    Particle particle = particles[id];
    particle.position.x += particle.velocity.x / 750;
    particle.position.y += particle.velocity.y / 750;

    // particle.position.x += particle.velocity.x / 75;
    // particle.position.y += particle.velocity.y / 75;

    if ((particle.position.x > posX) && (particle.position.y > (0.1 + posY))) {
        particle.gravity.x = -0.3;
    } else if ((particle.position.x < posX) &&
                (particle.position.y > (0.1 + posY))) {
        particle.gravity.x = 0.3;
    } else {
        particle.gravity.x = 0.0;
    }
    
    particle.velocity += particle.gravity + gravity;
    particle.life -= particle.fade;

    // if (particle.life < 0.0) {
    //     particle.life = 1.0;
    //     particle.fade = (hash(id, id * 57) * 100.0) / 1000.0 + 0.003;
    //     particle.x = 
    // }

    particles[id] = particle;
}

struct VertexIn {
    float2 position  [[attribute(0)]];
    float2 texCoords  [[attribute(1)]];
};

struct ParticleVertex {
    float2 position [[attribute(2)]];
    float3 color [[attribute(3)]];
    float2 velocity;
    float2 gravity;
    float life;
    float fade;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoords; 
    // Add other vertex outputs as needed
};

struct Uniforms {
    float4x4 modelViewMatrix;
    float4x4 projectionMatrix;
};

vertex VertexOut vertex_main(VertexIn vertexIn [[stage_in]], 
                             constant Particle *particles [[ buffer(1) ]], 
                             constant Uniforms &uniforms [[buffer(2)]], 
                             uint id [[ vertex_id ]], uint instance_id [[instance_id]])
{
    VertexOut out;

    // Do something with the particle data
    float2 particlePosition = particles[instance_id].position;

    // Convert to homogeneous coordinates
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(vertexIn.position + particlePosition, 0.9, 1.0);
    out.texCoords = vertexIn.texCoords;

    return out;
}


fragment float4 fragment_main(
    VertexOut fragmentIn [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    // float sampled = round(tex.sample(smp, fragmentIn.texCoords.xy).r);
    float sampled = tex.sample(smp, fragmentIn.texCoords.xy).r;

    return float4(1.0, 0.0, 0.0, 1.0) * sampled;
}
