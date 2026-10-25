using Godot;
using System;
using System.Collections.Generic;

/// <summary>
/// 体素物理与动态特性标志位（位掩码），专为类似 Caelix / Teardown 的 Dynamic Voxel 引擎提供底层铺垫。
/// </summary>
[Flags]
public enum VoxelFlags : uint
{
	None        = 0,
	Solid       = 1 << 0,  // 是否参与物理碰撞 (除空气、静态纯流体外为 True)
	HasGravity  = 1 << 1,  // 是否受重力下落 (落沙、砾石、松散颗粒) -> Dynamic Voxel 核心
	IsFluid     = 1 << 2,  // 是否为流体 (水、岩浆等元胞自动机流动扩散)
	Flammable   = 1 << 3,  // 是否易燃 (原木、树叶、干草等热量扩散反应)
	Transparent = 1 << 4,  // 是否透光/半透明 (空气、水体、玻璃、树叶)
	Emissive    = 1 << 5,  // 是否自发光光源 (荧石、岩浆、火把) -> 光追自发光
}

/// <summary>
/// 体素静态元数据属性（享元模式 Flyweight，零每体素内存开销）。
/// </summary>
public struct VoxelTypeInfo
{
	public ChunkData.Voxel VoxelType;
	public string Name;
	public string EnglishName;
	public VoxelFlags Flags;
	public float Hardness;         // 挖掘破坏硬度（秒/抗爆基准系数）
	public float Density;          // 质量密度 (kg/m^3)，用于刚体碎片物理与沉浮浮力计算
	public Color Color;            // 光栅化与 UI 调色板颜色
	public ushort RaytracingMatId; // Vulkan 光追 HLSL 材质 ID
	public float Emission;         // 发光强度 (0.0 表示无自发光)

	public bool IsSolid => (Flags & VoxelFlags.Solid) != 0;
	public bool HasGravity => (Flags & VoxelFlags.HasGravity) != 0;
	public bool IsFluid => (Flags & VoxelFlags.IsFluid) != 0;
	public bool IsFlammable => (Flags & VoxelFlags.Flammable) != 0;
	public bool IsTransparent => (Flags & VoxelFlags.Transparent) != 0;
	public bool IsEmissive => (Flags & VoxelFlags.Emissive) != 0;
}

/// <summary>
/// 全局体素类型与属性注册表单例（供 C# 算法层与 GDScript 表现层共享查询）。
/// </summary>
[GlobalClass]
public partial class VoxelTypeRegistry : RefCounted
{
	private static readonly Dictionary<ChunkData.Voxel, VoxelTypeInfo> Registry = new();
	private static readonly Godot.Collections.Dictionary<int, Color> ColorPalette = new();

