// Original hybrid atmosphere renderer. No extracted Apple artwork or private APIs.
// Clouds integrate in a small linear-light target; the final sky stays full resolution.
#include <metal_stdlib>
using namespace metal;

// Specialize out the tower field for all ordinary cloud scenes, including their
// shadow probes. The second pipeline is created once, never in the frame loop.
constant bool convectionEnabled [[function_constant(0)]];
constant bool hasConvection = is_function_constant_defined(convectionEnabled) ? convectionEnabled : false;
constant bool volumeEnabled [[function_constant(2)]];
constant bool hasCloudVolume = is_function_constant_defined(volumeEnabled) ? volumeEnabled : true;
// 0: protected sheets/banks, 1: continuously mixed morphology, 2: full cumulus.
// Specialize once, not per frame; default mixed keeps source-only probes usable.
constant uint cloudBillowMode [[function_constant(3)]];
constant uint billowMode = is_function_constant_defined(cloudBillowMode) ? cloudBillowMode : 1;

struct AtmosphereUniforms {
    float4 viewport, atmosphere, weather, celestial, options;
    float4 moon, moonLight, lightning, clock, clouds, rendering; // moonLight.w = solar weather-glare permission
    float4 morphology, cloudStructure, upperStyle, convection, towerMetrics;
};
constexpr sampler volumeSampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
constexpr sampler atmosphereSampler(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler moonSamplerV2(coord::normalized, address::repeat, filter::linear, mip_filter::linear, max_anisotropy(8));

float3 noiseHash3(float3 p) {
    return fract(sin(float3(dot(p, float3(127.1,311.7,74.7)), dot(p, float3(269.5,183.3,246.1)),
                            dot(p, float3(113.5,271.9,124.6)))) * 43758.5453);
}
float periodicNoise(float3 p, float period) {
    float3 cell = floor(p), f = fract(p);
    f = f * f * (3 - 2 * f);
    float value = 0;
    for (int z = 0; z < 2; z++) for (int y = 0; y < 2; y++) for (int x = 0; x < 2; x++) {
        float3 corner = float3(x,y,z);
        float3 weight = mix(1 - f, f, corner);
        value += noiseHash3(fmod(cell + corner + period, period)).x * weight.x * weight.y * weight.z;
    }
    return value;
}
kernel void makeAtmosphereNoise(texture3d<float, access::write> output [[texture(0)]], uint3 id [[thread_position_in_grid]]) {
    if (any(id >= uint3(output.get_width(), output.get_height(), output.get_depth()))) return;
    float3 uv = (float3(id) + 0.5) / float(output.get_width());
    float3 p = uv * 8, cell = floor(p), f = fract(p);
    float nearest = 2;
    for (int z = -1; z <= 1; z++) for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        float3 offset = float3(x,y,z);
        float3 point = noiseHash3(fmod(cell + offset + 8, 8));
        nearest = min(nearest, length(offset + point - f));
    }
    float billow = 1 - saturate(nearest * 0.88);
    float low = periodicNoise(uv * 8, 8) * 0.57 + periodicNoise(uv * 16, 16) * 0.28
        + periodicNoise(uv * 32, 32) * 0.15;
    float detail = periodicNoise(uv * 16, 16) * 0.60 + periodicNoise(uv * 32, 32) * 0.40;
    output.write(float4(low * 0.45 + billow * 0.55, detail, 0, 1), id);
}

struct AtmosphereVertex { float4 position [[position]]; float2 uv; };
vertex AtmosphereVertex atmosphereVertex(uint id [[vertex_id]]) {
    float2 p = float2(id == 1 ? 3.0 : -1.0, id == 2 ? 3.0 : -1.0);
    return { float4(p, 0, 1), float2((p.x + 1) * 0.5, (1 - p.y) * 0.5) };
}
float boundedPhase(float coarse, float fine, float rate) { return fract(coarse * rate) + fine * rate; }
float2 celestialDeltaV2(float2 uv, float2 source) {
    return float2(fract(uv.x - source.x + 0.5) - 0.5, uv.y - source.y);
}
float3 viewRay(float2 uv, constant AtmosphereUniforms &u) {
    if (u.rendering.z < 1.5) {
        // Preserve the established artistic desktop framing. Crucially, source
        // lighting uses this SAME inverse screen map, not the old guessed vector.
        return normalize(float3((uv.x - 0.5) * u.viewport.w * 1.45,(0.88 - uv.y) * 1.35,1.35));
    }
    // Match WeatherCore.SkyProjection: a 360-degree azimuth panorama, horizon y=.97.
    float azimuth = uv.x * 2 * M_PI_F;
    float vertical = clamp((0.97 - uv.y) / 0.90,-1.0,1.0);
    float horizontal = sqrt(max(0.0,1 - vertical * vertical));
    return float3(sin(azimuth) * horizontal,vertical,cos(azimuth) * horizontal);
}
float3 lightDirectionV2(constant AtmosphereUniforms &u) {
    return viewRay(u.atmosphere.x > 0.02 ? u.celestial.xy : u.moon.xy,u);
}

float cloudBottomFade(float y) {
    // User-requested compositional fade. Zero before the ray/volume horizon cutoff.
    // Quintic endpoints have zero slope/curvature, unlike a clipped opacity slab.
    float t = saturate((y - 0.62) / 0.22);
    return 1 - t*t*t * (t * (t * 6 - 15) + 10);
}

