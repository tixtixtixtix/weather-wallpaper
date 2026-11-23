#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 viewport;    // width, height, fine animation clock, aspect
    float4 atmosphere;  // daylight, twilight, cloud cover, fog
    float4 weather;     // rain, snow, storm, wind
    float4 celestial;   // sun x, sun y, lunar illumination, wind direction
    float4 options;     // particle scale, lightning enabled, fine wind clock, bloom enabled
    float4 moon;        // x, y, visibility, local north rotation
    float4 moonLight;   // lunar sunlight direction xyz, hybrid solar weather-glare permission w
    float4 lightning;   // origin x, seed, envelope, reach
    float4 clock;       // coarse animation clock, coarse wind clock, leader progress, bloom divisor
    float4 clouds;      // effective coverage, optical depth, wet-bank blend, cirrus amount
    float4 rendering;   // integration samples, cloud divisor, hybrid renderer enabled, solar disk radius
    float4 morphology, cloudStructure, upperStyle, convection, towerMetrics;
};
constexpr sampler artwork(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
constexpr sampler lunarSampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear, max_anisotropy(8));

float timePhase(float rate, constant Uniforms &u) { return fract(u.clock.x * rate) + u.viewport.z * rate; }
float windPhase(float rate, constant Uniforms &u) { return fract(u.clock.y * rate) + u.options.z * rate; }
float hash21(float2 p) {
    float3 v = fract(float3(p.xyx) * 0.1031);
    v += dot(v, v.yzx + 33.33);
    return fract((v.x + v.y) * v.z);
}
float2 skyDelta(float2 a, float2 b) {
    return float2(fract(a.x - b.x + 0.5) - 0.5, a.y - b.y);
}
float3 rollOff(float3 color) { return max(color, 0.0) / (1 + max(color, 0.0) * 0.30); }

struct CloudPlacement {
    float2 center; float2 size; float2 tile; float2 wetTile;
    float opacity; float thickness; float blend; float high; float mirrored;
};
CloudPlacement cloudPlacement(uint index, constant Uniforms &u) {
    float i = float(index);
    bool high = index < 6, middle = index >= 6 && index < 12;
    uint layerIndex = high ? index : (middle ? index - 6 : index - 12);
    float j = float(layerIndex), wet = u.clouds.z;
    float depth = high ? 0.18 : (middle ? 0.38 : 0.65 + hash21(float2(i, 71)) * 0.35);
    float drift = timePhase(0.001215 * depth, u) + windPhase(0.006 * depth, u);
    float columns = high || middle ? 3 : 4;
    float x = fract((fmod(j, columns) + 0.35) / columns + drift + hash21(float2(i, 17)) * 0.07) * 1.5 - 0.25;
    float scatteredY = 0.04 + hash21(float2(i, 26)) * 0.76;
    float bankY = (middle ? 0.14 + floor(j / 3) * 0.34 : 0.02 + floor(j / 4) * 0.25)
        + hash21(float2(i, 26)) * 0.15;
    float y = high ? 0.06 + hash21(float2(i, 26)) * 0.36 : mix(scatteredY, bankY, wet);
    float height = high ? 0.20 + hash21(float2(i, 43)) * 0.12
        : (0.27 + hash21(float2(i, 43)) * 0.12) * mix(1.0, 1.80, wet);
    float aspect = high ? 3.6 : (middle ? 2.4 : mix(1.65, 2.15, wet));
    float activation = high ? u.clouds.w * 0.68
        : smoothstep(j * (middle ? 0.085 : 0.057), j * (middle ? 0.085 : 0.057) + 0.24, u.cloudStructure.z)
            * smoothstep(0.07, 0.24, u.cloudStructure.z) * (middle ? 0.62 : 0.92);
    uint tile = high ? layerIndex % 4 : (middle ? 4 : 8) + (layerIndex * 3) % 4;
    uint wetTile = 12 + (middle ? layerIndex % 2 : layerIndex % 4);
    return { float2(x, y), float2(height * aspect / u.viewport.w, height),
             float2(tile % 4, tile / 4), float2(wetTile % 4, wetTile / 4), activation,
             high ? 1.0 : u.clouds.y, high ? 0.0 : wet, high ? 1.0 : 0.0,
             (layerIndex / 4) % 2 == 0 ? 0.0 : 1.0 };
}

