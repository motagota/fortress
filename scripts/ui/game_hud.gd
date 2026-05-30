extends CanvasLayer

signal tool_mode_requested(mode: String)
signal stockpile_mode_requested(storage_mode: String)
signal workshop_recipe_requested(recipe_id: String)
signal layer_depth_requested(delta: int)

const WorldgenDiagnosticsScript := preload("res://scripts/simulation/worldgen_diagnostics.gd")

const TOOL_MODE_INSPECT := "inspect"
const TOOL_MODE_GATHER_WOOD := "gather_wood"
const TOOL_MODE_GATHER_STONE := "gather_stone"
const TOOL_MODE_GATHER_FOOD := "gather_food"
const TOOL_MODE_MINE := "mine"
const TOOL_MODE_DESIGNATE_STOCKPILE := "designate_stockpile"
const TOOL_MODE_PLACE_KITCHEN := "place_kitchen"
const TOOL_MODE_LABELS := {
    TOOL_MODE_INSPECT: "Inspect",
    TOOL_MODE_GATHER_WOOD: "Chop Wood",
    TOOL_MODE_GATHER_STONE: "Gather Stone",
    TOOL_MODE_GATHER_FOOD: "Gather Food",
    TOOL_MODE_MINE: "Mine",
    TOOL_MODE_DESIGNATE_STOCKPILE: "Stockpile",
    TOOL_MODE_PLACE_KITCHEN: "Kitchen",
}

@onready var label: Label = $Panel/SimInfo/StatusLabel
@onready var pause_button: Button = $Panel/PauseButton
@onready var speed_1x: Button = $Panel/Speed1x
@onready var speed_2x: Button = $Panel/Speed2x
@onready var speed_4x: Button = $Panel/Speed4x
@onready var inspect_button: Button = $Panel/InspectButton
@onready var gather_wood_button: Button = $Panel/GatherWoodButton
@onready var gather_stone_button: Button = $Panel/GatherStoneButton
@onready var gather_food_button: Button = $Panel/GatherFoodButton
@onready var mine_button: Button = $Panel/MineButton
@onready var stockpile_button: Button = $Panel/StockpileButton
@onready var kitchen_button: Button = $Panel/KitchenButton
@onready var storage_only_button: Button = $Panel/StockpileConfig/StorageOnlyButton
@onready var supply_only_button: Button = $Panel/StockpileConfig/SupplyOnlyButton
@onready var both_mode_button: Button = $Panel/StockpileConfig/BothModeButton
@onready var cook_meal_button: Button = $Panel/CookMealButton
@onready var layer_up_button: Button = $Panel/LayerUpButton
@onready var layer_down_button: Button = $Panel/LayerDownButton
@onready var layer_label: Label = $Panel/LayerLabel
@onready var worldgen_diagnostics_button: Button = $Panel/WorldgenDiagnosticsButton
@onready var jobs_panel: Panel = $JobsPanel
@onready var jobs_list_label: Label = $JobsPanel/JobsListLabel
@onready var workers_panel: Panel = $WorkersPanel
@onready var workers_list: ItemList = $WorkersPanel/WorkersList
@onready var worker_detail_label: Label = $WorkersPanel/WorkerDetailLabel
@onready var worldgen_diagnostics_panel: Panel = $WorldgenDiagnosticsPanel
@onready var worldgen_diagnostics_label: Label = $WorldgenDiagnosticsPanel/WorldgenDiagnosticsLabel

var sim_clock: SimClock
var active_tool_mode: String = TOOL_MODE_INSPECT
var last_warning: String = ""
var selected_stockpile_id: String = ""
var selected_stockpile_mode: String = ""
var selected_workshop_id: String = ""
var selected_workshop_name: String = ""
var selected_worker_id: String = ""
var layer_depth: int = 0
var jobs_panel_visible: bool = false
var workers_panel_visible: bool = false
var worldgen_diagnostics_panel_visible: bool = false
var _last_worker_snapshot: Array = []
var _last_synced_simulation: Simulation = null
var _signals_connected: bool = false

