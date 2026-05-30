class_name World
extends RefCounted

# Dense, single-instance layered world store (no chunks).
#
# Cells are addressed by Vector3i(x, y, z) with x in [0,WIDTH), z in [0,DEPTH),
# y in [0,LAYER_COUNT) and higher y = up. Layers are materialized lazily: a
# layer's flat Array[SimCell] (indexed i = x + z*WIDTH) is allocated the first
# time any cell on it is touched, so untouched sky layers cost nothing.

const C := preload("res://scripts/simulation/world_constants.gd")
const SimCellScript := preload("res://scripts/simulation/cell.gd")

var width: int = C.WIDTH
var depth: int = C.DEPTH
var layer_count: int = C.LAYER_COUNT

# y -> Array[SimCell] (size width*depth)
var _layers: Dictionary = {}
# Per-column surface elevation (top solid-floor y), keyed by x + z*width.
var _surface_y: PackedInt32Array = PackedInt32Array()

# Shared read-only sentinel for peeking at unmaterialized cells.
static var _DEFAULT_CELL: SimCell = SimCellScript.new()

func _init(pwidth: int = C.WIDTH, pdepth: int = C.DEPTH, player_count: int = C.LAYER_COUNT) -> void:
	width = pwidth
	depth = pdepth
	layer_count = player_count
	_surface_y.resize(width * depth)
	_surface_y.fill(C.SURFACE_Y_MEAN)

func in_bounds(cell: Vector3i) -> bool:
	return cell.x >= 0 and cell.x < width \
		and cell.z >= 0 and cell.z < depth \
		and cell.y >= 0 and cell.y < layer_count

func _index(x: int, z: int) -> int:
	return x + z * width

# Returns the live, mutable cell at the address, materializing its layer.
# Returns null if out of bounds.
func get_cell(cell: Vector3i):
	if not in_bounds(cell):
		return null
	return _ensure_layer(cell.y)[_index(cell.x, cell.z)]

# Read-only peek that does NOT materialize. Unstored cells return a shared
# default sentinel; callers must not mutate the result.
func peek_cell(cell: Vector3i) -> SimCell:
	if not in_bounds(cell):
		return _DEFAULT_CELL
	if not _layers.has(cell.y):
		return _DEFAULT_CELL
	return _layers[cell.y][_index(cell.x, cell.z)]

func has_layer(y: int) -> bool:
	return _layers.has(y)

func _ensure_layer(y: int) -> Array:
	if _layers.has(y):
		return _layers[y]
	var cells: Array = []
	cells.resize(width * depth)
	for i in range(cells.size()):
		cells[i] = SimCellScript.new()
	_layers[y] = cells
	return cells

func cells_on_layer(y: int) -> Array:
	return _ensure_layer(y)

func set_surface_y(x: int, z: int, y: int) -> void:
	_surface_y[_index(x, z)] = y

func surface_y(x: int, z: int) -> int:
	if x < 0 or x >= width or z < 0 or z >= depth:
		return C.SURFACE_Y_MEAN
	return _surface_y[_index(x, z)]

func is_walkable(cell: Vector3i) -> bool:
	if not in_bounds(cell):
		return false
	return peek_cell(cell).is_walkable()

# Movement neighbors: 4-directional on the same layer plus vertical moves through
# stair/ramp connectors. Only walkable destinations are returned.
func neighbors_for_movement(cell: Vector3i) -> Array:
	var result: Array = []
	if not in_bounds(cell):
		return result
	var here: SimCell = peek_cell(cell)
	for offset in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var n: Vector3i = cell + offset
		if in_bounds(n) and is_walkable(n):
			result.append(n)
			continue
		# Slope step: walk up/down one layer between sky-exposed surface cells.
		if here.exposure == "sky":
			var up: Vector3i = n + Vector3i(0, 1, 0)
			if in_bounds(up) and is_walkable(up) and peek_cell(up).exposure == "sky":
				result.append(up)
				continue
			var down: Vector3i = n + Vector3i(0, -1, 0)
			if in_bounds(down) and is_walkable(down) and peek_cell(down).exposure == "sky":
				result.append(down)
	if here.connects_up():
		var up: Vector3i = cell + Vector3i(0, 1, 0)
		if in_bounds(up) and not peek_cell(up).has_wall() and is_walkable(up):
			result.append(up)
	if here.connects_down():
		var down: Vector3i = cell + Vector3i(0, -1, 0)
		if in_bounds(down) and not peek_cell(down).has_wall() and is_walkable(down):
			result.append(down)
	return result

# Canonical, deterministic dump of every non-default cell with its address.
func to_canonical_array() -> Array:
	var output: Array = []
	var ys: Array = _layers.keys()
	ys.sort()
	for y in ys:
		var cells: Array = _layers[y]
		for z in range(depth):
			for x in range(width):
				var c: SimCell = cells[_index(x, z)]
				if c.is_default():
					continue
				var record: Dictionary = c.to_canonical_dict()
				record["cell"] = [x, y, z]
				output.append(record)
	return output

# Efficient deterministic digest of all non-default cells (for state hashing).
func content_hash() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var ys: Array = _layers.keys()
	ys.sort()
	for y in ys:
		var cells: Array = _layers[y]
		for z in range(depth):
			for x in range(width):
				var c: SimCell = cells[_index(x, z)]
				if c.is_default():
					continue
				var token: String = "%d,%d,%d|%s|%s|%s|%d|%s|%d|%s|%s|%s|%d\n" % [
					x, y, z, c.floor_material, c.wall_material, c.liquid_type, c.liquid_level,
					c.plant, c.plant_growth, c.resource_id, c.building_id, c.stair,
					c.mining_tier_required]
				ctx.update(token.to_utf8_buffer())
				if not c.hidden_ore.is_empty():
					ctx.update(JSON.stringify(c.hidden_ore).to_utf8_buffer())
	return ctx.finish().hex_encode()

func materialized_cell_count() -> int:
	return _layers.size() * width * depth

func non_default_cell_count() -> int:
	var total: int = 0
	for y in _layers.keys():
		var cells: Array = _layers[y]
		for c in cells:
			if not c.is_default():
				total += 1
	return total
