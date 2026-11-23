// Test-only pre-filament field; substituted into the current renderer for paired review.
float cirrusDensityV2(float2 uv, constant AtmosphereUniforms &u, texture3d<float> noise) {
    float drift = boundedPhase(u.clock.x, u.viewport.z, 0.00003375)
        + boundedPhase(u.clock.y, u.options.z, 0.0007);
    float2 p = float2((uv.x - 0.5) * u.viewport.w, uv.y);
    float warp = noise.sample(volumeSampler, float3(p * 0.17, 0.6), level(0)).r;
    float3 q = float3(p.x * 0.23 + drift, p.y * 0.23 + warp * 0.16, 0.37);
    float broad = noise.sample(volumeSampler, q, level(0)).r;
    float3 featherCoords = float3(p.x * 0.17 + p.y * 0.12 + drift,p.y * 1.6 + warp * 0.45,0.82);
    float3 rippleCoords = float3(p * float2(2.3,2.9) + float2(drift * 1.7 + warp * 0.8 + broad * 0.4 + p.x * 0.4, warp * 0.6 + p.y * 0.2),
        0.82 + warp * 0.25 + broad * 0.15);
    float feather = noise.sample(volumeSampler,mix(featherCoords,rippleCoords,u.upperStyle.y),level(0)).r;
    float wisps = smoothstep(0.46,0.65,broad) * smoothstep(0.30,0.65,feather);
    float ripples = smoothstep(0.42,0.62,broad) * smoothstep(0.55,0.72,feather);
    float veil = smoothstep(0.20,0.65,broad) * (0.85 + feather * 0.15);
    float pattern = dot(float3(wisps * 0.42,ripples * 0.30,veil * 0.85),u.upperStyle.xyz);
    return pattern * (1 - smoothstep(0.38,0.85,uv.y)) * u.clouds.w;
}