func _ready() -> void:
    _refresh_jobs_panel_visibility()
    _refresh_workers_panel_visibility()
    _refresh_worldgen_diagnostics_panel_visibility()
    _refresh_workshop_buttons()
    _refresh_layer_controls()
    if _signals_connected:
        _refresh_status_text(null)
        return
    if pause_button:
        _connect_pressed(pause_button, _on_pause_pressed)
    if speed_1x:
        _connect_pressed(speed_1x, _on_speed_pressed.bind(1))
    if speed_2x:
        _connect_pressed(speed_2x, _on_speed_pressed.bind(2))
    if speed_4x:
        _connect_pressed(speed_4x, _on_speed_pressed.bind(4))
    if inspect_button:
        _connect_pressed(inspect_button, _on_tool_button_pressed.bind(TOOL_MODE_INSPECT))
    if gather_wood_button:
        _connect_pressed(gather_wood_button, _on_tool_button_pressed.bind(TOOL_MODE_GATHER_WOOD))
    if gather_stone_button:
        _connect_pressed(gather_stone_button, _on_tool_button_pressed.bind(TOOL_MODE_GATHER_STONE))
    if gather_food_button:
        _connect_pressed(gather_food_button, _on_tool_button_pressed.bind(TOOL_MODE_GATHER_FOOD))
    if mine_button:
        _connect_pressed(mine_button, _on_tool_button_pressed.bind(TOOL_MODE_MINE))
    if stockpile_button:
        _connect_pressed(stockpile_button, _on_tool_button_pressed.bind(TOOL_MODE_DESIGNATE_STOCKPILE))
    if kitchen_button:
        _connect_pressed(kitchen_button, _on_tool_button_pressed.bind(TOOL_MODE_PLACE_KITCHEN))
    if storage_only_button:
        _connect_pressed(storage_only_button, _on_stockpile_mode_pressed.bind("storage"))
    if supply_only_button:
        _connect_pressed(supply_only_button, _on_stockpile_mode_pressed.bind("supply"))
    if both_mode_button:
        _connect_pressed(both_mode_button, _on_stockpile_mode_pressed.bind("both"))
    if cook_meal_button:
        _connect_pressed(cook_meal_button, _on_cook_meal_pressed)
    if layer_up_button:
        _connect_pressed(layer_up_button, _on_layer_up_pressed)
    if layer_down_button:
        _connect_pressed(layer_down_button, _on_layer_down_pressed)
    if worldgen_diagnostics_button:
        _connect_pressed(worldgen_diagnostics_button, _on_worldgen_diagnostics_pressed)
    if workers_list and not workers_list.item_selected.is_connected(_on_worker_selected):
        workers_list.item_selected.connect(_on_worker_selected)
    _signals_connected = true
    _refresh_status_text(null)

func _connect_pressed(button: Button, callable: Callable) -> void:
    if not button.pressed.is_connected(callable):
        button.pressed.connect(callable)

func set_sim_clock(clock: SimClock) -> void:
    sim_clock = clock

func _on_pause_pressed() -> void:
    if sim_clock == null:
        return
    sim_clock.set_paused(not sim_clock.paused)
    if sim_clock.paused:
        pause_button.text = "Play"
    else:
        pause_button.text = "Pause"

func _on_speed_pressed(speed: int) -> void:
    if sim_clock == null:
        return
    sim_clock.set_speed(speed)

func _on_tool_button_pressed(mode: String) -> void:
    if set_active_tool_mode(mode):
        tool_mode_requested.emit(mode)

func _on_stockpile_mode_pressed(storage_mode: String) -> void:
    if selected_stockpile_id == "":
        show_warning("Select a stockpile first")
        return
    stockpile_mode_requested.emit(storage_mode)

func _on_cook_meal_pressed() -> void:
    if selected_workshop_id == "":
        show_warning("Select a kitchen first")
        return
    workshop_recipe_requested.emit("cook_meal")