float cloudSamplePhase(uint2 pixel) {
    // Full-stratum decorrelation, not the old linear diagonal pattern with 0.3-step span.
    uint h = pixel.x * 1973u + pixel.y * 9277u + 89173u;
    h = (h ^ (h >> 16)) * 0x7feb352du;
    h = (h ^ (h >> 15)) * 0x846ca68bu;
    return float(h & 0x00ffffffu) / 16777216.0;
}
float3 cloudWindV2(constant AtmosphereUniforms &u, float scale) {
    // Integrate movement in Swift, then use bounded coordinates in the periodic volume.
    return float3(boundedPhase(u.clock.y, u.options.z, 0.003 * scale)
        + boundedPhase(u.clock.x, u.viewport.z, 0.000162 * scale), 0, 0);
}
struct VolumeShapeSettings {
    float base, inverseDepth;
    float3 frequency, wind, macroWind;
    float macroWeight, threshold, topTaper, erosion, detailFrequency, densityGain, lod, distanceSparsity;
    float towerMass, summitSpread, deckCoverage, towerStepLOD, cumulusAmount, densityWidth;
    float4 towers[2]; // center x/z, height, radius; fixed bounded envelopes
    float2 towerInverse[2]; // inverse height/radius, hoisted out of ALL density probes
    float4 towerStyle[2]; // lean x/z, shoulder/turret height; stable per-envelope variation
};
VolumeShapeSettings volumeSettings(constant AtmosphereUniforms &u) {
    // Uniform-only work is explicit and outside all three density probes in the ray loop.
    VolumeShapeSettings s;
    s.base = u.morphology.x; s.inverseDepth = 1 / u.morphology.y;
    // Broad horizontal parent lobes and smaller vertical features, not upright cells.
    s.frequency = (u.rendering.z > 1.5 ? float3(0.035,0.12,0.035) : float3(0.13,0.16,0.13)) * u.morphology.z;
    // Store one world-space displacement; each frequency samples the same transported sky.
    s.wind = cloudWindV2(u,1) / 0.13; s.macroWind = s.wind * 0.027;
    s.macroWeight = mix(0.2,0.55,u.morphology.w);
    s.threshold = mix(mix(0.72,0.23,u.cloudStructure.z),mix(0.62,0.22,u.cloudStructure.z),u.morphology.w);
    s.topTaper = mix(mix(0.20,0.09,u.clouds.z),0.055,u.morphology.w);
    s.erosion = u.cloudStructure.x * (1 - u.clouds.z * 0.6);
    s.detailFrequency = 0.28 * u.morphology.z;
    s.densityGain = mix(u.cloudStructure.y,28.0,u.clouds.z);
    s.lod = 0;
    // A compositional distance bias for broken clouds, not a change to reported
    // weather cover. Never perforate an opaque/wet ceiling or a continuous sheet.
    s.distanceSparsity = (1-smoothstep(0.58,0.86,u.cloudStructure.z))
        * (1-u.cloudStructure.w) * (1-u.clouds.z) * (1-u.morphology.w);
    s.towerMass = hasConvection ? u.convection.x : 0;
    s.summitSpread = smoothstep(0.65,1.0,u.convection.y); s.deckCoverage = u.cloudStructure.z;
    s.towerStepLOD = 0;
    s.densityWidth = 0;
    // Broken billowing volumes only. Continuous sheets and wet/opaque ceilings
    // keep their established morphology, opacity and subdued lighting.
    s.cumulusAmount = billowMode == 2 ? 1 : (billowMode == 0 ? 0 :
        (1-smoothstep(0.25,0.65,u.morphology.w)) * (1-u.clouds.z) * (1-u.cloudStructure.w)
        * (1-smoothstep(0.72,0.92,u.cloudStructure.z)));
    if (s.towerMass > 0.001) {
        for (uint i = 0; i < 2; ++i) {
            float index = float(i);
            // Stable independent seeds, not per-frame randomness or extra texture
            // lookups. Slow bounded development varies the unequal silhouettes.
            float4 seed = i == 0 ? float4(0.19,0.77,0.34,0.86) : float4(0.82,0.23,0.71,0.31);
            float triangle = abs(fract(u.convection.z/(2*M_PI_F)+seed.w)*2-1);
            float growth = triangle*triangle*(3-2*triangle);
            s.towerStyle[i] = float4((seed.x-0.5)*2.2+growth*0.20,(seed.y-0.5)*1.1-growth*0.15,
                                    0.20+seed.z*0.08+growth*0.03,0.53+seed.w*0.12+growth*0.03);
            s.towers[i] = float4(-8.0+index*15.0+(seed.x-0.5)*3.5+u.convection.w*(0.65+seed.x*0.7),
                                16.0+index*4.0+(seed.y-0.5)*3.0,
                                u.towerMetrics[i],
                                (1.65+index*0.18)*1.35*(0.90+seed.z*0.20));
            s.towerInverse[i] = float2(u.towerMetrics[i+2],1/s.towers[i].w);
        }
    }
    return s;
}
float filteredCloudDensity(float value, float width) {
    // Exact average of max(0,x) over a bounded linear-density footprint. This
    // anti-aliases the transfer function inside the volume, not the final image.
    // Compact support: no infinite softplus haze or density outside the footprint.
    if (width <= 0.00001 || value >= width) return max(0.0,value);
    if (value <= -width) return 0;
    float t = value+width;
    return t*t/(4*width);
}
float deckDensityV2(float3 p, thread const VolumeShapeSettings &s, texture3d<float> noise, thread float &structure, const bool fullDetail) {
    structure = 0.5;
    if (s.deckCoverage <= 0.075) return 0;
    float height = (p.y - s.base) * s.inverseDepth;
    if (height <= 0 || height >= 1) return 0;
    // The macro slice drifts with height so large-scale structure can't terrace into
    // horizontal bands when the ray marches through the slab.
    float macro = noise.sample(volumeSampler,float3(p.x * 0.027,0.24 + p.y * 0.05,p.z * 0.027) + s.macroWind,level(1)).r;
    float3 warp = float3(macro - 0.5,0,(macro - 0.5) * 0.7) * 0.12;
    float2 body = noise.sample(volumeSampler,(p + s.wind) * s.frequency + warp + float3(0.37,0.12,0.29),level(s.lod)).rg;
    // Reuse already-fetched shape channels for broad underside relief, not extra noise work.
    structure = body.g * 0.45 + macro * 0.55;
    float shape = mix(body.r,macro,s.macroWeight);
    // Reuse the second body channel to vary the parent outline. Shadow probes
    // see this same irregular mass without another texture lookup per probe.
    shape += (body.g-0.5)*0.12*s.cumulusAmount;
    float threshold = s.threshold+s.cumulusAmount*0.018;
    // Flat condensation base, sculpted tops; wet banks fill in instead of scaling stamps.
    threshold += height * height * s.topTaper * (1+s.cumulusAmount*(0.5-macro));
    threshold += (1 - smoothstep(0, 0.12, height)) * (0.18-0.04*s.cumulusAmount);
    // Reuse the advected macro parent: remove weak remote fragments before erosion,
    // instead of fading every cloud into a translucent fog. No additional lookup.
    if (s.distanceSparsity > 0.001) {
        threshold += smoothstep(36.0,400.0,dot(p,p)) * s.distanceSparsity * (0.10+(1-macro)*0.08);
    }
    float density = max(0.0, shape - threshold);
    if (density <= 0) return 0;
    // Optical-depth probes integrate coarse mass; unresolved erosion does not need
    // another lookup at every light sample. The main ray retains edge detail.
    if (!fullDetail) return density * s.densityGain * (1 - smoothstep(0.76,1,height));
    if (s.cumulusAmount > 0.001) {
        // Connected medium-scale lobes sculpt the existing parent, not a noisy
        // skin around a smooth oval. Cannot create detached mass outside it.
        float3 q = (p+s.wind)*s.frequency*1.85 + warp
            + float3(0.13*body.g,0.31+macro*0.09,0.57);
        float2 billow = noise.sample(volumeSampler,q,level(s.lod+0.5)).rg;
        float support = smoothstep(0.0,0.025,density);
        density = max(0.0,density+(billow.r-0.58)*0.22*s.cumulusAmount)*mix(1.0,support,s.cumulusAmount);
        structure = mix(structure,saturate((billow.r-0.58)*2.2+body.g*0.30+0.35),s.cumulusAmount*0.80);
    }
    // Only the boundary needs small erosion: dense interiors retain broad soft
    // variation from the body/billow channels instead of another noisy octave.
    float detail = 0.5;
    if (s.cumulusAmount < 0.999 || density < s.erosion*2.2+0.035) {
        detail = noise.sample(volumeSampler,(p+s.wind)*s.detailFrequency,level(s.lod+0.5+s.cumulusAmount*0.65)).g;
    }
    density -= (1-detail)*s.erosion*(1-s.cumulusAmount*0.30)+s.cumulusAmount*0.020;
    density = filteredCloudDensity(density,s.densityWidth*s.cumulusAmount);
    // In cumulus the former finest erosion lookup is replaced by the connected
    // billow lookup above; do not spend it again on unresolved edge crumbling.
    if (s.cumulusAmount < 0.999) {
        // High-frequency cauliflower carve on the main probe only; shadow probes skip it.
        float fine = noise.sample(volumeSampler,(p + s.wind) * s.detailFrequency * 2.7 + float3(0.11,0.07,0.53),level(s.lod + 1)).g;
        // Erosion cannot manufacture disconnected density outside the coarse parent.
        density *= smoothstep(0.0,s.erosion * 0.7 + 0.001,density);
        density = max(0.0,density - (1-fine)*s.erosion*0.45*(1-s.cumulusAmount));
    }
    float baseEdge = mix(1.0,smoothstep(0.0,0.035,height),s.cumulusAmount);
    return density * s.densityGain * (1 - smoothstep(0.76,1,height)) * baseEdge;
}