float2 tileUV(float2 tile, float2 local) {
    // Keep filtering inside each formation, including the low-resolution bloom pass.
    return (tile + clamp(local, 0.006, 0.994)) * 0.25;
}
float4 cloudArtwork(texture2d<float> atlas, float2 local, float2 tile, float2 wetTile, float blend, float lod) {
    if (blend > 0.999) return atlas.sample(artwork, tileUV(wetTile, local), level(lod));
    float4 fair = atlas.sample(artwork, tileUV(tile, local), level(lod));
    if (blend < 0.001) return fair;
    float4 bank = atlas.sample(artwork, tileUV(wetTile, local), level(lod));
    return mix(fair, bank, blend);
}
float cloudAlpha(float alpha, float opacity, float thickness) {
    return 1 - pow(max(0.0001, 1 - alpha * opacity), thickness);
}

// Only used for point-source occlusion, not a 24-layer loop at every sky pixel.
float cloudOpacity(float2 uv, constant Uniforms &u, texture2d<float> atlas) {
    float result = 0;
    for (uint i = 0; i < 24; i++) {
        CloudPlacement c = cloudPlacement(i, u);
        if (c.opacity < 0.003) continue;
        float2 local = (uv - c.center) / c.size + 0.5;
        if (any(local < 0) || any(local > 1)) continue;
        local.x = mix(local.x, 1 - local.x, c.mirrored);
        float alpha = cloudAlpha(cloudArtwork(atlas, local, c.tile, c.wetTile, c.blend, 1).a, c.opacity, c.thickness);
        result += alpha * (1 - result);
    }
    return result;
}

struct SkyVertex { float4 position [[position]]; float2 uv; float sunVisibility [[flat]]; };
vertex SkyVertex skyVertex(uint id [[vertex_id]], constant Uniforms &u [[buffer(0)]], texture2d<float> atlas [[texture(0)]]) {
    float2 p = float2(id == 1 ? 3.0 : -1.0, id == 2 ? 3.0 : -1.0);
    float visibility = 0;
    if (u.options.w > 0.5 && u.atmosphere.x > 0.01 && u.celestial.y < 1.08) {
        float2 sun = float2(fract(u.celestial.x), u.celestial.y);
        float2 offset = float2(0.008 / u.viewport.w, 0);
        float opacity = (cloudOpacity(sun, u, atlas) * 2 + cloudOpacity(sun - offset, u, atlas)
                         + cloudOpacity(sun + offset, u, atlas)) * 0.25;
        visibility = (1 - opacity) * u.atmosphere.x * (1 - u.atmosphere.w);
    }
    return { float4(p, 0, 1), float2((p.x + 1) * 0.5, (1 - p.y) * 0.5), visibility };
}

fragment float4 emissionFragment(SkyVertex in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float radius = length(skyDelta(in.uv, u.celestial.xy) * float2(u.viewport.w, 1));
    // One quarter-resolution HDR target handles both the bright source and its aureole.
    float solar = (exp(-pow(radius / 0.020, 2)) * 10 + exp(-pow(radius / 0.055, 2)) * 0.85) * in.sunVisibility;
    return float4(float3(1.0, 0.90, 0.70) * solar, 0);
}

