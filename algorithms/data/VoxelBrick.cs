using System;
using System.Runtime.CompilerServices;

/// <summary>
/// Caelix 风格的 8x8x8 (512 体素) 紧凑微型砖块结构体（值类型）。
/// 包含 512-bit 内联微掩码与纯色折叠优化，完全消除 C# 托管堆分配与 GC 压力。
/// </summary>
public struct VoxelBrick
{
	public const int SIZE = 8;
	public const int TOTAL_VOXELS = 512; // 8 * 8 * 8

	public bool IsUniform;
	public ChunkData.Voxel UniformVoxel;
	public ushort SolidCount;
	public int PayloadOffset; // -1 表示纯色/空气，>= 0 表示在 ChunkData.voxelPayloads 中的连续偏移

	// 内联 512 bits (8 个 ulong)，无需在堆上分配数组
	public ulong Mask0;
	public ulong Mask1;
	public ulong Mask2;
	public ulong Mask3;
	public ulong Mask4;
	public ulong Mask5;
	public ulong Mask6;
	public ulong Mask7;

	public VoxelBrick(ChunkData.Voxel uniformVoxel)
	{
		IsUniform = true;
		UniformVoxel = uniformVoxel;
		SolidCount = (uniformVoxel != ChunkData.Voxel.AIR) ? (ushort)TOTAL_VOXELS : (ushort)0;
		PayloadOffset = -1;
		Mask0 = Mask1 = Mask2 = Mask3 = Mask4 = Mask5 = Mask6 = Mask7 = 
			(uniformVoxel != ChunkData.Voxel.AIR) ? 0xFFFFFFFFFFFFFFFFUL : 0UL;
	}

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	public ulong GetMicroMask(int wordIdx) => wordIdx switch
	{
		0 => Mask0,
		1 => Mask1,
		2 => Mask2,
		3 => Mask3,
		4 => Mask4,
		5 => Mask5,
		6 => Mask6,
		7 => Mask7,
		_ => 0UL
	};

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	public void SetMicroMask(int wordIdx, ulong val)
	{
		switch (wordIdx)
		{
			case 0: Mask0 = val; break;
			case 1: Mask1 = val; break;
			case 2: Mask2 = val; break;
			case 3: Mask3 = val; break;
			case 4: Mask4 = val; break;
			case 5: Mask5 = val; break;
			case 6: Mask6 = val; break;
			case 7: Mask7 = val; break;
		}
	}

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	public void SetOccupancyBit(int lx, int ly, int lz, bool solid)
	{
		int index = lx | (ly << 3) | (lz << 6);
		int wordIdx = index >> 6;
		ulong bit = 1UL << (index & 63);

		if (solid)
		{
			SetMicroMask(wordIdx, GetMicroMask(wordIdx) | bit);
		}
		else
		{
			SetMicroMask(wordIdx, GetMicroMask(wordIdx) & ~bit);
		}
	}

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	public bool HasVoxel(int lx, int ly, int lz)
	{
		if (IsUniform) return UniformVoxel != ChunkData.Voxel.AIR;
		int index = lx | (ly << 3) | (lz << 6);
		return (GetMicroMask(index >> 6) & (1UL << (index & 63))) != 0;
	}
}
