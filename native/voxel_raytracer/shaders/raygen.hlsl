#include "common.hlsl"

[shader("raygeneration")]
void RayGenMain()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    float2 pixelCenter = float2(launchIndex) + float2(0.5, 0.5);
    float2 inUV = pixelCenter / float2(launchDim);
    float2 d = inUV * 2.0 - 1.0;

    float4 target = mul(g_Camera.projInverse, float4(d.x, -d.y, 1.0, 1.0));
    float3 rayDir = mul(g_Camera.viewInverse, float4(normalize(target.xyz / target.w), 0.0)).xyz;
    float3 rayOrigin = g_Camera.camPos.xyz;

    RayDesc ray;
    ray.Origin = rayOrigin;
    ray.Direction = normalize(rayDir);
    ray.TMin = 0.01;
    ray.TMax = 10000.0;

    RayPayload payload;
    payload.color = float4(0.0, 0.0, 0.0, 1.0);
    payload.normal = float3(0.0, 1.0, 0.0);
    payload.hitT = -1.0;
    payload.matID = 0;

    TraceRay(g_AccelStruct, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);

    if (payload.hitT > 0.0) {
        float3 hitWorldPos = rayOrigin + ray.Direction * payload.hitT;
        float3 worldNormal = payload.normal;
        uint matID = payload.matID;
        float3 albedo = payload.color.rgb;

        // Unpack Lighting & Visual parameters
        float3 rawSunDir = g_Camera.sunDir.xyz;
        float3 sunDir = (length(rawSunDir) > 0.001) ? normalize(rawSunDir) : normalize(float3(0.55, 0.75, 0.35));
        float3 rawSunColor = g_Camera.sunColor.rgb;
        float3 sunColor = (length(rawSunColor) > 0.001) ? rawSunColor : float3(1.0, 0.95, 0.85);
        float sunIntensity = (g_Camera.sunDir.w > 0.0001) ? g_Camera.sunDir.w : 1.0;
        float ambientIntensity = (g_Camera.sunColor.w > 0.0001) ? g_Camera.sunColor.w : 0.28;

        float rtaoStrength = g_Camera.visualSettings.x;
        float rtaoRadius = g_Camera.visualSettings.y;
        float softAngle = g_Camera.visualSettings.z;
        float waterSpecularMult = g_Camera.visualSettings.w;

        // 1. Water procedural normal ripples
        if (matID == 8u) {
            float time = float(g_Camera.frameIndex) * 0.035;
            float wave1 = sin(hitWorldPos.x * 2.5 + time) * cos(hitWorldPos.z * 2.5 + time);
            float wave2 = sin(hitWorldPos.x * 5.0 - time * 1.3) * sin(hitWorldPos.z * 5.0 + time * 1.3);
            float2 ripple = float2(wave1 + wave2 * 0.5, wave2 - wave1 * 0.5) * 0.12;

            if (abs(worldNormal.y) > 0.7) {
                worldNormal = normalize(float3(ripple.x, worldNormal.y, ripple.y));
            }
        }

        // 2. Emissive block check (matID == 11 Glowstone)
        if (matID == 11u) {
            float3 litColor = albedo * 1.6;
            float fog = 1.0 - exp(-payload.hitT * 0.0032);
            float3 horizonRayDir = normalize(float3(ray.Direction.x, max(ray.Direction.y * 0.2, 0.0), ray.Direction.z));
            float3 skyFogColor = GetSkyColor(horizonRayDir, sunDir, sunColor);
            payload.color = float4(lerp(litColor, skyFogColor, clamp(fog, 0.0, 1.0)), 1.0);
            g_OutputTarget[launchIndex] = payload.color;
            return;
        }

        // 3. Hardware Raytraced Soft Shadows
        float NdotL = max(0.0, dot(worldNormal, sunDir));
        float shadow = 0.0;

        if (NdotL > 0.001 && sunIntensity > 0.001) {
            float3 sunTangent = (abs(sunDir.y) < 0.99) ? normalize(cross(sunDir, float3(0.0, 1.0, 0.0))) : normalize(cross(sunDir, float3(1.0, 0.0, 0.0)));
            float3 sunBitangent = cross(sunDir, sunTangent);

            float2 shadowRnd = Hash2D(launchIndex, g_Camera.frameIndex, 0u);
            float r = sqrt(shadowRnd.x) * softAngle;
            float phi = 6.283185307 * shadowRnd.y;
            float2 diskOffset = float2(cos(phi), sin(phi)) * r;

            // Sample 1: Jittered shadow ray
            RayDesc sRay1;
            sRay1.Origin = hitWorldPos + worldNormal * 0.05;
            sRay1.Direction = normalize(sunDir + sunTangent * diskOffset.x + sunBitangent * diskOffset.y);
            sRay1.TMin = 0.02;
            sRay1.TMax = 400.0;

            RayPayload sPayload1;
            sPayload1.color = float4(0, 0, 0, 1);
            sPayload1.normal = float3(0, 1, 0);
            sPayload1.hitT = 1.0;
            sPayload1.matID = 0;

            TraceRay(g_AccelStruct,
                     RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
                     0xFF, 0, 1, 0,
                     sRay1, sPayload1);

            if (sPayload1.hitT < 0.0) {
                shadow += 0.5;
            }

            // Sample 2: Antithetic shadow ray (opposite offset)
            RayDesc sRay2;
            sRay2.Origin = hitWorldPos + worldNormal * 0.05;
            sRay2.Direction = normalize(sunDir - sunTangent * diskOffset.x - sunBitangent * diskOffset.y);
            sRay2.TMin = 0.02;
            sRay2.TMax = 400.0;

            RayPayload sPayload2;
            sPayload2.color = float4(0, 0, 0, 1);
            sPayload2.normal = float3(0, 1, 0);
            sPayload2.hitT = 1.0;
            sPayload2.matID = 0;

            TraceRay(g_AccelStruct,
                     RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
                     0xFF, 0, 1, 0,
                     sRay2, sPayload2);

            if (sPayload2.hitT < 0.0) {
                shadow += 0.5;
            }
        }

        // 4. Hardware Raytraced Ambient Occlusion (RTAO)
        float ao = 1.0;
        if (rtaoStrength > 0.001) {
            float3 Nt = (abs(worldNormal.y) < 0.99) ? normalize(cross(worldNormal, float3(0.0, 1.0, 0.0))) : normalize(cross(worldNormal, float3(1.0, 0.0, 0.0)));
            float3 Nb = cross(worldNormal, Nt);

            float occCount = 0.0;

            // AO Sample 1
            float2 aoRnd = Hash2D(launchIndex, g_Camera.frameIndex, 1u);
            float r1 = sqrt(aoRnd.x * 0.75 + 0.25);
            float phi1 = 6.283185307 * aoRnd.y;
            float3 dirLocal1 = float3(r1 * cos(phi1), r1 * sin(phi1), sqrt(max(0.0, 1.0 - r1 * r1)));
            float3 aoDir1 = normalize(dirLocal1.x * Nt + dirLocal1.y * Nb + dirLocal1.z * worldNormal);

            RayDesc aoRay1;
            aoRay1.Origin = hitWorldPos + worldNormal * 0.05;
            aoRay1.Direction = aoDir1;
            aoRay1.TMin = 0.02;
            aoRay1.TMax = rtaoRadius;

            RayPayload aoPayload1;
            aoPayload1.color = float4(0, 0, 0, 1);
            aoPayload1.normal = float3(0, 1, 0);
            aoPayload1.hitT = 1.0;
            aoPayload1.matID = 0;

            TraceRay(g_AccelStruct,
                     RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
                     0xFF, 0, 1, 0,
                     aoRay1, aoPayload1);

            if (aoPayload1.hitT > 0.0) {
                occCount += 1.0;
            }

            // AO Sample 2 (Opposite azimuth)
            float r2 = sqrt((1.0 - aoRnd.x) * 0.75 + 0.25);
            float phi2 = phi1 + 3.14159265;
            float3 dirLocal2 = float3(r2 * cos(phi2), r2 * sin(phi2), sqrt(max(0.0, 1.0 - r2 * r2)));
            float3 aoDir2 = normalize(dirLocal2.x * Nt + dirLocal2.y * Nb + dirLocal2.z * worldNormal);

            RayDesc aoRay2;
            aoRay2.Origin = hitWorldPos + worldNormal * 0.05;
            aoRay2.Direction = aoDir2;
            aoRay2.TMin = 0.02;
            aoRay2.TMax = rtaoRadius;

            RayPayload aoPayload2;
            aoPayload2.color = float4(0, 0, 0, 1);
            aoPayload2.normal = float3(0, 1, 0);
            aoPayload2.hitT = 1.0;
            aoPayload2.matID = 0;

            TraceRay(g_AccelStruct,
                     RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
                     0xFF, 0, 1, 0,
                     aoRay2, aoPayload2);

            if (aoPayload2.hitT > 0.0) {
                occCount += 1.0;
            }

            float rawOcclusion = occCount * 0.5;
            ao = 1.0 - rawOcclusion * rtaoStrength;
        }

        // 5. Sky Hemisphere ambient lighting with RTAO
        float skyHemi = clamp(worldNormal.y * 0.5 + 0.5, 0.0, 1.0);
        float3 skyAmbientColor = lerp(float3(0.25, 0.22, 0.20), float3(0.40, 0.55, 0.78), skyHemi);
        float3 ambientLight = skyAmbientColor * ambientIntensity * ao;

        // 6. Direct Sunlight
        float3 directLight = sunColor * (sunIntensity * NdotL * shadow);

        // 7. Base lit color
        float3 litColor = albedo * (ambientLight + directLight);

        // 8. Water and Glass Specular & Sky Reflections
        float3 viewDir = -ray.Direction;
        if (matID == 8u) { // Water
            float3 halfVec = normalize(viewDir + sunDir);
            float NdotH = max(0.0, dot(worldNormal, halfVec));
            float specular = pow(NdotH, 96.0) * shadow * waterSpecularMult;

            float fresnel = 0.05 + 0.95 * pow(1.0 - max(0.0, dot(worldNormal, viewDir)), 4.0);
            float3 reflDir = reflect(ray.Direction, worldNormal);
            float3 skyRefl = GetSkyColor(reflDir, sunDir, sunColor);

            litColor = lerp(litColor, skyRefl, fresnel * 0.65) + sunColor * (specular * 1.8);
        }
        else if (matID == 10u) { // Glass
            float3 halfVec = normalize(viewDir + sunDir);
            float NdotH = max(0.0, dot(worldNormal, halfVec));
            float specular = pow(NdotH, 48.0) * shadow * 0.7;

            float fresnel = 0.08 + 0.92 * pow(1.0 - max(0.0, dot(worldNormal, viewDir)), 3.0);
            float3 reflDir = reflect(ray.Direction, worldNormal);
            float3 skyRefl = GetSkyColor(reflDir, sunDir, sunColor);

            litColor = lerp(litColor, skyRefl, fresnel * 0.45) + float3(1.0, 1.0, 1.0) * specular;
        }

        // 9. Distance Atmospheric Fog
        float fog = 1.0 - exp(-payload.hitT * 0.0032);
        float3 horizonRayDir = normalize(float3(ray.Direction.x, max(ray.Direction.y * 0.2, 0.0), ray.Direction.z));
        float3 skyFogColor = GetSkyColor(horizonRayDir, sunDir, sunColor);
        payload.color = float4(lerp(litColor, skyFogColor, clamp(fog, 0.0, 1.0)), 1.0);
    } else {
        // Caelix Architecture: Primary Ray missed all geometry -> directly evaluate sky model!
        float3 sunDir = g_Camera.sunDir.xyz;
        float3 sunColor = g_Camera.sunColor.rgb;
        float3 sky = GetSkyColor(ray.Direction, sunDir, sunColor);
        payload.color = float4(sky, 1.0);
    }

    g_OutputTarget[launchIndex] = payload.color;
}