constexpr sampler hazeNoiseSamplerLegacy(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
struct MoonlitHazeUniformsLegacy { float4 appearance, motion; };
float3 moonlitNotchHazeLegacy(float2 uv,constant Uniforms &u,constant MoonlitHazeUniformsLegacy &haze,
                             texture3d<float> noise) {
    float night = (1-smoothstep(0.015,0.15,u.atmosphere.x))*(1-smoothstep(0.10,0.55,u.atmosphere.y));
    if (haze.appearance.x <= 0 || night <= 0) return float3(0);
    float expansion = haze.appearance.y;
    float2 delta = uv-float2(haze.appearance.z,haze.appearance.w);
    float2 supportPoint = delta/float2(mix(0.34,0.46,expansion),mix(0.19,0.24,expansion));
    float support = dot(supportPoint,supportPoint);
    if (support >= 1) return float3(0);
    float2 p = delta/float2(mix(0.21,0.33,expansion),mix(0.11,0.16,expansion));
    float2 broad = noise.sample(hazeNoiseSamplerLegacy,float3(p*float2(0.15,0.25)+float2(0.28,0.62)+haze.motion.xy,0.21),level(2)).rg;
    float2 fine = noise.sample(hazeNoiseSamplerLegacy,float3(p*float2(0.34,0.29)+float2(-0.40,0.11)+haze.motion.zw,0.73),level(2)).rg;
    p += (float2(broad.x,fine.y)-0.5)*0.42;
    float2 a = (p-float2(-0.16,-0.10))*float2(1.35,1.8);
    float2 b = (p-float2(0.42,0.10))*float2(1.8,2.4);
    float2 c = (p-float2(-0.46,0.26))*float2(2.1,2.1);
    float layers = exp(-dot(a,a))*0.50+exp(-dot(b,b))*0.32+exp(-dot(c,c))*0.25;
    float thinMist = 0.60+0.40*smoothstep(0.20,0.80,0.50+(broad.x-0.5)*1.3+(fine.y-0.5)*0.65);
    float2 focus = (p-float2(0,-0.03))*float2(mix(3.6,2.8,expansion),4.0);
    float core = exp(-dot(focus,focus));
    float fade = saturate((support-0.35)/0.65);
    float envelope = saturate(1-fade*fade*fade*(fade*(fade*6-15)+10));
    float3 blueGrey = float3(0.44,0.56,0.77), silver = float3(0.83,0.88,0.94);
    return (blueGrey*(0.018*layers*thinMist)+silver*(0.011*core))
        * (haze.appearance.x*night*envelope*(1-expansion*0.10));
}
fragment float4 skyFragment(SkyVertex in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                            constant MoonlitHazeUniformsLegacy &haze [[buffer(3)]],
                            texture2d<float> moonMap [[texture(1)]], texture2d<float> bloom [[texture(2)]],
                            texture3d<float> hazeNoise [[texture(4)]]) {
    float2 uv = in.uv, metric = float2(u.viewport.w, 1);
    float day = u.atmosphere.x, twilight = u.atmosphere.y;
    float overcast = smoothstep(0.55, 1.0, u.cloudStructure.z);
    float3 zenith = mix(float3(0.0015, 0.003, 0.012), float3(0.012, 0.08, 0.25), day);
    float3 horizon = mix(float3(0.016, 0.022, 0.045), float3(0.10, 0.27, 0.46), day);
    zenith = mix(zenith, mix(float3(0.009, 0.014, 0.026), float3(0.17, 0.22, 0.29), day), overcast);
    horizon = mix(horizon, mix(float3(0.028, 0.035, 0.055), float3(0.31, 0.37, 0.43), day), overcast);
    float stormShade = 1 - u.clouds.z * 0.22 - u.weather.z * 0.24;
    zenith *= stormShade; horizon *= stormShade;
    zenith = mix(zenith, float3(0.045, 0.055, 0.13), twilight * 0.50);
    horizon = mix(horizon, float3(0.74, 0.24, 0.11), twilight * (1 - overcast * 0.7));
    float3 color = mix(zenith, horizon, pow(uv.y, 1.4));
    float sunDistance = length(skyDelta(uv, u.celestial.xy) * metric);
    float3 sunlight = mix(float3(1.5, 0.60, 0.24), float3(1.8, 1.58, 1.20), day);
    color += sunlight * exp(-sunDistance * 6) * day * 0.11 * (1 - overcast);
    float sunEdge = max(1 / u.viewport.y,0.0005);
    color += sunlight * (1 - smoothstep(u.rendering.w - sunEdge,u.rendering.w + sunEdge,sunDistance)) * day * (1 - overcast * 0.94);
    float night = (1 - day) * (1 - twilight * 0.9);
    if (night > 0.005) {
        float2 grid = uv * metric * 108, cell = floor(grid);
        float random = hash21(cell);
        float2 offset = float2(hash21(cell + 5.7), hash21(cell + 17.2));
        offset = 0.16+offset*0.68; // Keep the enlarged source inside its cell.
        float star = (1 - smoothstep(0.023, 0.155, length(fract(grid) - offset))) * step(0.982, random);
        float temperature = hash21(cell+93);
        float3 tint = temperature < 0.58 ? float3(0.96,0.97,1.0)
            : (temperature < 0.76 ? float3(1.0,0.87,0.70)
            : (temperature < 0.93 ? float3(0.73,0.85,1.0) : float3(1.0,0.76,0.67)));
        color += tint * 0.62 * star * night
            * (0.9 + 0.1 * sin(timePhase(0.13 / (2 * M_PI_F), u) * (2 * M_PI_F) + random * 300));
    }

    // Preserve the existing photographic map: avoid overexposure and excessive mip blur.
    if (u.moon.z > 0.001) {
        float moonRadius = u.rendering.w * 1.5; // Keep the solar disk unchanged.
        float2 local = skyDelta(uv, u.moon.xy) * metric / moonRadius;
        float r2 = dot(local, local);
        if (r2 < 1.04) {
            float3 normal = float3(local.x, -local.y, sqrt(max(0.0, 1 - min(r2, 1.0))));
            float c = cos(u.moon.w), s = sin(u.moon.w);
            float3 rotated = float3(normal.x * c - normal.y * s, normal.x * s + normal.y * c, normal.z);
            float2 surfaceUV = float2(atan2(rotated.x, rotated.z) / (2 * M_PI_F) + 0.5,
                                      acos(clamp(rotated.y, -1.0, 1.0)) / M_PI_F);
            float lod = max(0.0, log2(float(moonMap.get_height()) / max(1.0, u.viewport.y * moonRadius * 4.3)) - 0.35);
            float2 texel = exp2(lod) * 0.25 / float2(moonMap.get_width(), moonMap.get_height());
            float3 albedo = (moonMap.sample(lunarSampler, surfaceUV + texel, level(lod)).rgb
                + moonMap.sample(lunarSampler, surfaceUV - texel, level(lod)).rgb
                + moonMap.sample(lunarSampler, surfaceUV + float2(texel.x, -texel.y), level(lod)).rgb
                + moonMap.sample(lunarSampler, surfaceUV + float2(-texel.x, texel.y), level(lod)).rgb) * 0.25;
            albedo = max(0.0, (albedo - 0.18) * 1.15 + 0.18);
            float diffuse = dot(normal, normalize(u.moonLight.xyz));
            float terminator = smoothstep(-0.012, 0.025, diffuse);
            float lighting = saturate(2 * max(diffuse, 0.0) / max(0.02, max(diffuse, 0.0) + normal.z));
            float3 surface = albedo * (0.006 * night + lighting * 1.55);
            float edge = saturate((1 - sqrt(r2)) * u.viewport.y * moonRadius + 0.5);
            float alpha = edge * u.moon.z * mix(1.0, terminator * 0.75, day);
            color = mix(color, surface + color * day * 0.42, alpha);
        }
        float distance = length(skyDelta(uv, u.moon.xy) * metric);
        color += float3(0.016, 0.025, 0.042) * exp(-distance * 52) * night * u.moon.z * u.celestial.z;
    }
    float fog = u.atmosphere.w;
    color = mix(color, mix(float3(0.035, 0.045, 0.065), float3(0.38, 0.45, 0.50), day),
                saturate(fog * (0.35 + 0.58 * pow(uv.y, 0.8))));
    float flashDistance = length((uv - float2(u.lightning.x, 0.22)) * metric);
    color += float3(0.08, 0.11, 0.18) * u.lightning.z * exp(-flashDistance * 2.5);
    if (u.options.w > 0.5) {
        color += bloom.sample(artwork, uv).rgb * 0.42;
        float2 axis = float2(0.5) - float2(fract(u.celestial.x), u.celestial.y);
        for (int i = 0; i < 3; i++) {
            float index = float(i);
            float2 center = u.celestial.xy + axis * (1.35 + index * 0.52);
            float radius = 0.027 + index * 0.014;
            float ghost = 1 - smoothstep(radius * 0.7, radius, length((uv - center) * metric));
            color += float3(0.08, 0.16, 0.22) * ghost * in.sunVisibility * 0.13;
        }
    }
    float3 result = rollOff(color);
    float3 mist = moonlitNotchHazeLegacy(uv,u,haze,hazeNoise);
    result += mist;
    if (any(mist > 0)) {
        // The legacy sky has no general output dither; add it only within haze.
        uint h = uint(in.position.x)*1973u+uint(in.position.y)*9277u+89173u;
        h = (h^(h>>16))*0x7feb352du; h = (h^(h>>15))*0x846ca68bu;
        float triangular = float(h&65535u)/65535.0-float((h>>16)&65535u)/65535.0;
        float3 slope = select(float3(1.0/12.92),(2.4/1.055)*pow(max(result,0.0),1.0-1.0/2.4),result > 0.0031308);
        float feather = smoothstep(0.0,0.0004,max(mist.x,max(mist.y,mist.z)));
        result += slope*(triangular*(0.5/255.0)*feather);
    }
    return float4(result, 1);
}

struct CloudVertex {
    float4 position [[position]];
    float2 local;
    float2 screen;
    float4 tiles [[flat]];
    float4 appearance [[flat]];
};
vertex CloudVertex cloudVertex(uint vertexID [[vertex_id]], uint instance [[instance_id]], constant Uniforms &u [[buffer(0)]]) {
    const float2 corners[] = { float2(0,0), float2(1,0), float2(0,1), float2(0,1), float2(1,0), float2(1,1) };
    CloudPlacement c = cloudPlacement(instance, u);
    if (c.opacity < 0.003) return { float4(2, 2, 0, 1), float2(0), float2(0), float4(0), float4(0) };
    float2 local = corners[vertexID];
    float2 uv = c.center + (local - 0.5) * c.size;
    local.x = mix(local.x, 1 - local.x, c.mirrored);
    return { float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), local, uv,
             float4(c.tile, c.wetTile), float4(c.opacity, c.thickness, c.blend, c.high) };
}
fragment float4 cloudFragment(CloudVertex in [[stage_in]], constant Uniforms &u [[buffer(0)]], texture2d<float> atlas [[texture(0)]]) {
    float2 uv = tileUV(in.tiles.xy, in.local);
    float4 baked;
    if (in.appearance.z > 0.999) baked = atlas.sample(artwork, tileUV(in.tiles.zw, in.local));
    else {
        baked = atlas.sample(artwork, uv);
        if (in.appearance.z > 0.001) baked = mix(baked, atlas.sample(artwork, tileUV(in.tiles.zw, in.local)), in.appearance.z);
    }
    float alpha = cloudAlpha(baked.a, in.appearance.x, in.appearance.y);
    if (alpha < 0.002) discard_fragment();
    float day = u.atmosphere.x;
    float3 ambient = mix(float3(0.018, 0.028, 0.055), float3(0.70, 0.77, 0.86), day);
    ambient = mix(ambient, float3(0.44, 0.28, 0.27), u.atmosphere.y * 0.52);
    float wetShade = 1 - u.clouds.z * 0.28 - u.weather.z * 0.32;
    ambient *= mix(wetShade, 1.0, in.appearance.w);
    float3 color = ambient * (0.18 + clamp(baked.r, 0.15, 1.0) * 1.10);
    color *= 1 - smoothstep(0.35, 0.85, in.local.y) * u.clouds.z * 0.20 * (1 - in.appearance.w);
    // Thin, distant ice clouds stay airy rather than looking like grey foreground cutouts.
    color = mix(color, ambient * 1.12, in.appearance.w);
    float sunDistance = length(skyDelta(in.screen, u.celestial.xy) * float2(u.viewport.w, 1));
    color += float3(1.0, 0.74, 0.43) * pow(1 - baked.a, 2) * baked.a * exp(-sunDistance * 3) * day * 0.6;
    float flashDistance = length((in.screen - float2(u.lightning.x, 0.22)) * float2(u.viewport.w, 1));
    color += float3(0.27, 0.36, 0.64) * u.lightning.z * exp(-flashDistance * 3.5);
    color = mix(color, mix(float3(0.035, 0.045, 0.065), float3(0.38, 0.45, 0.50), day),
                saturate(u.atmosphere.w * (0.35 + 0.58 * pow(max(0.0, in.screen.y), 0.8))));
    return float4(rollOff(color) * alpha, alpha);
}