float3 towerBoundRadiusV2(float4 tower) { return float3(tower.w*2.25,tower.z*0.76,tower.w*1.60); }
float3 towerBoundCenterV2(thread const VolumeShapeSettings &s, uint index) {
    return float3(s.towers[index].x+s.towerStyle[index].x*0.5,s.base+s.towers[index].z*0.48,
                  s.towers[index].y+s.towerStyle[index].y*0.5);
}
float cloudDensityV2(float3 p, thread const VolumeShapeSettings &s, texture3d<float> noise,
                     thread float &structure, thread float &towerAmount, const bool fullDetail) {
    float density = deckDensityV2(p,s,noise,structure,fullDetail);
    float deck = density, towers = 0;
    towerAmount = 0;
    if (s.towerMass <= 0.001) return density;
    // Condensation bases and continuous tilted columns, not stacked sphere stamps.
    // Analytic bounds reject empty space before any tower texture fetches.
    for (uint i = 0; i < 2; ++i) {
        float4 tower = s.towers[i];
        if (any(abs(p-towerBoundCenterV2(s,i)) > towerBoundRadiusV2(tower))) continue;
        float h = (p.y - s.base) * s.towerInverse[i].x;
        if (h <= 0 || h >= 1) continue;
        float4 style = s.towerStyle[i];
        float side = i == 0 ? 1.0 : -1.0;
        float2 local = p.xz - tower.xy - style.xy*h*h;
        float2 normalized = local * s.towerInverse[i].y;
        float radius = 0.72 + 0.20 * smoothstep(0.08,0.55,h);
        // A restrained spreading, fibrous summit only in developing Cb.
        radius *= 1 + s.summitSpread * smoothstep(0.65,0.9,h) * 0.30;
        float3 envelope = float3(normalized.x / radius,(h-0.42)/0.58,normalized.y/(radius*0.82));
        float radial = dot(envelope,envelope);
        // Unequal connected shoulders/turrets break the oval silhouette. These are
        // one continuous parent field with shared erosion, not separate ray passes
        // or a vertical stack of repeated spheres.
        float3 shoulder = float3((normalized.x*side+0.65)/(i == 0 ? 0.92 : 0.70),(h-style.z)/0.34,(normalized.y+0.08)/0.68);
        float3 turret = float3((normalized.x*side-0.48)/(i == 0 ? 0.58 : 0.76),(h-style.w)/0.34,(normalized.y-0.12)/0.62);
        radial = min(radial,min(dot(shoulder,shoulder),dot(turret,turret)));
        if (radial > 1.38) continue;
        float3 q = float3(local.x*side,p.y-s.base,local.y) * (i == 0 ? float3(0.25,0.21,0.28) : float3(0.30,0.19,0.24))
            + float3(float(i)*0.31,0.17,0.43);
        // Tower noise has a higher world frequency than the foreground. Filter
        // both its pixel footprint and unresolved main-ray segment detail.
        float towerLOD = min(3.0,max(s.lod+1.15,s.towerStepLOD));
        float2 billow = noise.sample(volumeSampler,q,level(towerLOD)).rg;
        // Large connected cauliflower lobes deform the entire flank, not just a
        // fuzzy outline around an otherwise smooth ellipsoid.
        float parent = (1 - radial) * 0.45 + (billow.r - 0.48) * 1.30 + (billow.g - 0.5) * 0.30;
        if (parent <= 0) continue;
        float mass = parent;
        if (fullDetail) {
            float detail = noise.sample(volumeSampler,q * 2.8 + 0.31,level(towerLOD + 0.5)).g;
            mass = filteredCloudDensity(parent-(1-detail)*0.16,s.densityWidth*1.5);
            mass *= smoothstep(0.0,0.10,parent); // retain the parent support
        }
        mass *= smoothstep(0,0.07,h) * (1 - smoothstep(0.94,1.0,h)) * smoothstep(0.0,0.25,1.38-radial);
        float towerDensity = mass * smoothstep(0.0,0.18,parent) * 4.5 * s.towerMass;
        towers = max(towers,towerDensity);
        if (towerDensity > density) { density = towerDensity; structure = billow.r*0.65 + billow.g*0.35; }
    }
    towerAmount = towers / max(0.001,deck+towers);
    return density;
}
float cloudDensityV2(float3 p, thread const VolumeShapeSettings &s, texture3d<float> noise, const bool fullDetail) {
    float unused, towerAmount;
    return cloudDensityV2(p,s,noise,unused,towerAmount,fullDetail);
}

// Midpoint quadrature along the actual path to the source, not a density average.
float cloudLightDepth(float3 p, float3 toLight, thread const VolumeShapeSettings &s,
                       texture3d<float> noise, uint samples, float towerAmount = 0) {
    if (toLight.y <= 0.001) return 12.0;
    float ceiling = s.base + 1 / s.inverseDepth;
    if (s.towerMass > 0.001) ceiling = mix(ceiling,max(ceiling,s.base+max(s.towers[0].z,s.towers[1].z)),towerAmount);
    // Shorter surface probes resolve the tower billows instead of reducing every
    // interior to the same flat self-shadow; multiple scattering supplies deep fill.
    // Local tower contribution, not a scene-wide switch: adding a distant tower
    // must not change the probe length/shading of ordinary foreground clouds.
    float length = clamp((ceiling - p.y) / toLight.y,0.0,mix(4.0,1.4,towerAmount));
    // Towers already have short local surface probes; retain their established
    // spacing. Bias only the broad foreground probes toward nearby billows.
    float local = s.cumulusAmount*(1-towerAmount);
    if (samples == 2) {
        // Explicit default pair: same two lookups, no per-probe division/loop.
        // At local=0 this is the original midpoint rule for protected decks.
        float nearLength = length*mix(0.5,0.25,local);
        return cloudDensityV2(p+toLight*(nearLength*0.5),s,noise,false)*nearLength
            + cloudDensityV2(p+toLight*((nearLength+length)*0.5),s,noise,false)*(length-nearLength);
    }
    float depth = 0;
    for (uint j = 0; j < samples; ++j) {
        // Front-loaded quadrature resolves local billow shadows using the SAME
        // two probes, rather than spending both far beyond the nearby surface.
        float a = float(j)/float(samples), b = float(j+1)/float(samples);
        float begin = mix(a,a*a,local)*length, end = mix(b,b*b,local)*length;
        depth += cloudDensityV2(p+toLight*((begin+end)*0.5),s,noise,false)*(end-begin);
    }
    return depth;
}

// Small world-space cache of LIGHT depth only. Main-ray density/opacity is never
// reconstructed from this grid. Refreshed on every rendered cloud frame, no history.
kernel void makeCloudLightDepth(texture3d<half,access::write> output [[texture(0)]],
                               texture3d<float> noise [[texture(1)]],
                               constant AtmosphereUniforms &u [[buffer(0)]],uint3 id [[thread_position_in_grid]]) {
    uint3 size = uint3(output.get_width(),output.get_height(),output.get_depth());
    if (any(id >= size)) return;
    VolumeShapeSettings settings = volumeSettings(u);
    float3 uvw = (float3(id)+0.5)/float3(size);
    float3 p = float3((uvw.x-0.5)*24,settings.base+uvw.y/settings.inverseDepth,(uvw.z-0.5)*24);
    float depth = cloudLightDepth(p,lightDirectionV2(u),settings,noise,u.rendering.x >= 96 ? 4 : 2);
    output.write(half4(half(depth),0,0,0),id);
}

float sampleCloudLight(float3 p, float3 toLight, thread const VolumeShapeSettings &s,
                       texture3d<float> noise, texture3d<half> cache,constant AtmosphereUniforms &u,uint samples,float towerAmount) {
    if (u.upperStyle.w > 0.5 && max(abs(p.x),abs(p.z)) < 12) {
        float3 uvw = float3(p.x/24+0.5,(p.y-s.base)*s.inverseDepth,p.z/24+0.5);
        float value = float(cache.sample(atmosphereSampler,uvw,level(0)).r);
        float edge = smoothstep(11.0,12.0,max(abs(p.x),abs(p.z)));
        if (edge <= 0) return value;
        return mix(value,cloudLightDepth(p,toLight,s,noise,samples,towerAmount),edge);
    }
    return cloudLightDepth(p,toLight,s,noise,samples,towerAmount);
}

float cloudPhase(float cosine) {
    // HG relative to isotropic scattering (4*pi convention), bounded broad fill.
    float g = 0.58;
    float forward = (1 - g*g) / pow(max(0.01,1 + g*g - 2*g*cosine),1.5);
    return 0.70 + 0.30 * forward;
}

float4 towerRayIntervals(float3 ray, thread const VolumeShapeSettings &s) {
    float4 intervals = float4(64,0,64,0);
    for (uint i = 0; i < 2; ++i) {
        float4 t = s.towers[i];
        // Conservative ellipsoid includes support-preserving noise, shear and the
        // slight Cb summit spread, but rejects much more empty space than a box.
        float3 radius = towerBoundRadiusV2(t);
        float3 center = towerBoundCenterV2(s,i);
        float3 origin = -center/radius, direction = ray/radius;
        float a = dot(direction,direction), b = dot(origin,direction);
        float discriminant = b*b-a*(dot(origin,origin)-1);
        if (discriminant < 0) continue;
        float root = sqrt(discriminant);
        // The density is identically zero outside its condensation base/top.
        float entry = max(s.base/ray.y,(-b-root)/a);
        float exit = min(min(64.0,(s.base+t.z)/ray.y),(-b+root)/a);
        if (exit > entry) {
            if (i == 0) intervals.xy = float2(entry,exit);
            else intervals.zw = float2(entry,exit);
        }
    }
    if (intervals.z < intervals.x) intervals = intervals.zwxy;
    if (intervals.z <= intervals.y) { intervals.y = max(intervals.y,intervals.w); intervals.zw = float2(64,0); }
    return intervals;
}

