extends Node3D

const SimulationScript := preload("res://scripts/simulation/simulation.gd")

@onready var world_root: Node3D = $WorldRoot
@onready var hud: CanvasLayer = $GameHud

var simulation: Simulation

func _ready() -> void:
    simulation = Simulation.new()
    simulation.initialize_new_game(42)
    sync_from_simulation(simulation)

func sync_from_simulation(sim: Simulation) -> void:
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
