#include "common.hlsl"

[shader("miss")]
void MissMain(inout RayPayload payload)
{
    float3 rayDir = WorldRayDirection();
    float3 sunDir = normalize(g_Camera.sunDir.xyz);
    float3 sunColor = g_Camera.sunColor.rgb;

    float3 sky = GetSkyColor(rayDir, sunDir, sunColor);

    payload.color = float4(sky, 1.0);
    payload.hitT = -1.0;
    payload.matID = 0;
}