struct CloudRayPlan {
    float2 intervals[3];
    uint samples[3];
    bool foreground[3];
    uint count;
};
CloudRayPlan compositeCloudRayPlan(float2 deck, float4 towers, uint budget) {
    float2 candidates[3] = {deck,towers.xy,towers.zw};
    for (uint i = 1; i < 3; ++i) {
        for (uint j = i; j > 0; --j) {
            if (candidates[j].x < candidates[j-1].x) {
                float2 t = candidates[j]; candidates[j] = candidates[j-1]; candidates[j-1] = t;
            }
        }
    }
    CloudRayPlan plan; plan.count = 0;
    for (uint i = 0; i < 3; ++i) {
        if (candidates[i].y <= candidates[i].x) continue;
        if (plan.count > 0 && candidates[i].x <= plan.intervals[plan.count-1].y) {
            plan.intervals[plan.count-1].y = max(plan.intervals[plan.count-1].y,candidates[i].y);
        } else { plan.intervals[plan.count++] = candidates[i]; }
    }
    float weights[3], backgroundLength = 0;
    for (uint i = 0; i < plan.count; ++i) {
        plan.foreground[i] = plan.intervals[i].x <= deck.y && plan.intervals[i].y >= deck.x;
        weights[i] = plan.intervals[i].y-plan.intervals[i].x;
        if (!plan.foreground[i]) backgroundLength += weights[i];
    }
    float totalWeight = 0;
    for (uint i = 0; i < plan.count; ++i) {
        // Roughly half the budget goes to a separate foreground interval. The
        // previous union-span allocation wasted it on the gap and speckled edges.
        if (plan.foreground[i]) weights[i] = max(weights[i],backgroundLength);
        totalWeight += weights[i];
    }
    uint remaining = budget;
    for (uint i = 0; i < plan.count; ++i) {
        uint reserved = plan.count-i-1;
        plan.samples[i] = i+1 == plan.count ? remaining : uint(clamp(round(float(budget)*weights[i]/max(0.001,totalWeight)),1.0,float(remaining-reserved)));
        remaining -= plan.samples[i];
    }
    return plan;
}

float cirrusDensityV2(float2 uv, constant AtmosphereUniforms &u, texture3d<float> noise) {
    float drift = boundedPhase(u.clock.x, u.viewport.z, 0.00003375)
        + boundedPhase(u.clock.y, u.options.z, 0.0007);
    // Transport the WHOLE hierarchy together; warps must not remain screen-fixed
    // while their filaments drift through them. Shared mipmapped field, no new asset.
    float2 p = float2((uv.x - 0.5) * u.viewport.w + drift * 3.0, uv.y);
    float lod = max(0.0,log2(max(1.0,128 * 3.2 * u.rendering.y / u.viewport.y)));
    float2 warp = noise.sample(volumeSampler, float3(p * 0.17, 0.6), level(lod)).rg;
    float3 q = float3(p.x * 0.23, p.y * 0.23 + warp.x * 0.16, 0.37);
    float2 patch = noise.sample(volumeSampler, q, level(lod)).rg;
    float broad = patch.x;
    // Ice is a screen-field approximation: horizon/scale proxy, not claimed 3D depth.
    float remote = smoothstep(0.32,0.76,uv.y);
    float wispThreshold = 0.46 + remote*0.075, rippleThreshold = 0.42 + remote*0.065;
    if ((u.upperStyle.x <= 0 || broad <= wispThreshold) && (u.upperStyle.y <= 0 || broad <= rippleThreshold)
        && (u.upperStyle.z <= 0 || broad <= 0.20)) return 0;
    float2 curved = float2(p.x * 0.45 + p.y * 0.12,
                          p.y * 1.6 + (warp.x-0.5) * 0.32 + (patch.y-0.5) * 0.22 + p.x * 0.18);
    float3 featherCoords = float3(curved,0.82 + warp.y * 0.06);
    float3 rippleCoords = float3(p * float2(2.3,2.9) + float2(warp.x * 0.8 + broad * 0.4 + p.x * 0.4, warp.x * 0.6 + p.y * 0.2),
        0.82 + warp.x * 0.25 + broad * 0.15);
    // The same third lookup supplies wisps, tiny high ripples or a veil. Never one pass per genus.
    float2 fiber = noise.sample(volumeSampler,mix(featherCoords,rippleCoords,u.upperStyle.y),level(lod)).rg;
    float feather = fiber.x;
    // One selective fine-field lookup breaks the feather into fibers of differing
    // lengths; no dedicated texture, generation or target is needed.
    float fine = fiber.y;
    if (u.upperStyle.x > 0.001 && broad > wispThreshold && feather > 0.32 && patch.y > 0.36) {
        fine = noise.sample(volumeSampler,float3(curved * float2(1.8,2.6),0.28),level(lod + 0.5)).g;
    }
    float strands = smoothstep(0.40,0.67,fine);
    float taper = smoothstep(0.37,0.62,feather) * smoothstep(0.36,0.60,patch.y);
    float wisps = smoothstep(wispThreshold,0.66+remote*0.04,broad) * smoothstep(0.32,0.60,feather)
        * (0.20 + strands * taper * 0.80);
    float ripples = smoothstep(rippleThreshold,0.62+remote*0.04,broad) * smoothstep(0.55,0.72,feather);
    float veil = smoothstep(0.20,0.65,broad) * (0.85 + feather * 0.15);
    float pattern = dot(float3(wisps * 0.42,ripples * 0.30,veil * 0.85),u.upperStyle.xyz);
    return pattern * (1 - smoothstep(0.38,0.85,uv.y)) * u.clouds.w;
}

