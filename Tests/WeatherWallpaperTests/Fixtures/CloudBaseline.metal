// Original pre-layer-profile volume path retained ONLY for paired performance tests.
// Uses the same shared noise, uniforms prefix and target dimensions; never ships in the app.
#include <metal_stdlib>
using namespace metal;
struct BUniforms {
    float4 viewport,atmosphere,weather,celestial,options,moon,moonLight,lightning,clock,clouds,rendering;
};
constexpr sampler bs(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
struct BVertex { float4 position [[position]]; float2 uv; };
vertex BVertex baselineVertex(uint id [[vertex_id]]) {
    float2 p = float2(id == 1 ? 3.0 : -1.0,id == 2 ? 3.0 : -1.0);
    return {float4(p,0,1),float2((p.x + 1) * 0.5,(1 - p.y) * 0.5)};
}
float bp(float coarse,float fine,float rate) { return fract(coarse * rate) + fine * rate; }
float3 bw(constant BUniforms &u,float scale) {
    return float3(bp(u.clock.y,u.options.z,0.003 * scale) + bp(u.clock.x,u.viewport.z,0.000162 * scale),0,0);
}
float bd(float3 p,constant BUniforms &u,texture3d<float> noise,thread float &structure) {
    structure = 0.5;
    float wet = u.clouds.z;
    float height = (p.y - 1.15) / mix(1.1,1.8,u.weather.z);
    if (height <= 0 || height >= 1) return 0;
    float3 wind = bw(u,1);
    float2 body = noise.sample(bs,p * float3(0.13,0.16,0.13) + wind + float3(0.37,0.12,0.29),level(0)).rg;
    float macro = noise.sample(bs,float3(p.x * 0.027,0.24,p.z * 0.027) + bw(u,0.3),level(1)).r;
    structure = body.g * 0.45 + macro * 0.55;
    float shape = body.r * 0.8 + macro * 0.2;
    float threshold = mix(0.72,0.23,u.clouds.x);
    threshold += height * height * mix(0.20,0.09,wet);
    threshold += (1 - smoothstep(0,0.12,height)) * 0.18;
    float density = max(0.0,shape - threshold);
    if (density <= 0) return 0;
    float detail = noise.sample(bs,p * 0.28 + wind,level(0)).g;
    density = max(0.0,density - (1 - detail) * 0.075 * (1 - wet * 0.6));
    return density * mix(38.0,28.0,wet) * (1 - smoothstep(0.76,1,height));
}
float bd(float3 p,constant BUniforms &u,texture3d<float> noise) { float unused; return bd(p,u,noise,unused); }
float bc(float2 uv,constant BUniforms &u,texture3d<float> noise) {
    float drift = bp(u.clock.x,u.viewport.z,0.00003375) + bp(u.clock.y,u.options.z,0.0007);
    float2 p = float2((uv.x - 0.5) * u.viewport.w,uv.y);
    float warp = noise.sample(bs,float3(p * 0.17,0.6),level(0)).r;
    float broad = noise.sample(bs,float3(p.x * 0.23 + drift,p.y * 0.23 + warp * 0.16,0.37),level(0)).r;
    float feather = noise.sample(bs,float3(p.x * 0.17 + p.y * 0.12 + drift,p.y * 1.6 + warp * 0.45,0.82),level(0)).r;
    return smoothstep(0.46,0.65,broad) * smoothstep(0.30,0.65,feather)
        * (1 - smoothstep(0.38,0.85,uv.y)) * u.clouds.w * 0.28;
}
fragment float4 baselineClouds(BVertex in [[stage_in]],constant BUniforms &u [[buffer(0)]],texture3d<float> noise [[texture(0)]]) {
    float3 ray = normalize(float3((in.uv.x - 0.5) * u.viewport.w * 1.45,(0.88 - in.uv.y) * 1.35,1.35));
    float day = u.atmosphere.x, twilight = u.atmosphere.y, wet = u.clouds.z;
    float3 ambient = mix(float3(0.007,0.013,0.030),float3(0.30,0.42,0.60),day);
    ambient = mix(ambient,float3(0.25,0.15,0.25),twilight * 0.55);
    float3 sun = mix(float3(1.9,0.58,0.22),float3(1.65,1.69,1.75),day);
    float3 lightDirection = normalize(float3((fract(u.celestial.x) - 0.5) * u.viewport.w,max(0.25,1 - u.celestial.y),-0.55));
    float trans = 1; float3 color = 0;
    if (ray.y > 0.055 && u.clouds.x > 0.075) {
        float enter = 1.15 / ray.y, exit = min(24.0,(1.15 + mix(1.1,1.8,u.weather.z)) / ray.y);
        uint count = uint(clamp(u.rendering.x,12.0,48.0));
        float stepLength = max(0.0,exit - enter) / float(count);
        float jitter = fract(dot(floor(in.position.xy),float2(0.75487766,0.56984029)));
        for (uint i = 0; i < count; i++) {
            float distance = enter + (float(i) + 0.35 + jitter * 0.3) * stepLength;
            float3 p = ray * distance; float structure;
            float density = bd(p,u,noise,structure) * (1 - smoothstep(12.0,24.0,distance));
            if (density < 0.002) continue;
            float h = saturate((p.y - 1.15) / mix(1.1,1.8,u.weather.z));
            float shadow = bd(p + lightDirection * 0.16,u,noise) * 0.55 + bd(p + lightDirection * 0.48,u,noise) * 0.45;
            float direct = exp(-shadow * 1.25) * (0.18 + h * 1.05);
            float silver = pow(max(0.0,dot(ray,-lightDirection)),12) * 0.28;
            float3 light = ambient * (0.65 + h * 0.70) + sun * (direct + silver) * (day * 0.9 + twilight * 0.30);
            light *= 1 - wet * 0.20 - u.weather.z * 0.20;
            float bankDetail = smoothstep(0.55,0.90,u.clouds.x) * (1 - u.atmosphere.w * 0.75);
            light *= 1 + (structure - 0.5) * 1.15 * bankDetail;
            float2 flash = (in.uv - float2(u.lightning.x,0.26)) * float2(u.viewport.w,1);
            light += float3(0.48,0.61,0.95) * u.lightning.z * exp(-dot(flash,flash) * 6);
            light = mix(light,ambient * 1.6,(1 - exp(-distance * 0.025)) * 0.52);
            float alpha = 1 - exp(-density * stepLength * (1.7 + u.clouds.y * 0.35));
            color += trans * alpha * light; trans *= 1 - alpha;
            if (trans < 0.012) break;
        }
    }
    float cirrus = bc(in.uv,u,noise);
    float3 iceLight = mix(float3(0.027,0.038,0.070),float3(1.0,1.17,1.37),day);
    iceLight = mix(iceLight,float3(0.65,0.32,0.28),twilight * 0.5);
    color += trans * cirrus * iceLight; trans *= 1 - cirrus;
    float fade = 1 - smoothstep(0.60,0.84,in.uv.y);
    return float4(color * fade,(1 - trans) * fade);
}
