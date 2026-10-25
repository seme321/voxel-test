using Godot;
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;

/// <summary>
/// Caelix 风格的 128x128x128 两级稀疏 Sector 存储容器。
/// 包含 4096 个 8x8x8 VoxelBrick 紧凑值类型槽位，连续一维负载缓冲，零 GC 堆垃圾。
/// 支持 64-bit 粗粒度掩码快速跳跃、Dirty Flags 增量管道、以及 6 向跨 Sector 拓扑接缝消除。
/// </summary>
[GlobalClass]
public partial class ChunkData : Resource
{
	public const int DEFAULT_SIZE = 128;
	public const int BRICK_SIZE = 8;
	public const int BRICK_SHIFT = 3;
	public const int BRICK_MASK = 7;

	public enum Voxel : byte { SAND = 0, GRASS = 1, MOUNTAIN = 2, SNOW = 3, AIR = 4 };

	private int size = DEFAULT_SIZE;
	private int bricksPerAxis = 16;   // 128 / 8 = 16
	private int totalBricks = 4096;   // 16 * 16 * 16 = 4096
	private int coarseWords = 64;     // 4096 / 64 = 64
	private int numberOfVoxels = 0;

	// 4096 bits 粗粒度掩码（64 个 ulong，每 bit 对应一个 8x8x8 Brick 是否非空）
	public ulong[] CoarseOccupancy { get; private set; }

	// 4096 个微型 Brick 的结构体平铺数组（仅 288 KB 连续内存，无指针跳跃，零 GC 追踪）
	private VoxelBrick[] bricks;

	// 连续一维体素数据负载池（按需以 512 字节为单位动态复用）
	private Voxel[] voxelPayloads;
	private int payloadCount = 0;
	private readonly Stack<int> freePayloadOffsets = new();

	// 沿 X、Y、Z 轴的切片占用掩码（每层切片 1 bit，128 层切片需要 128 bits = 2 个 ulong）
	private ulong[] layerMaskX;
	private ulong[] layerMaskY;
	private ulong[] layerMaskZ;

	private int[] countX;
	private int[] countY;
	private int[] countZ;

	// 64-bit Dirty Flags：每 1 bit 对应一个 32^3 子区块是否脏（需要重新网格化）
	public ulong DirtySubChunksMask { get; private set; } = 0UL;
	public byte DirtyNeighborMask { get; private set; } = 0;

	// 6 向跨 Sector 邻居引用（拓扑缝合）
	public ChunkData NeighborNegX; // 0: -X
	public ChunkData NeighborPosX; // 1: +X
	public ChunkData NeighborNegY; // 2: -Y
	public ChunkData NeighborPosY; // 3: +Y
	public ChunkData NeighborNegZ; // 4: -Z
	public ChunkData NeighborPosZ; // 5: +Z


	public ChunkData()
	{
		SetSize(size);
	}

	public int GetSize() => size;

	public void SetSize(int newSize)
	{
		size = newSize;
		bricksPerAxis = Math.Max(1, size >> BRICK_SHIFT);
		totalBricks = bricksPerAxis * bricksPerAxis * bricksPerAxis;
		coarseWords = Math.Max(1, (totalBricks + 63) >> 6);

		bricks = new VoxelBrick[totalBricks];
		// 初始化为空气纯色砖块
		for (int i = 0; i < totalBricks; ++i)
		{
			bricks[i] = new VoxelBrick(Voxel.AIR);
		}

		// 预分配 1024 个 Brick 的体素负载池（512 KB，足以容纳大多数地表过渡区，避免反复动态扩容重分配）
		voxelPayloads = new Voxel[1024 * VoxelBrick.TOTAL_VOXELS];
		payloadCount = 0;
		freePayloadOffsets.Clear();

		CoarseOccupancy = new ulong[coarseWords];
		numberOfVoxels = 0;

		int layerWords = Math.Max(1, (size + 63) >> 6);
		layerMaskX = new ulong[layerWords];
		layerMaskY = new ulong[layerWords];
		layerMaskZ = new ulong[layerWords];

		countX = new int[size];
		countY = new int[size];
		countZ = new int[size];

		DirtySubChunksMask = 0UL;
		DirtyNeighborMask = 0;
	}