inline __attribute__((always_inline)) float4 integrateCloudsV2(float2 uv, float2 pixel, constant AtmosphereUniforms &u,
                         texture3d<float> noise, texture3d<half> lightDepth,
                         thread float &meanDepth, const bool captureDepth) {
    meanDepth = 0;
    float bottomFade = cloudBottomFade(uv.y);
    if (bottomFade <= 0) return float4(0);
    float3 ray = viewRay(uv, u);
    float day = u.atmosphere.x, twilight = u.atmosphere.y, wet = u.clouds.z;
    float moonlight = saturate(u.moon.z * u.celestial.z);
    half3 ambient = half3(mix(float3(0.007,0.013,0.030) * (0.25 + moonlight * 0.75), float3(0.30,0.42,0.60), day));
    ambient = half3(mix(float3(ambient), float3(0.25,0.15,0.25), twilight * 0.55));
    half3 towerAmbient = half3(mix(float3(0.008,0.011,0.016) * (0.25 + moonlight * 0.75),float3(0.38,0.41,0.46),day));
    towerAmbient = mix(towerAmbient,half3(0.25,0.15,0.25),half(twilight * 0.55));
    float3 sunColor = mix(float3(1.9,0.58,0.22), float3(1.65,1.69,1.75), day);
    float3 direction = lightDirectionV2(u);
    float extinction = 1.7 + u.clouds.y * 0.35;
    float phase = cloudPhase(dot(ray,direction));
    float lightGain = (1 - wet * 0.20 - u.weather.z * 0.20) * (1 + twilight * 0.15);
    half3 directColor = half3(mix(float3(0.045,0.060,0.09) * moonlight,sunColor,day)
        * (day * 0.8 + twilight * 0.22 + moonlight * (1-day)));
    float bankDetail = smoothstep(0.55,0.90,u.clouds.x) * (1 - u.atmosphere.w * 0.75);
    float2 flashDelta = (uv - float2(u.lightning.x, 0.26)) * float2(u.viewport.w, 1);
    half3 flashLight = half3(float3(0.48,0.61,0.95) * u.lightning.z);
    if (u.lightning.z > 0.001) flashLight *= half(exp(-dot(flashDelta,flashDelta) * 6));
    float overcast = smoothstep(0.50,1.0,u.cloudStructure.z);
    float3 horizonLight = mix(float3(0.012,0.021,0.048),float3(0.25,0.53,0.83),day);
    horizonLight = mix(horizonLight,mix(float3(0.023,0.032,0.049),float3(0.39,0.47,0.55),day),overcast);
    horizonLight = mix(horizonLight,float3(1.05,0.29,0.11),twilight * (1 - overcast * 0.65));
    horizonLight *= 1 - wet * 0.16 - u.weather.z * 0.24;
    half3 scatteredHorizon = half3(horizonLight);
    float footprintScale = 2 * M_PI_F * 128 * 0.13 * u.morphology.z * u.rendering.y / u.viewport.x;
    float transmittance = 1;
    float3 radiance = 0;
    if (hasCloudVolume && ray.y > 0.018 && (u.cloudStructure.z > 0.075 || u.convection.x > 0.001)) {
        VolumeShapeSettings settings = volumeSettings(u);
        float enter = u.morphology.x / ray.y;
        float exit = min(64.0,(u.morphology.x + u.morphology.y) / ray.y);
        float2 deckInterval = float2(enter,exit);
        CloudRayPlan composite; composite.count = 0;
        // Adaptive within the existing caps: broken clouds cost fewer steps than overcast.
        // Thin clouds need stable integration, not the old 16-step quality cliff.
        // Battery retains its existing 20-step ceiling; reference fixtures may converge higher.
        float adaptiveSteps = mix(min(20.0,u.rendering.x),u.rendering.x,smoothstep(0.10,0.55,u.cloudStructure.z));
        uint count = uint(clamp(adaptiveSteps, 12.0, 256.0));
        float2 priority = float2(64,0);
        float4 occupied = float4(64,0,64,0);
        bool towerHit = false;
        bool splitTowers = false;
        uint firstTowerCount = 0;
        uint beforeCount = 0, towerCount = 0;
        if (settings.towerMass > 0.001) {
            occupied = towerRayIntervals(ray,settings);
            priority = float2(occupied.x,max(occupied.y,occupied.w));
            towerHit = priority.y > priority.x;
            if (towerHit) {
                if (settings.deckCoverage <= 0.075) { enter = priority.x; exit = priority.y; }
                else { enter = min(enter,priority.x); exit = max(exit,priority.y); }
                count = uint(clamp(u.rendering.x,12.0,256.0));
                // Spend the SAME capped sample budget near the bounded towers,
                // rather than undersampling them across a 64-unit empty horizon.
                towerCount = uint(float(count) * 0.65);
                float outside = (priority.x-enter) + (exit-priority.y);
                beforeCount = uint(round(float(count-towerCount) * (priority.x-enter) / max(0.001,outside)));
                if (outside < 0.001) { towerCount = count; beforeCount = 0; }
                // Only skip a gap when NO foreground volume can occupy it.
                splitTowers = settings.deckCoverage <= 0.075 && occupied.w > occupied.z;
                if (splitTowers) {
                    float lengthA = occupied.y-occupied.x, lengthB = occupied.w-occupied.z;
                    firstTowerCount = uint(clamp(round(float(count)*lengthA/(lengthA+lengthB)),1.0,float(count-1)));
                }
                if (settings.deckCoverage > 0.075) composite = compositeCloudRayPlan(deckInterval,occupied,count);
            } else if (settings.deckCoverage <= 0.075) {
                count = 0; // No volume on this ray. Still composite any high ice below.
            }
        }
        // Static subpixel phase: no frame-random noise, temporal trails or history buffers.
        // Static decorrelated phase; no frame-random noise or temporal history.
        float jitter = cloudSamplePhase(uint2(pixel));
        float deckPhase = jitter; // Full stratum avoids coherent horizontal bands.
        uint lightSamples = u.rendering.x >= 96 ? 4 : 2;
        for (uint i = 0; i < count; i++) {
            float begin = enter, end = exit;
            uint segmentCount = count, index = i;
            float samplePhase = towerHit ? mix(0.5,jitter,0.35) : deckPhase;
            if (composite.count > 0) {
                uint segment = 0;
                while (segment+1 < composite.count && index >= composite.samples[segment]) {
                    index -= composite.samples[segment++];
                }
                begin = composite.intervals[segment].x; end = composite.intervals[segment].y;
                segmentCount = composite.samples[segment];
                if (composite.foreground[segment]) samplePhase = deckPhase;
            } else if (splitTowers) {
                if (i < firstTowerCount) { begin = occupied.x; end = occupied.y; segmentCount = firstTowerCount; }
                else { begin = occupied.z; end = occupied.w; segmentCount = count-firstTowerCount; index -= firstTowerCount; }
            } else if (towerHit) {
                if (i < beforeCount) { end = priority.x; segmentCount = beforeCount; }
                else if (i < beforeCount+towerCount) {
                    begin = priority.x; end = priority.y; segmentCount = towerCount; index -= beforeCount;
                } else {
                    begin = priority.y; segmentCount = count-beforeCount-towerCount; index -= beforeCount+towerCount;
                }
            }
            float stepLength = max(0.0,end-begin) / float(max(1u,segmentCount));
            settings.densityWidth = min(0.025,stepLength*0.05);
            float distance = begin + (float(index) + samplePhase) * stepLength;
            float3 p = ray * distance;
            // Filter noise by ray footprint, before it aliases into horizon speckles/stripes.
            float footprint = distance * footprintScale;
            settings.lod = footprint > 1 ? min(log2(footprint),4.0) : 0;
            if (settings.cumulusAmount > 0.001 || towerHit) {
                // Filter detail the ray cannot integrate, not the entire cloud
                // image. Preserve low-frequency billows and sharp near contours.
                float stepFootprint = stepLength*128*0.13*0.30;
                if (stepFootprint > 1) {
                    float stepLOD = min(log2(stepFootprint),2.0);
                    settings.lod = max(settings.lod,stepLOD*max(settings.cumulusAmount,towerHit ? 1.0 : 0.0));
                }
            }
            if (towerHit) {
                settings.towerStepLOD = clamp(log2(max(1.0,stepLength*128*0.29))-1.0,0.0,2.5);
            }
            float structure, towerAmount;
            float density = cloudDensityV2(p,settings,noise,structure,towerAmount,true) * (1 - smoothstep(40.0,64.0,distance));
            // Retain the established small-mass early-out in nearly empty samples.
            if (density < 0.002) continue;
            float depth = 1 / settings.inverseDepth;
            if (settings.towerMass > 0.001) depth = mix(depth,max(depth,max(settings.towers[0].z,settings.towers[1].z)),towerAmount);
            float h = saturate((p.y - settings.base) / depth);
            float opticalDepth = sampleCloudLight(p,direction,settings,noise,lightDepth,u,lightSamples,towerAmount) * extinction;
            float direct = exp(-opticalDepth);
            float multiple = 0.14 * exp(-opticalDepth * 0.22);
            float billowing = max(settings.cumulusAmount,towerAmount);
            float skyAccess = mix(0.38,0.30,billowing) + mix(0.62,0.70,billowing)*sqrt(h);
            // Local lighting is stored in half precision to reduce Apple GPU register
            // pressure. Density, optical depth, transmittance and accumulation stay float.
            half3 light = mix(ambient,towerAmbient,half(towerAmount)) * half(skyAccess)
                + directColor * half(direct * phase + multiple);
            light *= half(lightGain);
            // A restrained tonal ceiling remains visible even when the slab is opaque.
            // No extra puff layers, texture samples, targets or full-screen noise octaves.
            light *= half(1 + (structure-0.5)*1.55*max(bankDetail,max(settings.cumulusAmount*0.65,towerAmount*0.85)));
            // Restrained silver lining: only thin, directly lit density facing
            // the source. No screen-space outline, extra gradient probes or pass.
            float lining = (1-saturate(density*0.35))*direct*max(0.0,phase-1.0)*0.16
                * billowing * (0.25+0.75*h);
            light += directColor*half(lining);
            light += flashLight;
            // Distance haze softens remote cloud banks without blurring foreground edges.
            // Keep close billows crisp/contrasty, while distant decks and remote
            // towers settle into the atmosphere. Same single analytic haze term.
            float hazeDistance = max(0.0,distance-2*settings.cumulusAmount*(1-towerAmount));
            float haze = 1-exp(-hazeDistance*mix(mix(0.11,0.10,settings.cumulusAmount),0.026,towerAmount));
            light = mix(light,scatteredHorizon,half(haze));
            float alpha = 1 - exp(-density * stepLength * extinction);
            radiance += transmittance * alpha * float3(light);
            if (captureDepth) meanDepth += transmittance * alpha * distance;
            transmittance *= 1 - alpha;
            if (transmittance < 0.012) break;
        }
    }
    if (captureDepth) meanDepth /= max(0.0001,1-transmittance);
    transmittance *= 1 - u.cloudStructure.w * smoothstep(0.90,0.985,1 - transmittance);
    if (u.clouds.w > 0.001 && transmittance > 0.02) {
        float cirrus = cirrusDensityV2(uv,u,noise);
        float3 iceLight = mix(float3(0.027,0.034,0.046) * moonlight,float3(1.0,1.17,1.37),day);
        // Elevated ice remains sunlit briefly at twilight, but never glows on a
        // moonless dark night. Restrained source-aligned forward scattering.
        iceLight = mix(iceLight,float3(0.78,0.40,0.30),twilight * 0.65);
        iceLight *= 0.85 + 0.15 * cloudPhase(dot(ray,direction));
        radiance += transmittance * cirrus * iceLight;
        transmittance *= 1 - cirrus;
    }
    // The float target holds physical scattering/opacity, never display dither.
    // Fade premultiplied scattering AND opacity together, so there is no dark/color rim.
    return float4(max(0.0,radiance),saturate(1 - transmittance)) * bottomFade;
}

fragment float4 volumeCloudFragment(AtmosphereVertex in [[stage_in]], constant AtmosphereUniforms &u [[buffer(0)]],
                                   texture3d<float> noise [[texture(0)]],texture3d<half> lightDepth [[texture(1)]]) {
    float unused;
    return integrateCloudsV2(in.uv,in.position.xy,u,noise,lightDepth,unused,false);
}

struct CloudHistoryOutput {
    float4 color [[color(0)]];
    float depth [[color(1)]];
};
fragment CloudHistoryOutput cloudHistoryFragment(AtmosphereVertex in [[stage_in]], constant AtmosphereUniforms &u [[buffer(0)]],
                                                 texture3d<float> noise [[texture(0)]],texture3d<half> lightDepth [[texture(1)]]) {
    float depth;
    float4 color = integrateCloudsV2(in.uv,in.position.xy,u,noise,lightDepth,depth,true);
    return { color, depth };
}

