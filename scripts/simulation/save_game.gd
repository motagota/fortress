class_name SaveGame
extends RefCounted

# Save / load for the simulation.
#
# The world is reproducible from its seed, so a save stores only the seed plus
# the cells the player has changed (cell diffs against a fresh worldgen), keeping
# files small. All live entities, RNG state, the command queue, and id counters
# are stored verbatim so a loaded game has an identical state hash.

const SAVE_VERSION := 1

const C := preload("res://scripts/simulation/world_constants.gd")
const WorldScript := preload("res://scripts/simulation/world.gd")
const WorldgenScript := preload("res://scripts/simulation/worldgen.gd")
const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const UnitScript := preload("res://scripts/simulation/unit.gd")
const ItemScript := preload("res://scripts/simulation/item.gd")
const StockpileScript := preload("res://scripts/simulation/stockpile.gd")
const ConstructionRecordScript := preload("res://scripts/simulation/construction_record.gd")
const JobScript := preload("res://scripts/simulation/job.gd")
const JobBoardScript := preload("res://scripts/simulation/job_board.gd")
const AnimalScript := preload("res://scripts/simulation/animal.gd")
const NetScript := preload("res://scripts/simulation/net_projectile.gd")

# --- Serialization ------------------------------------------------------------

static func to_dict(sim) -> Dictionary:
	var reference = WorldScript.new()
	var ref_resources: Dictionary = {}
	WorldgenScript.generate(reference, ref_resources, sim.world_seed)
	return {
		"version": SAVE_VERSION,
		"world_seed": sim.world_seed,
		"tick": sim.tick,
		"id_counters": sim.id_counters.duplicate(true),
		"rng": {
			"event_rng": int(sim.rng_streams["event_rng"].get_state()),
			"unit_rng": int(sim.rng_streams["unit_rng"].get_state()),
			"world_rng": int(sim.rng_streams["world_rng"].get_state()),
			"animal_rng": int(sim.rng_streams["animal_rng"].get_state()),
		},
		"cell_diffs": _diff_world(sim.world, reference),
		"resources": sim.resources.duplicate(true),
		"units": sim._object_snapshot(sim.units),
		"animals": sim._object_snapshot(sim.animals),
		"nets": sim._object_snapshot(sim.nets),
		"items": sim._object_snapshot(sim.items),
		"stockpiles": sim._object_snapshot(sim.stockpiles),
		"constructions": sim._object_snapshot(sim.constructions),
		"workshop_orders": sim._workshop_orders_snapshot(),
		"jobs": sim.job_board.to_canonical_array(),
		"command_queue": sim._command_queue_snapshot(),
	}

static func save_to_file(sim, path: String) -> bool:
	var dir: String = path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(to_dict(sim)))
	file.close()
	return true

# --- Deserialization ----------------------------------------------------------

# JSON parses every number as float; convert whole numbers back to int so the
# restored state hashes identically to the original.
static func _normalize(value):
	if value is float:
		if value == floor(value) and abs(value) < 9.0e15:
			return int(value)
		return value
	if value is Dictionary:
		var out: Dictionary = {}
		for key in value.keys():
			out[key] = _normalize(value[key])
		return out
	if value is Array:
		var out: Array = []
		for v in value:
			out.append(_normalize(v))
		return out
	return value

