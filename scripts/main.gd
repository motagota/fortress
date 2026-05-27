extends Node3D

const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const SimClockScript := preload("res://scripts/simulation/sim_clock.gd")

const TOOL_MODE_INSPECT := "inspect"
const TOOL_MODE_GATHER_WOOD := "gather_wood"
const TOOL_MODE_GATHER_STONE := "gather_stone"
const TOOL_MODE_GATHER_FOOD := "gather_food"
const TOOL_MODE_MINE := "mine"
const TOOL_MODE_DESIGNATE_STOCKPILE := "designate_stockpile"
const TOOL_MODE_PLACE_KITCHEN := "place_kitchen"
const TOOL_MODES: Array[String] = [
    TOOL_MODE_INSPECT,
    TOOL_MODE_GATHER_WOOD,
    TOOL_MODE_GATHER_STONE,
    TOOL_MODE_GATHER_FOOD,
    TOOL_MODE_MINE,
    TOOL_MODE_DESIGNATE_STOCKPILE,
    TOOL_MODE_PLACE_KITCHEN,
]

@onready var world_root: Node3D = $WorldRoot
@onready var hud: CanvasLayer = $GameHud
@onready var camera: Camera3D = $Camera3D

var simulation: Simulation
var sim_clock: SimClock
var active_tool_mode: String = TOOL_MODE_INSPECT
var _stockpile_drag_start: Vector2i = Vector2i(-1, -1)
var _stockpile_drag_current: Vector2i = Vector2i(-1, -1)
var _is_stockpile_dragging: bool = false
var selected_stockpile_id: String = ""
var selected_workshop_id: String = ""
var layer_cutaway_depth: int = 0

func _ready() -> void:
    simulation = Simulation.new()
    simulation.initialize_new_game(42)
    sim_clock = SimClockScript.new()
    if hud != null and hud.has_method("set_sim_clock"):
        hud.set_sim_clock(sim_clock)
    if hud != null and hud.has_signal("tool_mode_requested"):
        hud.tool_mode_requested.connect(set_active_tool_mode)
    if hud != null and hud.has_signal("stockpile_mode_requested"):
        hud.stockpile_mode_requested.connect(_on_stockpile_mode_requested)
    if hud != null and hud.has_signal("workshop_recipe_requested"):
        hud.workshop_recipe_requested.connect(_on_workshop_recipe_requested)
    if hud != null and hud.has_signal("layer_depth_requested"):
        hud.layer_depth_requested.connect(_on_layer_depth_requested)
    set_active_tool_mode(active_tool_mode)
    _set_layer_cutaway_depth(layer_cutaway_depth)
    sync_from_simulation(simulation)

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        var mouse_event := event as InputEventMouseButton
        if mouse_event.button_index == MOUSE_BUTTON_LEFT and active_tool_mode in [TOOL_MODE_DESIGNATE_STOCKPILE, TOOL_MODE_PLACE_KITCHEN, TOOL_MODE_MINE]:
            var target_cell: Vector2i = _pick_grid_cell_from_mouse_position(mouse_event.position)
            if mouse_event.pressed:
                _begin_stockpile_drag(target_cell)
            else:
                _finish_stockpile_drag(target_cell)
            return
        if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT:
            var target_cell: Vector2i = _pick_grid_cell_from_mouse_position(mouse_event.position)
            if active_tool_mode == TOOL_MODE_INSPECT:
                _handle_inspect_click(target_cell)
                return
            _handle_grid_cell_designation(target_cell)
        return
    if event is InputEventMouseMotion and _is_stockpile_dragging:
        var motion_event := event as InputEventMouseMotion
        var target_cell: Vector2i = _pick_grid_cell_from_mouse_position(motion_event.position)
        _refresh_hover_cell(target_cell)
        _update_stockpile_drag(target_cell)
        return
    if event is InputEventMouseMotion and active_tool_mode == TOOL_MODE_PLACE_KITCHEN:
        var motion_event := event as InputEventMouseMotion
        var target_cell: Vector2i = _pick_grid_cell_from_mouse_position(motion_event.position)
        _refresh_hover_cell(target_cell)
        _refresh_kitchen_hover_preview(target_cell)
        return
    if event is InputEventMouseMotion:
        var motion_event := event as InputEventMouseMotion
        _refresh_hover_cell(_pick_grid_cell_from_mouse_position(motion_event.position))
        return
    if not (event is InputEventKey):
        return
    var key_event := event as InputEventKey
    if not key_event.pressed or key_event.echo:
        return
    match key_event.keycode:
        KEY_J:
            _toggle_jobs_panel()
        KEY_W:
            _toggle_workers_panel()
        KEY_1:
            set_active_tool_mode(TOOL_MODE_INSPECT)
        KEY_2:
            set_active_tool_mode(TOOL_MODE_GATHER_WOOD)
        KEY_3:
            set_active_tool_mode(TOOL_MODE_GATHER_STONE)
        KEY_4:
            set_active_tool_mode(TOOL_MODE_GATHER_FOOD)
        KEY_5:
            set_active_tool_mode(TOOL_MODE_MINE)
        KEY_6:
            set_active_tool_mode(TOOL_MODE_DESIGNATE_STOCKPILE)
        KEY_7:
            set_active_tool_mode(TOOL_MODE_PLACE_KITCHEN)
        KEY_Q:
            _adjust_layer_cutaway(1)
        KEY_E:
            _adjust_layer_cutaway(-1)

