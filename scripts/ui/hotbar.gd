class_name HotbarUI extends CanvasLayer

## 独立模块化快捷栏组件 (HotbarUI)
## 管理快捷槽位选择、物理属性展示、UI 高亮与输入交互

signal voxel_changed(new_voxel: int)

@export var items: Array[int] = VoxelTypes.DEFAULT_HOTBAR_ITEMS

@onready var info_label: Label = $Root/CenterBox/VBox/InfoLabel
@onready var slots_hbox: HBoxContainer = $Root/CenterBox/VBox/SlotsHBox

var selected_index: int = 0
var slot_panels: Array[PanelContainer] = []


func _ready() -> void:
	layer = 10 # 保证始终呈现在光追 CanvasLayer 之上
	build_slots()
	update_ui()


func build_slots() -> void:
	if slots_hbox == null:
		return

	for child in slots_hbox.get_children():
		child.queue_free()
	slot_panels.clear()

	var palette = VoxelTypes.get_palette()

	for i in range(items.size()):
		var v_id = items[i]
		var panel = PanelContainer.new()
		panel.custom_minimum_size = Vector2(48, 48)
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var margin = MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 5)
		margin.add_theme_constant_override("margin_right", 5)
		margin.add_theme_constant_override("margin_top", 5)
		margin.add_theme_constant_override("margin_bottom", 5)
		margin.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var color_rect = ColorRect.new()
		color_rect.custom_minimum_size = Vector2(36, 36)
		color_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var c = palette[v_id] if palette.has(v_id) else Color.WHITE
		color_rect.color = Color(c.r, c.g, c.b, 1.0)
		margin.add_child(color_rect)
		panel.add_child(margin)

		var num_label = Label.new()
		num_label.text = str((i + 1) % 10)
		num_label.add_theme_font_size_override("font_size", 12)
		num_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
		num_label.add_theme_color_override("font_outline_color", Color.BLACK)
		num_label.add_theme_constant_override("outline_size", 3)
		num_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(num_label)

		slots_hbox.add_child(panel)
		slot_panels.append(panel)


func select_slot(index: int) -> void:
	if items.is_empty():
		return
	var prev_idx = selected_index
	selected_index = clampi(index, 0, items.size() - 1)
	if prev_idx != selected_index:
		update_ui()
		voxel_changed.emit(get_selected_voxel())


func get_selected_voxel() -> int:
	if items.is_empty():
		return VoxelTypes.Type.AIR
	return items[selected_index]


func update_ui() -> void:
	for i in range(slot_panels.size()):
		var slot = slot_panels[i]
		var is_selected = (i == selected_index)
		var style = StyleBoxFlat.new()
		style.set_corner_radius_all(6)
		if is_selected:
			style.bg_color = Color(0.20, 0.38, 0.55, 0.95)
			style.set_border_width_all(2)
			style.border_color = Color(0.35, 0.92, 1.0, 1.0) # 高亮荧光青边框
		else:
			style.bg_color = Color(0.12, 0.15, 0.20, 0.75)
			style.set_border_width_all(1)
			style.border_color = Color(0.28, 0.35, 0.45, 0.6)
		slot.add_theme_stylebox_override("panel", style)

	var cur_voxel = get_selected_voxel()
	var v_name = VoxelTypes.get_voxel_name(cur_voxel)
	var v_flags = VoxelTypes.get_voxel_flags_desc(cur_voxel)
	if info_label != null:
		info_label.text = "[槽位 %d] %s  %s  (滚轮 / 键盘 1~0 切换)" % [
			(selected_index + 1) % 10,
			v_name,
			v_flags
		]


func _unhandled_input(event: InputEvent) -> void:
	# 键盘数字键 1~0 快速选择快捷槽位
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			select_slot(event.keycode - KEY_1)
		elif event.keycode == KEY_0:
			select_slot(9)

	# 鼠标滚轮循环切换当前手持方块
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			var next_idx = (selected_index - 1 + items.size()) % items.size()
			select_slot(next_idx)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var next_idx = (selected_index + 1) % items.size()
			select_slot(next_idx)