static func from_dict(raw_data: Dictionary):
	var data: Dictionary = _normalize(raw_data)
	var sim = SimulationScript.new()
	sim.initialize_new_game(int(data.get("world_seed", 1)))
	sim.tick = int(data.get("tick", 0))
	sim.id_counters = data.get("id_counters", sim.id_counters).duplicate(true)
	var rng: Dictionary = data.get("rng", {})
	sim.rng_streams["event_rng"].set_state(int(rng.get("event_rng", sim.rng_streams["event_rng"].get_state())))
	sim.rng_streams["unit_rng"].set_state(int(rng.get("unit_rng", sim.rng_streams["unit_rng"].get_state())))
	sim.rng_streams["world_rng"].set_state(int(rng.get("world_rng", sim.rng_streams["world_rng"].get_state())))
	sim.rng_streams["animal_rng"].set_state(int(rng.get("animal_rng", sim.rng_streams["animal_rng"].get_state())))
	_apply_cell_diffs(sim.world, data.get("cell_diffs", []))
	sim.resources = data.get("resources", {}).duplicate(true)
	sim.units = _restore_units(data.get("units", []))
	# Older saves predate wildlife: keep the freshly spawned animals for those.
	if data.has("animals"):
		sim.animals = _restore_animals(data.get("animals", []))
		sim.nets = _restore_nets(data.get("nets", []))
	sim.items = _restore_items(data.get("items", []))
	sim.stockpiles = _restore_stockpiles(data.get("stockpiles", []))
	sim.constructions = _restore_constructions(data.get("constructions", []))
	sim.workshop_orders = _restore_workshop_orders(data.get("workshop_orders", []))
	sim.job_board = _restore_jobs(data.get("jobs", []))
	sim.command_queue = _restore_command_queue(data.get("command_queue", []))
	return sim

static func load_from_file(path: String):
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text: String = file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return null
	return from_dict(parsed)

# --- World diffing -------------------------------------------------------------

static func _diff_world(world, reference) -> Array:
	var diffs: Array = []
	var layers: Dictionary = {}
	for y in world._layers.keys():
		layers[y] = true
	for y in reference._layers.keys():
		layers[y] = true
	var ys: Array = layers.keys()
	ys.sort()
	for y in ys:
		for z in range(world.depth):
			for x in range(world.width):
				var addr := Vector3i(x, y, z)
				var a = world.peek_cell(addr)
				var b = reference.peek_cell(addr)
				if _cell_token(a) == _cell_token(b):
					continue
				var record: Dictionary = a.to_canonical_dict()
				record["cell"] = [x, y, z]
				diffs.append(record)
	return diffs

static func _apply_cell_diffs(world, diffs: Array) -> void:
	for record in diffs:
		var addr := Vector3i(int(record["cell"][0]), int(record["cell"][1]), int(record["cell"][2]))
		var cell = world.get_cell(addr)
		if cell == null:
			continue
		cell.floor_material = str(record.get("floor_material", ""))
		cell.wall_material = str(record.get("wall_material", ""))
		cell.liquid_type = str(record.get("liquid_type", ""))
		cell.liquid_level = int(record.get("liquid_level", 0))
		cell.plant = str(record.get("plant", ""))
		cell.plant_growth = int(record.get("plant_growth", 0))
		cell.resource_id = str(record.get("resource_id", ""))
		cell.building_id = str(record.get("building_id", ""))
		cell.hidden_ore = record.get("hidden_ore", {}).duplicate(true)
		cell.stair = str(record.get("stair", C.STAIR_NONE))
		cell.band = str(record.get("band", C.BAND_SKY))
		cell.mining_tier_required = int(record.get("mining_tier_required", 0))
		cell.designation = str(record.get("designation", C.DESIGNATION_NONE))
		cell.exposure = str(record.get("exposure", "dark"))

static func _cell_token(c) -> String:
	return "%s|%s|%s|%d|%s|%d|%s|%s|%s|%s|%d|%s|%s" % [
		c.floor_material, c.wall_material, c.liquid_type, c.liquid_level,
		c.plant, c.plant_growth, c.resource_id, c.building_id, c.stair,
		c.band, c.mining_tier_required, c.exposure, JSON.stringify(c.hidden_ore)]

# --- Entity restoration --------------------------------------------------------

static func _vec3(value) -> Vector3i:
	return Vector3i(int(value[0]), int(value[1]), int(value[2]))

