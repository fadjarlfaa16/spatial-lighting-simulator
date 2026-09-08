#include <metal_stdlib>
using namespace metal;

// All uniform fields are float4: identical 16-byte layout in Swift/MSL.
struct Light {
    float4 placement; // uv, signed Z, radius / short edge
    float4 colorPower;
    float4 feather; // softness, world-derived light direction xyz
    float4 beam;    // x,y: normalizedSourcePosition
};
struct Uniforms {
    float4 material; // ambient, diffuse, specular, shininess
    float4 scene;    // aspect, light count, has mask, reserved
    Light lights[3];
};
struct VertexOut {
    float4 position [[position]];
    float2 uv;
};
vertex VertexOut relightVertex(uint id [[vertex_id]]) {
    const float2 positions[3] = {float2(-1, 1), float2(-1, -3), float2(3, 1)};
    VertexOut out;
    out.position = float4(positions[id], 0, 1);
    out.uv = float2((positions[id].x + 1) * 0.5, (1 - positions[id].y) * 0.5);
    return out;
}
float3 unitOr(float3 value, float3 fallback) {
    float d = dot(value, value);
    return isfinite(d) && d > 1e-12 ? value * rsqrt(d) : fallback;
}
// Exposure-calibrated inverse-square falloff. The previous 0.29 coefficient
// made a real 4 m fixture practically invisible; this retains the physical
// distance relationship while keeping common 1–5 m studio placements usable.
float gain(float d2) { return min(6.0f, 2.2f / max(d2 + 0.35f, 1e-6f)); }
float2 aspectDelta(float2 delta, float aspect) {
    return delta * float2(max(aspect, 1.0f), max(1.0f / aspect, 1.0f));
}
float3 decodeSRGB(float3 v) {
    v = clamp(v, 0.0f, 1.0f);
    return select(pow((v + 0.055f) / 1.055f, 2.4f), v / 12.92f, v <= 0.04045f);
}
float3 encodeSRGB(float3 v) {
    v = max(v, 0.0f);
    return clamp(select(1.055f * pow(v, 1.0f / 2.4f) - 0.055f,
                        v * 12.92f, v <= 0.0031308f), 0.0f, 1.0f);
}
uint2 pixelAt(float2 uv, texture2d<float, access::read> tex) {
    uint2 size(tex.get_width(), tex.get_height());
    return min(uint2(clamp(uv, 0.0f, 1.0f) * float2(size)), size - 1);
}
fragment float4 relightFragment(
    VertexOut in [[stage_in]],
    constant Uniforms &u [[buffer(0)]],
    texture2d<float> photo [[texture(0)]],
    texture2d<float, access::read> normals [[texture(1)]],
    texture2d<float> mask [[texture(2)]]
) {
    constexpr sampler photoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 source = photo.sample(photoSampler, in.uv); // BGRA unorm texture returns RGBA.
    float3 base = decodeSRGB(source.a > 1e-6f ? source.rgb / source.a : float3(0));
    float4 rawNormal = normals.read(pixelAt(in.uv, normals));
    float3 N = unitOr(float3(rawNormal.x, -rawNormal.y, rawNormal.z), float3(0, 0, 1));
    float subjectWeight = u.scene.z > 0 ? mask.sample(photoSampler, in.uv).r
                                       : (rawNormal.w > 0 ? 1 : 0);
    float3 bg(0), diffuse(0), specular(0), haze(0);
    float hazeIntensity = u.scene.w;

    for (uint i = 0; i < uint(u.scene.y); ++i) {
        Light light = u.lights[i];
        float2 delta = aspectDelta(in.uv - light.placement.xy, u.scene.x);
        float d = length(delta) / light.placement.w;
        float falloff = 1 - smoothstep(1 - light.feather.x, 1.0f, d);
        float3 energy = light.colorPower.rgb * light.colorPower.a;
        
        if (falloff > 0) {
            bg += energy * (falloff * gain(light.placement.z * light.placement.z) * 0.75f);
            
            float depth = max(light.placement.z, 0.05f);
            float3 toLight(-delta.x * depth, -delta.y * depth, depth);
            float3 V(0, 0, 1);
            float3 L = unitOr(toLight, float3(0, 0, 1));
            float3 plannedDirection = unitOr(light.feather.yzw, float3(0, 0, 1));
            L = unitOr(mix(L, plannedDirection, 0.35f), L);
            
            float attenuation = falloff * gain(dot(toLight, toLight));
            float nDotL = max(dot(N, L), 0.0f);
            diffuse += energy * (attenuation * u.material.y * nDotL);
            float3 H = unitOr(L + V, V);
            specular += energy * (attenuation * u.material.z * (nDotL > 0 ? 1.0f : 0.0f) *
                                  pow(max(dot(N, H), 0.0f), u.material.w));
        }
        
        // Volumetric Beam Cone (Shaft)
        if (hazeIntensity > 0) {
            float2 sourcePos = light.beam.xy;
            float2 targetPos = light.placement.xy;
            float2 shaftDir = targetPos - sourcePos;
            float2 aspectDir = aspectDelta(shaftDir, u.scene.x);
            float shaftLen = length(aspectDir);
            
            if (shaftLen > 1e-4) {
                float2 uvDelta = aspectDelta(in.uv - sourcePos, u.scene.x);
                float projectedDist = dot(aspectDir / shaftLen, uvDelta);
                
                // Allow beam to extend a bit past the target
                if (projectedDist > 0 && projectedDist < shaftLen * 1.5f) {
                    float2 closestPoint = sourcePos + shaftDir * (projectedDist / shaftLen);
                    float lateral = length(aspectDelta(in.uv - closestPoint, u.scene.x));
                    
                    float coneRadius = (projectedDist / shaftLen) * light.placement.w;
                    float shaftFalloff = 1.0f - smoothstep(max(coneRadius * (1.0f - light.feather.x), 1e-4f), max(coneRadius, 1e-4f), lateral);
                    
                    if (shaftFalloff > 0) {
                        float occlusion = 0;
                        if (u.scene.z > 0) {
                            // 2D Raymarch occlusion (B1/B2)
                            float m1 = mask.sample(photoSampler, mix(sourcePos, in.uv, 0.25f)).r;
                            float m2 = mask.sample(photoSampler, mix(sourcePos, in.uv, 0.50f)).r;
                            float m3 = mask.sample(photoSampler, mix(sourcePos, in.uv, 0.75f)).r;
                            float m4 = mask.sample(photoSampler, in.uv).r;
                            occlusion = saturate(m1 + m2 + m3 + m4);
                        }
                        
                        float currentZ = (projectedDist / shaftLen) * light.placement.z;
                        float shaftAttenuation = gain(currentZ * currentZ);
                        haze += energy * (shaftFalloff * shaftAttenuation * hazeIntensity * (1.0f - occlusion) * 0.15f);
                    }
                }
            }
        }
    }
    float3 background = base * (u.material.x + bg);
    // Tinting the specular highlight with the 'base' color makes it look like 
    // natural skin/fabric (photographic) rather than white CG plastic.
    float3 subject = base * (u.material.x + diffuse) + (base * specular);
    float3 linear = mix(background, subject, subjectWeight) + haze;
    return float4(encodeSRGB(linear) * source.a, source.a);
}