struct LightningInstance { float4 endpoints; float4 appearance; };
struct LightningVertex {
    float4 position [[position]];
    float2 point;
    float4 endpoints [[flat]];
    float4 appearance [[flat]];
    float visibility [[flat]];
};
vertex LightningVertex lightningVertex(uint vertexID [[vertex_id]], uint instance [[instance_id]],
    constant Uniforms &u [[buffer(0)]], const device LightningInstance *segments [[buffer(1)]]) {
    const float2 corners[] = { float2(0,-1), float2(1,-1), float2(0,1), float2(0,1), float2(1,-1), float2(1,1) };
    LightningInstance line = segments[instance];
    float2 metric = float2(u.viewport.w, 1);
    float2 a = line.endpoints.xy * metric, b = line.endpoints.zw * metric;
    float2 tangent = normalize(b - a + float2(0.000001, 0));
    float2 perpendicular = float2(-tangent.y, tangent.x);
    float width = max(line.appearance.x * 6, 2 / u.viewport.y);
    float2 corner = corners[vertexID];
    float2 point = mix(a - tangent * width, b + tangent * width, corner.x) + perpendicular * corner.y * width;
    float2 screen = point / metric;
    // A cheap bank-depth approximation is sufficient for a transient bolt. Never
    // resample all cloud layers per lightning pixel (or per segment vertex).
    float bank = (1 - smoothstep(0.60, 0.85, (line.endpoints.y + line.endpoints.w) * 0.5)) * u.clouds.x;
    float visibility = u.rendering.z > 0.5 ? 1 : 1 - bank * 0.64;
    return { float4(screen.x * 2 - 1, 1 - screen.y * 2, 0, 1), point, line.endpoints * float4(metric, metric), line.appearance, visibility };
}
float3 lightningRadiance(LightningVertex in, constant Uniforms &u, float widthScale, float gain) {
    float2 a = in.endpoints.xy, b = in.endpoints.zw, ab = b - a;
    float along = clamp(dot(in.point - a, ab) / max(0.0000001, dot(ab, ab)), 0.0, 1.0);
    float distance = length(in.point - (a + ab * along));
    float width = max(in.appearance.x * widthScale, 0.38 / u.viewport.y);
    float core = exp(-pow(distance / width, 2) * 2.5);
    float corona = exp(-pow(distance / (width * 3.2), 2)) * 0.10;
    float leader = smoothstep(in.appearance.z - 0.07, in.appearance.z + 0.035, u.clock.z);
    return (float3(1.0, 0.97, 0.95) * core + float3(0.30, 0.48, 1) * corona)
        * in.appearance.y * u.lightning.z * leader * in.visibility * gain;
}
fragment float4 lightningFragment(LightningVertex in [[stage_in]], constant Uniforms &u [[buffer(0)]], texture2d<float> clouds [[texture(3)]]) {
    float opacity = u.rendering.z > 0.5 ? clouds.sample(artwork,in.point / float2(u.viewport.w,1)).a : 0;
    return float4(lightningRadiance(in, u, 1, 3.5) * (1 - opacity * 0.65), 0);
}
fragment float4 lightningEmissionFragment(LightningVertex in [[stage_in]], constant Uniforms &u [[buffer(0)]], texture2d<float> clouds [[texture(3)]]) {
    float opacity = u.rendering.z > 0.5 ? clouds.sample(artwork,in.point / float2(u.viewport.w,1)).a : 0;
    return float4(lightningRadiance(in, u, 2.4, 4.0) * (1 - opacity * 0.65), 0);
}

