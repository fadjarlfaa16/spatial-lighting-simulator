#include <metal_stdlib>
using namespace metal;

// All uniform fields are float4: identical 16-byte layout in Swift/MSL.
struct Light {
    float4 placement; // uv, signed Z, radius / short edge
    float4 colorPower;
    float4 feather; // softness, world-derived light direction xyz
    float4 beam;    // xy: source UV, z: metres/image unit, w: source projection valid
    float4 fixture; // fixed subject->fixture xyz in displayed camera axes
};
struct Uniforms {
    float4 material; // ambient, diffuse, specular, shininess
    float4 scene;    // aspect, light count, has mask, reserved
    float4 maskGeometry; // normalized foreground bounds: center xy, size zw
    float4 rendering; // x: RGB-guided normal refinement (export only)
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
float4 sampleNormalBilinear(
    texture2d<float, access::read> tex,
    float2 uv
) {
    int2 size = int2(tex.get_width(), tex.get_height());
    float2 coordinate = clamp(uv, 0.0f, 1.0f) * float2(size) - 0.5f;
    int2 lower = int2(floor(coordinate));
    int2 upper = lower + 1;
    float2 fraction = fract(coordinate);
    int2 maximum = size - 1;
    uint2 p00 = uint2(clamp(lower, int2(0), maximum));
    uint2 p10 = uint2(clamp(int2(upper.x, lower.y), int2(0), maximum));
    uint2 p01 = uint2(clamp(int2(lower.x, upper.y), int2(0), maximum));
    uint2 p11 = uint2(clamp(upper, int2(0), maximum));
    float4 top = mix(tex.read(p00), tex.read(p10), fraction.x);
    float4 bottom = mix(tex.read(p01), tex.read(p11), fraction.x);
    return mix(top, bottom, fraction.y);
}

// Joint-bilateral normal reconstruction for full-resolution export. The
// low-resolution model output stays compact; the full-resolution camera RGB
// and segmentation mask guide which neighbouring normals may cross an edge.
float4 sampleNormalEdgeAware(
    texture2d<float, access::read> normals,
    texture2d<float> photo,
    texture2d<float> mask,
    sampler linearSampler,
    float2 uv,
    bool hasMask
) {
    int2 size = int2(normals.get_width(), normals.get_height());
    int2 maximum = size - 1;
    float2 coordinate = clamp(uv, 0.0f, 1.0f) * float2(size) - 0.5f;
    int2 centrePixel = int2(floor(coordinate + 0.5f));
    float4 reference = sampleNormalBilinear(normals, uv);
    float3 referenceNormal = unitOr(reference.xyz, float3(0, 0, 1));
    float3 guide = photo.sample(linearSampler, uv).rgb;
    float guideMask = hasMask ? mask.sample(linearSampler, uv).r : 1.0f;
    float3 accumulated = float3(0);
    float accumulatedWeight = 0.0f;

    for (int offsetY = -1; offsetY <= 1; ++offsetY) {
        for (int offsetX = -1; offsetX <= 1; ++offsetX) {
            int2 candidatePixel = clamp(
                centrePixel + int2(offsetX, offsetY),
                int2(0),
                maximum
            );
            float4 candidate = normals.read(uint2(candidatePixel));
            if (candidate.w <= 0.01f) continue;

            float2 candidateUV = (float2(candidatePixel) + 0.5f) / float2(size);
            float3 candidateGuide = photo.sample(linearSampler, candidateUV).rgb;
            float3 colourDelta = candidateGuide - guide;
            float2 sampleDelta = float2(candidatePixel) - coordinate;
            float spatialWeight = exp(-0.55f * dot(sampleDelta, sampleDelta));
            float colourWeight = exp(-24.0f * dot(colourDelta, colourDelta));
            float maskWeight = 1.0f;
            if (hasMask) {
                float candidateMask = mask.sample(linearSampler, candidateUV).r;
                maskWeight = exp(-18.0f * abs(candidateMask - guideMask));
            }
            float3 candidateNormal = unitOr(candidate.xyz, referenceNormal);
            float agreement = 0.25f + 0.75f
                * pow(max(dot(candidateNormal, referenceNormal), 0.0f), 2.0f);
            float weight = spatialWeight * colourWeight * maskWeight * agreement;
            accumulated += candidateNormal * weight;
            accumulatedWeight += weight;
        }
    }

    if (accumulatedWeight <= 1e-5f) return reference;
    return float4(
        unitOr(accumulated / accumulatedWeight, referenceNormal),
        max(reference.w, saturate(accumulatedWeight))
    );
}

// Vision already supplies a soft, antialiased alpha. Sampling it directly keeps
// the exact segmentation boundary; any blur here would grow the subject into
// the background and recreate a bright halo around hair.
float sampleSubjectMask(
    texture2d<float> mask,
    sampler linearSampler,
    float2 uv
) {
    return saturate(mask.sample(linearSampler, uv).r);
}

float2 inverseAspectDelta(float2 value, float aspect) {
    return value / float2(max(aspect, 1.0f), max(1.0f / aspect, 1.0f));
}

// Project the foreground silhouette onto the assumed flat receiver behind it.
// This is an inverse warp rather than a translated mask copy: perspective,
// grazing angle, distance, feather and both screen axes change the result.
float projectedShadow(
    texture2d<float> mask,
    sampler linearSampler,
    float2 receiver,
    float receiverMask,
    float4 maskGeometry,
    float3 subjectToLight,
    float metresPerImageUnit,
    float feather,
    float aspect
) {
    float2 centre = maskGeometry.xy;

    // This is the fixed AR subject->fixture vector, not the current beam aim.
    // Aiming rotates the COB but never translates the source casting the shadow.
    float physicalDistance = length(subjectToLight);
    float3 physicalDirection = physicalDistance > 1e-5f
        ? subjectToLight / physicalDistance
        : float3(0, 0, 1);

    // Only a source on the camera-facing side of the subject can project its
    // silhouette onto the background visible behind it. Rear fixtures are
    // handled by backRim instead of creating a physically inverted shadow.
    float frontFactor = smoothstep(0.04f, 0.34f, physicalDirection.z);
    if (frontFactor <= 0.0f || receiverMask >= 0.98f) return 0.0f;

    // Exact point-light projection onto a parallel receiver plane behind the
    // subject. If g is the subject->receiver distance and zL is the light depth:
    //   receiverXY = (1 + g/zL) * subjectXY - (g/zL) * lightXY.
    // Therefore the shadow translates away from the fixed light and grows by
    // the same perspective ratio. X and Y use the same 3-D source geometry.
    float receiverGap = mix(0.46f, 0.34f, feather);
    float lightDepth = max(subjectToLight.z, 0.12f);
    float projectionRatio = clamp(receiverGap / lightDepth, 0.035f, 1.60f);
    float2 castOffset = float2(-subjectToLight.x, subjectToLight.y)
        * projectionRatio / max(metresPerImageUnit, 0.01f);
    float castLength = length(castOffset);
    float2 away = castLength > 1e-5f
        ? castOffset / castLength
        : float2(0, 1);
    float2 across = float2(-away.y, away.x);

    float pointScale = 1.0f + projectionRatio;
    float grazing = saturate(length(physicalDirection.xy));
    // A slight longitudinal term approximates a receiver that is not perfectly
    // parallel to the camera, without the extreme mask stretching used before.
    float longitudinalScale = pointScale
        * (1.0f + 0.14f * projectionRatio * grazing);
    float transverseScale = pointScale;

    float2 receiverLocal = aspectDelta(receiver - centre, aspect) - castOffset;
    float2 maskLocal = away * (dot(receiverLocal, away) / longitudinalScale)
                     + across * (dot(receiverLocal, across) / transverseScale);
    float2 lookup = centre + inverseAspectDelta(maskLocal, aspect);

    // Penumbra grows with projection, grazing angle and the user's feather.
    // A small 2-D tent kernel is important here: a cross-shaped five tap blur
    // leaves the stepped Vision-mask contour visible on hair and shoulders.
    float shortEdge = float(min(mask.get_width(), mask.get_height()));
    float penumbraPixels = 1.5f
        + 13.0f * feather * feather
        + 7.0f * projectionRatio
        + 3.0f * grazing;
    float penumbra = penumbraPixels / max(shortEdge, 1.0f);
    float2 alongUV = inverseAspectDelta(away * penumbra, aspect);
    float2 acrossUV = inverseAspectDelta(across * penumbra, aspect);
    float2 diagonalA = (alongUV + acrossUV) * 0.70710678f;
    float2 diagonalB = (alongUV - acrossUV) * 0.70710678f;

    // 13 weighted samples approximate an area emitter while remaining cheap
    // enough for three interactive lights. Inner taps preserve the silhouette;
    // the outer ring produces a genuinely gradual penumbra on both axes.
    float silhouette = mask.sample(linearSampler, lookup).r * 0.16f;
    silhouette += mask.sample(linearSampler, lookup + alongUV * 0.42f).r * 0.10f;
    silhouette += mask.sample(linearSampler, lookup - alongUV * 0.42f).r * 0.10f;
    silhouette += mask.sample(linearSampler, lookup + acrossUV * 0.42f).r * 0.10f;
    silhouette += mask.sample(linearSampler, lookup - acrossUV * 0.42f).r * 0.10f;
    silhouette += mask.sample(linearSampler, lookup + alongUV).r * 0.055f;
    silhouette += mask.sample(linearSampler, lookup - alongUV).r * 0.055f;
    silhouette += mask.sample(linearSampler, lookup + acrossUV).r * 0.055f;
    silhouette += mask.sample(linearSampler, lookup - acrossUV).r * 0.055f;
    silhouette += mask.sample(linearSampler, lookup + diagonalA).r * 0.055f;
    silhouette += mask.sample(linearSampler, lookup - diagonalA).r * 0.055f;
    silhouette += mask.sample(linearSampler, lookup + diagonalB).r * 0.055f;
    silhouette += mask.sample(linearSampler, lookup - diagonalB).r * 0.055f;

    float backgroundOnly = 1.0f - smoothstep(0.02f, 0.35f, receiverMask);
    float opacity = mix(0.72f, 0.36f, feather);
    return frontFactor * backgroundOnly * opacity
         * smoothstep(0.015f, 0.985f, silhouette);
}

// A rear fixture cannot illuminate front-facing normals directly, but it does
// create a rim on the silhouette facing the fixture. Probe outward through the
// mask in the actual projected lamp direction, with an isotropic fallback for a
// lamp directly behind the subject.
float backRim(
    texture2d<float> mask,
    sampler linearSampler,
    float2 uv,
    float subjectMask,
    float3 lightDirection,
    float feather,
    float radius
) {
    float rearFactor = smoothstep(0.02f, 0.58f, -lightDirection.z);
    if (rearFactor <= 0.0f) return 0.0f;

    float2 size(float(mask.get_width()), float(mask.get_height()));
    // Project the measured 3-D subject->light direction onto displayed pixels.
    // This makes a high rear fixture favour the upper silhouette and a left or
    // right rear fixture illuminate the corresponding edge.
    float2 toSourcePixels = float2(lightDirection.x, -lightDirection.y) * size;
    float directionalStrength = smoothstep(1.0f, 18.0f, length(toSourcePixels));
    float lengthSquared = dot(toSourcePixels, toSourcePixels);
    float2 pixelDirection = lengthSquared > 1e-5f
        ? toSourcePixels * rsqrt(lengthSquared)
        : float2(0, -1);
    float elevationSpread = 1.0f + 0.65f * abs(lightDirection.y);
    float rimPixels = (1.5f + 4.5f * feather + min(radius * 1.8f, 3.0f))
        * elevationSpread;
    float2 offset = pixelDirection * rimPixels / size;
    float directedInner = 0.55f * saturate(
        subjectMask - mask.sample(linearSampler, uv + offset * 0.48f).r
    ) + 0.45f * saturate(
        subjectMask - mask.sample(linearSampler, uv + offset).r
    );
    float directedOuter = 0.55f * saturate(
        mask.sample(linearSampler, uv - offset * 0.48f).r - subjectMask
    ) + 0.45f * saturate(
        mask.sample(linearSampler, uv - offset).r - subjectMask
    );
    float2 cardinal = rimPixels / size;
    float outerMinimum = min(
        min(mask.sample(linearSampler, uv + float2(cardinal.x, 0)).r,
            mask.sample(linearSampler, uv - float2(cardinal.x, 0)).r),
        min(mask.sample(linearSampler, uv + float2(0, cardinal.y)).r,
            mask.sample(linearSampler, uv - float2(0, cardinal.y)).r)
    );
    float neighbourMaximum = max(
        max(mask.sample(linearSampler, uv + float2(cardinal.x, 0)).r,
            mask.sample(linearSampler, uv - float2(cardinal.x, 0)).r),
        max(mask.sample(linearSampler, uv + float2(0, cardinal.y)).r,
            mask.sample(linearSampler, uv - float2(0, cardinal.y)).r)
    );
    float isotropicInner = saturate(subjectMask - outerMinimum);
    float isotropicOuter = saturate(neighbourMaximum - subjectMask);
    float innerEdge = mix(isotropicInner, directedInner, directionalStrength);
    float outerEdge = mix(isotropicOuter, directedOuter, directionalStrength);
    float innerRim = smoothstep(0.025f, 0.64f, innerEdge)
        * smoothstep(0.025f, 0.42f, subjectMask);
    float outerGlow = smoothstep(0.02f, 0.58f, outerEdge)
        * (1.0f - smoothstep(0.30f, 0.82f, subjectMask));
    return rearFactor * (innerRim + outerGlow * 0.34f);
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
    float subjectWeight = u.scene.z > 0 ? sampleSubjectMask(mask, photoSampler, in.uv)
                                       : 1.0f;

    // The segmentation mask is the authority for geometry. Do not even sample
    // the model's background normals: their noisy changes were visible as large
    // broken patches around an otherwise clean subject silhouette.
    float4 rawNormal = float4(0, 0, 1, 0);
    if (u.scene.z <= 0 || subjectWeight > 0.05f) {
        rawNormal = u.rendering.x > 0.5f
            ? sampleNormalEdgeAware(
                normals,
                photo,
                mask,
                photoSampler,
                in.uv,
                u.scene.z > 0
            )
            : sampleNormalBilinear(normals, in.uv);
    }
    float3 N = unitOr(float3(rawNormal.x, -rawNormal.y, rawNormal.z), float3(0, 0, 1));
    float normalValidity = smoothstep(0.05f, 0.75f, rawNormal.w);
    // Keep the transition inside the soft mask. Pixels outside this core always
    // use the flat receiver, regardless of what the normal model predicted.
    float subjectCore = u.scene.z > 0
        ? smoothstep(0.35f, 0.82f, subjectWeight)
        : normalValidity;
    float normalInfluence = normalValidity * subjectCore;
    float3 flatDiffuse(0), directionalDiffuse(0), specular(0), rim(0), haze(0);
    float hazeIntensity = u.scene.w;

    for (uint i = 0; i < uint(u.scene.y); ++i) {
        Light light = u.lights[i];
        float2 delta = aspectDelta(in.uv - light.placement.xy, u.scene.x);
        float d = length(delta) / light.placement.w;
        float falloff = 1 - smoothstep(1 - light.feather.x, 1.0f, d);
        float3 energy = light.colorPower.rgb * light.colorPower.a;
        float3 plannedDirection = unitOr(light.feather.yzw, float3(0, 0, 1));
        float castShadow = 0.0f;
        
        if (falloff > 0) {
            float distance = max(light.placement.z, 0.05f);
            float metresPerImageUnit = max(light.beam.z, 0.01f);

            // Build the actual target-plane geometry in camera/display space.
            // At the aimed pixel this equals the measured AR light vector;
            // across the photo it changes naturally as the surface point moves.
            // This is what makes a left fixture illuminate left-facing normals
            // while the opposite side falls into shade. The radial falloff is
            // retained only as the circular beam boundary, not as light direction.
            float3 sourceRelative = plannedDirection * distance;
            float3 surfaceRelative = float3(
                delta.x * metresPerImageUnit,
                -delta.y * metresPerImageUnit,
                0
            );
            float3 toLight = sourceRelative - surfaceRelative;
            float3 V(0, 0, 1);
            float3 L = unitOr(toLight, float3(0, 0, 1));

            float attenuation = falloff * gain(dot(toLight, toLight));
            castShadow = u.scene.z > 0
                ? projectedShadow(
                    mask,
                    photoSampler,
                    in.uv,
                    subjectWeight,
                    u.maskGeometry,
                    light.fixture.xyz,
                    metresPerImageUnit,
                    light.feather.x,
                    u.scene.x
                )
                : 0.0f;
            float nDotL = max(dot(N, L), 0.0f);
            directionalDiffuse += energy * (
                attenuation * u.material.y * nDotL
            );
            // The background is a single flat receiver. It keeps the beam's
            // radius, feather and distance response, but never inherits noisy
            // normal detail; only the smooth projected visibility affects it.
            flatDiffuse += energy * (
                falloff * gain(distance * distance) * u.material.y * 0.35f
                * (1.0f - castShadow)
            );
            float3 H = unitOr(L + V, V);
            specular += energy * (attenuation * u.material.z * (nDotL > 0 ? 1.0f : 0.0f) *
                                  pow(max(dot(N, H), 0.0f), u.material.w));
            float rimBand = u.scene.z > 0
                ? backRim(
                    mask,
                    photoSampler,
                    in.uv,
                    subjectWeight,
                    plannedDirection,
                    light.feather.x,
                    light.placement.w
                )
                : 0.0f;
            rim += energy * (
                falloff * gain(distance * distance) * rimBand
                * (0.28f + 0.52f * u.material.y)
            );
        }
        
        // Volumetric Beam Cone (Shaft)
        // A COB behind the camera has no valid perspective origin in the
        // photograph. Its diffuse/specular contribution is still rendered from
        // the measured 3-D direction, but drawing a 2-D shaft from an invented
        // near-plane icon creates the false diagonal/vertical seam seen in the
        // editor. Volumetric cone projection is therefore limited to fixtures
        // whose physical source is actually in front of the camera plane.
        if (hazeIntensity > 0 && light.beam.w > 0.5f) {
            float2 sourcePos = light.beam.xy;
            float2 targetPos = light.placement.xy;
            float2 shaftDir = targetPos - sourcePos;
            float2 aspectDir = aspectDelta(shaftDir, u.scene.x);
            float shaftLen = length(aspectDir);
            
            if (shaftLen > 1e-4) {
                float2 uvDelta = aspectDelta(in.uv - sourcePos, u.scene.x);
                float projectedDist = dot(aspectDir / shaftLen, uvDelta);
                
                // Feather the shaft in two dimensions. The old strict 0...1.5
                // interval introduced a straight brightness seam even when the
                // radial edge was fully feathered. This signed soft window makes
                // both the emitter end and the far end continuous.
                float softness = saturate(light.feather.x);
                float shortEdge = float(min(photo.get_width(), photo.get_height()));
                float pixelUnit = 1.0f / max(shortEdge, 1.0f);
                float maximumProjected = shaftLen * 1.5f;
                float startWidth = max(
                    shaftLen * mix(0.07f, 0.24f, softness),
                    pixelUnit * 3.0f
                );
                float endWidth = max(
                    shaftLen * mix(0.16f, 0.44f, softness),
                    pixelUnit * 5.0f
                );
                float longitudinalFalloff = smoothstep(
                    -startWidth,
                    startWidth,
                    projectedDist
                ) * (1.0f - smoothstep(
                    maximumProjected - endWidth,
                    maximumProjected + endWidth,
                    projectedDist
                ));

                float clampedProjected = clamp(projectedDist, 0.0f, maximumProjected);
                float coneProgress = clampedProjected / shaftLen;
                float2 closestPoint = sourcePos + shaftDir * coneProgress;
                float lateral = length(aspectDelta(in.uv - closestPoint, u.scene.x));

                // Give the emitter a finite aperture and feather across (not
                // only inside) the geometric cone. This removes the last hard
                // contour at wide beam angles and at Feather = 1.
                float apertureRadius = max(light.placement.w * 0.025f, pixelUnit * 2.0f);
                float coneRadius = mix(apertureRadius, light.placement.w * 1.5f, coneProgress / 1.5f);
                float lateralWidth = max(
                    coneRadius * mix(0.10f, 0.92f, softness),
                    pixelUnit * 2.0f
                );
                float shaftFalloff = 1.0f - smoothstep(
                    max(coneRadius - lateralWidth, 0.0f),
                    coneRadius + lateralWidth,
                    lateral
                );

                if (shaftFalloff > 0 && longitudinalFalloff > 0) {
                    // The shaft remains visible on the flat background, while
                    // the selected subject softly occludes it at the mask.
                    // No mask raymarch is projected back onto the background.
                    float occlusion = u.scene.z > 0
                        ? max(subjectWeight, castShadow)
                        : 0.0f;

                    float currentZ = coneProgress * light.placement.z;
                    float shaftAttenuation = gain(currentZ * currentZ);
                    // Reduce overlap where the flat surface footprint is
                    // already strong; this prevents a second bright "screen".
                    float surfaceOverlap = 1.0f - 0.55f * falloff;
                    haze += energy * (
                        shaftFalloff * longitudinalFalloff * shaftAttenuation
                        * hazeIntensity * surfaceOverlap * (1.0f - occlusion) * 0.11f
                    );
                }
            }
        }
    }
    // Only the mask core receives surface-normal shading/self-shadow. The soft
    // border returns to the flat background response before leaving the mask,
    // preventing normal-map fragments from appearing around hair and shoulders.
    float3 diffuseLight = mix(flatDiffuse, directionalDiffuse, normalInfluence);
    float specularMask = u.scene.z > 0 ? subjectCore : normalValidity;
    // Tinting the specular highlight with the 'base' color makes it look like 
    // natural skin/fabric (photographic) rather than white CG plastic.
    float3 linear = base * (u.material.x + diffuseLight)
                  + base * specular * specularMask
                  + mix(base, float3(1), 0.28f) * rim
                  + haze;
    return float4(encodeSRGB(linear) * source.a, source.a);
}