	public void SetNeighbor(int direction, ChunkData neighbor)
	{
		switch (direction)
		{
			case 0: NeighborNegX = neighbor; break;
			case 1: NeighborPosX = neighbor; break;
			case 2: NeighborNegY = neighbor; break;
			case 3: NeighborPosY = neighbor; break;
			case 4: NeighborNegZ = neighbor; break;
			case 5: NeighborPosZ = neighbor; break;
		}
	}

	private int AllocatePayload()
	{
		if (freePayloadOffsets.Count > 0)
		{
			return freePayloadOffsets.Pop();
		}
		int offset = payloadCount * VoxelBrick.TOTAL_VOXELS;
		payloadCount++;
		if (offset + VoxelBrick.TOTAL_VOXELS > voxelPayloads.Length)
		{
			Array.Resize(ref voxelPayloads, voxelPayloads.Length * 2);
		}
		return offset;
	}

	private void FreePayload(int offset)
	{
		if (offset >= 0)
		{
			freePayloadOffsets.Push(offset);
		}
	}

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	public void MarkSubChunkDirty(int sx, int sy, int sz)
	{
		if ((uint)sx < 4 && (uint)sy < 4 && (uint)sz < 4)
		{
			int subIdx = sx | (sy << 2) | (sz << 4);
			DirtySubChunksMask |= (1UL << subIdx);
		}
	}

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	public void MarkVoxelDirty(int x, int y, int z)
	{
		int sx = x >> 5;
		int sy = y >> 5;
		int sz = z >> 5;
		MarkSubChunkDirty(sx, sy, sz);

		int lx = x & 31;
		int ly = y & 31;
		int lz = z & 31;

		if (lx == 0)
		{
			if (sx > 0) MarkSubChunkDirty(sx - 1, sy, sz);
			else DirtyNeighborMask |= 1;
		}
		else if (lx == 31)
		{
			if (sx < 3) MarkSubChunkDirty(sx + 1, sy, sz);
			else DirtyNeighborMask |= 2;
		}

		if (ly == 0)
		{
			if (sy > 0) MarkSubChunkDirty(sx, sy - 1, sz);
			else DirtyNeighborMask |= 4;
		}
		else if (ly == 31)
		{
			if (sy < 3) MarkSubChunkDirty(sx, sy + 1, sz);
			else DirtyNeighborMask |= 8;
		}

		if (lz == 0)
		{
			if (sz > 0) MarkSubChunkDirty(sx, sy, sz - 1);
			else DirtyNeighborMask |= 16;
		}
		else if (lz == 31)
		{
			if (sz < 3) MarkSubChunkDirty(sx, sy, sz + 1);
			else DirtyNeighborMask |= 32;
		}
	}

	public void MarkBoundaryDirty(int direction)
	{
		for (int a = 0; a < 4; ++a)
		{
			for (int b = 0; b < 4; ++b)
			{
				switch (direction)
				{
					case 0: MarkSubChunkDirty(0, a, b); break; // -X: sx = 0
					case 1: MarkSubChunkDirty(3, a, b); break; // +X: sx = 3
					case 2: MarkSubChunkDirty(a, 0, b); break; // -Y: sy = 0
					case 3: MarkSubChunkDirty(a, 3, b); break; // +Y: sy = 3
					case 4: MarkSubChunkDirty(a, b, 0); break; // -Z: sz = 0
					case 5: MarkSubChunkDirty(a, b, 3); break; // +Z: sz = 3
				}
			}
		}
	}

	public long PopDirtySubChunksMask()
	{
		ulong mask = DirtySubChunksMask;
		DirtySubChunksMask = 0UL;
		return (long)mask;
	}

	public byte PopDirtyNeighborMask()
	{
		byte mask = DirtyNeighborMask;
		DirtyNeighborMask = 0;
		return mask;
	}

