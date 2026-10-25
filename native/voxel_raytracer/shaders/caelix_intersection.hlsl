#include "common.hlsl"

#define BRICK_SIZE 8
#define BRICK_DATA_BYTES 1096
#define BRICK_MAX_STEPS 22
#define BRICK_EPSILON 0.0001f

inline int3 VRTJump(int3 cell, float3 rayDir, uint mask) {
    return lerp(cell | mask, cell & (~mask), rayDir < 0.0);
}

inline float3 SafeInvDir(float3 d) {
    return float3(
        abs(d.x) > 1e-8 ? 1.0 / d.x : (d.x < 0 ? -1e8 : 1e8),
        abs(d.y) > 1e-8 ? 1.0 / d.y : (d.y < 0 ? -1e8 : 1e8),
        abs(d.z) > 1e-8 ? 1.0 / d.z : (d.z < 0 ? -1e8 : 1e8)
    );
}

inline float3 BoundaryOffset(float3 d) {
    return float3(
        d.x >= 0.0 ? 1.0 : 0.0,
        d.y >= 0.0 ? 1.0 : 0.0,
        d.z >= 0.0 ? 1.0 : 0.0
    );
}

inline int3 VRTStep(int3 cell, float3 tStart, float3 origin, float3 rayDir, float3 invDir) {
    float3 sideDist = tStart + float3(cell) * invDir;
    float tmin = min(min(sideDist.x, sideDist.y), sideDist.z) + BRICK_EPSILON;
    float3 currPos = origin + tmin * rayDir;
    return int3(floor(currPos));
}

inline uint NormalFlags(uint stepIdx, int3 cell, float3 tStart, float3 rayDir, float3 invDir, uint entryFlags, out float hitOffsetT) {
    if (stepIdx == 0u) {
        hitOffsetT = 0.0;
        return entryFlags;
    }
    float3 sideDist = tStart + float3(cell) * invDir;
    hitOffsetT = min(min(sideDist.x, sideDist.y), sideDist.z);

    bool3 axisMask = sideDist <= float3(hitOffsetT + BRICK_EPSILON, hitOffsetT + BRICK_EPSILON, hitOffsetT + BRICK_EPSILON);
    uint xUse = axisMask.x ? 0xFFFFFFFFu : 0u;
    uint yUse = (axisMask.y ? 0xFFFFFFFFu : 0u) & ~xUse;
    uint zUse = ~(xUse | yUse);

    uint xFlag = rayDir.x > 0.0 ? 0b000010 : 0b000001; // -X or +X
    uint yFlag = rayDir.y > 0.0 ? 0b001000 : 0b000100; // -Y or +Y
    uint zFlag = rayDir.z > 0.0 ? 0b100000 : 0b010000; // -Z or +Z

    return (xFlag & xUse) | (yFlag & yUse) | (zFlag & zUse);
}

inline uint ReadVoxelID(uint brickBase, int3 localPos) {
    uint voxelIdx = uint(localPos.x + localPos.y * 8 + localPos.z * 64);
    uint wordOffset = 72 + (voxelIdx / 2) * 4;
    uint word = g_Bricks.Load(brickBase + wordOffset);
    if (voxelIdx & 1) {
        return (word >> 16) & 0xFFFF;
    } else {
        return word & 0xFFFF;
    }
}

