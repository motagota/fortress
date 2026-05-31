extends CanvasLayer

# Heads-up display: top toolbar for tool selection, a layer/tick readout, time
# controls, a tile inspector panel, a stockpile config window, and a wall-material
# picker. Reads simulation state on sync; never mutates it. The toolbar and panels
# occupy small rects so the rest of the screen passes mouse events to the world.

const C := preload("res://scripts/simulation/world_constants.gd")
const SimulationScript := preload("res://scripts/simulation/simulation.gd")

signal tool_requested(tool_name: String)
signal layer_change_requested(delta: int)
signal stockpile_items_changed(stockpile_id: String, accepted_types: Array)
signal wall_material_changed(material: String)
signal worker_selected(unit_id: String)
signal worker_rename_requested(unit_id: String, new_name: String)
signal worker_allowed_job_toggled(unit_id: String, job_type: String, enabled: bool)
signal worker_job_priority_changed(unit_id: String, job_type: String, priority: int)

# Job types a colonist can be assigned (mirrors SimUnit.allowed_jobs defaults).
const WORKER_JOB_TYPES: Array = [
    "CHOP_TREE", "GATHER_STONE", "GATHER_FOOD",
    "MINE_WALL", "CHANNEL_FLOOR", "BUILD_STAIR",
    "HAUL_ITEM", "BUILD_CONSTRUCTION", "COOK_MEAL",
]

const TOOL_DEFINITIONS: Array = [
    {"id": "inspect", "label": "1 Inspect"},
    {"id": "chop", "label": "2 Chop"},
    {"id": "gather", "label": "3 Gather"},
    {"id": "mine", "label": "4 Mine"},
    {"id": "channel", "label": "5 Channel"},
    {"id": "stair_up", "label": "6 Stairs Up"},
    {"id": "stair_down", "label": "7 Stairs Down"},
    {"id": "stockpile", "label": "8 Stockpile"},
    {"id": "kitchen", "label": "9 Kitchen"},
    {"id": "wall", "label": "0 Wall"},
]

const STOCKPILE_ITEM_TYPES: Array = ["wood", "stone", "dirt", "food", "meal"]
const WALL_MATERIALS: Array = ["dirt", "wood", "stone"]

@onready var tool_buttons_container: Container = $Toolbar/ToolButtons
@onready var layer_label: Label = $Toolbar/StatusRow/LayerLabel
@onready var tick_label: Label = $Toolbar/StatusRow/TickLabel
@onready var pause_button: Button = $Toolbar/StatusRow/PauseButton
@onready var workers_button: Button = $Toolbar/StatusRow/WorkersButton
@onready var inspector_panel: Panel = $Inspector
@onready var inspector_label: Label = $Inspector/InspectorLabel
@onready var config_panel: Panel = $StockpileConfig
@onready var config_title: Label = $StockpileConfig/ConfigTitle
@onready var config_item_container: Container = $StockpileConfig/ItemList
@onready var config_close_button: Button = $StockpileConfig/CloseButton
@onready var wall_config_panel: Panel = $WallConfig
@onready var wall_buttons_container: Container = $WallConfig/WallButtons
@onready var workers_panel: Panel = $WorkersPanel
@onready var workers_list: Container = $WorkersPanel/WorkersScroll/WorkersList
@onready var workers_close_button: Button = $WorkersPanel/WorkersClose
@onready var worker_detail_panel: Panel = $WorkerDetail
@onready var worker_detail_close_button: Button = $WorkerDetail/DetailClose
@onready var worker_name_edit: LineEdit = $WorkerDetail/NameRow/NameEdit
@onready var worker_name_apply: Button = $WorkerDetail/NameRow/NameApply
@onready var worker_detail_body: Container = $WorkerDetail/DetailScroll/DetailBody

var _tool_button_lookup: Dictionary = {}
var _config_checkboxes: Dictionary = {}
var _wall_button_lookup: Dictionary = {}
var _config_stockpile_id: String = ""
var _wall_material: String = "stone"
var _selected_unit_id: String = ""
var active_tool: String = "inspect"
var active_layer: int = C.SURFACE_Y_MEAN
var _sim_clock = null
var _last_synced_simulation = null

func _ready() -> void:
    _resolve_nodes()
    _build_tool_buttons()
    _build_config_checkboxes()
    _build_wall_buttons()
    _connect_pressed(pause_button, _on_pause_button_pressed)
    _connect_pressed(workers_button, toggle_workers_panel)
    _connect_pressed(config_close_button, hide_stockpile_config)
    _connect_pressed(workers_close_button, hide_workers_panel)
    _connect_pressed(worker_detail_close_button, hide_worker_detail)
    _connect_pressed(worker_name_apply, _on_worker_name_apply)
    _refresh_tool_button_states()
    _refresh_wall_button_states()
    _refresh_layer_label()
    _refresh_time_controls()