	public void ClearDirtySubChunksMask()
	{
		DirtySubChunksMask = 0UL;
		DirtyNeighborMask = 0;
	}

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	public void AddVoxel(int x, int y, int z, Voxel voxel)
	{
		if ((uint)x >= (uint)size || (uint)y >= (uint)size || (uint)z >= (uint)size) return;

		int bx = x >> BRICK_SHIFT;
		int by = y >> BRICK_SHIFT;
		int bz = z >> BRICK_SHIFT;
		int bIndex = bx | (by * bricksPerAxis) | (bz * bricksPerAxis * bricksPerAxis);

		ref VoxelBrick brick = ref bricks[bIndex];
		int lx = x & BRICK_MASK;
		int ly = y & BRICK_MASK;
		int lz = z & BRICK_MASK;
		int localIndex = lx | (ly << 3) | (lz << 6);

		Voxel oldVoxel;
		if (brick.IsUniform)
		{
			oldVoxel = brick.UniformVoxel;
		}
		else if (brick.PayloadOffset >= 0)
		{
			oldVoxel = voxelPayloads[brick.PayloadOffset + localIndex];
		}
		else
		{
			oldVoxel = Voxel.AIR;
		}

		if (oldVoxel == voxel) return;

		// 首次将 Brick 展开为稠密 payload
		if (brick.IsUniform)
		{
			int offset = AllocatePayload();
			Array.Fill(voxelPayloads, brick.UniformVoxel, offset, VoxelBrick.TOTAL_VOXELS);
			brick.PayloadOffset = offset;
			brick.IsUniform = false;
		}
		else if (brick.PayloadOffset < 0)
		{
			if (voxel == Voxel.AIR) return;
			int offset = AllocatePayload();
			Array.Fill(voxelPayloads, Voxel.AIR, offset, VoxelBrick.TOTAL_VOXELS);
			brick.PayloadOffset = offset;
			brick.IsUniform = false;
		}

		voxelPayloads[brick.PayloadOffset + localIndex] = voxel;

		if (oldVoxel == Voxel.AIR && voxel != Voxel.AIR)
		{
			brick.SolidCount++;
			brick.SetOccupancyBit(lx, ly, lz, true);
			CoarseOccupancy[bIndex >> 6] |= (1UL << (bIndex & 63));

			numberOfVoxels++;
			if (++countX[x] == 1) layerMaskX[x >> 6] |= (1UL << (x & 63));
			if (++countY[y] == 1) layerMaskY[y >> 6] |= (1UL << (y & 63));
			if (++countZ[z] == 1) layerMaskZ[z >> 6] |= (1UL << (z & 63));
		}
		else if (oldVoxel != Voxel.AIR && voxel == Voxel.AIR)
		{
			brick.SolidCount--;
			brick.SetOccupancyBit(lx, ly, lz, false);

			numberOfVoxels--;
			if (--countX[x] == 0) layerMaskX[x >> 6] &= ~(1UL << (x & 63));
			if (--countY[y] == 0) layerMaskY[y >> 6] &= ~(1UL << (y & 63));
			if (--countZ[z] == 0) layerMaskZ[z >> 6] &= ~(1UL << (z & 63));

			if (brick.SolidCount <= 0)
			{
				FreePayload(brick.PayloadOffset);
				brick.PayloadOffset = -1;
				brick.IsUniform = true;
				brick.UniformVoxel = Voxel.AIR;
				brick.Mask0 = brick.Mask1 = brick.Mask2 = brick.Mask3 =
				brick.Mask4 = brick.Mask5 = brick.Mask6 = brick.Mask7 = 0UL;
				CoarseOccupancy[bIndex >> 6] &= ~(1UL << (bIndex & 63));
			}
		}

		MarkVoxelDirty(x, y, z);
	}

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	public void RemoveVoxel(int x, int y, int z)
	{
		AddVoxel(x, y, z, Voxel.AIR);
	}

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	public Voxel GetVoxel(int x, int y, int z)
	{
		if ((uint)x >= (uint)size || (uint)y >= (uint)size || (uint)z >= (uint)size)
		{
			// 跨 Sector 边界邻居穿透查询
			if (x < 0 && NeighborNegX != null) return NeighborNegX.GetVoxel(x + size, y, z);
			if (x >= size && NeighborPosX != null) return NeighborPosX.GetVoxel(x - size, y, z);
			if (y < 0 && NeighborNegY != null) return NeighborNegY.GetVoxel(x, y + size, z);
			if (y >= size && NeighborPosY != null) return NeighborPosY.GetVoxel(x, y - size, z);
			if (z < 0 && NeighborNegZ != null) return NeighborNegZ.GetVoxel(x, y, z + size);
			if (z >= size && NeighborPosZ != null) return NeighborPosZ.GetVoxel(x, y, z - size);
			return Voxel.AIR;
		}

		int bx = x >> BRICK_SHIFT;
		int by = y >> BRICK_SHIFT;
		int bz = z >> BRICK_SHIFT;
		int bIndex = bx | (by * bricksPerAxis) | (bz * bricksPerAxis * bricksPerAxis);

		if ((CoarseOccupancy[bIndex >> 6] & (1UL << (bIndex & 63))) == 0)
			return Voxel.AIR;

		ref VoxelBrick brick = ref bricks[bIndex];
		if (brick.IsUniform) return brick.UniformVoxel;
		if (brick.PayloadOffset < 0) return Voxel.AIR;

		int localIdx = (x & BRICK_MASK) | ((y & BRICK_MASK) << 3) | ((z & BRICK_MASK) << 6);
		return voxelPayloads[brick.PayloadOffset + localIdx];
	}

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	public bool IsLayerEmpty(int dimension, int layerIndex)
	{
		if ((uint)layerIndex >= (uint)size) return true;
		int wordIdx = layerIndex >> 6;
		int bitIdx = layerIndex & 63;
		ulong mask = dimension switch
		{
			0 => layerMaskX[wordIdx],
			1 => layerMaskY[wordIdx],
			2 => layerMaskZ[wordIdx],
			_ => 0UL
		};
		return (mask & (1UL << bitIdx)) == 0;
	}

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	public bool HasBrick(int bx, int by, int bz)
	{
		if ((uint)bx >= (uint)bricksPerAxis || (uint)by >= (uint)bricksPerAxis || (uint)bz >= (uint)bricksPerAxis)
			return false;
		int bIndex = bx | (by * bricksPerAxis) | (bz * bricksPerAxis * bricksPerAxis);
		return (CoarseOccupancy[bIndex >> 6] & (1UL << (bIndex & 63))) != 0;
	}

