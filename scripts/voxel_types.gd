class_name VoxelTypes extends Object

## 全局统一体素类型枚举（整个项目唯一的类型源，杜绝各脚本重复声明）
enum Type {
	SAND = 0,
	GRASS = 1,
	STONE = 2,
	SNOW = 3,
	AIR = 4,
	DIRT = 5,
	WOOD = 6,
	LEAVES = 7,
	WATER = 8,
	GRAVEL = 9,
	GLASS = 10,
	GLOWSTONE = 11,
	
	# 兼容别名
	MOUNTAIN = STONE
}

## 默认推荐快捷栏槽位方块列表 (10 种可用放置体素)
const DEFAULT_HOTBAR_ITEMS: Array[int] = [
	Type.GRASS,     # 1: 草方块
	Type.DIRT,      # 2: 泥土
	Type.STONE,     # 3: 岩石
	Type.SAND,      # 4: 沙子 (受重力落体)
	Type.WOOD,      # 5: 原木 (易燃)
	Type.LEAVES,    # 6: 树叶 (易燃/透光)
	Type.GLASS,     # 7: 玻璃 (透明)
	Type.GLOWSTONE, # 8: 荧石 (自发光光源)
	Type.SNOW,      # 9: 雪块
	Type.WATER      # 0: 水体 (动态流体)
]


## 查询方块中文名称
static func get_voxel_name(type: int) -> String:
	return VoxelTypeRegistry.GetVoxelName(type)


## 查询方块动态与物理属性描述文本
static func get_voxel_flags_desc(type: int) -> String:
	return VoxelTypeRegistry.GetVoxelFlagsDescription(type)


## 查询物理与动态特性
static func is_solid(type: int) -> bool:
	return VoxelTypeRegistry.IsSolid(type)


static func has_gravity(type: int) -> bool:
	return VoxelTypeRegistry.HasGravity(type)


static func is_fluid(type: int) -> bool:
	return VoxelTypeRegistry.IsFluid(type)


static func is_flammable(type: int) -> bool:
	return VoxelTypeRegistry.IsFlammable(type)


static func is_transparent(type: int) -> bool:
	return VoxelTypeRegistry.IsTransparent(type)


static func is_emissive(type: int) -> bool:
	return VoxelTypeRegistry.IsEmissive(type)


static func get_hardness(type: int) -> float:
	return VoxelTypeRegistry.GetHardness(type)


static func get_density(type: int) -> float:
	return VoxelTypeRegistry.GetDensity(type)


## 获取全局全方块色盘 (ID -> Color)
static func get_palette() -> Dictionary:
	return VoxelTypeRegistry.GetColorPalette()