func _toggle_jobs_panel() -> void:
    _resolve_child_nodes()
    if hud != null and hud.has_method("toggle_jobs_panel"):
        hud.toggle_jobs_panel()
        if simulation != null and hud.has_method("sync_from_simulation"):
            hud.sync_from_simulation(simulation)

func _toggle_workers_panel() -> void:
    _resolve_child_nodes()
    if hud != null and hud.has_method("toggle_workers_panel"):
        hud.toggle_workers_panel()
        if simulation != null and hud.has_method("sync_from_simulation"):
            hud.sync_from_simulation(simulation)

func _pick_grid_cell_from_mouse_position(mouse_position: Vector2) -> Vector2i:
    _resolve_child_nodes()
    if camera == null or world_root == null or simulation == null or simulation.world == null:
        return Vector2i(-1, -1)
    if not world_root.has_method("ray_to_grid_cell"):
        return Vector2i(-1, -1)
    var ray_origin: Vector3 = camera.project_ray_origin(mouse_position)
    var ray_direction: Vector3 = camera.project_ray_normal(mouse_position)
    return world_root.ray_to_grid_cell(ray_origin, ray_direction, simulation.world)

func _handle_grid_cell_designation(target_cell: Vector2i) -> Dictionary:
    if active_tool_mode == TOOL_MODE_INSPECT:
        return {"valid": false, "warning": "", "command_type": ""}
    if simulation == null:
        return {"valid": false, "warning": "Simulation is not ready", "command_type": ""}
    var result: Dictionary
    if active_tool_mode == TOOL_MODE_DESIGNATE_STOCKPILE:
        result = simulation.queue_stockpile_designation_command(simulation.tick + 1, "player_001", target_cell, ["wood", "stone", "dirt", "food", "meal"])
    elif active_tool_mode == TOOL_MODE_PLACE_KITCHEN:
        result = _handle_kitchen_cells_designation(target_cell, _kitchen_cells_from_seed(target_cell))
    elif active_tool_mode == TOOL_MODE_MINE:
        result = _handle_mine_cells_designation(target_cell, [target_cell])
    else:
        result = simulation.queue_designation_command(simulation.tick + 1, "player_001", active_tool_mode, target_cell, {"priority": 5})
    if not bool(result["valid"]):
        _show_designation_warning(str(result["warning"]))
    return result

func _handle_kitchen_cells_designation(target_cell: Vector2i, cells: Array) -> Dictionary:
    if simulation == null:
        return {"valid": false, "warning": "Simulation is not ready", "command_type": ""}
    var center_cell: Vector2i = _center_cell_for_cells(cells, target_cell)
    var result: Dictionary = simulation.queue_blueprint_command(simulation.tick + 1, "player_001", "kitchen", center_cell, {
        "priority": 5,
        "cells": _serialize_cells(cells),
    })
    if not bool(result["valid"]):
        _show_designation_warning(str(result["warning"]))
    return result