func _resolve_nodes() -> void:
    tool_buttons_container = get_node_or_null("Toolbar/ToolButtons")
    layer_label = get_node_or_null("Toolbar/StatusRow/LayerLabel")
    tick_label = get_node_or_null("Toolbar/StatusRow/TickLabel")
    pause_button = get_node_or_null("Toolbar/StatusRow/PauseButton")
    workers_button = get_node_or_null("Toolbar/StatusRow/WorkersButton")
    inspector_panel = get_node_or_null("Inspector")
    inspector_label = get_node_or_null("Inspector/InspectorLabel")
    config_panel = get_node_or_null("StockpileConfig")
    config_title = get_node_or_null("StockpileConfig/ConfigTitle")
    config_item_container = get_node_or_null("StockpileConfig/ItemList")
    config_close_button = get_node_or_null("StockpileConfig/CloseButton")
    wall_config_panel = get_node_or_null("WallConfig")
    wall_buttons_container = get_node_or_null("WallConfig/WallButtons")
    workers_panel = get_node_or_null("WorkersPanel")
    workers_list = get_node_or_null("WorkersPanel/WorkersScroll/WorkersList")
    workers_close_button = get_node_or_null("WorkersPanel/WorkersClose")
    worker_detail_panel = get_node_or_null("WorkerDetail")
    worker_detail_close_button = get_node_or_null("WorkerDetail/DetailClose")
    worker_name_edit = get_node_or_null("WorkerDetail/NameRow/NameEdit")
    worker_name_apply = get_node_or_null("WorkerDetail/NameRow/NameApply")
    worker_detail_body = get_node_or_null("WorkerDetail/DetailScroll/DetailBody")

func _build_tool_buttons() -> void:
    if tool_buttons_container == null:
        return
    for child in tool_buttons_container.get_children():
        child.queue_free()
    _tool_button_lookup.clear()
    for definition in TOOL_DEFINITIONS:
        var button := Button.new()
        button.text = str(definition["label"])
        button.toggle_mode = true
        button.pressed.connect(_on_tool_button_pressed.bind(str(definition["id"])))
        tool_buttons_container.add_child(button)
        _tool_button_lookup[str(definition["id"])] = button

func _build_config_checkboxes() -> void:
    if config_item_container == null:
        return
    for child in config_item_container.get_children():
        child.queue_free()
    _config_checkboxes.clear()
    for item_type in STOCKPILE_ITEM_TYPES:
        var checkbox := CheckBox.new()
        checkbox.text = str(item_type).capitalize()
        checkbox.toggled.connect(_on_config_item_toggled.bind(str(item_type)))
        config_item_container.add_child(checkbox)
        _config_checkboxes[str(item_type)] = checkbox

func _build_wall_buttons() -> void:
    if wall_buttons_container == null:
        return
    for child in wall_buttons_container.get_children():
        child.queue_free()
    _wall_button_lookup.clear()
    for material in WALL_MATERIALS:
        var button := Button.new()
        button.text = str(material).capitalize()
        button.toggle_mode = true
        button.pressed.connect(_on_wall_material_pressed.bind(str(material)))
        wall_buttons_container.add_child(button)
        _wall_button_lookup[str(material)] = button

func _connect_pressed(button: Button, callable: Callable) -> void:
    if button != null and not button.pressed.is_connected(callable):
        button.pressed.connect(callable)

func _refresh_tool_button_states() -> void:
    for tool_id in _tool_button_lookup.keys():
        var button: Button = _tool_button_lookup[tool_id]
        button.button_pressed = tool_id == active_tool

func _refresh_wall_button_states() -> void:
    for material in _wall_button_lookup.keys():
        var button: Button = _wall_button_lookup[material]
        button.button_pressed = material == _wall_material

func set_active_tool(tool_name: String) -> void:
    active_tool = tool_name
    _refresh_tool_button_states()

func _on_tool_button_pressed(tool_id: String) -> void:
    active_tool = tool_id
    _refresh_tool_button_states()
    tool_requested.emit(tool_id)

func set_active_layer(layer: int) -> void:
    active_layer = layer
    _refresh_layer_label()

func _refresh_layer_label() -> void:
    if layer_label != null:
        layer_label.text = "Layer %d" % active_layer

