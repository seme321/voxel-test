#include "common.hlsl"

[shader("closesthit")]
void ClosestHitMain(inout RayPayload payload, AttributeData attrib)
{
    uint matID = (attrib.matID_faceNormal >> 16u) & 0xFFFFu;
    uint normalFlag = attrib.matID_faceNormal & 0x3Fu;

    // Transform Object-space normal to World-space
    float3 objNormal = UnpackNormal(normalFlag);
    float3 worldNormal = normalize(mul((float3x3)ObjectToWorld3x4(), objNormal));

    // Directional sunlight + ambient term
    float3 sunDir = normalize(float3(0.55, 0.75, 0.35));
    float NdotL = max(0.0, dot(worldNormal, sunDir));
    float ambient = 0.22;
    float lighting = ambient + NdotL * 0.78;

    float3 albedo = GetVoxelColor(matID);
    payload.color = float4(albedo * lighting, 1.0);
    payload.normal = worldNormal;
    payload.hitT = RayTCurrent();
}
