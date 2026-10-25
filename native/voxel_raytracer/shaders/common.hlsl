#ifndef COMMON_HLSL
#define COMMON_HLSL

struct CameraParams {
    float4x4 viewInverse;
    float4x4 projInverse;
    float4 camPos;
    float fov;
    uint width;
    uint height;
    uint frameIndex;
};

// Global Bindings (Set 0)
RaytracingAccelerationStructure g_AccelStruct : register(t0, space0);
RWTexture2D<float4> g_OutputTarget : register(u0, space0);
ByteAddressBuffer g_Bricks : register(t1, space0);
ConstantBuffer<CameraParams> g_Camera : register(b0, space0);

struct RayPayload {
    float4 color;
    float3 normal;
    float hitT;
};

struct AttributeData {
    // High 16: matID, Low 6: faceNormalFlags
    uint matID_faceNormal;
};

// Voxel Face Normal decoding
static const float3 kFaceNormals[6] = {
    float3( 1.0,  0.0,  0.0), // 0b000001: +X
    float3(-1.0,  0.0,  0.0), // 0b000010: -X
    float3( 0.0,  1.0,  0.0), // 0b000100: +Y
    float3( 0.0, -1.0,  0.0), // 0b001000: -Y
    float3( 0.0,  0.0,  1.0), // 0b010000: +Z
    float3( 0.0,  0.0, -1.0)  // 0b100000: -Z
};

inline float3 UnpackNormal(uint normalFlag) {
    if (normalFlag & 0x01) return kFaceNormals[0];
    if (normalFlag & 0x02) return kFaceNormals[1];
    if (normalFlag & 0x04) return kFaceNormals[2];
    if (normalFlag & 0x08) return kFaceNormals[3];
    if (normalFlag & 0x10) return kFaceNormals[4];
    return kFaceNormals[5];
}

// Procedural voxel color palette
inline float3 GetVoxelColor(uint matID) {
    switch (matID) {
        case 1: return float3(0.35, 0.65, 0.25); // Grass green
        case 2: return float3(0.55, 0.40, 0.25); // Dirt brown
        case 3: return float3(0.50, 0.50, 0.50); // Stone gray
        case 4: return float3(0.85, 0.75, 0.45); // Sand yellow
        case 5: return float3(0.40, 0.25, 0.15); // Wood bark
        case 6: return float3(0.20, 0.50, 0.20); // Leaves
        case 7: return float3(0.25, 0.45, 0.85); // Water blue
        default: return float3(0.80, 0.30, 0.70); // Custom / Debug magenta
    }
}

#endif // COMMON_HLSL