struct ParticleVertex { float4 position [[position]]; float2 local; float alpha; float kind [[flat]]; float daylight; };
struct WidgetRainUniforms { float4 rect, options; };
struct WidgetRainLayout { float4 settings; WidgetRainUniforms areas[24]; }; // count, guide, animated, minimum top

struct RainDrop {
    float2 center, size;
    float depth, opacity, speed, seed, phase;
};
RainDrop rainDrop(uint instance, constant Uniforms &u) {
    float seed = float(instance);
    float a = hash21(float2(seed,1)), b = hash21(float2(seed,8));
    float variation = hash21(float2(seed,4));
    // Interleave layers so reducing the instance budget retains the same mix.
    uint layer = instance%10;
    float depth = layer < 6 ? mix(0.08,0.32,variation)
        : (layer < 9 ? mix(0.38,0.70,variation) : mix(0.78,1.0,variation));
    float speed = mix(0.20,1.45,depth*depth)*(0.82+0.36*hash21(float2(seed,19)));
    float wind = u.weather.w*u.celestial.w;
    float phase = timePhase(0.8/(2*M_PI_F),u)*2*M_PI_F+a*40;
    float y = fract(b+timePhase(speed/1.3,u))*1.3-0.15;
    float x = fract(a+windPhase(0.018,u)+y*wind*0.055+sin(phase)*0.002)*1.2-0.1;
    float width = max(0.45/u.viewport.y,mix(0.00018,0.00165,depth*depth));
    float length = mix(0.002,0.029,depth*depth)*(0.65+hash21(float2(seed,27))*0.7);
    float opacity = mix(0.045,0.42,depth*depth)*(0.65+hash21(float2(seed,32))*0.55);
    opacity *= (1-u.atmosphere.w*(1-depth)*0.65);
    return {float2(x,y),float2(width/u.viewport.w,length),depth,opacity,speed,a,phase};
}

