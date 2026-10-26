#include "common.hlsl"

[shader("closesthit")]
void ClosestHitMain(inout RayPayload payload, AttributeData attrib)
{
    uint matID = (attrib.matID_faceNormal >> 16u) & 0xFFFFu;
    uint normalFlag = attrib.matID_faceNormal & 0x3Fu;

    // Transform Object-space normal to World-space
    float3 objNormal = UnpackNormal(normalFlag);
    float3 worldNormal = normalize(mul((float3x3)ObjectToWorld3x4(), objNormal));

    payload.color = float4(GetVoxelColor(matID), 1.0);
    payload.normal = worldNormal;
    payload.hitT = RayTCurrent();
    payload.matID = matID;
}