func _handle_stockpile_cells_designation(target_cell: Vector2i, cells: Array) -> Dictionary:
    if simulation == null:
        return {"valid": false, "warning": "Simulation is not ready", "command_type": ""}
    var result: Dictionary = simulation.queue_stockpile_designation_command(
        simulation.tick + 1,
        "player_001",
        target_cell,
        ["wood", "stone", "dirt", "food", "meal"],
        cells
    )
    if not bool(result["valid"]):
        _show_designation_warning(str(result["warning"]))
    return result

func _handle_mine_cells_designation(target_cell: Vector2i, cells: Array) -> Dictionary:
    if simulation == null:
        return {"valid": false, "warning": "Simulation is not ready", "command_type": ""}
    var queued: int = 0
    var last_warning: String = "Select grass, dirt, or a surface rock to mine"
    for cell in cells:
        var result: Dictionary = simulation.queue_designation_command(simulation.tick + 1, "player_001", TOOL_MODE_MINE, cell, {"priority": 5})
        if bool(result.get("valid", false)):
            queued += 1
        else:
            last_warning = str(result.get("warning", last_warning))
    if queued == 0:
        _show_designation_warning(last_warning)
        return {"valid": false, "warning": last_warning, "command_type": "DESIGNATE_MINE"}
    return {"valid": true, "warning": "", "command_type": "DESIGNATE_MINE", "queued": queued, "target_cell": [target_cell.x, target_cell.y]}

func _handle_stockpile_selection_or_resize(target_cell: Vector2i) -> Dictionary:
    if simulation == null:
        return {"valid": false, "warning": "Simulation is not ready", "command_type": ""}
    if selected_stockpile_id != "":
        var resize_handle: Dictionary = _stockpile_resize_handle_at_cell(target_cell)
        if not resize_handle.is_empty():
            var result: Dictionary = simulation.queue_stockpile_resize_command(
                simulation.tick + 1,
                "player_001",
                selected_stockpile_id,
                str(resize_handle["side"]),
                int(resize_handle["delta"])
            )
            if not bool(result["valid"]):
                _show_designation_warning(str(result["warning"]))
            return result
    var stockpile_id: String = simulation.find_stockpile_at_cell(target_cell)
    _set_selected_stockpile_id(stockpile_id)
    sync_from_simulation(simulation)
    return {"valid": stockpile_id != "", "warning": "", "stockpile_id": stockpile_id}

func _handle_inspect_click(target_cell: Vector2i) -> Dictionary:
    var stockpile_result: Dictionary = _handle_stockpile_selection_or_resize(target_cell)
    if bool(stockpile_result.get("valid", false)):
        _set_selected_workshop({})
        return stockpile_result
    if simulation == null:
        return {"valid": false, "warning": "Simulation is not ready"}
    var workshop: Dictionary = simulation.find_workshop_at_cell(target_cell)
    _set_selected_workshop(workshop)
    if not workshop.is_empty():
        _set_selected_stockpile_id("")
    sync_from_simulation(simulation)
    return {"valid": not workshop.is_empty(), "warning": "", "workshop": workshop}

func _on_stockpile_mode_requested(storage_mode: String) -> void:
    if simulation == null or selected_stockpile_id == "":
        _show_designation_warning("Select a stockpile first")
        return
    var result: Dictionary = simulation.queue_stockpile_mode_command(simulation.tick + 1, "player_001", selected_stockpile_id, storage_mode)
    if not bool(result["valid"]):
        _show_designation_warning(str(result["warning"]))

func _on_workshop_recipe_requested(recipe_id: String) -> void:
    if simulation == null or selected_workshop_id == "":
        _show_designation_warning("Select a kitchen first")
        return
    var result: Dictionary = simulation.queue_workshop_recipe_command(simulation.tick + 1, "player_001", selected_workshop_id, recipe_id, {"priority": 5})
    if not bool(result["valid"]):
        _show_designation_warning(str(result["warning"]))