// Select the FIRST rounded top crossed by this trajectory, independent of list
// order. Time at impact anchors the splash instead of sliding it with the rain.
float4 rainWidgetImpact(RainDrop drop, constant Uniforms &u, constant WidgetRainLayout &layout) {
    float wind = u.weather.w*u.celestial.w;
    float firstY = 2, firstX = 0;
    for (uint i = 0; i < uint(layout.settings.x); ++i) {
        float4 rect = layout.areas[i].rect;
        // A rounded top is never above rect.y. Keep list order and exact
        // intersection maths; only reject candidates that cannot win.
        if (rect.y >= firstY) continue;
        float radius = min(layout.areas[i].options.x,min(rect.z*u.viewport.w,rect.w)*0.5);
        float y = rect.y, x = 0;
        for (uint iteration = 0; iteration < 3; ++iteration) {
            float age = (drop.center.y+drop.size.y*0.7-y)/drop.speed;
            x = fract(drop.seed+windPhase(0.018,u)-wind*1.35*0.018*age+y*wind*0.055
                +sin(drop.phase-0.8*age)*0.002)*1.2-0.1;
            float dx = max(0.0,max(rect.x+radius/u.viewport.w-x,x-(rect.x+rect.z-radius/u.viewport.w)))*u.viewport.w;
            y = rect.y+radius-sqrt(max(0.0,radius*radius-dx*dx));
        }
        if (x >= rect.x && x <= rect.x+rect.z && y < firstY) { firstY = y; firstX = x; }
    }
    return float4(firstX,firstY,(drop.center.y+drop.size.y*0.7-firstY)/drop.speed,firstY < 2 ? 1 : 0);
}

