class_name BuildingDefinition
extends RefCounted

const WALL_BLOCK := "wall_block"
const KITCHEN := "kitchen"

const DEFINITIONS := {
    WALL_BLOCK: {
        "id": WALL_BLOCK,
        "display_name": "Wall Block",
        "required_items": {"stone": 2},
        "blocks_movement": true,
        "footprint": [1, 1],
        "work_ticks": 5,
        "wall_material": "LOOSE_STONE",
        "cave_in_base": 0.01,
    },
    "wall_dirt": {
        "id": "wall_dirt",
        "display_name": "Dirt Wall",
        "required_items": {"dirt": 1},
        "blocks_movement": true,
        "footprint": [1, 1],
        "work_ticks": 4,
        "wall_material": "DIRT",
        "cave_in_base": 0.06,
    },
    "wall_wood": {
        "id": "wall_wood",
        "display_name": "Wood Wall",
        "required_items": {"wood": 1},
        "blocks_movement": true,
        "footprint": [1, 1],
        "work_ticks": 5,
        "wall_material": "WOOD",
        "cave_in_base": 0.03,
    },
    "wall_stone": {
        "id": "wall_stone",
        "display_name": "Stone Wall",
        "required_items": {"stone": 1},
        "blocks_movement": true,
        "footprint": [1, 1],
        "work_ticks": 6,
        "wall_material": "LOOSE_STONE",
        "cave_in_base": 0.01,
    },
    KITCHEN: {
        "id": KITCHEN,
        "display_name": "Kitchen",
        "required_items": {"wood": 3},
        "blocks_movement": false,
        "footprint": [3, 3],
        "work_ticks": 5,
        "workshop": true,
        "recipes": ["cook_meal"],
    },
}

static func has_definition(building_type: String) -> bool:
    return DEFINITIONS.has(building_type)

static func get_definition(building_type: String) -> Dictionary:
    if not DEFINITIONS.has(building_type):
        return {}
    return _sorted_dictionary(DEFINITIONS[building_type].duplicate(true))

static func all_definitions() -> Dictionary:
    var output: Dictionary = {}
    var keys: Array = DEFINITIONS.keys()
    keys.sort()
    for key in keys:
        output[key] = get_definition(str(key))
    return output

static func _sorted_dictionary(input: Dictionary) -> Dictionary:
    var output: Dictionary = {}
    var keys: Array = input.keys()
    keys.sort()
    for key in keys:
        var value: Variant = input[key]
        if value is Dictionary:
            output[key] = _sorted_dictionary(value)
        elif value is Array:
            output[key] = _sorted_array(value)
        else:
            output[key] = value
    return output

static func _sorted_array(input: Array) -> Array:
    var output: Array = []
    for value in input:
        if value is Dictionary:
            output.append(_sorted_dictionary(value))
        elif value is Array:
            output.append(_sorted_array(value))
        else:
            output.append(value)
    return output