// One fresh cloud image only, never a feedback blend or a library of finished skies.
// Invalid/disoccluded pixels are integrated freshly, preserving the capped sample quality.
fragment float4 reprojectCloudFragment(AtmosphereVertex in [[stage_in]], constant AtmosphereUniforms &u [[buffer(0)]],
                                       constant AtmosphereUniforms &previous [[buffer(1)]],
                                       texture3d<float> noise [[texture(0)]],texture3d<half> lightDepth [[texture(1)]],
                                       texture2d<float> history [[texture(2)]],texture2d<float> depths [[texture(3)]]) {
    if (cloudBottomFade(in.uv.y) <= 0) return float4(0);
    float2 oldUV = in.uv;
    bool valid = true;
    if (!hasCloudVolume) {
        // Exact screen-field transport for high-only ice (no lower-cloud parallax).
        float nowDrift = boundedPhase(u.clock.x,u.viewport.z,0.00003375) + boundedPhase(u.clock.y,u.options.z,0.0007);
        float oldDrift = boundedPhase(previous.clock.x,previous.viewport.z,0.00003375) + boundedPhase(previous.clock.y,previous.options.z,0.0007);
        oldUV.x += 3 * (nowDrift-oldDrift) / u.viewport.w;
    } else {
        float dx = (cloudWindV2(u,1).x-cloudWindV2(previous,1).x) / 0.13;
        for (uint i = 0; i < 2; ++i) {
            float depth = depths.sample(atmosphereSampler,oldUV).r;
            if (depth <= 0.01) { valid = false; break; }
            float3 p = viewRay(in.uv,u) * depth + float3(dx,0,0);
            oldUV = float2(0.5 + (p.x/p.z) * 1.35/(u.viewport.w*1.45),0.88-p.y/p.z);
        }
        float2 texel = float2(1.0/float(history.get_width()),0);
        float d = depths.sample(atmosphereSampler,oldUV).r;
        float dl = depths.sample(atmosphereSampler,oldUV-texel).r;
        float dr = depths.sample(atmosphereSampler,oldUV+texel).r;
        float a = history.sample(atmosphereSampler,oldUV).a;
        float al = history.sample(atmosphereSampler,oldUV-texel).a;
        float ar = history.sample(atmosphereSampler,oldUV+texel).a;
        valid = valid && a > 0.02 && max(abs(dl-d),abs(dr-d)) < max(0.04,d*0.05)
            && max(abs(al-a),abs(ar-a)) < 0.05;
    }
    // No edge clamping/wrapping of history into newly uncovered sky.
    valid = valid && all(oldUV > float2(0.001)) && all(oldUV < float2(0.999));
    if (valid) return history.sample(atmosphereSampler,oldUV);
    float unused;
    return integrateCloudsV2(in.uv,in.position.xy,u,noise,lightDepth,unused,false);
}

float visibleSunV2(constant AtmosphereUniforms &u, texture2d<float> clouds) {
    if (u.moonLight.w <= 0 || u.atmosphere.x <= 0.001 || u.atmosphere.w >= 0.999 || u.celestial.y < -0.035 || u.celestial.y > 1.035) return 0;
    float2 sun = float2(fract(u.celestial.x), u.celestial.y);
    float inFrame = smoothstep(-0.035,0.005,sun.y) * (1 - smoothstep(0.995,1.035,sun.y));
    float transmission = (1-clouds.sample(atmosphereSampler,sun,level(0)).a) * (1-u.atmosphere.w);
    // Fair-weather clouds dim the optics continuously, not a disk-only switch.
    // Gloomy weather disables glare via the scene permission, independently of
    // this pixel's cloud opacity. Nearly opaque/opaque sources still extinguish it.
    return transmission * smoothstep(0.015,0.12,transmission) * u.moonLight.w * u.atmosphere.x * inFrame;
}

struct SolarAtmosphereVertex { float4 position [[position]]; float2 uv; float sunVisibility [[flat]]; };
vertex SolarAtmosphereVertex solarAtmosphereVertex(uint id [[vertex_id]],constant AtmosphereUniforms &u [[buffer(0)]],
                                                  texture2d<float> clouds [[texture(3)]]) {
    float2 p = float2(id == 1 ? 3.0 : -1.0,id == 2 ? 3.0 : -1.0);
    // The same source sample was previously repeated at every output pixel.
    float visibility = u.options.w > 0.5 ? visibleSunV2(u,clouds) : 0;
    return {float4(p,0,1),float2((p.x+1)*0.5,(1-p.y)*0.5),visibility};
}
float solarOpticalScaleV2(constant AtmosphereUniforms &u) {
    // Portrait reference framing should not turn a height-scaled glare into an
    // enormous star spanning the narrow view. The physical body radius is separate.
    return min(1.0,sqrt(u.viewport.w));
}
float2 solarOpticalDeltaV2(float2 uv, constant AtmosphereUniforms &u) {
    float2 sun = float2(fract(u.celestial.x),u.celestial.y);
    // Only the experimental 360° panorama wraps glare. A desktop/portrait sensor
    // image must not duplicate half the star on its opposite edge.
    float2 delta = u.rendering.z > 1.5 ? celestialDeltaV2(uv,sun) : uv-sun;
    return delta*float2(u.viewport.w,1)/solarOpticalScaleV2(u);
}
float solarDiffractionV2(float2 delta, constant AtmosphereUniforms &u) {
    if (dot(delta,delta) > 0.21*0.21) return 0;
    // One counterclockwise revolution / 120 scene seconds. Screen y points down:
    // rotating the lookup positively rotates the visible axes negatively (CCW).
    // 120 divides the existing 3600-second clock split exactly; no uptime jump.
    // The shared scene clock freezes for pause / Reduce Motion.
    float angle = fract(u.viewport.z / 120.0) * (2 * M_PI_F);
    float c = cos(angle), s = sin(angle);
    delta = float2(c*delta.x-s*delta.y,s*delta.x+c*delta.y);
    // Three opposing axes = six slender, feathered points, initially at 15°.
    const float2 axes[3] = {float2(0.9659258,0.2588190),float2(0.2588190,0.9659258),float2(-0.7071068,0.7071068)};
    float spikes = 0;
    for (uint i = 0; i < 3; ++i) {
        // Shorten the longitudinal profile 30%, without changing core, flare
        // placement, feather width or the two-minute counterclockwise rotation.
        float along = abs(dot(delta,axes[i])) / 0.70;
        float across = dot(delta,float2(-axes[i].y,axes[i].x));
        float width = 0.0035 + 0.0045 * (1-saturate(along/0.30));
        spikes += exp(-across*across/(width*width)-along*10) * (1-smoothstep(0.12,0.30,along));
    }
    // Let the radial bloom dominate the inner shoulders instead of stacking
    // bright blade roots on top of it. Smoothly restore the unchanged outer rays.
    float innerBlend = mix(0.40,1.0,smoothstep(0.025,0.13,length(delta)));
    return spikes * (6.6 * innerBlend);
}
float3 solarGlareTintV2(float radius, constant AtmosphereUniforms &u) {
    // White-hot center, pale yellow inner rays and subtle amber outer tips.
    float3 tint = mix(float3(1.0,0.90,0.62),float3(1.0,0.58,0.24),smoothstep(0.06,0.32,radius));
    return mix(tint*float3(1.0,0.72,0.55),tint,smoothstep(0.12,0.70,u.atmosphere.x));
}
fragment float4 atmosphereEmission(SolarAtmosphereVertex in [[stage_in]], constant AtmosphereUniforms &u [[buffer(0)]],
                                   texture2d<float> clouds [[texture(3)]]) {
    float visibility = in.sunVisibility;
    if (visibility <= 0) return float4(0);
    float2 delta = solarOpticalDeltaV2(in.uv,u);
    // Concentrate exposure in the center instead of a giant uniformly white veil.
    // Existing reduced-resolution blur supplies the soft component of the rays.
    float r2 = dot(delta,delta);
    float core = exp(-r2/(0.020*0.020))*18;
    float glow = exp(-r2/(0.055*0.055))*2.6 + exp(-r2/(0.150*0.150))*0.30;
    float3 tint = solarGlareTintV2(sqrt(r2),u);
    return float4((float3(1.0,0.985,0.94)*core + tint*(glow+solarDiffractionV2(delta,u)*0.60))*visibility,0);
}

