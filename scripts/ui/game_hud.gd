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
signal recipe_queue_requested(building_id: String, recipe_id: String)

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
    {"id": "kiln", "label": "K Kiln"},
    {"id": "carpenter", "label": "B Carpenter"},
    {"id": "wall", "label": "0 Wall"},
]

const STOCKPILE_ITEM_TYPES: Array = ["wood", "stone", "dirt", "food", "meal", "mud_brick", "wood_plank"]
const WALL_MATERIALS: Array = ["mud_brick", "wood_plank"]
const RECIPE_LABELS: Dictionary = {
    "make_mud_brick": "Make Mud Brick",
    "make_wood_plank": "Make Wood Plank",
    "cook_meal": "Cook Meal",
}

@onready var tool_buttons_container: Container = $Toolbar/ToolButtons
@onready var layer_label: Label = $Toolbar/StatusRow/LayerLabel
@onready var tick_label: Label = $Toolbar/StatusRow/TickLabel
@onready var pause_button: Button = $Toolbar/StatusRow/PauseButton
@onready var inspector_panel: Panel = $Inspector
@onready var inspector_label: Label = $Inspector/InspectorLabel
@onready var config_panel: Panel = $StockpileConfig
@onready var config_title: Label = $StockpileConfig/ConfigTitle
@onready var config_item_container: Container = $StockpileConfig/ItemList
@onready var config_close_button: Button = $StockpileConfig/CloseButton
@onready var wall_config_panel: Panel = $WallConfig
@onready var wall_buttons_container: Container = $WallConfig/WallButtons
@onready var workshop_config_panel: Panel = $WorkshopConfig
@onready var workshop_title: Label = $WorkshopConfig/WorkshopTitle
@onready var workshop_recipes_container: Container = $WorkshopConfig/RecipeButtons
@onready var workshop_close_button: Button = $WorkshopConfig/CloseButton

var _tool_button_lookup: Dictionary = {}
var _config_checkboxes: Dictionary = {}
var _wall_button_lookup: Dictionary = {}
var _config_stockpile_id: String = ""
var _workshop_building_id: String = ""
var _wall_material: String = "mud_brick"
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
    _connect_pressed(config_close_button, hide_stockpile_config)
    _connect_pressed(workshop_close_button, hide_workshop_orders)
    _refresh_tool_button_states()
    _refresh_wall_button_states()
    _refresh_layer_label()
    _refresh_time_controls()

func _resolve_nodes() -> void:
    tool_buttons_container = get_node_or_null("Toolbar/ToolButtons")
    layer_label = get_node_or_null("Toolbar/StatusRow/LayerLabel")
    tick_label = get_node_or_null("Toolbar/StatusRow/TickLabel")
    pause_button = get_node_or_null("Toolbar/StatusRow/PauseButton")
    inspector_panel = get_node_or_null("Inspector")
    inspector_label = get_node_or_null("Inspector/InspectorLabel")
    config_panel = get_node_or_null("StockpileConfig")
    config_title = get_node_or_null("StockpileConfig/ConfigTitle")
    config_item_container = get_node_or_null("StockpileConfig/ItemList")
    config_close_button = get_node_or_null("StockpileConfig/CloseButton")
    wall_config_panel = get_node_or_null("WallConfig")
    wall_buttons_container = get_node_or_null("WallConfig/WallButtons")
    workshop_config_panel = get_node_or_null("WorkshopConfig")
    workshop_title = get_node_or_null("WorkshopConfig/WorkshopTitle")
    workshop_recipes_container = get_node_or_null("WorkshopConfig/RecipeButtons")
    workshop_close_button = get_node_or_null("WorkshopConfig/CloseButton")

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

# --- Workshop recipe queue ----------------------------------------------------

func show_workshop_orders(summary: Dictionary) -> void:
    _workshop_building_id = str(summary.get("building_id", ""))
    if workshop_title != null:
        workshop_title.text = "%s — Recipes" % str(summary.get("display_name", "Workshop"))
    if workshop_recipes_container != null:
        for child in workshop_recipes_container.get_children():
            child.queue_free()
        for recipe_id in summary.get("recipes", []):
            var button := Button.new()
            button.text = "Queue %s" % str(RECIPE_LABELS.get(recipe_id, str(recipe_id).capitalize()))
            button.pressed.connect(_on_recipe_queue_pressed.bind(str(recipe_id)))
            workshop_recipes_container.add_child(button)
    if workshop_config_panel != null:
        workshop_config_panel.visible = true

func hide_workshop_orders() -> void:
    _workshop_building_id = ""
    if workshop_config_panel != null:
        workshop_config_panel.visible = false

func _on_recipe_queue_pressed(recipe_id: String) -> void:
    if _workshop_building_id == "":
        return
    recipe_queue_requested.emit(_workshop_building_id, recipe_id)
