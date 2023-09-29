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

float randomNoise(float2 p, uint i) {
  return fract(6791.0 * sin(i * 47.0 * p.x + 9973.0 * p.y));
}

kernel void compute_main(device Particle *particles [[ buffer(0) ]],
                            constant float &time [[ buffer(1) ]],
                            uint id [[ thread_position_in_grid ]])
{
    const float2 gravity = float2(0.0, 0.0);
    const float posX = 0.0;
    const float posY = 0.0;
    Particle particle = particles[id];
    particle.position.x += particle.velocity.x / 750;
    particle.position.y += particle.velocity.y / 750;

    // particle.position.x += particle.velocity.x / 75;
    // particle.position.y += particle.velocity.y / 75;

    // if (particle.position.y > 0.05 + posY) {
    //     particle.gravity.x = sin(particle.gravity.x);
    // }

    if (particle.position.x > posX && particle.position.y > (0.05 + posY)) {
        particle.gravity.x = -0.3;
    } else if (particle.position.x < posX &&
                particle.position.y > (0.05 + posY)) {
        particle.gravity.x = 0.3;
    } else {
        particle.gravity.x = 0.0;
    }
    
    particle.velocity += particle.gravity + gravity;
    particle.life -= particle.fade * 5;

    if (particle.life < 0.0) {
        particle.life = 1.0;
        particle.velocity = float2(
            randomNoise(particle.position + particle.fade, id + 1) * 60 - 30,
            randomNoise(particle.position + particle.fade, id + 1) * 60 + 30
        );
        particle.fade = (randomNoise(particle.position, id) * 100.0) / 1000.0 + 0.003;
        particle.position = float2(posX, posY);
        particle.color = float3(0, 0, 0.000001);
    } else if (particle.life < 0.4) {
        particle.color = float3(1, 0, 0); // red
    } else if (particle.life < 0.6) {
        particle.color = float3(1, 0.5, 0); // orange
    } else if (particle.life < 0.75) {
        particle.color = float3(1, 1, 0); // yellow
    } else if (particle.life < 0.9) {
        particle.color = float3(0, 0, 1); // blue
    }

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
    float4 color;
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
    // out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(vertexIn.position + particlePosition, 40, 1.0);
    out.position = uniforms.projectionMatrix * float4(vertexIn.position + particlePosition, 40, 1.0);
    out.color = float4(particles[instance_id].color.xyz, particles[instance_id].life);
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

    return float4(fragmentIn.color.xyz, fragmentIn.color.w * sampled);
}