func _on_layer_up_pressed() -> void:
    layer_depth_requested.emit(1)

func _on_layer_down_pressed() -> void:
    layer_depth_requested.emit(-1)

func _on_worldgen_diagnostics_pressed() -> void:
    toggle_worldgen_diagnostics_panel()

func set_active_tool_mode(mode: String) -> bool:
    if not TOOL_MODE_LABELS.has(mode):
        return false
    active_tool_mode = mode
    last_warning = ""
    _refresh_status_text(null)
    return true

func show_warning(warning: String) -> void:
    last_warning = warning
    _refresh_status_text(null)

func toggle_jobs_panel() -> void:
    set_jobs_panel_visible(not jobs_panel_visible)

func set_jobs_panel_visible(panel_visible: bool) -> void:
    jobs_panel_visible = panel_visible
    _refresh_jobs_panel_visibility()

func toggle_workers_panel() -> void:
    set_workers_panel_visible(not workers_panel_visible)

func set_workers_panel_visible(panel_visible: bool) -> void:
    workers_panel_visible = panel_visible
    _refresh_workers_panel_visibility()

func toggle_worldgen_diagnostics_panel() -> void:
    set_worldgen_diagnostics_panel_visible(not worldgen_diagnostics_panel_visible)

func set_worldgen_diagnostics_panel_visible(panel_visible: bool) -> void:
    worldgen_diagnostics_panel_visible = panel_visible
    _refresh_worldgen_diagnostics_panel_visibility()
    if worldgen_diagnostics_panel_visible:
        _refresh_worldgen_diagnostics(_last_synced_simulation)

func set_selected_stockpile(stockpile_id: String, storage_mode: String = "") -> void:
    selected_stockpile_id = stockpile_id
    selected_stockpile_mode = storage_mode
    _refresh_stockpile_mode_buttons()
    _refresh_status_text(null)

func set_selected_workshop(workshop_id: String, display_name: String = "") -> void:
    selected_workshop_id = workshop_id
    selected_workshop_name = display_name
    _refresh_workshop_buttons()
    _refresh_status_text(null)

func set_layer_depth(depth: int) -> void:
    layer_depth = clampi(depth, -15, 0)
    _refresh_layer_controls()
    _refresh_status_text(null)

func sync_from_simulation(simulation: Simulation) -> void:
    _last_synced_simulation = simulation
    if selected_stockpile_id != "":
        var found: bool = false
        for stockpile in simulation.canonical_snapshot()["stockpiles"]:
            if str(stockpile.get("id", "")) == selected_stockpile_id:
                selected_stockpile_mode = str(stockpile.get("storage_mode", "both"))
                found = true
                break
        if not found:
            selected_stockpile_id = ""
            selected_stockpile_mode = ""
    _refresh_stockpile_mode_buttons()
    _refresh_workshop_buttons()
    _refresh_jobs_list(simulation)
    _refresh_workers_list(simulation)
    _refresh_worldgen_diagnostics(simulation)
    _refresh_status_text(simulation)

func _refresh_jobs_panel_visibility() -> void:
    if jobs_panel == null:
        return
    jobs_panel.visible = jobs_panel_visible

func _refresh_workers_panel_visibility() -> void:
    if workers_panel == null:
        return
    workers_panel.visible = workers_panel_visible

func _refresh_worldgen_diagnostics_panel_visibility() -> void:
    if worldgen_diagnostics_panel == null:
        return
    worldgen_diagnostics_panel.visible = worldgen_diagnostics_panel_visible

func _refresh_jobs_list(simulation: Simulation) -> void:
    if jobs_list_label == null or simulation == null:
        return
    var snapshot: Dictionary = simulation.canonical_snapshot()
    var jobs: Array = snapshot.get("jobs", [])
    if jobs.is_empty():
        jobs_list_label.text = "No jobs"
        return
    var lines: Array[String] = []
    for job in jobs:
        var target: Array = job.get("target_world_cell", job.get("target_cell", [0, 0, 0]))
        var claimed_by: String = str(job.get("claimed_by_unit_id", ""))
        var claimed_text: String = "unclaimed" if claimed_by == "" else claimed_by
        lines.append("%s | %s | %s | (%d,%d,%d) | %s" % [
            str(job.get("id", "")),
            str(job.get("type", "")),
            str(job.get("status", "")),
            int(target[0]),
            int(target[1]),
            int(target[2]) if target.size() >= 3 else 0,
            claimed_text,
        ])
    jobs_list_label.text = "\n".join(lines)

