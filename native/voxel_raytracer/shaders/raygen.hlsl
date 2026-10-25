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

    TraceRay(g_AccelStruct, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);

    if (payload.hitT > 0.0) {
        float3 hitWorldPos = rayOrigin + ray.Direction * payload.hitT;
        float3 sunDir = normalize(float3(0.55, 0.75, 0.35));
        float NdotL = max(0.0, dot(payload.normal, sunDir));
        float shadow = 0.0;

        // Trace real-time hardware shadow ray if surface faces the sun
        if (NdotL > 0.001) {
            RayDesc shadowRay;
            shadowRay.Origin = hitWorldPos + payload.normal * 0.05;
            shadowRay.Direction = sunDir;
            shadowRay.TMin = 0.02;
            shadowRay.TMax = 400.0;

            RayPayload shadowPayload;
            shadowPayload.color = float4(0.0, 0.0, 0.0, 1.0);
            shadowPayload.normal = float3(0.0, 1.0, 0.0);
            shadowPayload.hitT = 1.0; // Presume occluded until miss shader confirms clear sky

            TraceRay(g_AccelStruct,
                     RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
                     0xFF, 0, 1, 0,
                     shadowRay, shadowPayload);

            // If ray escaped all geometry into the sky, miss shader executed and set hitT = -1.0
            if (shadowPayload.hitT < 0.0) {
                shadow = 1.0;
            }
        }

        // Physically plausible illumination: Ambient (0.26) + Direct Sun (0.74 * NdotL * shadow)
        // If block is emissive (payload.color.a > 1.5, e.g. Glowstone), unshaded radiant boost
        float isEmissive = (payload.color.a > 1.5) ? 1.0 : 0.0;
        float lighting = lerp(0.26 + 0.74 * NdotL * shadow, 1.4, isEmissive);
        float3 albedo = payload.color.rgb;
        float3 litColor = albedo * lighting;

        // Exponential atmospheric distance fog
        float fog = 1.0 - exp(-payload.hitT * 0.0035);
        float3 skyFogColor = float3(0.72, 0.80, 0.89);
        payload.color = float4(lerp(litColor, skyFogColor, clamp(fog, 0.0, 1.0)), 1.0);
    }

    g_OutputTarget[launchIndex] = payload.color;
}
