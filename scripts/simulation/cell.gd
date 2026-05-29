class_name SimCell
extends RefCounted

var x: int
var z: int
var terrain: String = "grass"
var material_key: String = "GRASS"
var walkable: bool = true
var resource_id: String = ""
var building_id: String = ""
var depth: int = 0
var surface_height: int = 0
var slope_degrees: int = 0
var strata_key: String = "surface"
var mining_tier_required: int = 1
var hidden_mine_yield: Dictionary = {}
var is_river: bool = false
var river_id: String = ""
var distance_to_river: int = 999
var water_feature: String = ""
var is_cave: bool = false
var cave_id: String = ""
var exposure: String = "covered"

func _init(px: int = 0, pz: int = 0, pterrain: String = "grass", pwalkable: bool = true, pdepth: int = 0, pmaterial_key: String = "") -> void:
    x = px
    z = pz
    terrain = pterrain
    material_key = pmaterial_key if pmaterial_key != "" else _default_material_for_terrain(pterrain)
    walkable = pwalkable
    depth = pdepth

func _default_material_for_terrain(pterrain: String) -> String:
    match pterrain:
        "dirt":
            return "DIRT"
        "excavated":
            return "AIR"
        "rock":
            return "SOFT_ROCK"
        "solid_rock":
            return "HARD_ROCK"
        "collapsed":
            return "HARD_ROCK"
    return "GRASS"

func to_canonical_dict() -> Dictionary:
    return {
        "x": x,
        "z": z,
        "terrain": terrain,
        "material_key": material_key,
        "walkable": walkable,
        "resource_id": resource_id,
        "building_id": building_id,
        "depth": depth,
        "surface_height": surface_height,
        "slope_degrees": slope_degrees,
        "strata_key": strata_key,
        "mining_tier_required": mining_tier_required,
        "hidden_mine_yield": hidden_mine_yield.duplicate(true),
        "is_river": is_river,
        "river_id": river_id,
        "distance_to_river": distance_to_river,
        "water_feature": water_feature,
        "is_cave": is_cave,
        "cave_id": cave_id,
        "exposure": exposure,
    }
