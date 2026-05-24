extends CanvasLayer

@onready var label: Label = $Panel/StatusLabel

func sync_from_simulation(simulation: Simulation) -> void:
    if label == null:
        return
    var snapshot: Dictionary = simulation.canonical_snapshot()
    label.text = "Tick %d | Units %d | Resources %d | Jobs %d | Hash %s" % [
        snapshot["tick"],
        snapshot["units"].size(),
        snapshot["resources"].size(),
        snapshot["jobs"].size(),
        simulation.state_hash().substr(0, 8),
    ]
