#include "common.hlsl"

[shader("closesthit")]
void ClosestHitMain(inout RayPayload payload, AttributeData attrib)
{
    uint matID = (attrib.matID_faceNormal >> 16u) & 0xFFFFu;
    uint normalFlag = attrib.matID_faceNormal & 0x3Fu;

    // Transform Object-space normal to World-space
    float3 objNormal = UnpackNormal(normalFlag);
    float3 worldNormal = normalize(mul((float3x3)ObjectToWorld3x4(), objNormal));

    // Export raw albedo and world normal for lighting & shadow in raygen
    // For emissive block (matID == 11, Glowstone), mark alpha = 2.0 to signal unshaded emission in raygen
    float emissionAlpha = (matID == 11u) ? 2.0 : 1.0;
    payload.color = float4(GetVoxelColor(matID), emissionAlpha);
    payload.normal = worldNormal;
    payload.hitT = RayTCurrent();
}
