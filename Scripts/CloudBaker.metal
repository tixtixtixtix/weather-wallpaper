// Offline artwork generator only. Never compiled into or executed by the wallpaper app.
#include <metal_stdlib>
using namespace metal;

float random3(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}
float valueNoise(float3 p) {
    float3 i = floor(p), f = fract(p);
    f = f * f * (3 - 2 * f);
    return mix(mix(mix(random3(i), random3(i + float3(1,0,0)), f.x),
                   mix(random3(i + float3(0,1,0)), random3(i + float3(1,1,0)), f.x), f.y),
               mix(mix(random3(i + float3(0,0,1)), random3(i + float3(1,0,1)), f.x),
                   mix(random3(i + float3(0,1,1)), random3(i + 1), f.x), f.y), f.z);
}
float softUnion(float a, float b, float radius) {
    float h = saturate(0.5 + 0.5 * (b - a) / radius);
    return mix(a, b, h) + radius * h * (1 - h);
}

float density(float3 p, float seed, uint family) {
    // A connected condensation body keeps the lobes from becoming disconnected
    // beads; smaller satellite volumes sculpt its upper edge and shoulders.
    float3 body = family == 1 ? float3(1.45, 0.24, 0.48)
        : (family == 3 ? float3(1.65, 0.48, 0.68) : float3(1.08, 0.30, 0.48));
    float shape = (1 - length((p - float3(0, -0.12, 0)) / body)) * 0.48;
    for (int i = 0; i < 28; i++) {
        float index = float(i);
        float3 r = float3(random3(float3(index, seed, 2)), random3(float3(index, seed, 6)),
                          random3(float3(index, seed, 9)));
        float variant = fmod(floor(seed / 19.31), 4.0);
        float vertical = family == 1 ? 0.35 : (family == 3 ? 1.05 : 0.75 + variant * 0.08);
        float3 center = float3((r.x - 0.5) * (family == 3 ? 2.9 : 2.4),
                              (r.y - 0.35) * vertical, (r.z - 0.5) * 0.65);
        float radius = (family == 1 ? 0.16 : 0.20) + random3(float3(index, seed, 13)) * 0.31;
        float flatten = family == 1 ? 0.62 : 0.95;
        float sphere = (1 - length((p - center) / float3(radius, radius * flatten, radius))) * radius;
        shape = softUnion(shape, sphere, 0.16);
    }
    if (family == 3) {
        // Broad rain bases, with anvil shoulders on two of the storm variants.
        bool convective = fmod(floor(seed / 19.31), 4.0) >= 2;
        float tower = (1 - length((p - float3(0.12, 0.28, 0))
            / (convective ? float3(0.74, 0.77, 0.62) : float3(1.35, 0.38, 0.62)))) * 0.58;
        shape = softUnion(shape, tower, 0.24);
        if (convective) {
            float anvil = (1 - length((p - float3(0.15, 0.82, 0)) / float3(1.55, 0.28, 0.55))) * 0.40;
            shape = softUnion(shape, anvil, 0.18);
        }
    }
    if (shape < -0.06) return 0;
    float erosion = 0;
    float amplitude = 0.16;
    float3 q = p * 4.2 + seed * 3.7;
    for (int i = 0; i < 4; i++) {
        erosion += (1 - valueNoise(q)) * amplitude;
        q = q * 2.13 + 11.7;
        amplitude *= 0.48;
    }
    return smoothstep(-0.035, 0.12, shape - erosion) * 1.4;
}

float4 cirrus(float2 uv, float seed) {
    float2 p = (uv - 0.5) * 2;
    float fibers = 0;
    for (int i = 0; i < 4; i++) {
        float f = float(i);
        float r = random3(float3(f, seed, 7));
        float along = p.x - (r - 0.5) * 0.65;
        float curve = 0.20 * along + (0.18 + r * 0.15) * sin(along * 2.3 + seed);
        float across = p.y - (f - 1.5) * 0.15 - curve;
        float warp = valueNoise(float3(along * 3.5, across * 6, seed)) - 0.5;
        float grain = valueNoise(float3(along * 7, across * 55 + warp * 5, seed + f * 11));
        float detail = valueNoise(float3(along * 17, across * 110, seed + 31));
        float envelope = exp(-pow(across / (0.10 + r * 0.09), 2)
                             - pow(along / (0.42 + r * 0.26), 4));
        fibers += envelope * (0.15 + grain * grain * 1.5) * (0.4 + detail * 0.6) * 0.7;
    }
    float edge = (1 - smoothstep(0.72, 0.98, abs(p.x))) * (1 - smoothstep(0.65, 0.95, abs(p.y)));
    float alpha = (1 - exp(-fibers)) * edge;
    return float4(float3(0.88), alpha);
}

kernel void bakeClouds(texture2d<float, access::write> output [[texture(0)]], uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) return;
    uint tileSize = output.get_width() / 4;
    uint2 tile = pixel / tileSize;
    uint family = tile.y; // rows: cirrus, stratocumulus, cumulus, rain / anvil banks
    float seed = float(tile.x + tile.y * 4) * 19.31 + 2.7;
    float2 uv = (float2(pixel % tileSize) + 0.5) / float(tileSize);
    if (family == 0) { output.write(cirrus(uv, seed), pixel); return; }
    float2 xy = float2((uv.x - 0.5) * 4.6, (0.5 - uv.y) * 3.1);
    float3 light = normalize(float3(-0.7, 0.9, 0.6));
    float transmittance = 1, radiance = 0;
    const float step = 4.0 / 56.0;
    for (int i = 0; i < 56; i++) {
        float3 p = float3(xy, 2 - (float(i) + 0.5) * step);
        float amount = density(p, seed, family);
        if (amount < 0.001) continue;
        float shadow = density(p + light * 0.12, seed, family) * 0.20
                     + density(p + light * 0.36, seed, family) * 0.32
                     + density(p + light * 0.78, seed, family) * 0.54
                     + density(p + light * 1.40, seed, family) * 0.70;
        float direct = exp(-shadow * 2.9);
        float ambient = 0.29 + saturate(p.y + 0.4) * 0.14;
        float opacity = 1 - exp(-amount * step * 8.0);
        radiance += transmittance * opacity * (ambient + direct * 0.72);
        transmittance *= 1 - opacity;
        if (transmittance < 0.004) break;
    }
    float alpha = 1 - transmittance;
    float edge = smoothstep(0.002, 0.035, alpha);
    float shade = alpha > 0.001 ? radiance / alpha : 0;
    float padding = smoothstep(0.0, 0.045, min(min(uv.x, 1 - uv.x), min(uv.y, 1 - uv.y)));
    output.write(float4(float3(saturate(shade)), alpha * edge * padding), pixel);
}
