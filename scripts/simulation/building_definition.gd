class_name BuildingDefinition
extends RefCounted

const KITCHEN := "kitchen"
const BRICK_KILN := "brick_kiln"
const CARPENTER := "carpenter"
const WALL_MUD_BRICK := "wall_mud_brick"
const WALL_WOOD_PLANK := "wall_wood_plank"

const DEFINITIONS := {
    WALL_MUD_BRICK: {
        "id": WALL_MUD_BRICK,
        "display_name": "Mud Brick Wall",
        "required_items": {"mud_brick": 1},
        "blocks_movement": true,
        "footprint": [1, 1],
        "work_ticks": 5,
        "wall_material": "DIRT",
        "cave_in_base": 0.02,
    },
    WALL_WOOD_PLANK: {
        "id": WALL_WOOD_PLANK,
        "display_name": "Wood Plank Wall",
        "required_items": {"wood_plank": 1},
        "blocks_movement": true,
        "footprint": [1, 1],
        "work_ticks": 5,
        "wall_material": "WOOD",
        "cave_in_base": 0.03,
    },
    BRICK_KILN: {
        "id": BRICK_KILN,
        "display_name": "Brick Kiln",
        "required_items": {"stone": 3},
        "blocks_movement": false,
        "footprint": [1, 1],
        "work_ticks": 6,
        "workshop": true,
        "recipes": ["make_mud_brick"],
        "requires_adjacent_liquid": "water",
    },
    CARPENTER: {
        "id": CARPENTER,
        "display_name": "Carpenter's Bench",
        "required_items": {"wood": 3},
        "blocks_movement": false,
        "footprint": [1, 1],
        "work_ticks": 5,
        "workshop": true,
        "recipes": ["make_wood_plank"],
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