vertex ParticleVertex particleVertex(uint vertexID [[vertex_id]], uint instance [[instance_id]],
    constant Uniforms &u [[buffer(0)]], constant uint &kind [[buffer(1)]],constant WidgetRainLayout &layout [[buffer(2)]]) {
    const float2 corners[] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 local = corners[vertexID];
    if (kind == 3) {
        WidgetRainUniforms widget = layout.areas[instance];
        float2 halfSize = widget.rect.zw*0.5;
        float2 offset = local*(halfSize+float2(2/u.viewport.x,2/u.viewport.y));
        float2 uv = widget.rect.xy+halfSize+offset;
        // Pass the area index through alpha; guides use no particle opacity.
        return {float4(uv.x*2-1,1-uv.y*2,0,1),offset*float2(u.viewport.w,1),float(instance),3,u.atmosphere.x};
    }
    if (kind == 5) {
        // Bounded camera-impact events: four small scattered beads per impact.
        float event = float(instance/4), child = float(instance%4);
        float a = hash21(float2(event,51)), b = hash21(float2(event,91));
        float age = fract(b+timePhase(0.10+a*0.08,u))/(0.10+a*0.08);
        float angle = child*2.399+event*1.7;
        float2 center = float2(a,b);
        center += float2(cos(angle)/u.viewport.w,sin(angle))*age*0.045;
        float size = (0.0008+a*0.0015)*(1+age);
        float2 uv = center+local*float2(size/u.viewport.w,size);
        return {float4(uv.x*2-1,1-uv.y*2,0,1),local,(1-smoothstep(0.03,0.32,age))*0.28,5,u.atmosphere.x};
    }
    if (kind == 0 || kind == 2) {
        // A small subset of rain seeds emit three larger secondary droplets.
        uint parent = kind == 2 ? (instance/6)*10+8+(instance/3)%2 : instance;
        RainDrop drop = rainDrop(parent,u);
        float2 center = drop.center, size = drop.size;
        float opacity = drop.opacity, outputKind = 0;
        // Fine distant rain belongs behind the widgets, preserving atmospheric
        // depth instead of leaving completely empty columns beneath every area.
        if (layout.settings.z > 0.5 && layout.settings.x > 0 && drop.depth >= 0.35
            && drop.center.y+drop.size.y*0.7 >= layout.settings.w) {
            float4 hit = rainWidgetImpact(drop,u,layout);
            if (hit.w > 0 && hit.z >= 0) {
                float child = kind == 2 ? float(instance%3)+1 : 0;
                float variation = hash21(float2(float(parent),child+41));
                float velocity = 0.10+variation*0.12;
                float lifetime = min(0.42,2*velocity/1.15);
                float direction = variation < 0.5 ? -1.0 : 1.0;
                center = hit.xy+float2((direction*(0.03+child*0.025)+u.weather.w*u.celestial.w*0.012)*hit.z/u.viewport.w,
                    -velocity*hit.z+0.575*hit.z*hit.z);
                float radius = (0.001+drop.depth*0.0012)*(child == 0 ? 1 : 0.65);
                size = float2(radius/u.viewport.w,radius);
                opacity = (0.15+drop.depth*0.36)*(1-smoothstep(lifetime*0.3,lifetime,hit.z));
                outputKind = 2;
                if (hit.z >= lifetime) opacity = 0;
            } else if (kind == 2) { opacity = 0; }
        } else if (kind == 2) { opacity = 0; }
        float2 uv = center+local*size;
        if (outputKind == 0) uv.x += local.y*size.y*u.weather.w*u.celestial.w*0.066;
        if (opacity <= 0) uv = float2(-10);
        return {float4(uv.x*2-1,1-uv.y*2,0,1),local,opacity,outputKind,u.atmosphere.x};
    }
    float seed = float(instance) + float(kind) * 1703;
    float a = hash21(float2(seed, 1)), b = hash21(float2(seed, 8));
    float depth = 0.15 + hash21(float2(seed, 4)) * 0.85;
    float2 center, size;
    center.y = fract(b + timePhase(0.018 + depth * 0.07, u)) * 1.2 - 0.1;
    float flutter = sin(timePhase((0.25 + depth * 0.4) / (2 * M_PI_F), u) * (2 * M_PI_F) + b * 30);
    center.x = fract(a + windPhase(0.032, u) + flutter * 0.025) * 1.2 - 0.1;
    float radius = 0.0007 + depth * depth * 0.005;
    size = float2(radius / u.viewport.w, radius);
    float2 uv = center + local * size;
    float opacity = 0.10 + depth * 0.48;
    if (u.rendering.z > 0.5) {
        opacity = 0.08 + depth * depth * 0.52;
        opacity *= 1 - u.atmosphere.w * 0.25;
    }
    return { float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), local, opacity, float(kind), u.atmosphere.x };
}
fragment float4 particleFragment(ParticleVertex in [[stage_in]],constant Uniforms &u [[buffer(0)]],
                                 constant WidgetRainLayout &layout [[buffer(2)]]) {
    if (in.kind > 2.5 && in.kind < 3.5) {
        WidgetRainUniforms widget = layout.areas[uint(in.alpha+0.5)];
        float2 halfSize = widget.rect.zw*float2(u.viewport.w,1)*0.5;
        float radius = min(widget.options.x,min(halfSize.x,halfSize.y));
        float2 q = abs(in.local)-halfSize+radius;
        float distance = length(max(q,0.0))+min(max(q.x,q.y),0.0)-radius;
        float outline = 1-smoothstep(0.7/u.viewport.y,2/u.viewport.y,abs(distance));
        return float4(0.15,0.8,1,outline*0.85);
    }
    float taper = mix(0.25,1.0,smoothstep(-1.0,0.55,in.local.y));
    float alpha = in.kind < 0.5
        ? exp(-pow(in.local.x/taper,2)*2.6)*smoothstep(-1.0,-0.25,in.local.y)*(1-smoothstep(0.65,1.0,in.local.y))
        : exp(-dot(in.local, in.local) * 2.6) * (1 - smoothstep(0.65, 1.0, length(in.local)));
    return float4(mix(float3(0.31, 0.43, 0.65), float3(0.86, 0.92, 1), in.daylight), alpha * in.alpha);
}