func set_sim_clock(clock) -> void:
    _sim_clock = clock
    _refresh_time_controls()

func _process(_delta: float) -> void:
    _refresh_time_controls()

func _refresh_time_controls() -> void:
    if tick_label != null and _last_synced_simulation != null:
        tick_label.text = "Tick %d" % _last_synced_simulation.tick
    if pause_button != null and _sim_clock != null:
        pause_button.text = "Resume" if _sim_clock.paused else "Pause"

func _on_pause_button_pressed() -> void:
    if _sim_clock != null:
        _sim_clock.set_paused(not _sim_clock.paused)

func sync_from_simulation(simulation) -> void:
    _last_synced_simulation = simulation
    _refresh_time_controls()
    if workers_panel != null and workers_panel.visible:
        _refresh_workers_list(simulation)
    if worker_detail_panel != null and worker_detail_panel.visible and _selected_unit_id != "":
        _refresh_worker_detail(simulation, false)

# --- Tile inspector -----------------------------------------------------------

func show_tile_details(text: String) -> void:
    if inspector_label != null:
        inspector_label.text = text
    if inspector_panel != null:
        inspector_panel.visible = true

func hide_tile_details() -> void:
    if inspector_panel != null:
        inspector_panel.visible = false

# --- Stockpile config window --------------------------------------------------

func show_stockpile_config(stockpile_id: String, accepted_types: Array) -> void:
    _config_stockpile_id = stockpile_id
    if config_title != null:
        config_title.text = "Stockpile %s — Allowed Items" % stockpile_id
    for item_type in _config_checkboxes.keys():
        var checkbox: CheckBox = _config_checkboxes[item_type]
        checkbox.set_pressed_no_signal(accepted_types.has(item_type))
    if config_panel != null:
        config_panel.visible = true

func hide_stockpile_config() -> void:
    _config_stockpile_id = ""
    if config_panel != null:
        config_panel.visible = false

func _on_config_item_toggled(_pressed: bool, _item_type: String) -> void:
    if _config_stockpile_id == "":
        return
    var accepted: Array = []
    for item_type in STOCKPILE_ITEM_TYPES:
        var checkbox: CheckBox = _config_checkboxes.get(item_type)
        if checkbox != null and checkbox.button_pressed:
            accepted.append(item_type)
    stockpile_items_changed.emit(_config_stockpile_id, accepted)

# --- Wall material picker -----------------------------------------------------

func show_wall_config(material: String) -> void:
    _wall_material = material
    _refresh_wall_button_states()
    if wall_config_panel != null:
        wall_config_panel.visible = true

func hide_wall_config() -> void:
    if wall_config_panel != null:
        wall_config_panel.visible = false

func _on_wall_material_pressed(material: String) -> void:
    _wall_material = material
    _refresh_wall_button_states()
    wall_material_changed.emit(material)

# --- Workers roster -----------------------------------------------------------

func toggle_workers_panel() -> void:
    if workers_panel != null and workers_panel.visible:
        hide_workers_panel()
    else:
        show_workers_panel()

func show_workers_panel() -> void:
    if workers_panel != null:
        workers_panel.visible = true
        _refresh_workers_list(_last_synced_simulation)

func hide_workers_panel() -> void:
    if workers_panel != null:
        workers_panel.visible = false

func _refresh_workers_list(simulation) -> void:
    if workers_list == null or simulation == null:
        return
    for child in workers_list.get_children():
        child.queue_free()
    var unit_ids: Array = simulation.units.keys()
    unit_ids.sort()
    for unit_id in unit_ids:
        var unit = simulation.units[unit_id]
        var job: String = ""
        if unit.current_job_id != "" and simulation.job_board != null and simulation.job_board.jobs.has(unit.current_job_id):
            job = str(simulation.job_board.jobs[unit.current_job_id].type)
        var button := Button.new()
        button.text = "%s — %s%s" % [unit.display_name, unit.state, (" (" + job + ")") if job != "" else ""]
        button.alignment = HORIZONTAL_ALIGNMENT_LEFT
        button.pressed.connect(_on_worker_row_pressed.bind(str(unit_id)))
        workers_list.add_child(button)

func _on_worker_row_pressed(unit_id: String) -> void:
    worker_selected.emit(unit_id)

# --- Worker detail ------------------------------------------------------------

func select_worker(unit_id: String) -> void:
    _selected_unit_id = unit_id
    if worker_detail_panel != null:
        worker_detail_panel.visible = true
    _refresh_worker_detail(_last_synced_simulation, true)