func _on_layer_depth_requested(delta: int) -> void:
    _adjust_layer_cutaway(delta)

func _adjust_layer_cutaway(delta: int) -> void:
    _set_layer_cutaway_depth(layer_cutaway_depth + delta)
    sync_from_simulation(simulation)

func _set_layer_cutaway_depth(depth: int) -> void:
    layer_cutaway_depth = clampi(depth, -4, 0)
    _resolve_child_nodes()
    if world_root != null and world_root.has_method("set_layer_cutaway_depth"):
        world_root.set_layer_cutaway_depth(layer_cutaway_depth)
    if hud != null and hud.has_method("set_layer_depth"):
        hud.set_layer_depth(layer_cutaway_depth)

func _refresh_hover_cell(target_cell: Vector2i) -> void:
    _resolve_child_nodes()
    if world_root != null and world_root.has_method("set_hover_cell"):
        world_root.set_hover_cell(target_cell, _hover_target_is_valid(target_cell))

func _hover_target_is_valid(target_cell: Vector2i) -> bool:
    if target_cell == Vector2i(-1, -1):
        return false
    if simulation == null:
        return true
    if active_tool_mode in [TOOL_MODE_GATHER_WOOD, TOOL_MODE_GATHER_STONE, TOOL_MODE_GATHER_FOOD, TOOL_MODE_MINE]:
        return bool(simulation.validate_designation_target(active_tool_mode, target_cell).get("valid", false))
    if active_tool_mode == TOOL_MODE_DESIGNATE_STOCKPILE:
        return bool(simulation.validate_stockpile_designation_target(target_cell).get("valid", false))
    if active_tool_mode == TOOL_MODE_PLACE_KITCHEN:
        return bool(simulation.validate_blueprint_target("kitchen", target_cell, _kitchen_cells_from_seed(target_cell)).get("valid", false))
    return true

func _stockpile_resize_handle_at_cell(target_cell: Vector2i) -> Dictionary:
    if simulation == null or selected_stockpile_id == "":
        return {}
    for handle in simulation.get_stockpile_resize_handles(selected_stockpile_id):
        var raw_cell: Array = handle.get("cell", [])
        if raw_cell.size() >= 2 and Vector2i(int(raw_cell[0]), int(raw_cell[1])) == target_cell:
            return handle
    return {}

func _begin_stockpile_drag(target_cell: Vector2i) -> void:
    _stockpile_drag_start = target_cell
    _stockpile_drag_current = target_cell
    _is_stockpile_dragging = target_cell != Vector2i(-1, -1)
    _refresh_stockpile_preview()

func _update_stockpile_drag(target_cell: Vector2i) -> void:
    if not _is_stockpile_dragging or target_cell == _stockpile_drag_current:
        return
    _stockpile_drag_current = target_cell
    _refresh_stockpile_preview()

func _finish_stockpile_drag(target_cell: Vector2i) -> Dictionary:
    if not _is_stockpile_dragging:
        _clear_stockpile_preview()
        return {"valid": false, "warning": "", "command_type": ""}
    if target_cell != Vector2i(-1, -1):
        _stockpile_drag_current = target_cell
    var cells: Array[Vector2i] = _stockpile_drag_cells()
    var result: Dictionary
    if active_tool_mode == TOOL_MODE_PLACE_KITCHEN:
        if cells.size() == 1:
            cells = _kitchen_cells_from_seed(_stockpile_drag_current)
        result = _handle_kitchen_cells_designation(_stockpile_drag_start, cells)
    elif active_tool_mode == TOOL_MODE_MINE:
        result = _handle_mine_cells_designation(_stockpile_drag_start, cells)
    else:
        result = _handle_stockpile_cells_designation(_stockpile_drag_start, cells)
    _is_stockpile_dragging = false
    _stockpile_drag_start = Vector2i(-1, -1)
    _stockpile_drag_current = Vector2i(-1, -1)
    _clear_stockpile_preview()
    return result

