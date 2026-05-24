extends CanvasLayer

signal tool_mode_requested(mode: String)

const TOOL_MODE_INSPECT := "inspect"
const TOOL_MODE_GATHER_WOOD := "gather_wood"
const TOOL_MODE_GATHER_STONE := "gather_stone"
const TOOL_MODE_GATHER_FOOD := "gather_food"
const TOOL_MODE_DESIGNATE_STOCKPILE := "designate_stockpile"
const TOOL_MODE_LABELS := {
    TOOL_MODE_INSPECT: "Inspect",
    TOOL_MODE_GATHER_WOOD: "Chop Wood",
    TOOL_MODE_GATHER_STONE: "Gather Stone",
    TOOL_MODE_GATHER_FOOD: "Gather Food",
    TOOL_MODE_DESIGNATE_STOCKPILE: "Stockpile",
}

@onready var label: Label = $Panel/StatusLabel
@onready var pause_button: Button = $Panel/PauseButton
@onready var speed_1x: Button = $Panel/Speed1x
@onready var speed_2x: Button = $Panel/Speed2x
@onready var speed_4x: Button = $Panel/Speed4x
@onready var inspect_button: Button = $Panel/InspectButton
@onready var gather_wood_button: Button = $Panel/GatherWoodButton
@onready var gather_stone_button: Button = $Panel/GatherStoneButton
@onready var gather_food_button: Button = $Panel/GatherFoodButton
@onready var stockpile_button: Button = $Panel/StockpileButton

var sim_clock: SimClock
var active_tool_mode: String = TOOL_MODE_INSPECT
var last_warning: String = ""
var _signals_connected: bool = false

func _ready() -> void:
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
    if stockpile_button:
        _connect_pressed(stockpile_button, _on_tool_button_pressed.bind(TOOL_MODE_DESIGNATE_STOCKPILE))
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

func sync_from_simulation(simulation: Simulation) -> void:
    _refresh_status_text(simulation)

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
    var warning_str: String = ""
    if last_warning != "":
        warning_str = " | Warning: " + last_warning
    if simulation == null:
        label.text = "Tool %s | Speed %s%s%s" % [tool_str, speed_str, paused_str, warning_str]
        return
    var snapshot: Dictionary = simulation.canonical_snapshot()
    label.text = "Tick %d | Units %d | Resources %d | Jobs %d | Hash %s | Speed %s%s | Tool %s%s" % [
        snapshot["tick"],
        snapshot["units"].size(),
        snapshot["resources"].size(),
        snapshot["jobs"].size(),
        simulation.state_hash().substr(0, 8),
        speed_str,
        paused_str,
        tool_str,
        warning_str,
    ]