	static VoxelTypeRegistry()
	{
		Register(new VoxelTypeInfo {
			VoxelType = ChunkData.Voxel.AIR,
			Name = "空气", EnglishName = "Air",
			Flags = VoxelFlags.Transparent,
			Hardness = 0.0f, Density = 1.225f,
			Color = new Color(1f, 1f, 1f, 0f),
			RaytracingMatId = 0, Emission = 0.0f
		});

		Register(new VoxelTypeInfo {
			VoxelType = ChunkData.Voxel.GRASS,
			Name = "草方块", EnglishName = "Grass",
			Flags = VoxelFlags.Solid,
			Hardness = 0.6f, Density = 1200f,
			Color = new Color(0.35f, 0.65f, 0.25f, 1f),
			RaytracingMatId = 1, Emission = 0.0f
		});

		Register(new VoxelTypeInfo {
			VoxelType = ChunkData.Voxel.DIRT,
			Name = "泥土", EnglishName = "Dirt",
			Flags = VoxelFlags.Solid,
			Hardness = 0.5f, Density = 1300f,
			Color = new Color(0.55f, 0.40f, 0.25f, 1f),
			RaytracingMatId = 2, Emission = 0.0f
		});

		Register(new VoxelTypeInfo {
			VoxelType = ChunkData.Voxel.MOUNTAIN,
			Name = "岩石", EnglishName = "Stone",
			Flags = VoxelFlags.Solid,
			Hardness = 1.5f, Density = 2600f,
			Color = new Color(0.50f, 0.50f, 0.50f, 1f),
			RaytracingMatId = 3, Emission = 0.0f
		});

		Register(new VoxelTypeInfo {
			VoxelType = ChunkData.Voxel.SAND,
			Name = "沙子", EnglishName = "Sand",
			Flags = VoxelFlags.Solid | VoxelFlags.HasGravity,
			Hardness = 0.5f, Density = 1600f,
			Color = new Color(0.85f, 0.75f, 0.45f, 1f),
			RaytracingMatId = 4, Emission = 0.0f
		});

		Register(new VoxelTypeInfo {
			VoxelType = ChunkData.Voxel.SNOW,
			Name = "雪块", EnglishName = "Snow",
			Flags = VoxelFlags.Solid,
			Hardness = 0.3f, Density = 300f,
			Color = new Color(0.95f, 0.95f, 0.98f, 1f),
			RaytracingMatId = 5, Emission = 0.0f
		});

		Register(new VoxelTypeInfo {
			VoxelType = ChunkData.Voxel.WOOD,
			Name = "原木", EnglishName = "Wood",
			Flags = VoxelFlags.Solid | VoxelFlags.Flammable,
			Hardness = 1.2f, Density = 650f,
			Color = new Color(0.40f, 0.25f, 0.15f, 1f),
			RaytracingMatId = 6, Emission = 0.0f
		});

		Register(new VoxelTypeInfo {
			VoxelType = ChunkData.Voxel.LEAVES,
			Name = "树叶", EnglishName = "Leaves",
			Flags = VoxelFlags.Solid | VoxelFlags.Flammable | VoxelFlags.Transparent,
			Hardness = 0.2f, Density = 150f,
			Color = new Color(0.20f, 0.50f, 0.20f, 0.85f),
			RaytracingMatId = 7, Emission = 0.0f
		});

		Register(new VoxelTypeInfo {
			VoxelType = ChunkData.Voxel.WATER,
			Name = "水体", EnglishName = "Water",
			Flags = VoxelFlags.IsFluid | VoxelFlags.Transparent,
			Hardness = 0.0f, Density = 1000f,
			Color = new Color(0.20f, 0.45f, 0.85f, 0.75f),
			RaytracingMatId = 8, Emission = 0.0f
		});

		Register(new VoxelTypeInfo {
			VoxelType = ChunkData.Voxel.GRAVEL,
			Name = "砾石", EnglishName = "Gravel",
			Flags = VoxelFlags.Solid | VoxelFlags.HasGravity,
			Hardness = 0.6f, Density = 1700f,
			Color = new Color(0.42f, 0.40f, 0.40f, 1f),
			RaytracingMatId = 9, Emission = 0.0f
		});

		Register(new VoxelTypeInfo {
			VoxelType = ChunkData.Voxel.GLASS,
			Name = "玻璃", EnglishName = "Glass",
			Flags = VoxelFlags.Solid | VoxelFlags.Transparent,
			Hardness = 0.3f, Density = 2500f,
			Color = new Color(0.80f, 0.90f, 0.95f, 0.40f),
			RaytracingMatId = 10, Emission = 0.0f
		});

		Register(new VoxelTypeInfo {
			VoxelType = ChunkData.Voxel.GLOWSTONE,
			Name = "荧石", EnglishName = "Glowstone",
			Flags = VoxelFlags.Solid | VoxelFlags.Emissive,
			Hardness = 0.4f, Density = 1800f,
			Color = new Color(1.00f, 0.85f, 0.30f, 1f),
			RaytracingMatId = 11, Emission = 1.5f
		});
	}

	private static void Register(VoxelTypeInfo info)
	{
		Registry[info.VoxelType] = info;
		ColorPalette[(int)info.VoxelType] = info.Color;
	}

	public static VoxelTypeInfo GetInfo(ChunkData.Voxel type)
	{
		return Registry.TryGetValue(type, out var info) ? info : Registry[ChunkData.Voxel.AIR];
	}

	public static VoxelTypeInfo GetInfoByIndex(int index) => GetInfo((ChunkData.Voxel)index);

	public static bool IsSolid(ChunkData.Voxel type) => GetInfo(type).IsSolid;
	public static bool HasGravity(ChunkData.Voxel type) => GetInfo(type).HasGravity;
	public static bool IsFluid(ChunkData.Voxel type) => GetInfo(type).IsFluid;
	public static bool IsFlammable(ChunkData.Voxel type) => GetInfo(type).IsFlammable;
	public static bool IsTransparent(ChunkData.Voxel type) => GetInfo(type).IsTransparent;
	public static bool IsEmissive(ChunkData.Voxel type) => GetInfo(type).IsEmissive;

	public static bool IsSolid(int index) => GetInfoByIndex(index).IsSolid;
	public static bool HasGravity(int index) => GetInfoByIndex(index).HasGravity;
	public static bool IsFluid(int index) => GetInfoByIndex(index).IsFluid;
	public static bool IsFlammable(int index) => GetInfoByIndex(index).IsFlammable;
	public static bool IsTransparent(int index) => GetInfoByIndex(index).IsTransparent;
	public static bool IsEmissive(int index) => GetInfoByIndex(index).IsEmissive;
	public static float GetHardness(int index) => GetInfoByIndex(index).Hardness;
	public static float GetDensity(int index) => GetInfoByIndex(index).Density;

	public static string GetVoxelName(int index) => GetInfoByIndex(index).Name;
	public static string GetVoxelFlagsDescription(int index)
	{
		var info = GetInfoByIndex(index);
		var desc = new System.Text.StringBuilder();
		if (info.IsSolid) desc.Append("[实体]");
		if (info.HasGravity) desc.Append("[受重力落体]");
		if (info.IsFluid) desc.Append("[流体扩散]");
		if (info.IsFlammable) desc.Append("[易燃]");
		if (info.IsEmissive) desc.Append("[自发光光源]");
		if (info.IsTransparent) desc.Append("[透光]");
		return desc.ToString();
	}

	public static Godot.Collections.Dictionary<int, Color> GetColorPalette() => ColorPalette;
}