func _refresh_workers_list(simulation: Simulation) -> void:
    if workers_list == null or simulation == null:
        return
    var snapshot: Dictionary = simulation.canonical_snapshot()
    var workers: Array = snapshot.get("units", [])
    _last_worker_snapshot = workers
    workers_list.clear()
    if workers.is_empty():
        selected_worker_id = ""
        _refresh_worker_detail(workers)
        return
    var selected_index: int = -1
    for worker in workers:
        var position: Array = worker.get("world_cell", worker.get("position", [0, 0, 0]))
        var current_job_id: String = str(worker.get("current_job_id", ""))
        var job_text: String = "no job" if current_job_id == "" else current_job_id
        var needs: Dictionary = worker.get("needs", {})
        workers_list.add_item("%s | %s | (%d,%d,%d) | %s | H%d E%d" % [
            str(worker.get("display_name", "")),
            str(worker.get("state", "")),
            int(position[0]),
            int(position[1]),
            int(position[2]) if position.size() >= 3 else 0,
            job_text,
            int(needs.get("hunger", 0)),
            int(needs.get("energy", 0)),
        ])
        var item_index: int = workers_list.get_item_count() - 1
        var worker_id: String = str(worker.get("id", ""))
        workers_list.set_item_metadata(item_index, worker_id)
        if worker_id == selected_worker_id:
            selected_index = item_index
    if selected_index >= 0:
        workers_list.select(selected_index)
    else:
        workers_list.deselect_all()
        if selected_worker_id != "":
            selected_worker_id = ""
    _refresh_worker_detail(workers)

func _on_worker_selected(index: int) -> void:
    if workers_list == null or index < 0 or index >= workers_list.get_item_count():
        return
    selected_worker_id = str(workers_list.get_item_metadata(index))
    _refresh_worker_detail(_last_worker_snapshot)

func _refresh_worker_detail(workers: Array) -> void:
    if worker_detail_label == null:
        return
    if selected_worker_id == "":
        worker_detail_label.text = "Select a worker"
        return
    var worker: Dictionary = _find_worker_snapshot(workers, selected_worker_id)
    if worker.is_empty():
        worker_detail_label.text = "Select a worker"
        return
    var position: Array = worker.get("position", [0, 0])
    var current_job_id: String = str(worker.get("current_job_id", ""))
    var job_text: String = "None" if current_job_id == "" else current_job_id
    var needs: Dictionary = worker.get("needs", {})
    var inventory: Array = worker.get("inventory", [])
    var allowed_jobs: Array = worker.get("allowed_jobs", [])
    var job_priorities: Dictionary = worker.get("job_type_priorities", {})
    var skills: Dictionary = worker.get("skills", {})
    worker_detail_label.text = "%s (%s)\nState: %s\nPosition: (%d,%d)\nCurrent job: %s\nNeeds: Hunger %d | Energy %d | Morale %d\nInventory: %s\nAllowed jobs: %s\nPriorities: %s\nLabor: %d | Mining: %d" % [
        str(worker.get("display_name", "")),
        str(worker.get("id", "")),
        str(worker.get("state", "")),
        int(position[0]),
        int(position[1]),
        job_text,
        int(needs.get("hunger", 0)),
        int(needs.get("energy", 0)),
        int(needs.get("morale", 0)),
        _format_array(inventory),
        _format_array(allowed_jobs),
        _format_dictionary(job_priorities),
        int(skills.get("labor", 0)),
        int(skills.get("mining", 0)),
    ]