static func _restore_units(records: Array) -> Dictionary:
	var output: Dictionary = {}
	for record in records:
		var unit = UnitScript.new(str(record["id"]), str(record["display_name"]), _vec3(record["position"]))
		unit.inventory = _string_array(record.get("inventory", []))
		unit.allowed_jobs = _string_array(record.get("allowed_jobs", []))
		unit.job_type_priorities = record.get("job_type_priorities", {}).duplicate(true)
		unit.skills = record.get("skills", {}).duplicate(true)
		unit.current_job_id = str(record.get("current_job_id", ""))
		unit.unreachable_job_ticks = int(record.get("unreachable_job_ticks", 0))
		unit.needs = record.get("needs", unit.needs).duplicate(true)
		unit.state = str(record.get("state", "idle"))
		output[unit.id] = unit
	return output

static func _restore_animals(records: Array) -> Dictionary:
	var output: Dictionary = {}
	for record in records:
		var animal = AnimalScript.new(str(record["id"]), str(record.get("species", "rabbit")), _vec3(record["position"]))
		animal.state = str(record.get("state", AnimalScript.STATE_WILD))
		animal.netted_by_net_id = str(record.get("netted_by_net_id", ""))
		output[animal.id] = animal
	return output

static func _restore_nets(records: Array) -> Dictionary:
	var output: Dictionary = {}
	for record in records:
		var net = NetScript.new(str(record["id"]), str(record.get("shooter_unit_id", "")), str(record.get("job_id", "")),
			str(record.get("target_animal_id", "")), _vec3(record["origin"]), int(record.get("flight_ticks_total", 1)))
		net.position = _vec3(record["position"])
		net.state = str(record.get("state", NetScript.STATE_FLYING))
		net.flight_ticks_done = int(record.get("flight_ticks_done", 0))
		output[net.id] = net
	return output

static func _restore_items(records: Array) -> Dictionary:
	var output: Dictionary = {}
	for record in records:
		var item = ItemScript.new(str(record["id"]), str(record["item_type"]), int(record["quantity"]), _vec3(record["position"]))
		item.holder_unit_id = str(record.get("holder_unit_id", ""))
		item.stockpile_id = str(record.get("stockpile_id", ""))
		item.reserved_by_job_id = str(record.get("reserved_by_job_id", ""))
		output[item.id] = item
	return output

static func _restore_stockpiles(records: Array) -> Dictionary:
	var output: Dictionary = {}
	for record in records:
		var stockpile = StockpileScript.new(str(record["id"]), record.get("accepted_item_types", []), record.get("cells", []), str(record.get("storage_mode", "both")))
		output[stockpile.id] = stockpile
	return output

static func _restore_constructions(records: Array) -> Dictionary:
	var output: Dictionary = {}
	for record in records:
		var construction = ConstructionRecordScript.new(
			str(record["id"]), str(record["type"]), _vec3(record["target_cell"]),
			record.get("required_items", {}), int(record.get("priority", 1)),
			str(record.get("status", "planned")), str(record.get("completed_building_id", "")),
			record.get("cells", []))
		construction.reserved_item_ids = _string_array(record.get("reserved_item_ids", []))
		construction.build_job_id = str(record.get("build_job_id", ""))
		output[construction.id] = construction
	return output

static func _restore_workshop_orders(records: Array) -> Dictionary:
	var output: Dictionary = {}
	for record in records:
		output[str(record["id"])] = record.duplicate(true)
	return output

static func _restore_jobs(records: Array):
	var board = JobBoardScript.new()
	for record in records:
		var job = JobScript.new(str(record["id"]), str(record["type"]), _vec3(record["target_cell"]), int(record.get("priority", 1)))
		job.required_skill = str(record.get("required_skill", "labor"))
		job.required_items = record.get("required_items", {}).duplicate(true)
		job.produced_items = record.get("produced_items", {}).duplicate(true)
		job.status = str(record.get("status", "open"))
		job.claimed_by_unit_id = str(record.get("claimed_by_unit_id", ""))
		job.work_remaining_ticks = int(record.get("work_remaining_ticks", 0))
		board.add_job(job)
	return board

static func _restore_command_queue(records: Array) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for record in records:
		output.append(record.duplicate(true))
	return output

static func _string_array(values: Array) -> Array[String]:
	var output: Array[String] = []
	for value in values:
		output.append(str(value))
	return output
