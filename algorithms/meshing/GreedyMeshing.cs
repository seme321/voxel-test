using Godot;
using System;

[GlobalClass]
public partial class GreedyMeshing : MeshingAlgorithm
{
	[ThreadStatic]
	private static ChunkData.Voxel[] localCache;

	public GreedyMeshing()
	{
		Name = "GreedyMeshing";
	}

	public override void GenerateMesh(ChunkData chunkData, MeshData meshData)
	{
		GenerateSubMesh(chunkData, 0, 0, 0, chunkData.GetSize(), meshData);
	}

	public override void GenerateSubMesh(ChunkData chunkData, Vector3I subOrigin, int subSize, MeshData meshData)
	{
		GenerateSubMesh(chunkData, subOrigin.X, subOrigin.Y, subOrigin.Z, subSize, meshData);
	}

	public override void GenerateSubMesh(ChunkData chunkData, int ox, int oy, int oz, int subSize, MeshData meshData)
	{
		if (chunkData.IsEmpty() || chunkData.IsSubChunkEmpty(ox, oy, oz, subSize)) return;

		int paddedSize = subSize + 2; // 例如 32 + 2 = 34，包含外围 1 格邻居进行无缝缝合
		int totalPadded = paddedSize * paddedSize * paddedSize;

		if (localCache == null || localCache.Length < totalPadded)
		{
			localCache = new ChunkData.Voxel[totalPadded];
		}

		// 1. 将 34x34x34 局部邻域快速填充至 L1 高速缓存（~38KB，耗时 < 0.05ms）
		int idx = 0;
		for (int lz = -1; lz <= subSize; ++lz)
		{
			int gz = oz + lz;
			for (int ly = -1; ly <= subSize; ++ly)
			{
				int gy = oy + ly;
				for (int lx = -1; lx <= subSize; ++lx)
				{
					int gx = ox + lx;
					localCache[idx++] = chunkData.GetVoxel(gx, gy, gz);
				}
			}
		}

		int strideX = 1;
		int strideY = paddedSize;
		int strideZ = paddedSize * paddedSize;

		ChunkData.Voxel[] mask = new ChunkData.Voxel[subSize * subSize];

		// 2. 贪心网格生成（所有体素查询直击 L1 缓存）
		for (int b = 0; b < 2; ++b)
		{
			for (int d = 0; d < 3; ++d)
			{
				int width = 0;
				int height = 0;
				int u = (d + 1) % 3;
				int v = (d + 2) % 3;
				Vector3 pos = Vector3.Zero;
				Vector3 q = Vector3.Zero;
				q[d] = 1;

				Face face = Face.BACK;
				if (d == 0) face = (b == 0) ? Face.LEFT : Face.RIGHT;
				if (d == 1) face = (b == 0) ? Face.BOTTOM : Face.TOP;
				if (d == 2) face = (b == 0) ? Face.BACK : Face.FRONT;

				int strideD = (d == 0) ? strideX : (d == 1) ? strideY : strideZ;
				int strideU = (u == 0) ? strideX : (u == 1) ? strideY : strideZ;
				int strideV = (v == 0) ? strideX : (v == 1) ? strideY : strideZ;

				pos[d] = -1;
				while (pos[d] < subSize)
				{
					int mask_index = 0;
					bool hasAnyFace = false;

					int sliceBase = ((int)pos[d] + 1) * strideD;

					for (int j = 0; j < subSize; ++j)
					{
						int rowBase = sliceBase + (j + 1) * strideV;
						for (int i = 0; i < subSize; ++i)
						{
							int cellIdx = rowBase + (i + 1) * strideU;

							ChunkData.Voxel current;
							ChunkData.Voxel compare;

							if (pos[d] >= 0)
							{
								current = localCache[cellIdx];
							}
							else
							{
								current = (b == 0) ? localCache[cellIdx] : ChunkData.Voxel.AIR;
							}

							if (pos[d] < subSize - 1)
							{
								compare = localCache[cellIdx + strideD];
							}
							else
							{
								compare = (b == 1) ? localCache[cellIdx + strideD] : ChunkData.Voxel.AIR;
							}

							ChunkData.Voxel faceVoxel = ChunkData.Voxel.AIR;
							if (b == 0)
							{
								if (current == ChunkData.Voxel.AIR && compare != ChunkData.Voxel.AIR) faceVoxel = compare;
							}
							else
							{
								if (current != ChunkData.Voxel.AIR && compare == ChunkData.Voxel.AIR) faceVoxel = current;
							}

							mask[mask_index] = faceVoxel;
							if (faceVoxel != ChunkData.Voxel.AIR) hasAnyFace = true;

							mask_index++;
						}
					}

					pos[d]++;

					if (!hasAnyFace)
					{
						continue;
					}

					mask_index = 0;
					for (int j = 0; j < subSize; ++j)
					{
						for (int i = 0; i < subSize;)
						{
							ChunkData.Voxel voxel = mask[mask_index];

							if (voxel == ChunkData.Voxel.AIR)
							{
								mask_index++;
								i++;
								continue;
							}

							width = 1;
							while (i + width < subSize && voxel == mask[mask_index + width]) width++;

							bool done = false;
							height = 1;
							while (height + j < subSize)
							{
								for (int k = 0; k < width; ++k)
								{
									if (voxel != mask[mask_index + k + height * subSize])
									{
										done = true;
										break;
									}
								}

								if (done) break;
								height += 1;
							}

							Vector3 deltau = Vector3.Zero;
							Vector3 deltav = Vector3.Zero;
							deltau[u] = width;
							deltav[v] = height;
							pos[u] = i;
							pos[v] = j;

							addFace(pos, deltau, deltav, face, voxel, meshData);

							for (int l = 0; l < height; ++l)
							{
								for (int k = 0; k < width; ++k)
								{
									mask[mask_index + k + l * subSize] = ChunkData.Voxel.AIR;
								}
							}

							i += width;
							mask_index += width;
						}
					}
				}
			}
		}
	}

	private void addFace(Vector3 pos, Vector3 deltau, Vector3 deltav, Face face, ChunkData.Voxel voxel, MeshData meshData)
	{
		Color color = Colors[voxel];
		Vector3 sizeVector = deltau + deltav;
		var indices = faceIndices[face];
		foreach (int[] triangle in indices)
		{
			foreach (int index in triangle)
			{
				Vector3 vertex = cubeVertices[index] * sizeVector;
				meshData.AddData(vertex + pos, faceNormals[face], color);
			}
		}
	}
}
