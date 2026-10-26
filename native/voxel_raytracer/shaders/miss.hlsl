#include "common.hlsl"

[shader("miss")]
void MissMain(inout RayPayload payload)
{
    float3 rayDir = WorldRayDirection();
    float3 sky = GetSkyColor(rayDir, g_Camera.sunDir.xyz, g_Camera.sunColor.rgb);

    payload.color = float4(sky, 1.0);
    payload.hitT = -1.0;
    payload.matID = 0;
}