	public VoxelBrick GetBrick(int bx, int by, int bz)
	{
		if ((uint)bx >= (uint)bricksPerAxis || (uint)by >= (uint)bricksPerAxis || (uint)bz >= (uint)bricksPerAxis)
			return default;
		int bIndex = bx | (by * bricksPerAxis) | (bz * bricksPerAxis * bricksPerAxis);
		return bricks[bIndex];
	}

	/// <summary>
	/// 基于 64-bit CoarseOccupancy 掩码超高速检测指定 subChunk (如 32^3) 是否完全为空。
	/// </summary>
	public bool IsSubChunkEmpty(int ox, int oy, int oz, int subSize = 32)
	{
		if (numberOfVoxels <= 0) return true;

		int bx0 = ox >> BRICK_SHIFT;
		int by0 = oy >> BRICK_SHIFT;
		int bz0 = oz >> BRICK_SHIFT;
		int bCount = Math.Max(1, subSize >> BRICK_SHIFT);

		int bxEnd = Math.Min(bricksPerAxis, bx0 + bCount);
		int byEnd = Math.Min(bricksPerAxis, by0 + bCount);
		int bzEnd = Math.Min(bricksPerAxis, bz0 + bCount);

		int startX = Math.Max(0, bx0);
		int startY = Math.Max(0, by0);
		int startZ = Math.Max(0, bz0);

		if (startX >= bxEnd || startY >= byEnd || startZ >= bzEnd) return true;

		for (int bz = startZ; bz < bzEnd; ++bz)
		{
			int zOffset = bz * bricksPerAxis * bricksPerAxis;
			for (int by = startY; by < byEnd; ++by)
			{
				int baseIdx = (by * bricksPerAxis) + zOffset;
				for (int bx = startX; bx < bxEnd; ++bx)
				{
					int bIndex = bx + baseIdx;
					if ((CoarseOccupancy[bIndex >> 6] & (1UL << (bIndex & 63))) != 0)
					{
						return false;
					}
				}
			}
		}
		return true;
	}

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	public bool IsSubChunkEmpty(Vector3I subOrigin, int subSize = 32)
	{
		return IsSubChunkEmpty(subOrigin.X, subOrigin.Y, subOrigin.Z, subSize);
	}

