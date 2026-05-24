extends Node3D

const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const SimClockScript := preload("res://scripts/simulation/sim_clock.gd")

const TOOL_MODE_INSPECT := "inspect"
const TOOL_MODE_GATHER_WOOD := "gather_wood"
const TOOL_MODE_GATHER_STONE := "gather_stone"
const TOOL_MODE_GATHER_FOOD := "gather_food"
const TOOL_MODE_DESIGNATE_STOCKPILE := "designate_stockpile"
const TOOL_MODES: Array[String] = [
    TOOL_MODE_INSPECT,
    TOOL_MODE_GATHER_WOOD,
    TOOL_MODE_GATHER_STONE,
    TOOL_MODE_GATHER_FOOD,
    TOOL_MODE_DESIGNATE_STOCKPILE,
]

@onready var world_root: Node3D = $WorldRoot
@onready var hud: CanvasLayer = $GameHud
@onready var camera: Camera3D = $Camera3D

var simulation: Simulation
var sim_clock: SimClock
var active_tool_mode: String = TOOL_MODE_INSPECT

func _ready() -> void:
    simulation = Simulation.new()
    simulation.initialize_new_game(42)
    sim_clock = SimClockScript.new()
    if hud != null and hud.has_method("set_sim_clock"):
        hud.set_sim_clock(sim_clock)
    if hud != null and hud.has_signal("tool_mode_requested"):
        hud.tool_mode_requested.connect(set_active_tool_mode)
    set_active_tool_mode(active_tool_mode)
    sync_from_simulation(simulation)

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        var mouse_event := event as InputEventMouseButton
        if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT:
            var target_cell: Vector2i = _pick_grid_cell_from_mouse_position(mouse_event.position)
            _handle_grid_cell_designation(target_cell)
        return
    if not (event is InputEventKey):
        return
    var key_event := event as InputEventKey
    if not key_event.pressed or key_event.echo:
        return
    match key_event.keycode:
        KEY_1:
            set_active_tool_mode(TOOL_MODE_INSPECT)
        KEY_2:
            set_active_tool_mode(TOOL_MODE_GATHER_WOOD)
        KEY_3:
            set_active_tool_mode(TOOL_MODE_GATHER_STONE)
        KEY_4:
            set_active_tool_mode(TOOL_MODE_GATHER_FOOD)
        KEY_5:
            set_active_tool_mode(TOOL_MODE_DESIGNATE_STOCKPILE)

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
        result = simulation.queue_stockpile_designation_command(simulation.tick + 1, "player_001", target_cell, ["wood", "stone", "food"])
    else:
        result = simulation.queue_designation_command(simulation.tick + 1, "player_001", active_tool_mode, target_cell, {"priority": 5})
    if not bool(result["valid"]):
        _show_designation_warning(str(result["warning"]))
    return result

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
    if world_root != null and world_root.has_method("sync_from_simulation"):
        world_root.sync_from_simulation(simulation)
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