func hide_worker_detail() -> void:
    _selected_unit_id = ""
    if worker_detail_panel != null:
        worker_detail_panel.visible = false

func _on_worker_name_apply() -> void:
    if _selected_unit_id == "" or worker_name_edit == null:
        return
    var new_name: String = worker_name_edit.text.strip_edges()
    if new_name != "":
        worker_rename_requested.emit(_selected_unit_id, new_name)

# selection_changed: when true, (re)seed editable fields (name); otherwise leave
# them alone so the player's in-progress typing isn't clobbered each tick.
func _refresh_worker_detail(simulation, selection_changed: bool) -> void:
    if worker_detail_body == null or simulation == null or _selected_unit_id == "":
        return
    var summary: Dictionary = simulation.unit_summary(_selected_unit_id)
    if summary.is_empty():
        hide_worker_detail()
        return
    if selection_changed and worker_name_edit != null:
        worker_name_edit.text = str(summary.get("display_name", ""))
    for child in worker_detail_body.get_children():
        child.queue_free()
    var pos: Array = summary.get("position", [0, 0, 0])
    _add_detail_label("State: %s" % str(summary.get("state", "")))
    _add_detail_label("Position: (%d, %d, %d)" % [int(pos[0]), int(pos[1]), int(pos[2])])
    var job_type: String = str(summary.get("current_job_type", ""))
    if job_type != "":
        var jt: Array = summary.get("current_job_target", [0, 0, 0])
        _add_detail_label("Job: %s @ (%d, %d, %d)" % [job_type, int(jt[0]), int(jt[1]), int(jt[2])])
    else:
        _add_detail_label("Job: idle")
    var needs: Dictionary = summary.get("needs", {})
    _add_detail_label("— Needs —")
    _add_need_bar("Hunger", int(needs.get("hunger", 0)))
    _add_need_bar("Energy", int(needs.get("energy", 0)))
    _add_need_bar("Morale", int(needs.get("morale", 0)))
    var skills: Dictionary = summary.get("skills", {})
    var skill_keys: Array = skills.keys()
    skill_keys.sort()
    var skill_text: Array = []
    for k in skill_keys:
        skill_text.append("%s %d" % [str(k).capitalize(), int(skills[k])])
    _add_detail_label("Skills: %s" % (", ".join(skill_text) if not skill_text.is_empty() else "none"))
    var inventory: Array = summary.get("inventory", [])
    _add_detail_label("Carrying: %s" % (str(inventory.size()) + " item(s)" if not inventory.is_empty() else "nothing"))
    _add_detail_label("— Work —")
    var allowed: Array = summary.get("allowed_jobs", [])
    var priorities: Dictionary = summary.get("job_type_priorities", {})
    for job in WORKER_JOB_TYPES:
        _add_job_row(job, allowed.has(job), int(priorities.get(job, 1)))

func _add_detail_label(text: String) -> void:
    var label := Label.new()
    label.text = text
    worker_detail_body.add_child(label)

func _add_need_bar(label_text: String, value: int) -> void:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 6)
    var label := Label.new()
    label.text = label_text
    label.custom_minimum_size = Vector2(70, 0)
    row.add_child(label)
    var bar := ProgressBar.new()
    bar.min_value = 0
    bar.max_value = 100
    bar.value = clampi(value, 0, 100)
    bar.custom_minimum_size = Vector2(200, 18)
    row.add_child(bar)
    worker_detail_body.add_child(row)

func _add_job_row(job_type: String, allowed: bool, priority: int) -> void:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 6)
    var checkbox := CheckBox.new()
    checkbox.text = job_type.capitalize()
    checkbox.custom_minimum_size = Vector2(200, 0)
    checkbox.set_pressed_no_signal(allowed)
    checkbox.toggled.connect(_on_worker_job_toggled.bind(job_type))
    row.add_child(checkbox)
    var spin := SpinBox.new()
    spin.min_value = 1
    spin.max_value = 9
    spin.value = clampi(priority, 1, 9)
    spin.editable = allowed
    spin.value_changed.connect(_on_worker_priority_changed.bind(job_type))
    row.add_child(spin)
    worker_detail_body.add_child(row)

func _on_worker_job_toggled(enabled: bool, job_type: String) -> void:
    if _selected_unit_id != "":
        worker_allowed_job_toggled.emit(_selected_unit_id, job_type, enabled)

func _on_worker_priority_changed(value: float, job_type: String) -> void:
    if _selected_unit_id != "":
        worker_job_priority_changed.emit(_selected_unit_id, job_type, int(value))
