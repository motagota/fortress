class_name SimCell
extends RefCounted

var x: int
var z: int
var terrain: String = "grass"
var walkable: bool = true
var resource_id: String = ""
var building_id: String = ""

func _init(px: int = 0, pz: int = 0, pterrain: String = "grass", pwalkable: bool = true) -> void:
    x = px
    z = pz
    terrain = pterrain
    walkable = pwalkable

func to_canonical_dict() -> Dictionary:
    return {
        "x": x,
        "z": z,
        "terrain": terrain,
        "walkable": walkable,
        "resource_id": resource_id,
        "building_id": building_id,
    }
