#include "common.hlsl"

[shader("miss")]
void MissMain(inout RayPayload payload)
{
    float3 rayDir = WorldRayDirection();
    // Procedural sky gradient (Sun / Sky dome)
    float t = 0.5 * (rayDir.y + 1.0);
    float3 sky = lerp(float3(0.75, 0.82, 0.90), float3(0.20, 0.45, 0.85), clamp(t, 0.0, 1.0));
    
    // Add sun highlight
    float3 sunDir = normalize(float3(0.55, 0.75, 0.35));
    float sun = max(0.0, dot(rayDir, sunDir));
    sky += float3(1.0, 0.9, 0.7) * pow(sun, 64.0);

    payload.color = float4(sky, 1.0);
    payload.hitT = -1.0;
}
