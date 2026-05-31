extends Node3D

# Top-down colony game shell: drives the simulation clock, routes input to
# designation commands, and keeps the renderer/HUD in sync with the active layer.

const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const SimClockScript := preload("res://scripts/simulation/sim_clock.gd")
const SaveGameScript := preload("res://scripts/simulation/save_game.gd")
const C := preload("res://scripts/simulation/world_constants.gd")

const INVALID_CELL := Vector3i(-2147483648, -2147483648, -2147483648)
const SAVE_PATH := "user://saves/quicksave.json"
const STOCKPILE_DEFAULT_ITEMS := ["wood", "stone", "dirt", "food", "meal"]

const TOOL_INSPECT := "inspect"
const TOOL_CHOP := "chop"
const TOOL_GATHER := "gather"
const TOOL_MINE := "mine"
const TOOL_CHANNEL := "channel"
const TOOL_STAIR_UP := "stair_up"
const TOOL_STAIR_DOWN := "stair_down"
const TOOL_STOCKPILE := "stockpile"
const TOOL_KITCHEN := "kitchen"
const TOOL_WALL := "wall"

const TOOL_COMMANDS := {
    TOOL_CHOP: "DESIGNATE_CHOP",
    TOOL_GATHER: "DESIGNATE_GATHER_FOOD",
    TOOL_MINE: "DESIGNATE_MINE",
    TOOL_CHANNEL: "DESIGNATE_CHANNEL",
    TOOL_STAIR_UP: "DESIGNATE_BUILD_STAIR_UP",
    TOOL_STAIR_DOWN: "DESIGNATE_BUILD_STAIR_DOWN",
}

@onready var world_root: Node3D = $WorldRoot
@onready var hud: CanvasLayer = $GameHud
@onready var camera: Camera3D = $Camera3D

var simulation
var sim_clock
var active_tool: String = TOOL_INSPECT
var active_layer: int = C.SURFACE_Y_MEAN
var _drag_active: bool = false
var _drag_start: Vector3i = INVALID_CELL
var _wall_material: String = "stone"

func _ready() -> void:
    simulation = SimulationScript.new()
    simulation.initialize_new_game(42)
    sim_clock = SimClockScript.new()
    _resolve_nodes()
    if hud != null and hud.has_signal("tool_requested"):
        hud.tool_requested.connect(set_active_tool)
    if hud != null and hud.has_signal("layer_change_requested"):
        hud.layer_change_requested.connect(_change_layer)
    if hud != null and hud.has_signal("stockpile_items_changed"):
        hud.stockpile_items_changed.connect(_on_stockpile_items_changed)
    if hud != null and hud.has_signal("wall_material_changed"):
        hud.wall_material_changed.connect(_on_wall_material_changed)
    if hud != null and hud.has_signal("worker_selected"):
        hud.worker_selected.connect(_on_worker_selected)
    if hud != null and hud.has_signal("worker_rename_requested"):
        hud.worker_rename_requested.connect(_on_worker_rename_requested)
    if hud != null and hud.has_signal("worker_allowed_job_toggled"):
        hud.worker_allowed_job_toggled.connect(_on_worker_allowed_job_toggled)
    if hud != null and hud.has_signal("worker_job_priority_changed"):
        hud.worker_job_priority_changed.connect(_on_worker_job_priority_changed)
    if hud != null and hud.has_method("set_sim_clock"):
        hud.set_sim_clock(sim_clock)
    _set_active_layer(active_layer)
    set_active_tool(active_tool)
    _sync()

func _process(delta: float) -> void:
    if sim_clock == null or simulation == null:
        return
    var steps: int = sim_clock.advance_steps(delta)
    for i in range(steps):
        simulation.step_tick()
    if steps > 0:
        _sync()

