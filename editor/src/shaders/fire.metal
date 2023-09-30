#include <metal_stdlib>
using namespace metal;

class Loki {
private:
    thread float seed;
    unsigned TausStep(const unsigned z, const int s1, const int s2, const int s3, const unsigned M);

public:
    thread Loki(const unsigned seed1, const unsigned seed2 = 1, const unsigned seed3 = 1);

    thread float rand();
};

unsigned Loki::TausStep(const unsigned z, const int s1, const int s2, const int s3, const unsigned M)
{
    unsigned b=(((z << s1) ^ z) >> s2);
    return (((z & M) << s3) ^ b);
}

thread Loki::Loki(const unsigned seed1, const unsigned seed2, const unsigned seed3) {
    unsigned seed = seed1 * 1099087573UL;
    unsigned seedb = seed2 * 1099087573UL;
    unsigned seedc = seed3 * 1099087573UL;

    // Round 1: Randomise seed
    unsigned z1 = TausStep(seed,13,19,12,429496729UL);
    unsigned z2 = TausStep(seed,2,25,4,4294967288UL);
    unsigned z3 = TausStep(seed,3,11,17,429496280UL);
    unsigned z4 = (1664525*seed + 1013904223UL);

    // Round 2: Randomise seed again using second seed
    unsigned r1 = (z1^z2^z3^z4^seedb);

    z1 = TausStep(r1,13,19,12,429496729UL);
    z2 = TausStep(r1,2,25,4,4294967288UL);
    z3 = TausStep(r1,3,11,17,429496280UL);
    z4 = (1664525*r1 + 1013904223UL);

    // Round 3: Randomise seed again using third seed
    r1 = (z1^z2^z3^z4^seedc);

    z1 = TausStep(r1,13,19,12,429496729UL);
    z2 = TausStep(r1,2,25,4,4294967288UL);
    z3 = TausStep(r1,3,11,17,429496280UL);
    z4 = (1664525*r1 + 1013904223UL);

    this->seed = (z1^z2^z3^z4) * 2.3283064365387e-10;
}

thread float Loki::rand() {
    unsigned hashed_seed = this->seed * 1099087573UL;

    unsigned z1 = TausStep(hashed_seed,13,19,12,429496729UL);
    unsigned z2 = TausStep(hashed_seed,2,25,4,4294967288UL);
    unsigned z3 = TausStep(hashed_seed,3,11,17,429496280UL);
    unsigned z4 = (1664525*hashed_seed + 1013904223UL);

    thread float old_seed = this->seed;

    this->seed = (z1^z2^z3^z4) * 2.3283064365387e-10;

    return old_seed;
}


struct Particle {
    float2 position;
    float4 color;
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
    const float posY = -5.0;
    const float convergence_height = 0.1;
    Particle particle = particles[id];

    // Initialize a random number generator, seeds 2 and 3 are optional
    Loki rng = Loki(id * time, particle.velocity.y, particle.velocity.x);

    particle.position.x += particle.velocity.x / 750;
    particle.position.y += particle.velocity.y / 1000;

    // particle.position.x += particle.velocity.x / 75;
    // particle.position.y += particle.velocity.y / 75;

    // if (particle.position.y > 0.05 + posY) {
    //     particle.gravity.x = sin(particle.gravity.x);
    // }

    if (particle.position.x > posX && particle.position.y > (convergence_height + posY)) {
        // particle.gravity.x = -1.3 / 2.0;
        particle.gravity.x = -0.3;
    } else if (particle.position.x < posX &&
                particle.position.y > (convergence_height + posY)) {
        // particle.gravity.x = 1.3 / 2.0;
        particle.gravity.x = 0.3;
    } else {
        particle.gravity.x = 0.0;
    }
    
    particle.velocity += particle.gravity + gravity;
    particle.life -= particle.fade * 1;

    if (particle.life < 0.0) {
        particle.life = 1.0;
        particle.velocity = float2(
            // randomNoise(particle.position + particle.velocity + particle.fade * time, id + 1) * 60 - 30,
            // randomNoise(particle.position + particle.velocity + particle.fade * time, id + 1) * 60 - 30

            
            rng.rand() * 60 - 30,
            rng.rand() * 60 - 30

            // (randomNoise(particle.position + particle.velocity + particle.fade, id + 1) * 50 - 25),
            // (randomNoise(particle.position + particle.velocity + particle.fade, id + 1) * 50 - 25) * 100
        );
        // particle.fade = (randomNoise(particle.position, id) * 100.0) / 1000.0 + 0.003;
        particle.fade = (rng.rand() * 100) / 1000.0 + 0.003;
        particle.position = float2(posX, posY);
        particle.color = float4(1, 1, 1.0, 0.0001);
    } else if (particle.life < 0.4) {
        particle.color = float4(1, 0, 0, 1.0); // red
    } else if (particle.life < 0.6) {
        particle.color = float4(1, 0.5, 0, 1.0); // orange
    } else if (particle.life < 0.75) {
        particle.color = float4(1, 1, 0, 1.0); // yellow
    } else if (particle.life < 0.85) {
        particle.color = float4(0, 0, 1, 1.0); // blue
    }

    particles[id] = particle;
}

struct VertexIn {
    float2 position  [[attribute(0)]];
    float2 texCoords  [[attribute(1)]];
};

struct ParticleVertex {
    float2 position [[attribute(2)]];
    float4 color [[attribute(3)]];
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
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(vertexIn.position + particlePosition, 80, 1.0);
    // out.position = uniforms.projectionMatrix * float4(vertexIn.position + particlePosition, 20, 1.0);
    out.color = float4(particles[instance_id].color.xyz, particles[instance_id].color.w * smoothstep(0.0, 0.3, particles[instance_id].life));
    out.texCoords = vertexIn.texCoords;

    return out;
}


fragment float4 fragment_main(
    VertexOut fragmentIn [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    // float sampled = round(tex.sample(smp, fragmentIn.texCoords.xy).r);

    // For Particle.bmp
    // float sampled = tex.sample(smp, fragmentIn.texCoords.xy).a;

    // float sampled = tex.sample(smp, fragmentIn.texCoords.xy).r;

    // For flare.png
    // float3 sampled_rgb = tex.sample(smp, fragmentIn.texCoords.xy).rgb;
    // float sampled = (sampled_rgb.r + sampled_rgb.g + sampled_rgb.b) / 3;

    // return float4(fragmentIn.color.xyz, fragmentIn.color.w * sampled);
    return float4(fragmentIn.color.xyz, fragmentIn.color.w);
}