func _stockpile_drag_cells() -> Array[Vector2i]:
    if _stockpile_drag_start == Vector2i(-1, -1) or _stockpile_drag_current == Vector2i(-1, -1):
        return []
    var min_x: int = mini(_stockpile_drag_start.x, _stockpile_drag_current.x)
    var max_x: int = maxi(_stockpile_drag_start.x, _stockpile_drag_current.x)
    var min_y: int = mini(_stockpile_drag_start.y, _stockpile_drag_current.y)
    var max_y: int = maxi(_stockpile_drag_start.y, _stockpile_drag_current.y)
    var cells: Array[Vector2i] = []
    for x in range(min_x, max_x + 1):
        for y in range(min_y, max_y + 1):
            cells.append(Vector2i(x, y))
    return cells

func _refresh_stockpile_preview() -> void:
    _resolve_child_nodes()
    if world_root == null:
        return
    var cells: Array = _stockpile_drag_cells()
    var valid_preview: bool = true
    if simulation != null:
        var validation: Dictionary
        if active_tool_mode == TOOL_MODE_PLACE_KITCHEN:
            if cells.size() == 1:
                cells = _kitchen_cells_from_seed(_stockpile_drag_current)
            validation = simulation.validate_blueprint_target("kitchen", _center_cell_for_cells(cells, _stockpile_drag_current), cells)
            valid_preview = bool(validation.get("valid", false))
            if not valid_preview:
                _set_placement_preview_cells(cells, false)
                return
        elif active_tool_mode == TOOL_MODE_MINE:
            var valid_mine_cells: Array[Vector2i] = []
            for cell in cells:
                validation = simulation.validate_designation_target(TOOL_MODE_MINE, cell)
                if bool(validation.get("valid", false)):
                    valid_mine_cells.append(cell)
            cells = valid_mine_cells
            valid_preview = not cells.is_empty()
        else:
            validation = simulation.validate_stockpile_designation_cells(cells)
            cells = validation.get("cells", [])
    _set_placement_preview_cells(cells, valid_preview)

func _refresh_kitchen_hover_preview(target_cell: Vector2i) -> void:
    _resolve_child_nodes()
    if world_root == null:
        return
    if target_cell == Vector2i(-1, -1):
        _set_placement_preview_cells([])
        return
    var cells: Array = _kitchen_cells_from_seed(target_cell)
    var valid_preview: bool = true
    if simulation != null:
        var validation: Dictionary = simulation.validate_blueprint_target("kitchen", target_cell, cells)
        valid_preview = bool(validation.get("valid", false))
        if valid_preview:
            cells = validation.get("cells", [])
    _set_placement_preview_cells(cells, valid_preview)

func _set_placement_preview_cells(cells: Array, valid: bool = true) -> void:
    if world_root == null:
        return
    if active_tool_mode == TOOL_MODE_PLACE_KITCHEN and world_root.has_method("set_kitchen_preview_cells"):
        world_root.set_kitchen_preview_cells(cells, valid)
    elif world_root.has_method("set_stockpile_preview_cells"):
        world_root.set_stockpile_preview_cells(cells)

func _kitchen_cells_from_seed(seed_cell: Vector2i) -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    for x in range(seed_cell.x - 1, seed_cell.x + 2):
        for y in range(seed_cell.y - 1, seed_cell.y + 2):
            cells.append(Vector2i(x, y))
    return cells

func _center_cell_for_cells(cells: Array, fallback: Vector2i) -> Vector2i:
    if cells.is_empty():
        return fallback
    var min_x: int = cells[0].x
    var max_x: int = cells[0].x
    var min_y: int = cells[0].y
    var max_y: int = cells[0].y
    for cell in cells:
        min_x = mini(min_x, cell.x)
        max_x = maxi(max_x, cell.x)
        min_y = mini(min_y, cell.y)
        max_y = maxi(max_y, cell.y)
    return Vector2i(int(floor(float(min_x + max_x) * 0.5)), int(floor(float(min_y + max_y) * 0.5)))