func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST:
        _quit_game()

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
        var cell: Vector3i = _pick_cell(event.position)
        if event.pressed:
            _on_left_pressed(cell)
        else:
            _on_left_released(cell)
        return
    if event is InputEventMouseMotion:
        var cell: Vector3i = _pick_cell(event.position)
        _set_hover(cell)
        if _drag_active:
            _update_stockpile_preview(cell)
        return
    if event is InputEventKey and event.pressed and not event.echo:
        match event.keycode:
            KEY_1: set_active_tool(TOOL_INSPECT)
            KEY_2: set_active_tool(TOOL_CHOP)
            KEY_3: set_active_tool(TOOL_GATHER)
            KEY_4: set_active_tool(TOOL_MINE)
            KEY_5: set_active_tool(TOOL_CHANNEL)
            KEY_6: set_active_tool(TOOL_STAIR_UP)
            KEY_7: set_active_tool(TOOL_STAIR_DOWN)
            KEY_8: set_active_tool(TOOL_STOCKPILE)
            KEY_9: set_active_tool(TOOL_KITCHEN)
            KEY_0: set_active_tool(TOOL_WALL)
            KEY_E: _change_layer(1)
            KEY_C: _change_layer(-1)
            KEY_R: _toggle_workers_panel()
            KEY_SPACE: _toggle_pause()
            KEY_F5: _quicksave()
            KEY_F9: _quickload()
            KEY_ESCAPE: _quit_game()

# --- Mouse handling -----------------------------------------------------------

func _on_left_pressed(cell: Vector3i) -> void:
    if cell == INVALID_CELL or simulation == null:
        return
    # Stockpile and the designation tools (chop/gather/mine/channel/stairs) drag
    # out an area; inspect and kitchen act on a single click.
    if active_tool == TOOL_STOCKPILE or active_tool == TOOL_WALL or TOOL_COMMANDS.has(active_tool):
        _drag_active = true
        _drag_start = cell
        _update_stockpile_preview(cell)
    else:
        _handle_click(cell)

func _on_left_released(cell: Vector3i) -> void:
    if not _drag_active:
        return
    _drag_active = false
    _clear_stockpile_preview()
    var end_cell: Vector3i = cell if cell != INVALID_CELL else _drag_start
    if _drag_start != INVALID_CELL:
        _apply_drag(_drag_start, end_cell)
    _drag_start = INVALID_CELL
    _sync()

func _apply_drag(a: Vector3i, b: Vector3i) -> void:
    if simulation == null:
        return
    if active_tool == TOOL_STOCKPILE:
        _create_stockpile_rect(a, b)
        return
    if active_tool == TOOL_WALL:
        _place_wall_rect(a, b)
        return
    if not TOOL_COMMANDS.has(active_tool):
        return
    var command: String = str(TOOL_COMMANDS[active_tool])
    var next_tick: int = simulation.tick + 1
    for raw in _rect_cells(a, b):
        var c := Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))
        simulation.queue_command(next_tick, "player_001", command, c, {"priority": 5})
    _hide_details()
    _hide_config()

func _place_wall_rect(a: Vector3i, b: Vector3i) -> void:
    var building_type: String = "wall_" + _wall_material
    var next_tick: int = simulation.tick + 1
    for raw in _rect_cells(a, b):
        var c := Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))
        simulation.queue_command(next_tick, "player_001", "PLACE_BLUEPRINT", c, {"building_type": building_type, "priority": 5})
    _hide_details()
    _hide_config()

func _on_wall_material_changed(material: String) -> void:
    _wall_material = material

func _handle_click(cell: Vector3i) -> void:
    if cell == INVALID_CELL or simulation == null:
        return
    var next_tick: int = simulation.tick + 1
    if TOOL_COMMANDS.has(active_tool):
        simulation.queue_command(next_tick, "player_001", str(TOOL_COMMANDS[active_tool]), cell, {"priority": 5})
        _hide_details()
        _hide_config()
    elif active_tool == TOOL_KITCHEN:
        simulation.queue_command(next_tick, "player_001", "PLACE_BLUEPRINT", cell, {"building_type": "kitchen", "priority": 5})
        _hide_details()
        _hide_config()
    else:
        _inspect_or_configure(cell)
    _sync()

# --- Stockpile drag + config --------------------------------------------------

func _rect_cells(a: Vector3i, b: Vector3i) -> Array:
    var cells: Array = []
    var min_x: int = mini(a.x, b.x)
    var max_x: int = maxi(a.x, b.x)
    var min_z: int = mini(a.z, b.z)
    var max_z: int = maxi(a.z, b.z)
    for x in range(min_x, max_x + 1):
        for z in range(min_z, max_z + 1):
            cells.append([x, active_layer, z])
    return cells

func _update_stockpile_preview(end_cell: Vector3i) -> void:
    _resolve_nodes()
    if world_root == null or not world_root.has_method("set_stockpile_preview"):
        return
    if _drag_start == INVALID_CELL or end_cell == INVALID_CELL:
        return
    world_root.set_stockpile_preview(_rect_cells(_drag_start, end_cell))

