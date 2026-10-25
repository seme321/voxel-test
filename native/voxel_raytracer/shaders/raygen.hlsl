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

    g_OutputTarget[launchIndex] = payload.color;
}
