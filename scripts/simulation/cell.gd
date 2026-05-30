class_name SimCell
extends RefCounted

# A single 1x1x1 cell in the layered world (Dwarf-Fortress tile model).
#
# Each cell carries a FLOOR (the surface you stand on) and an optional WALL
# (solid fill that blocks movement and vision), plus extras: liquid, a plant
# occupant, a building slot, hidden ore revealed on mining, and a stair/ramp
# connector to adjacent layers. The cell does not store its own (x,y,z) address;
# the World owns addressing.

const C := preload("res://scripts/simulation/world_constants.gd")

var floor_material: String = C.MATERIAL_NONE   # "" = open shaft (no floor)
var wall_material: String = C.MATERIAL_NONE    # "" = open space (no wall)
var liquid_type: String = C.LIQUID_NONE
var liquid_level: int = 0
var plant: String = C.PLANT_NONE
var plant_growth: int = 0
var resource_id: String = ""
var building_id: String = ""
var hidden_ore: Dictionary = {}                # {material, item_type, quantity}
var stair: String = C.STAIR_NONE
var band: String = C.BAND_SKY
var mining_tier_required: int = C.MINING_TIER_NONE
var designation: String = C.DESIGNATION_NONE
var exposure: String = "dark"                  # "sky" when open to air above

func has_floor() -> bool:
	return floor_material != C.MATERIAL_NONE

func has_wall() -> bool:
	return wall_material != C.MATERIAL_NONE

func has_liquid() -> bool:
	return liquid_type != C.LIQUID_NONE and liquid_level > 0

func has_plant() -> bool:
	return plant != C.PLANT_NONE

func has_stair() -> bool:
	return stair != C.STAIR_NONE

# A unit can occupy this cell if it has something to stand on, is not filled by a
# wall, and is not flooded by deep liquid.
func is_walkable() -> bool:
	if has_wall():
		return false
	if not (has_floor() or has_stair()):
		return false
	if liquid_level >= C.LIQUID_BLOCK_LEVEL:
		return false
	return true

# True if a unit standing here can climb to the layer above.
func connects_up() -> bool:
	return stair == C.STAIR_UP or stair == C.STAIR_UP_DOWN or stair == C.STAIR_RAMP

# True if a unit standing here can descend to the layer below.
func connects_down() -> bool:
	return stair == C.STAIR_DOWN or stair == C.STAIR_UP_DOWN or stair == C.STAIR_RAMP

func duplicate_cell() -> SimCell:
	var copy := SimCell.new()
	copy.floor_material = floor_material
	copy.wall_material = wall_material
	copy.liquid_type = liquid_type
	copy.liquid_level = liquid_level
	copy.plant = plant
	copy.plant_growth = plant_growth
	copy.resource_id = resource_id
	copy.building_id = building_id
	copy.hidden_ore = hidden_ore.duplicate(true)
	copy.stair = stair
	copy.band = band
	copy.mining_tier_required = mining_tier_required
	copy.designation = designation
	copy.exposure = exposure
	return copy

# True when every field is at its default value (used to keep snapshots compact).
func is_default() -> bool:
	return floor_material == C.MATERIAL_NONE \
		and wall_material == C.MATERIAL_NONE \
		and liquid_type == C.LIQUID_NONE \
		and liquid_level == 0 \
		and plant == C.PLANT_NONE \
		and plant_growth == 0 \
		and resource_id == "" \
		and building_id == "" \
		and hidden_ore.is_empty() \
		and stair == C.STAIR_NONE \
		and band == C.BAND_SKY \
		and mining_tier_required == C.MINING_TIER_NONE \
		and designation == C.DESIGNATION_NONE \
		and exposure == "dark"

func to_canonical_dict() -> Dictionary:
	return {
		"band": band,
		"building_id": building_id,
		"designation": designation,
		"exposure": exposure,
		"floor_material": floor_material,
		"hidden_ore": _sorted_dictionary(hidden_ore),
		"liquid_level": liquid_level,
		"liquid_type": liquid_type,
		"mining_tier_required": mining_tier_required,
		"plant": plant,
		"plant_growth": plant_growth,
		"resource_id": resource_id,
		"stair": stair,
		"wall_material": wall_material,
	}

static func _sorted_dictionary(input: Dictionary) -> Dictionary:
	var output: Dictionary = {}
	var keys: Array = input.keys()
	keys.sort()
	for key in keys:
		output[key] = input[key]
	return output