func _clear_stockpile_preview() -> void:
    if world_root != null and world_root.has_method("clear_stockpile_preview"):
        world_root.clear_stockpile_preview()

func _create_stockpile_rect(a: Vector3i, b: Vector3i) -> void:
    if simulation == null:
        return
    var cells: Array = _rect_cells(a, b)
    if cells.is_empty():
        return
    simulation.queue_command(simulation.tick + 1, "player_001", "DESIGNATE_STOCKPILE", a,
        {"cells": cells, "accepted_item_types": STOCKPILE_DEFAULT_ITEMS})

func _inspect_or_configure(cell: Vector3i) -> void:
    if simulation == null:
        return
    var unit_id: String = _unit_id_at_cell(cell)
    if unit_id != "":
        _on_worker_selected(unit_id)
        return
    var stockpile_id: String = simulation.find_stockpile_at_cell(cell)
    if stockpile_id != "" and hud != null and hud.has_method("show_stockpile_config"):
        _hide_details()
        var accepted: Array = simulation.stockpiles[stockpile_id].accepted_item_types
        hud.show_stockpile_config(stockpile_id, accepted)
    else:
        _hide_config()
        _inspect_cell(cell)

func _on_stockpile_items_changed(stockpile_id: String, accepted_types: Array) -> void:
    if simulation == null:
        return
    simulation.queue_command(simulation.tick + 1, "player_001", "SET_STOCKPILE_ITEMS", Vector3i.ZERO,
        {"stockpile_id": stockpile_id, "accepted_item_types": accepted_types})

func _hide_config() -> void:
    if hud != null and hud.has_method("hide_stockpile_config"):
        hud.hide_stockpile_config()

# --- Workers ------------------------------------------------------------------

func _unit_id_at_cell(cell: Vector3i) -> String:
    if simulation == null:
        return ""
    for unit_id in simulation.units.keys():
        if simulation.units[unit_id].position == cell:
            return str(unit_id)
    return ""

func _toggle_workers_panel() -> void:
    if hud != null and hud.has_method("toggle_workers_panel"):
        hud.toggle_workers_panel()

func _on_worker_selected(unit_id: String) -> void:
    if simulation == null or not simulation.units.has(unit_id):
        return
    var unit = simulation.units[unit_id]
    _hide_details()
    _hide_config()
    if hud != null and hud.has_method("select_worker"):
        hud.select_worker(unit_id)
    _set_active_layer(unit.position.y)
    if camera != null and camera.has_method("focus_on"):
        camera.focus_on(float(unit.position.x), float(unit.position.z))

func _on_worker_rename_requested(unit_id: String, new_name: String) -> void:
    if simulation != null:
        simulation.queue_command(simulation.tick + 1, "player_001", "SET_UNIT_NAME", Vector3i.ZERO,
            {"unit_id": unit_id, "name": new_name})

func _on_worker_allowed_job_toggled(unit_id: String, job_type: String, enabled: bool) -> void:
    if simulation != null:
        simulation.queue_command(simulation.tick + 1, "player_001", "SET_UNIT_ALLOWED_JOB", Vector3i.ZERO,
            {"unit_id": unit_id, "job_type": job_type, "enabled": enabled})

func _on_worker_job_priority_changed(unit_id: String, job_type: String, priority: int) -> void:
    if simulation != null:
        simulation.queue_command(simulation.tick + 1, "player_001", "SET_UNIT_JOB_PRIORITY", Vector3i.ZERO,
            {"unit_id": unit_id, "job_type": job_type, "priority": priority})

# --- Tools / layers -----------------------------------------------------------

func set_active_tool(tool_name: String) -> void:
    active_tool = tool_name
    if active_tool != TOOL_INSPECT:
        _hide_details()
        _hide_config()
    if hud != null:
        if active_tool == TOOL_WALL and hud.has_method("show_wall_config"):
            hud.show_wall_config(_wall_material)
        elif hud.has_method("hide_wall_config"):
            hud.hide_wall_config()
    if hud != null and hud.has_method("set_active_tool"):
        hud.set_active_tool(tool_name)

func _change_layer(delta: int) -> void:
    _set_active_layer(active_layer + delta)
    _sync()