float3 lensFlareV2(float2 uv, constant AtmosphereUniforms &u, float visibility) {
    if (visibility <= 0.0001) return float3(0);
    float2 sun = float2(fract(u.celestial.x),u.celestial.y);
    float2 axis = float2(0.5) - sun;
    float2 metric = float2(u.viewport.w,1);
    float3 flare = 0;
    // Soft circular sensor ghosts follow the source-to-image-center diagonal.
    // Their centers stay fixed while only the diffraction blades rotate.
    for (uint i = 0; i < 4; i++) {
        float position = i == 0 ? 0.66 : (i == 1 ? 1.0 : (i == 2 ? 1.38 : 2.05));
        float2 center = sun + axis * position;
        float radius = i == 0 ? 0.036 : (i == 1 ? 0.022 : (i == 2 ? 0.042 : 0.055));
        float2 local = (uv-center)*metric/radius;
        float r2 = dot(local,local);
        if (r2 > 1.44) continue;
        float r = sqrt(r2);
        float disk = (1-smoothstep(0.55,1.12,r))*(0.75+0.25*(1-r2/1.44));
        float rim = exp(-pow((r-0.83)/0.14,2))*0.12;
        float3 tint = i == 1 ? float3(0.23,0.55,0.68) : float3(0.22,0.39,0.72);
        float gain = i == 0 ? 0.25 : (i == 1 ? 0.20 : (i == 2 ? 0.18 : 0.12));
        flare += tint * gain * (disk+rim);
    }
    float2 streak = (uv-(sun+axis*0.40))*metric/float2(0.047,0.008);
    float streakR2 = dot(streak,streak);
    if (streakR2 < 6) {
        float3 spectral = mix(float3(0.65,0.07,0.95),float3(0.12,0.35,1.0),smoothstep(-1.0,1.0,streak.x));
        flare += spectral*0.30*exp(-streakR2*1.3);
    }
    // Broad spectral annulus, strongest on the inward-facing side of the sun.
    // Bound the expensive profiles to a narrow annulus, not the entire desktop.
    float2 delta = (uv-sun)*metric/solarOpticalScaleV2(u);
    float ringR2 = dot(delta,delta);
    if (ringR2 > 0.255*0.255 && ringR2 < 0.335*0.335) {
        float r = sqrt(ringR2);
        float2 inward = axis*metric;
        inward /= max(0.001,length(inward));
        float arc = pow(saturate(0.5+0.5*dot(delta/r,inward)),2);
        float3 spectrum = exp(-pow((float3(r)-float3(0.309,0.295,0.281))/0.015,2));
        flare += spectrum*float3(0.075,0.09,0.12)*arc;
    }
    float edgeFade = smoothstep(0,0.04,sun.x) * (1 - smoothstep(0.96,1.0,sun.x));
    return flare * visibility * visibility * edgeFade;
}

