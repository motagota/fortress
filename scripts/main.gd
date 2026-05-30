extends Node3D

# Top-down colony game shell: drives the simulation clock, routes input to
# designation commands, and keeps the renderer/HUD in sync with the active layer.

const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const SimClockScript := preload("res://scripts/simulation/sim_clock.gd")
const SaveGameScript := preload("res://scripts/simulation/save_game.gd")
const C := preload("res://scripts/simulation/world_constants.gd")

const INVALID_CELL := Vector3i(-2147483648, -2147483648, -2147483648)
const SAVE_PATH := "user://saves/quicksave.json"

const TOOL_INSPECT := "inspect"
const TOOL_CHOP := "chop"
const TOOL_GATHER := "gather"
const TOOL_MINE := "mine"
const TOOL_CHANNEL := "channel"
const TOOL_STAIR := "stair"
const TOOL_STOCKPILE := "stockpile"
const TOOL_KITCHEN := "kitchen"

const TOOL_COMMANDS := {
    TOOL_CHOP: "DESIGNATE_CHOP",
    TOOL_GATHER: "DESIGNATE_GATHER_FOOD",
    TOOL_MINE: "DESIGNATE_MINE",
    TOOL_CHANNEL: "DESIGNATE_CHANNEL",
    TOOL_STAIR: "DESIGNATE_BUILD_STAIR",
}

@onready var world_root: Node3D = $WorldRoot
@onready var hud: CanvasLayer = $GameHud
@onready var camera: Camera3D = $Camera3D

var simulation
var sim_clock
var active_tool: String = TOOL_INSPECT
var active_layer: int = C.SURFACE_Y_MEAN

func _ready() -> void:
    simulation = SimulationScript.new()
    simulation.initialize_new_game(42)
    sim_clock = SimClockScript.new()
    _resolve_nodes()
    if hud != null and hud.has_signal("tool_requested"):
        hud.tool_requested.connect(set_active_tool)
    if hud != null and hud.has_signal("layer_change_requested"):
        hud.layer_change_requested.connect(_change_layer)
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

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
        _handle_click(_pick_cell(event.position))
        return
    if event is InputEventMouseMotion:
        _set_hover(_pick_cell(event.position))
        return
    if event is InputEventKey and event.pressed and not event.echo:
        match event.keycode:
            KEY_1: set_active_tool(TOOL_INSPECT)
            KEY_2: set_active_tool(TOOL_CHOP)
            KEY_3: set_active_tool(TOOL_GATHER)
            KEY_4: set_active_tool(TOOL_MINE)
            KEY_5: set_active_tool(TOOL_CHANNEL)
            KEY_6: set_active_tool(TOOL_STAIR)
            KEY_7: set_active_tool(TOOL_STOCKPILE)
            KEY_8: set_active_tool(TOOL_KITCHEN)
            KEY_E: _change_layer(1)
            KEY_C: _change_layer(-1)
            KEY_SPACE: _toggle_pause()
            KEY_F5: _quicksave()
            KEY_F9: _quickload()

func _handle_click(cell: Vector3i) -> void:
    if cell == INVALID_CELL or simulation == null:
        return
    var next_tick: int = simulation.tick + 1
    if TOOL_COMMANDS.has(active_tool):
        simulation.queue_command(next_tick, "player_001", str(TOOL_COMMANDS[active_tool]), cell, {"priority": 5})
    elif active_tool == TOOL_STOCKPILE:
        simulation.queue_command(next_tick, "player_001", "DESIGNATE_STOCKPILE", cell,
            {"cells": [[cell.x, cell.y, cell.z]], "accepted_item_types": ["wood", "stone", "dirt", "food", "meal"]})
    elif active_tool == TOOL_KITCHEN:
        simulation.queue_command(next_tick, "player_001", "PLACE_BLUEPRINT", cell, {"building_type": "kitchen", "priority": 5})
    _sync()

func set_active_tool(tool_name: String) -> void:
    active_tool = tool_name
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

func _quicksave() -> void:
    if simulation != null:
        SaveGameScript.save_to_file(simulation, SAVE_PATH)

func _quickload() -> void:
    var loaded = SaveGameScript.load_from_file(SAVE_PATH)
    if loaded != null:
        simulation = loaded
        _sync()

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