func _set_active_layer(y: int) -> void:
    active_layer = clampi(y, 0, C.LAYER_COUNT - 1)
    _resolve_nodes()
    if world_root != null and world_root.has_method("set_active_layer"):
        world_root.set_active_layer(active_layer)
    if hud != null and hud.has_method("set_active_layer"):
        hud.set_active_layer(active_layer)

func _toggle_pause() -> void:
    if sim_clock != null:
        sim_clock.set_paused(not sim_clock.paused)

func _quit_game() -> void:
    get_tree().quit()

func _quicksave() -> void:
    if simulation != null:
        SaveGameScript.save_to_file(simulation, SAVE_PATH)

func _quickload() -> void:
    var loaded = SaveGameScript.load_from_file(SAVE_PATH)
    if loaded != null:
        simulation = loaded
        _sync()

# --- Tile inspection ----------------------------------------------------------

func _inspect_cell(cell: Vector3i) -> void:
    if simulation == null or hud == null or not hud.has_method("show_tile_details"):
        return
    hud.show_tile_details(_describe_cell(cell))

func _hide_details() -> void:
    if hud != null and hud.has_method("hide_tile_details"):
        hud.hide_tile_details()

func _describe_cell(cell: Vector3i) -> String:
    var world = simulation.world
    var c = world.peek_cell(cell)
    var lines: Array[String] = []
    lines.append("Tile (%d, %d, %d)" % [cell.x, cell.y, cell.z])
    lines.append("Band: %s" % str(c.band))
    lines.append("Floor: %s" % (c.floor_material if c.floor_material != "" else "open (no floor)"))
    lines.append("Wall: %s" % (c.wall_material if c.wall_material != "" else "none"))
    lines.append("Walkable: %s" % ("yes" if world.is_walkable(cell) else "no"))
    lines.append("Exposure: %s" % str(c.exposure))
    if c.has_liquid():
        lines.append("Liquid: %s (level %d)" % [c.liquid_type, c.liquid_level])
    if c.has_plant():
        var resource_type: String = ""
        if c.resource_id != "" and simulation.resources.has(c.resource_id):
            resource_type = str(simulation.resources[c.resource_id].get("type", ""))
        lines.append("Plant: %s%s" % [c.plant, ((" (%s)" % resource_type) if resource_type != "" else "")])
    if c.has_stair():
        lines.append("Stair: %s" % c.stair)
    if c.building_id != "":
        lines.append("Building: %s" % c.building_id)
    if c.has_wall() and c.mining_tier_required > C.MINING_TIER_NONE:
        lines.append("Mining tier required: %d" % c.mining_tier_required)
    var item_descriptions: Array[String] = []
    for item_id in simulation.items.keys():
        var item = simulation.items[item_id]
        if item.holder_unit_id == "" and item.position == cell:
            item_descriptions.append("%s x%d" % [item.item_type, int(item.quantity)])
    if not item_descriptions.is_empty():
        lines.append("Items: " + ", ".join(item_descriptions))
    var unit_descriptions: Array[String] = []
    for unit_id in simulation.units.keys():
        var unit = simulation.units[unit_id]
        if unit.position == cell:
            unit_descriptions.append("%s (%s)" % [unit.display_name, unit.state])
    if not unit_descriptions.is_empty():
        lines.append("Units: " + ", ".join(unit_descriptions))
    return "\n".join(lines)

# --- Picking / sync -----------------------------------------------------------

func _pick_cell(mouse_position: Vector2) -> Vector3i:
    _resolve_nodes()
    if camera == null or world_root == null or not world_root.has_method("ray_to_cell"):
        return INVALID_CELL
    var origin: Vector3 = camera.project_ray_origin(mouse_position)
    var direction: Vector3 = camera.project_ray_normal(mouse_position)
    return world_root.ray_to_cell(origin, direction)

func _set_hover(cell: Vector3i) -> void:
    _resolve_nodes()
    if world_root != null and world_root.has_method("set_hover_cell"):
        world_root.set_hover_cell(cell)

func _sync() -> void:
    _resolve_nodes()
    if world_root != null and world_root.has_method("sync_from_simulation"):
        world_root.sync_from_simulation(simulation)
    if hud != null and hud.has_method("sync_from_simulation"):
        hud.sync_from_simulation(simulation)

func _resolve_nodes() -> void:
    if world_root == null:
        world_root = get_node_or_null("WorldRoot") as Node3D
    if hud == null:
        hud = get_node_or_null("GameHud") as CanvasLayer
    if camera == null:
        camera = get_node_or_null("Camera3D") as Camera3D
