class_name WorldConstants
extends RefCounted

# Core constants for the layered floor/wall world.
#
# Coordinate convention: a cell address is Vector3i(x, y, z) where
#   x in [0, WIDTH)   horizontal east/west
#   z in [0, DEPTH)   horizontal north/south
#   y in [0, LAYER_COUNT)  vertical layer, HIGHER y = UP (Godot Y-up)
# The camera looks straight down -Y and shows one layer (constant y) at a time.

const WORLDGEN_PROFILE := "layered_floorwall_v1"

const WIDTH := 48
const DEPTH := 48
const LAYER_COUNT := 100

# --- Materials ----------------------------------------------------------------
# Empty string means "none": no floor (open shaft) or no wall (open space).
const MATERIAL_NONE := ""
const MATERIAL_GRASS := "GRASS"
const MATERIAL_DIRT := "DIRT"
const MATERIAL_CLAY := "CLAY"
const MATERIAL_SAND := "SAND"
const MATERIAL_GRAVEL := "GRAVEL"
const MATERIAL_LOOSE_STONE := "LOOSE_STONE"
const MATERIAL_SOFT_ROCK := "SOFT_ROCK"
const MATERIAL_HARD_ROCK := "HARD_ROCK"
const MATERIAL_BEDROCK := "BEDROCK"
const MATERIAL_WOOD := "WOOD"
const MATERIAL_ORE_COAL := "ORE_COAL"
const MATERIAL_ORE_COPPER := "ORE_COPPER"
const MATERIAL_ORE_IRON := "ORE_IRON"
const MATERIAL_ORE_SILVER := "ORE_SILVER"
const MATERIAL_ORE_GOLD := "ORE_GOLD"

# Plant occupants (stored in Cell.plant, not floor/wall).
const PLANT_NONE := ""
const PLANT_TREE_OAK := "TREE_OAK"
const PLANT_TREE_PINE := "TREE_PINE"
const PLANT_BERRY_BUSH := "BERRY_BUSH"
const PLANT_WILD_WHEAT := "WILD_WHEAT"
const PLANT_SAPLING := "SAPLING"

# --- Liquids ------------------------------------------------------------------
const LIQUID_NONE := ""
const LIQUID_WATER := "water"
const LIQUID_MAGMA := "magma"
const LIQUID_LEVEL_MAX := 7
# Liquid at or above this level blocks walking.
const LIQUID_BLOCK_LEVEL := 4

# --- Stairs / ramps -----------------------------------------------------------
const STAIR_NONE := "none"
const STAIR_UP := "up"
const STAIR_DOWN := "down"
const STAIR_UP_DOWN := "up_down"
const STAIR_RAMP := "ramp"

# --- Geological bands (strata tags) -------------------------------------------
const BAND_SKY := "sky"
const BAND_SURFACE := "surface"
const BAND_UPPER_EARTH := "upper_earth"
const BAND_STONE := "stone"
const BAND_CAVERN := "cavern"
const BAND_MAGMA_SEA := "magma_sea"
const BAND_BEDROCK := "bedrock"

# --- Mining tiers -------------------------------------------------------------
const MINING_TIER_NONE := 0
const MINING_TIER_BASIC := 1
const MINING_TIER_HARD_ROCK := 2
const MINING_TIER_RARE_ORE := 3

# --- Cell designations --------------------------------------------------------
const DESIGNATION_NONE := "none"
const DESIGNATION_MINE := "mine"        # remove a wall
const DESIGNATION_CHOP := "chop"        # fell a tree
const DESIGNATION_GATHER := "gather"    # harvest a plant (food)
const DESIGNATION_CHANNEL := "channel"  # remove a floor (open shaft down)
const DESIGNATION_BUILD_STAIR := "build_stair"

# --- Default band layout ------------------------------------------------------
# Approximate absolute-Y ranges. Bands overlap and are realized by separate
# worldgen passes (cavern carving, magma fill, ore seeding) layered on top of a
# base column whose top is the per-column surface elevation. Tunable.
const SURFACE_Y_MIN := 68
const SURFACE_Y_MAX := 82
const SURFACE_Y_MEAN := 75
const SURFACE_BAND_THICKNESS := 3          # grass layers at the column top
const UPPER_EARTH_Y_MIN := 40              # soil reaches down to here
const STONE_Y_MIN := 10                    # rock down to the magma band
const CAVERN_Y_MIN := 20                   # caverns carved within
const CAVERN_Y_MAX := 50
const MAGMA_SEA_Y_MAX := 12                # magma sea + bedrock floor below
const BEDROCK_Y_MAX := 2                   # bottom-most solid floor

static func in_bounds(cell: Vector3i) -> bool:
    return cell.x >= 0 and cell.x < WIDTH \
        and cell.z >= 0 and cell.z < DEPTH \
        and cell.y >= 0 and cell.y < LAYER_COUNT

static func is_plant_material(material_key: String) -> bool:
    return material_key in [PLANT_TREE_OAK, PLANT_TREE_PINE, PLANT_BERRY_BUSH, PLANT_WILD_WHEAT, PLANT_SAPLING]

static func required_mining_tier_for_material(material_key: String) -> int:
    match material_key:
        MATERIAL_GRASS, MATERIAL_DIRT, MATERIAL_CLAY, MATERIAL_SAND, MATERIAL_GRAVEL, \
        MATERIAL_LOOSE_STONE, MATERIAL_SOFT_ROCK, MATERIAL_WOOD:
            return MINING_TIER_BASIC
        MATERIAL_HARD_ROCK, MATERIAL_ORE_COAL, MATERIAL_ORE_COPPER, MATERIAL_ORE_IRON:
            return MINING_TIER_HARD_ROCK
        MATERIAL_ORE_SILVER, MATERIAL_ORE_GOLD:
            return MINING_TIER_RARE_ORE
        MATERIAL_BEDROCK:
            return 99  # unmineable
    return MINING_TIER_NONE

static func is_material_mineable_with_tier(material_key: String, tier: int) -> bool:
    if material_key == MATERIAL_NONE or material_key == MATERIAL_BEDROCK:
        return false
    var required: int = required_mining_tier_for_material(material_key)
    return required > MINING_TIER_NONE and tier >= required

# Item type dropped when a wall of the given material is mined out.
static func mined_item_type_for_material(material_key: String) -> String:
    match material_key:
        MATERIAL_GRASS, MATERIAL_DIRT:
            return "dirt"
        MATERIAL_WOOD:
            return "wood"
        MATERIAL_CLAY:
            return "clay"
        MATERIAL_SAND:
            return "sand"
        MATERIAL_GRAVEL:
            return "gravel"
        MATERIAL_LOOSE_STONE, MATERIAL_SOFT_ROCK, MATERIAL_HARD_ROCK:
            return "stone"
        MATERIAL_ORE_COAL:
            return "coal"
        MATERIAL_ORE_COPPER:
            return "copper_ore"
        MATERIAL_ORE_IRON:
            return "iron_ore"
        MATERIAL_ORE_SILVER:
            return "silver_ore"
        MATERIAL_ORE_GOLD:
            return "gold_ore"
    return "stone"
