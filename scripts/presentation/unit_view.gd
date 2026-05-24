extends Node3D

@onready var label: Label3D = $Label3D

func set_unit_data(unit_data: Dictionary) -> void:
    if label == null:
        label = get_node_or_null("Label3D") as Label3D
    if label != null:
        label.text = "%s
%s" % [unit_data["display_name"], unit_data["state"]]
