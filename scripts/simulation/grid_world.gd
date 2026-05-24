class_name GridWorld
extends RefCounted

const SimCellScript := preload("res://scripts/simulation/cell.gd")
const DeterministicRngScript := preload("res://scripts/simulation/deterministic_rng.gd")

var width: int
var height: int
var cells: Dictionary = {}

func _init(pwidth: int = 16, pheight: int = 16) -> void:
    width = pwidth
    height = pheight
    for z in range(height):
        for x in range(width):
            var cell = SimCellScript.new(x, z, "grass", true)
            cells[_key(Vector2i(x, z))] = cell

func _key(pos: Vector2i) -> String:
    return str(pos.x) + "," + str(pos.y)

func in_bounds(pos: Vector2i) -> bool:
    return pos.x >= 0 and pos.y >= 0 and pos.x < width and pos.y < height

func get_cell(pos: Vector2i) :
    if not in_bounds(pos):
        return null
    return cells[_key(pos)]

func set_resource(pos: Vector2i, resource_id: String) -> bool:
    var cell = get_cell(pos)
    if cell == null:
        return false
    cell.resource_id = resource_id
    return true

func clear_resource(pos: Vector2i, resource_id: String = "") -> bool:
    var cell = get_cell(pos)
    if cell == null:
        return false
    if resource_id != "" and cell.resource_id != resource_id:
        return false
    cell.resource_id = ""
    return true

func create_forest(rng, resource_index: Dictionary) -> void:
    # Deterministic seeded fixture: a small starting clearing surrounded by tree nodes.
    # This keeps the simulation data-only; presentation decides how trees look.
    var resource_count: int = 0
    for z in range(height):
        for x in range(width):
            var cell = get_cell(Vector2i(x, z))
            if x <= 2 and z <= 2:
                cell.terrain = "dirt"
                cell.resource_id = ""
                continue
            cell.terrain = "grass"
            cell.resource_id = ""
            if rng.range_i(0, 99) < 30:
                resource_count += 1
                var rid: String = "resource_%06d" % resource_count
                resource_index[rid] = {"id": rid, "type": "tree", "position": [x, z], "yield": {"wood": 1}}
                cell.resource_id = rid

func to_canonical_array() -> Array:
    var arr: Array = []
    for z in range(height):
        for x in range(width):
            arr.append(get_cell(Vector2i(x, z)).to_canonical_dict())
    return arr