func _refresh_worldgen_diagnostics(simulation: Simulation) -> void:
    if worldgen_diagnostics_label == null or not worldgen_diagnostics_panel_visible:
        return
    if simulation == null or not simulation.has_method("get_worldgen_storage_diagnostics"):
        worldgen_diagnostics_label.text = "Worldgen diagnostics unavailable"
        return
    var report: Dictionary = simulation.get_worldgen_storage_diagnostics()
    var lines: Array[String] = []
    lines = WorldgenDiagnosticsScript.format_report(report)
    worldgen_diagnostics_label.text = "\n".join(lines)

func _find_worker_snapshot(workers: Array, worker_id: String) -> Dictionary:
    for worker in workers:
        if str(worker.get("id", "")) == worker_id:
            return worker
    return {}

func _format_array(values: Array) -> String:
    if values.is_empty():
        return "None"
    var parts: Array[String] = []
    for value in values:
        parts.append(str(value))
    return ", ".join(parts)

func _format_dictionary(values: Dictionary) -> String:
    if values.is_empty():
        return "None"
    var keys: Array = values.keys()
    keys.sort()
    var parts: Array[String] = []
    for key in keys:
        parts.append("%s=%s" % [str(key), str(values[key])])
    return ", ".join(parts)

func _refresh_stockpile_mode_buttons() -> void:
    var has_selection: bool = selected_stockpile_id != ""
    _set_mode_button_state(storage_only_button, has_selection, selected_stockpile_mode == "storage")
    _set_mode_button_state(supply_only_button, has_selection, selected_stockpile_mode == "supply")
    _set_mode_button_state(both_mode_button, has_selection, selected_stockpile_mode == "both")

func _refresh_workshop_buttons() -> void:
    if cook_meal_button == null:
        return
    cook_meal_button.disabled = selected_workshop_id == ""

func _refresh_layer_controls() -> void:
    if layer_label != null:
        layer_label.text = "Chunk Layer %d" % (1 - layer_depth)
    if layer_up_button != null:
        layer_up_button.disabled = layer_depth >= 0
    if layer_down_button != null:
        layer_down_button.disabled = layer_depth <= -15

func _set_mode_button_state(button: Button, enabled: bool, active: bool) -> void:
    if button == null:
        return
    button.disabled = not enabled
    button.button_pressed = active

func _refresh_status_text(simulation: Simulation) -> void:
    if label == null:
        return
    var speed_str: String = "1x"
    var paused_str: String = ""
    if sim_clock != null:
        speed_str = str(sim_clock.speed) + "x"
        if sim_clock.paused:
            paused_str = " PAUSED"
    var tool_str: String = str(TOOL_MODE_LABELS.get(active_tool_mode, active_tool_mode))
    var stockpile_str: String = ""
    if selected_stockpile_id != "":
        stockpile_str = " | Stockpile %s %s" % [selected_stockpile_id, selected_stockpile_mode.capitalize()]
    var workshop_str: String = ""
    if selected_workshop_id != "":
        workshop_str = " | Workshop %s" % selected_workshop_name
    var layer_str: String = " | Chunk Layer %d" % (1 - layer_depth)
    var warning_str: String = ""
    if last_warning != "":
        warning_str = " | Warning: " + last_warning
    if simulation == null:
        label.text = "Tool %s | Speed %s%s%s%s%s%s" % [tool_str, speed_str, paused_str, layer_str, stockpile_str, workshop_str, warning_str]
        return
    var snapshot: Dictionary = simulation.canonical_snapshot()
    label.text = "Tick %d | Units %d | Resources %d | Jobs %d | Hash %s | Speed %s%s | Tool %s%s%s%s%s" % [
        snapshot["tick"],
        snapshot["units"].size(),
        snapshot["resources"].size(),
        snapshot["jobs"].size(),
        simulation.state_hash().substr(0, 8),
        speed_str,
        paused_str,
        tool_str,
        layer_str,
        stockpile_str,
        workshop_str,
        warning_str,
    ]