struct RainCompositeVertex { float4 position [[position]]; float2 uv; };
vertex RainCompositeVertex rainCompositeVertex(uint id [[vertex_id]]) {
    float2 p = float2(id == 1 ? 3 : -1,id == 2 ? 3 : -1);
    return {float4(p,0,1),float2((p.x+1)*0.5,(1-p.y)*0.5)};
}
fragment float4 rainCompositeFragment(RainCompositeVertex in [[stage_in]],texture2d<float> scene [[texture(0)]]) {
    return scene.sample(artwork,in.uv);
}

struct LensVertex {
    float4 position [[position]];
    float2 local, uv;
    float2 radius;
    float alpha;
};
vertex LensVertex lensVertex(uint vertexID [[vertex_id]],uint instance [[instance_id]],constant Uniforms &u [[buffer(0)]]) {
    const float2 corners[] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
    float seed = float(instance), a = hash21(float2(seed,61)), b = hash21(float2(seed,83));
    float rate = 0.035+a*0.055;
    float age = fract(b+timePhase(rate,u));
    float radius = (0.0012+pow(hash21(float2(seed,97)),3)*0.0055)*smoothstep(0.0,0.12,age);
    float slide = smoothstep(0.65,1.0,age)*step(0.72,a);
    float2 center = float2(hash21(float2(seed,103)),hash21(float2(seed,113)));
    center.y += slide*0.24;
    center.x += sin(age*4+a*30)*slide*0.005;
    float2 size = float2(radius/u.viewport.w,radius*(1+slide*1.8));
    float2 uv = center+corners[vertexID]*size;
    return {float4(uv.x*2-1,1-uv.y*2,0,1),corners[vertexID],uv,size,
        smoothstep(0.0,0.08,age)*(1-smoothstep(0.88,1.0,age))*min(1.0,u.weather.x*3)};
}
fragment float4 lensFragment(LensVertex in [[stage_in]],constant Uniforms &u [[buffer(0)]],texture2d<float> scene [[texture(0)]]) {
    float2 p = in.local;
    p.x *= 1+max(0.0,-p.y)*0.18; // A restrained tear shape, not perfect stamped disks.
    float r2 = dot(p,p);
    if (r2 >= 1) discard_fragment();
    float z = sqrt(max(0.001,1-r2));
    float2 offset = p*in.radius*(0.30+z*0.45);
    float3 refracted = scene.sample(artwork,in.uv+offset).rgb;
    float rim = pow(1-z,3);
    float highlight = exp(-dot(p+float2(0.34,0.40),p+float2(0.34,0.40))*65);
    float shade = exp(-dot(p-float2(0.30,0.48),p-float2(0.30,0.48))*18);
    float light = mix(0.10,0.40,u.atmosphere.x);
    refracted *= 1-shade*0.12;
    refracted += light*(highlight+rim*0.12);
    float edge = 1-smoothstep(1-max(fwidth(r2),0.02),1.0,r2);
    return float4(refracted,edge*in.alpha*(0.48+rim*0.30));
}