[shader("intersection")]
void IntersectionMain()
{
    uint primID = PrimitiveIndex();
    uint brickBase = (InstanceID() + primID) * BRICK_DATA_BYTES;

    // Load Word 0 and Word 1
    uint2 brickInfo = g_Bricks.Load2(brickBase);
    uint idx = brickInfo.x & 0xFFFu;
    uint coarseOccupancy = (brickInfo.x >> 16u) & 0xFFu;
    uint tightBounds = brickInfo.y;

    // Local Brick Origin inside the Sector (0..15 on each axis * 8)
    int bX = int(idx & 15u) * 8;
    int bY = int((idx >> 4u) & 15u) * 8;
    int bZ = int(idx >> 8u) * 8;
    float3 brickOrigin = float3(bX, bY, bZ);

    float3 tightMin = float3(
        tightBounds & 7u,
        (tightBounds >> 3u) & 7u,
        (tightBounds >> 6u) & 7u
    );
    float3 tightMax = float3(
        (tightBounds >> 9u) & 7u,
        (tightBounds >> 12u) & 7u,
        (tightBounds >> 15u) & 7u
    ) + 1.0f;

    float3 aabbMin = brickOrigin + tightMin;
    float3 aabbMax = brickOrigin + tightMax;

    // Ray Slab Test in Object Space
    float3 rayDir = ObjectRayDirection();
    float3 invDir = SafeInvDir(rayDir);
    float3 t0 = (aabbMin - ObjectRayOrigin()) * invDir;
    float3 t1 = (aabbMax - ObjectRayOrigin()) * invDir;

    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);

    float largestTmin = max(max(tmin.x, tmin.y), tmin.z);
    float smallestTmax = min(min(tmax.x, tmax.y), tmax.z);

    if (largestTmin > smallestTmax || smallestTmax < 0.0 || largestTmin > RayTCurrent()) {
        return;
    }

    float entryT = max(0.0, largestTmin);
    float3 entryPos = ObjectRayOrigin() + rayDir * entryT - brickOrigin;

    // Entry face normal
    uint entryNormalFlags = 0;
    if (largestTmin == tmin.x) {
        entryNormalFlags = rayDir.x > 0.0 ? 0b000010 : 0b000001;
    } else if (largestTmin == tmin.y) {
        entryNormalFlags = rayDir.y > 0.0 ? 0b001000 : 0b000100;
    } else {
        entryNormalFlags = rayDir.z > 0.0 ? 0b100000 : 0b010000;
    }

    // Micro-DDA inside the 8x8x8 Brick
    float3 tStart = (BoundaryOffset(rayDir) - entryPos) * invDir;
    float3 origin = clamp(entryPos, 0.0, 7.999);
    int3 cell = int3(floor(origin));
    int3 prevCell = cell;

    [loop]
    for (uint step = 0; step < BRICK_MAX_STEPS; ++step) {
        if (any(uint3(cell) >= 8u)) {
            break;
        }

        // 2x2x2 Coarse Jump
        uint3 coarseCell = uint3(cell) >> 2u;
        uint coarseBit = coarseCell.x | (coarseCell.y << 1u) | (coarseCell.z << 2u);
        if ((coarseOccupancy & (1u << coarseBit)) == 0u) {
            cell = VRTJump(cell, rayDir, 3u);
            prevCell = cell;
            cell = VRTStep(cell, tStart, origin, rayDir, invDir);
            continue;
        }

        // Micro-Occupancy 64-bit mask test
        uint occOffset = 8 + coarseBit * 8;
        uint2 occ64 = g_Bricks.Load2(brickBase + occOffset);
        
        int3 microCell = cell & 3;
        uint microBit = uint(microCell.x | (microCell.y << 2u) | (microCell.z << 4u));
        bool isOccupied = false;
        if (microBit < 32u) {
            isOccupied = (occ64.x & (1u << microBit)) != 0u;
        } else {
            isOccupied = (occ64.y & (1u << (microBit - 32u))) != 0u;
        }

        if (isOccupied) {
            uint voxelID = ReadVoxelID(brickBase, cell);
            if (voxelID > 0u) {
                float hitOffsetT;
                uint normalFlag = NormalFlags(step, prevCell, tStart, rayDir, invDir, entryNormalFlags, hitOffsetT);
                
                AttributeData attrib;
                attrib.matID_faceNormal = (voxelID << 16u) | (normalFlag & 0x3Fu);
                ReportHit(entryT + hitOffsetT, 0, attrib);
                return;
            }
        }

        prevCell = cell;
        cell = VRTStep(cell, tStart, origin, rayDir, invDir);
    }
}
