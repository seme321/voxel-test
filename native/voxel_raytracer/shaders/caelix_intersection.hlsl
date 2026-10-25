#include "common.hlsl"

#define BRICK_SIZE 8
#define BRICK_DATA_BYTES 1096
#define BRICK_MAX_STEPS 28
#define BRICK_EPSILON 0.0001f

inline float3 SafeInvDir(float3 d) {
    return float3(
        abs(d.x) > 1e-8 ? 1.0 / d.x : (d.x < 0.0 ? -1e8 : 1e8),
        abs(d.y) > 1e-8 ? 1.0 / d.y : (d.y < 0.0 ? -1e8 : 1e8),
        abs(d.z) > 1e-8 ? 1.0 / d.z : (d.z < 0.0 ? -1e8 : 1e8)
    );
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
    if (tmin.x >= tmin.y && tmin.x >= tmin.z) {
        entryNormalFlags = rayDir.x > 0.0 ? 0b000010 : 0b000001; // -X or +X
    } else if (tmin.y >= tmin.z) {
        entryNormalFlags = rayDir.y > 0.0 ? 0b001000 : 0b000100; // -Y or +Y
    } else {
        entryNormalFlags = rayDir.z > 0.0 ? 0b100000 : 0b010000; // -Z or +Z
    }

    // Amanatides-Woo 3D DDA traversal inside the 8x8x8 Brick
    float3 pos = clamp(entryPos, 0.0, 7.9999);
    int3 cell = int3(floor(pos));

    int3 stepDir = int3(
        rayDir.x > 0.0 ? 1 : (rayDir.x < 0.0 ? -1 : 0),
        rayDir.y > 0.0 ? 1 : (rayDir.y < 0.0 ? -1 : 0),
        rayDir.z > 0.0 ? 1 : (rayDir.z < 0.0 ? -1 : 0)
    );

    float3 nextBoundary = float3(
        rayDir.x > 0.0 ? float(cell.x + 1) : float(cell.x),
        rayDir.y > 0.0 ? float(cell.y + 1) : float(cell.y),
        rayDir.z > 0.0 ? float(cell.z + 1) : float(cell.z)
    );

    float3 tMax = (nextBoundary - pos) * invDir;
    if (rayDir.x == 0.0) tMax.x = 1e30;
    if (rayDir.y == 0.0) tMax.y = 1e30;
    if (rayDir.z == 0.0) tMax.z = 1e30;

    float3 tDelta = abs(invDir);

    float hitOffsetT = 0.0;
    uint currentNormalFlag = entryNormalFlags;

    [loop]
    for (uint step = 0; step < BRICK_MAX_STEPS; ++step) {
        if (any(uint3(cell) >= 8u)) {
            break;
        }

        // Planar Z-slice bitmask test: Mask0..Mask7 (8 slices of 64-bit uint64)
        uint occOffset = 8u + uint(cell.z) * 8u;
        uint2 occ64 = g_Bricks.Load2(brickBase + occOffset);
        uint bitIdx = uint(cell.x | (cell.y << 3));
        bool isOccupied = (bitIdx < 32u) 
            ? ((occ64.x & (1u << bitIdx)) != 0u) 
            : ((occ64.y & (1u << (bitIdx - 32u))) != 0u);

        if (isOccupied) {
            uint voxelID = ReadVoxelID(brickBase, cell);
            if (voxelID > 0u) {
                float totalHitT = entryT + hitOffsetT;
                AttributeData attrib;
                attrib.matID_faceNormal = (voxelID << 16u) | (currentNormalFlag & 0x3Fu);
                ReportHit(totalHitT, 0, attrib);
                return;
            }
        }

        // Step to next voxel along ray
        if (tMax.x < tMax.y) {
            if (tMax.x < tMax.z) {
                cell.x += stepDir.x;
                hitOffsetT = tMax.x;
                tMax.x += tDelta.x;
                currentNormalFlag = stepDir.x > 0 ? 0b000010 : 0b000001;
            } else {
                cell.z += stepDir.z;
                hitOffsetT = tMax.z;
                tMax.z += tDelta.z;
                currentNormalFlag = stepDir.z > 0 ? 0b100000 : 0b010000;
            }
        } else {
            if (tMax.y < tMax.z) {
                cell.y += stepDir.y;
                hitOffsetT = tMax.y;
                tMax.y += tDelta.y;
                currentNormalFlag = stepDir.y > 0 ? 0b001000 : 0b000100;
            } else {
                cell.z += stepDir.z;
                hitOffsetT = tMax.z;
                tMax.z += tDelta.z;
                currentNormalFlag = stepDir.z > 0 ? 0b100000 : 0b010000;
            }
        }
    }
}