float3 moonSurfaceV2(float2 uv, float3 sky, constant AtmosphereUniforms &u, texture2d<float> moonMap) {
    float bodyRadius = u.rendering.w * 1.5; // Moon only: 50% larger diameter; sun stays unchanged.
    float2 local = celestialDeltaV2(uv, u.moon.xy) * float2(u.viewport.w, 1) / bodyRadius;
    float r2 = dot(local,local);
    if (r2 >= 1.04 || u.moon.z <= 0.001) return sky;
    float3 n = float3(local.x, -local.y, sqrt(max(0.0, 1 - min(r2,1.0))));
    float c = cos(u.moon.w), s = sin(u.moon.w);
    float3 rotated = float3(n.x * c - n.y * s, n.x * s + n.y * c, n.z);
    float2 surfaceUV = float2(atan2(rotated.x, rotated.z) / (2 * M_PI_F) + 0.5, acos(clamp(rotated.y,-1.0,1.0)) / M_PI_F);
    float lod = max(0.0, log2(float(moonMap.get_height()) / max(1.0,u.viewport.y * bodyRadius * 4.3)) - 0.35);
    float3 albedo = moonMap.sample(moonSamplerV2,surfaceUV,level(lod)).rgb;
    albedo = max(0.0,(albedo - 0.18) * 1.15 + 0.18);
    float diffuse = dot(n,normalize(u.moonLight.xyz));
    float limb = smoothstep(-0.012,0.025,diffuse);
    float lighting = saturate(2 * max(0.0,diffuse) / max(0.02,max(0.0,diffuse) + n.z));
    float3 surface = albedo * (0.005 * (1 - u.atmosphere.x) + lighting * 1.8);
    // Earthshine: faint sunlit-earth glow on the lunar nightside, strongest at crescent.
    float earthshine = (1.0 - u.atmosphere.x) * (1.0 - u.celestial.z) * 0.030 * u.moon.z;
    surface += albedo * earthshine;
    float edge = saturate((1 - sqrt(r2)) * u.viewport.y * bodyRadius + 0.5);
    float alpha = edge * u.moon.z * mix(1.0,limb * 0.65,u.atmosphere.x);
    return mix(sky,surface + sky * u.atmosphere.x * 0.48,alpha);
}
float3 starFieldV2(float2 uv, constant AtmosphereUniforms &u) {
    float2 p = uv * float2(u.viewport.w,1) * 125;
    float2 cell = floor(p);
    float3 h = noiseHash3(float3(cell,41));
    if (h.z < 0.978) return float3(0); // Almost every star cell is empty.
    float distance = length(fract(p) - (0.15 + h.xy * 0.7));
    float size = (0.020 + pow(h.x,8) * 0.075) * 1.55;
    float star = exp(-distance * distance / (size * size)) * step(0.978,h.z) * (0.06 + pow(h.y,3) * 0.94);
    float phase = boundedPhase(u.clock.x,u.viewport.z,0.035) * 2 * M_PI_F;
    // Independent, stable temperature variation; most stars remain near-white.
    float temperature = noiseHash3(float3(cell,93)).x;
    float3 tint = temperature < 0.58 ? float3(0.96,0.97,1.0)
        : (temperature < 0.76 ? float3(1.0,0.87,0.70)
        : (temperature < 0.93 ? float3(0.73,0.85,1.0) : float3(1.0,0.76,0.67)));
    return star * (0.92 + 0.08 * sin(phase + h.x * 40)) * tint;
}
struct MoonlitHazeUniformsV2 { float4 appearance, motion; };
float3 moonlitNotchHazeV2(float2 uv,constant AtmosphereUniforms &u,constant MoonlitHazeUniformsV2 &haze,
                         texture3d<float> noise) {
    float night = (1-smoothstep(0.015,0.15,u.atmosphere.x))*(1-smoothstep(0.10,0.55,u.atmosphere.y));
    if (haze.appearance.x <= 0 || night <= 0) return float3(0);
    float expansion = haze.appearance.y;
    float2 delta = uv-float2(haze.appearance.z,haze.appearance.w);
    float2 supportPoint = delta/float2(mix(0.34,0.46,expansion),mix(0.19,0.24,expansion));
    float support = dot(supportPoint,supportPoint);
    if (support >= 1) return float3(0); // Only the small upper-center region samples noise.
    float2 p = delta/float2(mix(0.21,0.33,expansion),mix(0.11,0.16,expansion));
    // Reuse the existing periodic cloud volume at filtered mip levels. Two
    // slowly transported scales warp overlapping fields, not a noisy alpha skin.
    float2 broad = noise.sample(volumeSampler,float3(p*float2(0.15,0.25)+float2(0.28,0.62)+haze.motion.xy,0.21),level(2)).rg;
    float2 fine = noise.sample(volumeSampler,float3(p*float2(0.34,0.29)+float2(-0.40,0.11)+haze.motion.zw,0.73),level(2)).rg;
    p += (float2(broad.x,fine.y)-0.5)*0.42;
    float2 a = (p-float2(-0.16,-0.10))*float2(1.35,1.8);
    float2 b = (p-float2(0.42,0.10))*float2(1.8,2.4);
    float2 c = (p-float2(-0.46,0.26))*float2(2.1,2.1);
    float layers = exp(-dot(a,a))*0.50+exp(-dot(b,b))*0.32+exp(-dot(c,c))*0.25;
    float thinMist = 0.60+0.40*smoothstep(0.20,0.80,0.50+(broad.x-0.5)*1.3+(fine.y-0.5)*0.65);
    float2 focus = (p-float2(0,-0.03))*float2(mix(3.6,2.8,expansion),4.0);
    float core = exp(-dot(focus,focus));
    float fade = saturate((support-0.35)/0.65);
    float envelope = saturate(1-fade*fade*fade*(fade*(fade*6-15)+10)); // C2 feather, invisible boundary.
    float3 blueGrey = float3(0.44,0.56,0.77), silver = float3(0.83,0.88,0.94);
    return (blueGrey*(0.018*layers*thinMist)+silver*(0.011*core))
        * (haze.appearance.x*night*envelope*(1-expansion*0.10));
}
fragment float4 atmosphereComposite(SolarAtmosphereVertex in [[stage_in]], constant AtmosphereUniforms &u [[buffer(0)]],
                                    constant MoonlitHazeUniformsV2 &notchHaze [[buffer(3)]],
                                    texture2d<float> moonMap [[texture(1)]], texture2d<float> bloom [[texture(2)]],
                                    texture2d<float> clouds [[texture(3)]],texture3d<float> hazeNoise [[texture(4)]]) {
    float2 uv = in.uv;
    float day = u.atmosphere.x, twilight = u.atmosphere.y;
    // A high transparent veil is not the same optical regime as an opaque low ceiling.
    float overcast = smoothstep(0.50,1.0,u.cloudStructure.z);
    float3 zenith = mix(float3(0.0012,0.0028,0.010),float3(0.008,0.13,0.46),day);
    float3 horizon = mix(float3(0.012,0.021,0.048),float3(0.25,0.53,0.83),day);
    zenith = mix(zenith,mix(float3(0.008,0.013,0.025),float3(0.13,0.20,0.29),day),overcast);
    horizon = mix(horizon,mix(float3(0.023,0.032,0.049),float3(0.39,0.47,0.55),day),overcast);
    zenith = mix(zenith,float3(0.055,0.041,0.13),twilight * 0.80);
    horizon = mix(horizon,float3(1.05,0.29,0.11),twilight * (1 - overcast * 0.65));
    // Golden hour: warm the horizon when daylight is mid and the sun is low.
    float golden = clamp(day * (1.0 - day) * 4.0, 0.0, 1.0) * (1.0 - twilight * 0.3);
    horizon += float3(0.30,0.10,0.015) * golden * (1.0 - overcast * 0.6) * day;
    // Blue hour: cool the zenith once the sun drops but twilight lingers.
    float blue = (1.0 - day) * twilight;
    zenith = mix(zenith, float3(0.020,0.050,0.120), blue * 0.45 * (1.0 - overcast * 0.5));
    float horizonWeight = pow(saturate(uv.y),1.6);
    float3 sky = mix(zenith,horizon,horizonWeight);
    sky *= 1 - u.clouds.z * 0.16 - u.weather.z * 0.24;
    float distance = length(celestialDeltaV2(uv,u.celestial.xy) * float2(u.viewport.w,1));
    float3 sunlight = mix(float3(2.8,1.0,0.30),float3(2.8,2.55,2.05),day);
    sky += sunlight * exp(-distance * 5) * day * 0.07 * (1 - overcast * 0.75) * u.moonLight.w;
    float sunEdge = max(1 / u.viewport.y,0.0005);
    if (distance < u.rendering.w + sunEdge) {
        // The weather, not a passing light cloud, selects the plain white button.
        // Final cloud compositing still attenuates or hides the physical disk.
        float filtered = 1-u.moonLight.w;
        float3 diskLight = mix(sunlight,float3(2.8),filtered);
        sky += diskLight * (4 * (1+filtered*1.8))
            * (1-smoothstep(u.rendering.w-sunEdge,u.rendering.w+sunEdge,distance)) * day;
    }
    float night = (1 - day) * (1 - twilight * 0.95);
    if (night > 0.005) {
        float moonWash = 1.0 - u.moon.z * u.celestial.z * 0.55;
        sky += float3(0.62) * starFieldV2(uv,u) * (night * moonWash);
    }
    sky = moonSurfaceV2(uv,sky,u,moonMap);
    if (night * u.moon.z * u.celestial.z > 0.0001) {
        float moonDistance = length(celestialDeltaV2(uv,u.moon.xy) * float2(u.viewport.w,1));
        sky += float3(0.008,0.014,0.028) * exp(-moonDistance * 55) * night * u.moon.z * u.celestial.z;
    }
    float4 cloud = clouds.sample(atmosphereSampler,uv);
    // Both inputs are scene-linear. Clouds attenuate celestial bodies and stars naturally.
    sky = sky * (1 - cloud.a) + cloud.rgb;
    float haze = u.atmosphere.w * mix(0.25,0.92,pow(uv.y,0.9));
    float3 fogLight = mix(float3(0.027,0.038,0.060),float3(0.43,0.51,0.60),day);
    sky = mix(sky,fogLight,haze);
    if (u.lightning.z > 0.001) {
        float2 flashDelta = (uv - float2(u.lightning.x,0.24)) * float2(u.viewport.w,1);
        sky += float3(0.035,0.050,0.09) * u.lightning.z * exp(-dot(flashDelta,flashDelta) * 3);
    }
    if (u.options.w > 0.5) {
        sky += bloom.sample(atmosphereSampler,uv).rgb * 0.48;
        float visibility = in.sunVisibility;
        if (visibility > 0) {
            // Keep a slender feathered blade inside the same final pass, so the
            // bloom blur cannot turn all six rays back into chunky hazy prongs.
            float2 delta = solarOpticalDeltaV2(uv,u);
            if (dot(delta,delta) < 0.21*0.21) {
                sky += solarGlareTintV2(length(delta),u)*solarDiffractionV2(delta,u)*(0.25*visibility);
            }
        }
        sky += lensFlareV2(uv,u,visibility);
    }
    // One photographic shoulder after atmosphere, cloud and source-occluded optical effects.
    float3 color = 1 - exp(-max(0.0,sky));
    // Readability remains after cloud/fog composition; the existing output
    // dither below prevents banding in the thin haze. Previews bind zero strength.
    color += moonlitNotchHazeV2(uv,u,notchHaze,hazeNoise);
    // Approximate a half-code-LSB triangular offset through the inverse sRGB
    // derivative: no noisy alpha and no pair of full RGB encode/decode pow calls.
    uint hash = uint(in.position.x) * 1973u + uint(in.position.y) * 9277u + 89173u;
    hash = (hash ^ (hash >> 16)) * 0x7feb352du;
    hash = (hash ^ (hash >> 15)) * 0x846ca68bu;
    float a = float(hash & 65535u) / 65535.0;
    float b = float((hash >> 16) & 65535u) / 65535.0;
    float3 inverseSlope = select(float3(1.0/12.92),(2.4/1.055) * pow(color,1.0 - 1.0/2.4),color > 0.0031308);
    return float4(saturate(color + inverseSlope * ((a-b) * (0.5/255.0))),1);
}

// One tiny instanced quad per active meteor. No full-screen event work or bloom target.
struct MeteorDraw { float4 headDirection; float4 train; };
struct MeteorVertexOut { float4 position [[position]]; float2 local; float2 uv; };
vertex MeteorVertexOut meteorVertex(uint id [[vertex_id]], constant AtmosphereUniforms &u [[buffer(0)]],
                                    constant MeteorDraw &m [[buffer(1)]]) {
    const float2 corners[] = {float2(0,-1),float2(1,-1),float2(0,1),float2(0,1),float2(1,-1),float2(1,1)};
    float2 c = corners[id];
    float longitudinal = mix(-m.train.x,m.train.z,c.x);
    float2 dir = m.headDirection.zw;
    float2 metric = m.headDirection.xy + dir * longitudinal + float2(-dir.y,dir.x) * c.y * m.train.y * 3;
    float2 uv = metric / float2(u.viewport.w,1);
    return {float4(uv.x * 2 - 1,1 - uv.y * 2,0,1),float2(longitudinal,c.y * m.train.y * 3),uv};
}
fragment float4 meteorFragment(MeteorVertexOut in [[stage_in]], constant AtmosphereUniforms &u [[buffer(0)]],
                               constant MeteorDraw &m [[buffer(1)]],texture2d<float> clouds [[texture(3)]]) {
    float night = (1-u.atmosphere.x) * (1-u.atmosphere.y) * (1-u.atmosphere.w) * (1-u.atmosphere.w);
    float visibility = (1-clouds.sample(atmosphereSampler,in.uv).a) * night;
    float behind = max(0.0,-in.local.x);
    float tail = saturate(1 - behind / max(m.train.x,0.00001));
    float width = max(0.30/u.viewport.y,m.train.y * mix(0.16,1.0,tail));
    float core = exp(-pow(in.local.y / width,2)) * tail * tail * (1-smoothstep(0.0,m.train.z,in.local.x));
    float head = exp(-pow(in.local.x / max(m.train.z,1/u.viewport.y),2) - pow(in.local.y / m.train.y,2));
    float3 trainColor = mix(float3(0.30,0.055,0.012),float3(1.0,0.38,0.075),tail);
    float3 light = trainColor * core * 0.30 + float3(1.0,0.86,0.64) * head * 0.50;
    return float4(light * visibility * m.train.w,0);
}
