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
    float4 sunDir;         // xyz: normalized sun dir, w: sun intensity
    float4 sunColor;       // rgb: sun color, w: ambient intensity
    float4 visualSettings; // x: rtao_strength, y: rtao_radius, z: soft_shadow_angle, w: water_specular
};

// Global Bindings (Set 0)
[[vk::binding(0, 0)]] RaytracingAccelerationStructure g_AccelStruct : register(t0, space0);
[[vk::binding(1, 0)]] RWTexture2D<float4> g_OutputTarget : register(u0, space0);
[[vk::binding(2, 0)]] ByteAddressBuffer g_Bricks : register(t1, space0);
[[vk::binding(3, 0)]] ConstantBuffer<CameraParams> g_Camera : register(b0, space0);

struct RayPayload {
    float4 color;
    float3 normal;
    float hitT;
    uint matID;
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
        case 1: return float3(0.35, 0.65, 0.25); // 1: Grass green
        case 2: return float3(0.55, 0.40, 0.25); // 2: Dirt brown
        case 3: return float3(0.50, 0.50, 0.50); // 3: Stone gray
        case 4: return float3(0.85, 0.75, 0.45); // 4: Sand yellow
        case 5: return float3(0.95, 0.95, 0.98); // 5: Snow white
        case 6: return float3(0.40, 0.25, 0.15); // 6: Wood log bark brown
        case 7: return float3(0.20, 0.50, 0.20); // 7: Leaves green
        case 8: return float3(0.20, 0.45, 0.85); // 8: Water blue
        case 9: return float3(0.42, 0.40, 0.40); // 9: Gravel dark gray
        case 10: return float3(0.80, 0.90, 0.95); // 10: Glass light cyan
        case 11: return float3(1.00, 0.85, 0.30); // 11: Glowstone warm gold
        default: return float3(0.80, 0.30, 0.70); // Custom / Debug magenta
    }
}

// Atmospheric Procedural Sky Model
inline float3 GetSkyColor(float3 dir, float3 sunDir, float3 sunColor) {
    float sunLen = length(sunDir);
    float3 safeSunDir = (sunLen > 0.001) ? (sunDir / sunLen) : normalize(float3(0.55, 0.75, 0.35));
    float sunColorLen = length(sunColor);
    float3 safeSunColor = (sunColorLen > 0.001) ? sunColor : float3(1.0, 0.95, 0.85);

    float sunDot = clamp(dot(dir, safeSunDir), -1.0, 1.0);
    float height = clamp(dir.y, -1.0, 1.0);
    float sunHeight = clamp(safeSunDir.y, -1.0, 1.0);
    
    // Sunset / sunrise horizon warm golden-orange transition
    float sunsetFactor = clamp(1.0 - abs(sunHeight), 0.0, 1.0);
    float3 horizonColor = lerp(float3(0.72, 0.80, 0.90), float3(0.96, 0.55, 0.22), sunsetFactor * 0.85);
    float3 zenithColor = lerp(float3(0.20, 0.48, 0.88), float3(0.08, 0.18, 0.45), sunsetFactor * 0.6);
    
    float t = clamp(height * 0.5 + 0.5, 0.0, 1.0);
    float3 baseSky = lerp(horizonColor * 0.75, zenithColor, pow(t, 0.75));
    if (dir.y < 0.0) {
        baseSky = lerp(horizonColor * 0.75, float3(0.18, 0.17, 0.16), clamp(-dir.y * 3.0, 0.0, 1.0));
    }
    
    // Sun disc & atmospheric halo
    float sunDisc = max(0.0, sunDot);
    float disc = pow(sunDisc, 512.0) * 4.0;
    float corona = pow(max(0.0, sunDot), 32.0) * 0.45;
    
    return baseSky + safeSunColor * (disc + corona);
}

// Pseudo-random 2D hash for jittering
inline uint HashUInt2(uint2 v, uint seed) {
    uint h = seed ^ (v.x * 0x27d4eb2d) ^ (v.y * 0x165667b1);
    h = (h ^ 61) ^ (h >> 16);
    h += (h << 3);
    h ^= (h >> 4);
    h *= 0x27d4eb2d;
    h ^= (h >> 15);
    return h;
}

inline float2 Hash2D(uint2 pixel, uint frame, uint sampleIndex) {
    uint h1 = HashUInt2(pixel, frame * 1973u + sampleIndex * 9277u + 1u);
    uint h2 = HashUInt2(pixel, frame * 3149u + sampleIndex * 4099u + 1013904223u);
    return float2((h1 & 0x00FFFFFFu) / 16777216.0f, (h2 & 0x00FFFFFFu) / 16777216.0f);
}

#endif // COMMON_HLSL