	/// <summary>
	/// 基于 Caelix 思想的高速地形生成器。
	/// 结合 Brick 级 AABB 包围盒剪枝与一维连续缓冲填充：零托管堆分配，零 GC 垃圾。
	/// </summary>
	public void GenerateTerrainCaelix(
		Vector3 position,
		FastNoiseLite terrainNoise,
		FastNoiseLite biomeNoise,
		float noiseWeight = 0.8f,
		float surfaceThreshold = 0.0f,
		int maxHeight = 128)
	{
		float safeMaxHeight = Math.Max(1, maxHeight);
		float invMaxHeight = 1.0f / safeMaxHeight;

		// 1. 预计算 128x128 水平群系分布
		Voxel[] biomeColumn = new Voxel[size * size];
		bool[] snowColumn = new bool[size * size];

		if (biomeNoise != null)
		{
			for (int x = 0; x < size; ++x)
			{
				float gx = position.X + x;
				int rowIdx = x * size;
				for (int z = 0; z < size; ++z)
				{
					float gz = position.Z + z;
					float n1 = biomeNoise.GetNoise2D(gx, gz);
					float n2 = biomeNoise.GetNoise2D(2.0f * gx, 2.0f * gz);
					float n3 = biomeNoise.GetNoise2D(4.0f * gx, 4.0f * gz);
					float biomeN = ((n1 + 0.5f * n2 + 0.25f * n3) / 1.75f + 1.0f) * 0.5f;

					biomeColumn[rowIdx + z] = (biomeN > 0.55f) ? Voxel.GRASS : Voxel.SAND;
					snowColumn[rowIdx + z] = (biomeN > 0.5f);
				}
			}
		}

		for (int bx = 0; bx < bricksPerAxis; ++bx)
		{
			int baseGx = (int)position.X + (bx << BRICK_SHIFT);

			for (int bz = 0; bz < bricksPerAxis; ++bz)
			{
				int baseGz = (int)position.Z + (bz << BRICK_SHIFT);

				for (int by = 0; by < bricksPerAxis; ++by)
				{
					int baseGy = (int)position.Y + (by << BRICK_SHIFT);
					int minY = baseGy;
					int maxY = baseGy + 7;
					int bIndex = bx | (by * bricksPerAxis) | (bz * bricksPerAxis * bricksPerAxis);

					float maxDensity = (1.0f - (minY * invMaxHeight) * 2.0f) + noiseWeight;
					float minDensity = (1.0f - (maxY * invMaxHeight) * 2.0f) - noiseWeight;

					// 1. 天空砖块快速跳过
					if (minY >= maxHeight || maxDensity <= surfaceThreshold)
					{
						continue;
					}

					// 2. 深层地底砖块纯色折叠：零内存拷贝
					if (maxY <= 0 || minDensity > surfaceThreshold)
					{
						ref VoxelBrick uniformBrick = ref bricks[bIndex];
						uniformBrick.IsUniform = true;
						uniformBrick.UniformVoxel = Voxel.MOUNTAIN;
						uniformBrick.SolidCount = (ushort)VoxelBrick.TOTAL_VOXELS;
						uniformBrick.PayloadOffset = -1;
						uniformBrick.Mask0 = uniformBrick.Mask1 = uniformBrick.Mask2 = uniformBrick.Mask3 =
						uniformBrick.Mask4 = uniformBrick.Mask5 = uniformBrick.Mask6 = uniformBrick.Mask7 = 0xFFFFFFFFFFFFFFFFUL;

						CoarseOccupancy[bIndex >> 6] |= (1UL << (bIndex & 63));
						numberOfVoxels += VoxelBrick.TOTAL_VOXELS;

						for (int ly = 0; ly < BRICK_SIZE; ++ly)
						{
							int y = (by << BRICK_SHIFT) + ly;
							countY[y] += BRICK_SIZE * BRICK_SIZE;
							layerMaskY[y >> 6] |= (1UL << (y & 63));
						}
						for (int lx = 0; lx < BRICK_SIZE; ++lx)
						{
							int x = (bx << BRICK_SHIFT) + lx;
							countX[x] += BRICK_SIZE * BRICK_SIZE;
							layerMaskX[x >> 6] |= (1UL << (x & 63));
						}
						for (int lz = 0; lz < BRICK_SIZE; ++lz)
						{
							int z = (bz << BRICK_SHIFT) + lz;
							countZ[z] += BRICK_SIZE * BRICK_SIZE;
							layerMaskZ[z >> 6] |= (1UL << (z & 63));
						}
						continue;
					}

					// 3. 地表混合过渡区：向连续一维缓冲区写入
					int offset = AllocatePayload();
					Array.Fill(voxelPayloads, Voxel.AIR, offset, VoxelBrick.TOTAL_VOXELS);

					ref VoxelBrick brick = ref bricks[bIndex];
					brick.IsUniform = false;
					brick.UniformVoxel = Voxel.AIR;
					brick.PayloadOffset = offset;
					brick.SolidCount = 0;
					brick.Mask0 = brick.Mask1 = brick.Mask2 = brick.Mask3 =
					brick.Mask4 = brick.Mask5 = brick.Mask6 = brick.Mask7 = 0UL;

					int solidCountInBrick = 0;

					for (int lx = 0; lx < BRICK_SIZE; ++lx)
					{
						int x = (bx << BRICK_SHIFT) + lx;
						float gx = baseGx + lx;
						int colBase = x * size;

						for (int lz = 0; lz < BRICK_SIZE; ++lz)
						{
							int z = (bz << BRICK_SHIFT) + lz;
							float gz = baseGz + lz;

							Voxel baseBiome = biomeColumn[colBase + z];
							bool isSnowCandidate = snowColumn[colBase + z];

							for (int ly = 0; ly < BRICK_SIZE; ++ly)
							{
								int y = (by << BRICK_SHIFT) + ly;
								float gy = baseGy + ly;

								float gradient = 1.0f - (gy * invMaxHeight) * 2.0f;
								float n = terrainNoise.GetNoise3D(gx, gy, gz);
								bool hasVoxel = (gradient + n * noiseWeight) > surfaceThreshold;

								if (!hasVoxel) continue;

								float heightFactor = gy * invMaxHeight;
								Voxel voxel = baseBiome;
								if (heightFactor >= 0.22f)
								{
									voxel = Voxel.MOUNTAIN;
									if (isSnowCandidate && heightFactor > 0.4f)
									{
										voxel = Voxel.SNOW;
									}
								}

								int localIndex = lx | (ly << 3) | (lz << 6);
								voxelPayloads[offset + localIndex] = voxel;
								brick.SetOccupancyBit(lx, ly, lz, true);
								solidCountInBrick++;

								numberOfVoxels++;
								if (++countX[x] == 1) layerMaskX[x >> 6] |= (1UL << (x & 63));
								if (++countY[y] == 1) layerMaskY[y >> 6] |= (1UL << (y & 63));
								if (++countZ[z] == 1) layerMaskZ[z >> 6] |= (1UL << (z & 63));
							}
						}
					}

					if (solidCountInBrick > 0)
					{
						brick.SolidCount = (ushort)solidCountInBrick;
						CoarseOccupancy[bIndex >> 6] |= (1UL << (bIndex & 63));
					}
					else
					{
						FreePayload(offset);
						brick.PayloadOffset = -1;
						brick.IsUniform = true;
						brick.UniformVoxel = Voxel.AIR;
					}
				}
			}
		}
	}

	public int NumberOfVoxels() => numberOfVoxels;
	public bool IsEmpty() => numberOfVoxels <= 0;
}