func _serialize_cells(cells: Array) -> Array:
    var output: Array = []
    for cell in cells:
        output.append([cell.x, cell.y])
    return output

func _clear_stockpile_preview() -> void:
    _resolve_child_nodes()
    if world_root != null and world_root.has_method("set_kitchen_preview_cells"):
        world_root.set_kitchen_preview_cells([])
    if world_root != null and world_root.has_method("set_stockpile_preview_cells"):
        world_root.set_stockpile_preview_cells([])

func _set_selected_stockpile_id(stockpile_id: String) -> void:
    selected_stockpile_id = stockpile_id
    _resolve_child_nodes()
    if world_root != null and world_root.has_method("set_selected_stockpile_id"):
        world_root.set_selected_stockpile_id(stockpile_id)
    _sync_selected_stockpile_hud()

func _set_selected_workshop(workshop: Dictionary) -> void:
    if workshop.is_empty():
        selected_workshop_id = ""
    else:
        selected_workshop_id = str(workshop.get("building_id", ""))
    _sync_selected_workshop_hud(workshop)

func _sync_selected_stockpile_hud() -> void:
    _resolve_child_nodes()
    if hud == null or not hud.has_method("set_selected_stockpile"):
        return
    if simulation == null or selected_stockpile_id == "" or not simulation.stockpiles.has(selected_stockpile_id):
        hud.set_selected_stockpile("", "")
        return
    hud.set_selected_stockpile(selected_stockpile_id, simulation.stockpiles[selected_stockpile_id].storage_mode)

func _sync_selected_workshop_hud(workshop: Dictionary = {}) -> void:
    _resolve_child_nodes()
    if hud == null or not hud.has_method("set_selected_workshop"):
        return
    if workshop.is_empty() and simulation != null and selected_workshop_id != "":
        var construction = simulation._completed_construction_for_building(selected_workshop_id)
        if construction != null:
            workshop = simulation._workshop_summary(construction)
    if workshop.is_empty():
        hud.set_selected_workshop("", "")
        return
    hud.set_selected_workshop(str(workshop.get("building_id", "")), str(workshop.get("display_name", "")))

func _show_designation_warning(warning: String) -> void:
    if warning == "":
        return
    if hud != null and hud.has_method("show_warning"):
        hud.show_warning(warning)
    else:
        push_warning(warning)

func set_active_tool_mode(mode: String) -> bool:
    if not TOOL_MODES.has(mode):
        return false
    active_tool_mode = mode
    _is_stockpile_dragging = false
    _clear_stockpile_preview()
    if mode != TOOL_MODE_INSPECT:
        _set_selected_stockpile_id("")
        _set_selected_workshop({})
    _resolve_child_nodes()
    if hud != null and hud.has_method("set_active_tool_mode"):
        hud.set_active_tool_mode(mode)
    return true

func _process(delta: float) -> void:
    if sim_clock == null or simulation == null:
        return
    var advanced: int = sim_clock.advance_steps(delta)
    for i in range(advanced):
        simulation.step_tick()
    if advanced > 0:
        sync_from_simulation(simulation)

func sync_from_simulation(sim: Simulation) -> void:
    if sim != null:
        simulation = sim
    _resolve_child_nodes()
    if world_root != null and world_root.has_method("set_layer_cutaway_depth"):
        world_root.set_layer_cutaway_depth(layer_cutaway_depth)
    if world_root != null and world_root.has_method("sync_from_simulation"):
        world_root.sync_from_simulation(simulation)
    _sync_selected_stockpile_hud()
    _sync_selected_workshop_hud()
    if hud != null and hud.has_method("sync_from_simulation"):
        hud.sync_from_simulation(simulation)

func _resolve_child_nodes() -> void:
    # Tests may call sync_from_simulation() before _ready()/@onready run.
    if world_root == null:
        world_root = get_node_or_null("WorldRoot") as Node3D
    if hud == null:
        hud = get_node_or_null("GameHud") as CanvasLayer
    if camera == null:
        camera = get_node_or_null("Camera3D") as Camera3D
