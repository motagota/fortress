extends RefCounted

const GridWorldScript := preload("res://scripts/simulation/grid_world.gd")
const ChunkAddressingScript := preload("res://scripts/simulation/chunk_addressing.gd")
const ChunkedWorldStoreScript := preload("res://scripts/simulation/chunked_world_store.gd")
const ChunkedWorldReadAdapterScript := preload("res://scripts/simulation/chunked_world_read_adapter.gd")
const PackedCellCodecScript := preload("res://scripts/simulation/packed_cell_codec.gd")
const WorldgenDiagnosticsScript := preload("res://scripts/simulation/worldgen_diagnostics.gd")
const RngScript := preload("res://scripts/simulation/deterministic_rng.gd")
const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const WorldRendererScript := preload("res://scripts/presentation/world_renderer.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func _generated(seed: int) -> Dictionary:
    var world = GridWorldScript.new(16, 16)
    var resources: Dictionary = {}
    world.generate_ironveil_region(RngScript.new(seed), resources)
    return {"world": world, "resources": resources}

func _generated_through_compatibility_api(seed: int) -> Dictionary:
    var world = GridWorldScript.new(16, 16)
    var resources: Dictionary = {}
    world.create_forest(RngScript.new(seed), resources)
    return {"world": world, "resources": resources}

func _count_resources(resources: Dictionary, resource_type: String) -> int:
    var total: int = 0
    for id in resources.keys():
        if str(resources[id].get("type", "")) == resource_type:
            total += 1
    return total

func _first_resource_position(resources: Dictionary, resource_type: String) -> Vector2i:
    var ids: Array = resources.keys()
    ids.sort()
    for id in ids:
        var resource: Dictionary = resources[id]
        if str(resource.get("type", "")) == resource_type:
            var pos: Array = resource.get("position", [])
            return Vector2i(int(pos[0]), int(pos[1]))
    return Vector2i(-1, -1)

func _count_items_of_type(sim, item_type: String) -> int:
    var total: int = 0
    for id in sim.items.keys():
        if sim.items[id].item_type == item_type:
            total += int(sim.items[id].quantity)
    return total

func _step_ticks(sim, count: int) -> void:
    for i in range(count):
        sim.step_tick()

func _hidden_yield_cells(world, item_type: String = "") -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    for z in range(world.height):
        for x in range(world.width):
            var pos := Vector2i(x, z)
            var cell = world.get_cell(pos)
            if cell == null or cell.hidden_mine_yield.is_empty():
                continue
            if item_type != "" and str(cell.hidden_mine_yield.get("item_type", "")) != item_type:
                continue
            cells.append(pos)
    return cells

func _cells_with_material(world, material_key: String) -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    for z in range(world.height):
        for x in range(world.width):
            var pos := Vector2i(x, z)
            var cell = world.get_cell(pos)
            if cell != null and str(cell.material_key) == material_key:
                cells.append(pos)
    return cells

func _surface_height_bounds(sim) -> Vector2i:
    var min_height: int = 0
    var max_height: int = 0
    var found: bool = false
    for z in range(sim.world.height):
        for x in range(sim.world.width):
            var height: int = sim.world.get_surface_height(Vector2i(x, z))
            if not found:
                min_height = height
                max_height = height
                found = true
            else:
                min_height = mini(min_height, height)
                max_height = maxi(max_height, height)
    return Vector2i(min_height, max_height)

func _excavate_access_column(sim, target: Vector2i) -> void:
    var target_cell = sim.world.get_cell(target)
    if target_cell == null:
        return
    var target_depth: int = int(target_cell.depth)
    if target_depth >= 0:
        return
    var display_z: int = _render_z_for_sim_cell(sim, target)
    for depth in range(0, target_depth, -1):
        var shaft_cell: Vector2i = _cell_at_display_depth(sim, Vector2i(target.x, display_z), depth)
        if shaft_cell == Vector2i(-1, -1):
            continue
        var cell = sim.world.get_cell(shaft_cell)
        cell.terrain = "excavated"
        cell.material_key = "AIR"
        cell.resource_id = ""
        cell.walkable = true

func _cell_at_display_depth(sim, display_cell: Vector2i, depth: int) -> Vector2i:
    for z in range(sim.world.height):
        var candidate := Vector2i(display_cell.x, z)
        var cell = sim.world.get_cell(candidate)
        if cell == null or int(cell.depth) != depth:
            continue
        if _render_z_for_sim_cell(sim, candidate) == display_cell.y:
            return candidate
    return Vector2i(-1, -1)

func _render_z_for_sim_cell(sim, cell: Vector2i) -> int:
    var sim_cell = sim.world.get_cell(cell)
    if sim_cell == null:
        return cell.y
    var first_row: int = cell.y
    for z in range(sim.world.height):
        var layer_cell = sim.world.get_cell(Vector2i(cell.x, z))
        if layer_cell != null and int(layer_cell.depth) == int(sim_cell.depth):
            first_row = z
            break
    return cell.y - first_row

func _snapshot_text(generated: Dictionary) -> String:
    var world = generated["world"]
    return JSON.stringify({
        "profile": world.generation_profile,
        "cells": world.to_canonical_array(),
        "resources": generated["resources"],
    })

func _test_seeded_ironveil_generation_is_deterministic() -> bool:
    var a: Dictionary = _generated(4242)
    var b: Dictionary = _generated(4242)
    var c: Dictionary = _generated(9001)
    return _assert(_snapshot_text(a) == _snapshot_text(b), "same Ironveil worldgen seed must produce identical cells and resources") \
        and _assert(_snapshot_text(a) != _snapshot_text(c), "different Ironveil worldgen seeds should vary cells or resources")

func _test_create_forest_compatibility_uses_ironveil_generator() -> bool:
    var direct: Dictionary = _generated(5150)
    var compatibility: Dictionary = _generated_through_compatibility_api(5150)
    return _assert(_snapshot_text(direct) == _snapshot_text(compatibility), "create_forest compatibility API should delegate to the Ironveil generator")

func _test_ironveil_layer_projection_shape() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var ok: bool = true
    ok = _assert(world.generation_profile == "ironveil_layered_v1", "worldgen profile should name the Ironveil layered generator") and ok
    ok = _assert(world.get_cell(Vector2i(0, 12)).depth == -3, "row 12 should remain projected depth -3") and ok
    ok = _assert(world.get_cell(Vector2i(0, 12)).terrain == "dirt", "projected layer 4 should remain dirt for current mining rules") and ok
    ok = _assert(world.get_cell(Vector2i(0, 13)).depth == -4, "row 13 should remain projected depth -4") and ok
    ok = _assert(world.get_cell(Vector2i(0, 13)).terrain == "solid_rock", "projected layer 5 should be hard solid rock") and ok
    ok = _assert(world.get_cell(Vector2i(4, 8)).terrain == "rock", "projected layer 3 should introduce shallow mineable rock") and ok
    return ok

func _test_explicit_strata_rules_and_mining_tiers() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var surface = world.get_cell(Vector2i(4, 0))
    var soil = world.get_cell(Vector2i(4, 4))
    var soft_rock = world.get_cell(Vector2i(4, 8))
    var deep_soil = world.get_cell(Vector2i(0, 12))
    var hard_rock = world.get_cell(Vector2i(0, 13))
    var ok: bool = true
    ok = _assert(surface.strata_key == "surface" and surface.material_key == "GRASS" and surface.mining_tier_required == 1, "surface strata should be explicit and tier 1") and ok
    ok = _assert(soil.strata_key == "soil" and soil.material_key == "DIRT" and soil.mining_tier_required == 1, "soil strata should be explicit and tier 1") and ok
    ok = _assert(soft_rock.strata_key == "soft_rock" and soft_rock.material_key == "SOFT_ROCK" and soft_rock.mining_tier_required == 1, "soft rock strata should be explicit and tier 1") and ok
    ok = _assert(deep_soil.strata_key == "deep_soil" and deep_soil.material_key == "DIRT" and deep_soil.mining_tier_required == 1, "deep soil projection should remain tier 1 dirt for current mining") and ok
    ok = _assert(hard_rock.strata_key == "hard_rock" and hard_rock.material_key == "HARD_ROCK" and hard_rock.mining_tier_required == 2, "hard rock strata should require tier 2 mining") and ok
    ok = _assert(world.is_mineable_cell(Vector2i(4, 0), 1), "tier 1 should mine grass") and ok
    ok = _assert(world.is_mineable_cell(Vector2i(4, 4), 1), "tier 1 should mine dirt") and ok
    ok = _assert(world.is_mineable_cell(Vector2i(4, 8), 1), "tier 1 should mine shallow rock") and ok
    ok = _assert(not world.is_mineable_cell(Vector2i(0, 13), 1), "tier 1 should not mine hard rock") and ok
    ok = _assert(world.is_mineable_cell(Vector2i(0, 13), 2), "tier 2 should be able to mine hard rock through the gated API") and ok
    ok = _assert(not world.is_material_mineable_with_tier(GridWorldScript.MATERIAL_TREE_OAK, 1), "trees should not be mineable materials") and ok
    ok = _assert(world.is_material_mineable_with_tier(GridWorldScript.MATERIAL_LOOSE_STONE, 1), "loose stone should be tier 1 mineable") and ok
    ok = _assert(not world.is_material_mineable_with_tier(GridWorldScript.MATERIAL_ORE_IRON, 1), "future iron ore cells should reject tier 1 mining") and ok
    ok = _assert(world.is_material_mineable_with_tier(GridWorldScript.MATERIAL_ORE_IRON, 2), "future iron ore cells should accept tier 2 mining") and ok
    ok = _assert(not world.is_material_mineable_with_tier(GridWorldScript.MATERIAL_ORE_GOLD, 2), "future rare ore cells should reject tier 2 mining") and ok
    ok = _assert(world.is_material_mineable_with_tier(GridWorldScript.MATERIAL_ORE_GOLD, 3), "future rare ore cells should accept tier 3 mining") and ok
    ok = _assert(not world.is_material_mineable_with_tier(GridWorldScript.MATERIAL_BEDROCK, 99), "bedrock should remain unmineable at every tier") and ok
    return ok

func _test_seeded_hidden_ore_pass_places_current_ores_only() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var resources: Dictionary = generated["resources"]
    var coal_cells: Array[Vector2i] = _hidden_yield_cells(world, "coal")
    var copper_cells: Array[Vector2i] = _hidden_yield_cells(world, "copper_ore")
    var iron_cells: Array[Vector2i] = _hidden_yield_cells(world, "iron_ore")
    var ok: bool = true
    ok = _assert(coal_cells.size() > 0, "ore pass should seed hidden coal in rock bands") and ok
    ok = _assert(copper_cells.size() > 0, "ore pass should seed hidden copper in rock bands") and ok
    ok = _assert(iron_cells.size() > 0, "ore pass should seed hidden iron in hard rock bands") and ok
    for id in resources.keys():
        ok = _assert(not (str(resources[id].get("type", "")) in ["coal", "copper_ore", "iron_ore"]), "ore pass should not create visible ore resources") and ok
    for pos in coal_cells + copper_cells:
        var cell = world.get_cell(pos)
        ok = _assert(cell.strata_key == "soft_rock", "coal and copper should start as hidden soft-rock outputs") and ok
        ok = _assert(cell.material_key == "SOFT_ROCK", "hidden shallow ore should preserve base rock material") and ok
        ok = _assert(cell.resource_id == "", "hidden shallow ore should not occupy resource_id") and ok
    for pos in iron_cells:
        var cell = world.get_cell(pos)
        ok = _assert(cell.strata_key == "hard_rock", "iron should start as a hidden hard-rock output") and ok
        ok = _assert(cell.material_key == "HARD_ROCK", "hidden iron should preserve base hard-rock material") and ok
        ok = _assert(cell.resource_id == "", "hidden iron should not occupy resource_id") and ok
        ok = _assert(cell.mining_tier_required == 2, "hidden iron host cell should remain hard-rock tier gated") and ok
    ok = _assert(_hidden_yield_cells(world, "silver_ore").is_empty(), "silver should wait for later inventory/tool support") and ok
    ok = _assert(_hidden_yield_cells(world, "gold_ore").is_empty(), "gold should wait for later inventory/tool support") and ok
    ok = _assert(_hidden_yield_cells(world, "oil").is_empty(), "oil should wait for later fluid/industry support") and ok
    return ok

func _test_height_map_and_slope_metadata_are_deterministic() -> bool:
    var a: Dictionary = _generated(4242)
    var b: Dictionary = _generated(4242)
    var c: Dictionary = _generated(9001)
    var world_a = a["world"]
    var world_b = b["world"]
    var world_c = c["world"]
    var ok: bool = true
    ok = _assert(world_a.height_map == world_b.height_map, "same seed should produce identical height map") and ok
    ok = _assert(world_a.slope_map == world_b.slope_map, "same seed should produce identical slope map") and ok
    ok = _assert(world_a.height_map != world_c.height_map, "different seed should produce a different height map") and ok
    for z in range(world_a.height):
        for x in range(world_a.width):
            var pos := Vector2i(x, z)
            var cell = world_a.get_cell(pos)
            var surface_height: int = world_a.get_surface_height(pos)
            var slope: int = world_a.get_slope_degrees(pos)
            ok = _assert(surface_height >= GridWorldScript.HEIGHT_MIN and surface_height <= GridWorldScript.HEIGHT_MAX, "surface height should stay inside configured range") and ok
            ok = _assert(slope >= 0 and slope <= 89, "slope should be stored as clamped degrees") and ok
            ok = _assert(cell.surface_height == surface_height and cell.slope_degrees == slope, "cell metadata should mirror height/slope map values") and ok
            for offset in [Vector2i(1, 0), Vector2i(0, 1)]:
                var neighbor: Vector2i = pos + offset
                if world_a.in_bounds(neighbor):
                    ok = _assert(absi(surface_height - world_a.get_surface_height(neighbor)) <= 2, "adjacent surface columns should stay smoothly terraced") and ok
    return ok

func _test_seeded_river_map_applies_gravel_and_clay_without_fishing_spots() -> bool:
    var a: Dictionary = _generated(4242)
    var b: Dictionary = _generated(4242)
    var c: Dictionary = _generated(9001)
    var world = a["world"]
    var resources: Dictionary = a["resources"]
    var river_cells: Array[Vector2i] = world.get_river_cells()
    var clay_cells: Array[Vector2i] = _cells_with_material(world, "CLAY")
    var ok: bool = true
    ok = _assert(world.river_map == b["world"].river_map, "same seed should produce identical river map") and ok
    ok = _assert(world.river_map != c["world"].river_map, "different seed should vary river map") and ok
    ok = _assert(river_cells.size() > 0, "river map should precompute surface river cells") and ok
    ok = _assert(clay_cells.size() > 0, "river-adjacent dirt should convert to clay") and ok
    for river_cell in river_cells:
        var cell = world.get_cell(river_cell)
        var river_data: Dictionary = world.get_river_data(river_cell)
        ok = _assert(cell.is_river, "riverbed cell should be flagged as river") and ok
        ok = _assert(cell.material_key == "GRAVEL", "riverbed cells should convert to gravel") and ok
        ok = _assert(cell.terrain == "dirt", "riverbed cells should keep terrain compatibility as dirt") and ok
        ok = _assert(cell.resource_id == "", "riverbed cells should not contain scatter resources") and ok
        ok = _assert(cell.hidden_mine_yield.is_empty(), "riverbed cells should not contain hidden ore") and ok
        ok = _assert(cell.water_feature == "riverbed", "riverbed cells should identify their hydrology feature") and ok
        ok = _assert(cell.strata_key == "surface", "river map should be over the surface projection") and ok
        ok = _assert(river_data.get("feature", "") == "river", "river map should not create fishing spot features yet") and ok
    for clay_cell in clay_cells:
        var cell = world.get_cell(clay_cell)
        ok = _assert(not cell.is_river, "clay riverbank cells should not be river cells") and ok
        ok = _assert(cell.water_feature == "riverbank", "clay cells should be marked as riverbanks") and ok
        ok = _assert(cell.distance_to_river <= 1, "clay cells should be adjacent to the precomputed river") and ok
        ok = _assert(cell.terrain == "dirt", "clay should preserve dirt terrain compatibility") and ok
        ok = _assert(cell.resource_id == "", "clay riverbanks should not contain scatter resources") and ok
    for id in resources.keys():
        ok = _assert(not (str(resources[id].get("type", "")) in ["fish", "fishing_spot"]), "fishing resources should wait for food/job support") and ok
    return ok

func _test_seeded_cave_voids_expose_underground_projection() -> bool:
    var a: Dictionary = _generated(4242)
    var b: Dictionary = _generated(4242)
    var c: Dictionary = _generated(9001)
    var world = a["world"]
    var cave_cells: Array[Vector2i] = world.get_cave_cells()
    var ok: bool = true
    ok = _assert(world.cave_map == b["world"].cave_map, "same seed should produce identical cave map") and ok
    ok = _assert(world.cave_map != c["world"].cave_map, "different seed should vary cave map") and ok
    ok = _assert(cave_cells.size() > 0, "cave pass should expose underground void cells") and ok
    for cave_cell in cave_cells:
        var cell = world.get_cell(cave_cell)
        var cave_data: Dictionary = world.get_cave_data(cave_cell)
        ok = _assert(cell != null, "cave map should only reference valid cells") and ok
        ok = _assert(int(cell.depth) < 0, "cave voids should stay underground in the current projection") and ok
        ok = _assert(cell.is_cave, "cave void cells should be flagged") and ok
        ok = _assert(cell.cave_id != "", "cave void cells should carry a cave id") and ok
        ok = _assert(cell.exposure == "cave", "cave voids should be exposed without requiring a mined shaft") and ok
        ok = _assert(cell.terrain == "excavated", "cave voids should use excavated terrain compatibility") and ok
        ok = _assert(cell.material_key == "AIR", "cave voids should use AIR material") and ok
        ok = _assert(cell.walkable, "cave voids should be standable once reached by simulation rules") and ok
        ok = _assert(cell.resource_id == "", "cave voids should not contain scatter resources") and ok
        ok = _assert(cell.hidden_mine_yield.is_empty(), "cave voids should not contain hidden ore outputs") and ok
        ok = _assert(not cell.is_river and cell.water_feature == "", "cave voids should not be hydrology cells") and ok
        ok = _assert(cell.strata_key in ["soft_rock", "hard_rock"], "caves should carve rock strata in the current projection") and ok
        ok = _assert(cave_data.get("feature", "") == "cave_void", "cave map should identify cave void features") and ok
        ok = _assert(world.get_distance_to_cave(cave_cell) == 0, "cave distance query should resolve exact cave cells") and ok
    var sim = SimulationScript.new()
    sim.initialize_new_game(4242)
    var sim_cave_cells: Array[Vector2i] = sim.world.get_cave_cells()
    if _assert(not sim_cave_cells.is_empty(), "precondition: simulation world should include cave cells"):
        var sim_cave_cell: Vector2i = sim_cave_cells[0]
        ok = _assert(sim._is_cell_exposed(sim_cave_cell), "simulation exposure rules should treat cave voids as exposed") and ok
        ok = _assert(sim._can_stand_on_cell(sim_cave_cell), "simulation standing rules should accept exposed cave voids") and ok
    else:
        ok = false
    return ok

func _test_storage_metadata_tracks_current_projection_and_future_chunks() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var metadata: Dictionary = world.get_storage_metadata()
    var ok: bool = true
    ok = _assert(metadata.get("storage_model", "") == "stacked_projection_v1", "storage metadata should name the current stacked projection model") and ok
    ok = _assert(metadata.get("target_storage_model", "") == "chunked_3d_v1", "storage metadata should expose the target chunk model") and ok
    ok = _assert(not bool(metadata.get("chunk_storage_active", true)), "chunk storage should not be active for gameplay yet") and ok
    ok = _assert(int(metadata.get("projected_width", 0)) == 16, "storage metadata should expose projected width") and ok
    ok = _assert(int(metadata.get("projected_height", 0)) == 16, "storage metadata should expose projected height") and ok
    ok = _assert(int(metadata.get("projected_depth_layers", 0)) == 5, "storage metadata should expose current depth bands") and ok
    ok = _assert(int(metadata.get("target_chunk_size", 0)) == 16, "storage metadata should define the future chunk edge size") and ok
    ok = _assert(metadata.get("target_chunk_shape", []) == [16, 16, 16], "storage metadata should define the future 3D chunk shape") and ok
    ok = _assert(not bool(metadata.get("deep_hazards_enabled", true)), "storage metadata should keep deep hazards disabled in the current projection") and ok
    return ok

func _test_chunk_addressing_handles_signed_world_cells() -> bool:
    var positive: Dictionary = ChunkAddressingScript.world_to_chunk(Vector3i(17, -1, 31), 16)
    var negative: Dictionary = ChunkAddressingScript.world_to_chunk(Vector3i(-1, -17, -16), 16)
    var round_trip: Dictionary = ChunkAddressingScript.chunk_local_to_world(Vector3i(1, -1, 1), Vector3i(1, 15, 15), 16)
    var invalid_local: Dictionary = ChunkAddressingScript.chunk_local_to_world(Vector3i.ZERO, Vector3i(16, 0, 0), 16)
    var ok: bool = true
    ok = _assert(bool(positive.get("valid", false)), "positive/surface-adjacent world cells should convert to chunk addresses") and ok
    ok = _assert(positive.get("chunk_cell", []) == [1, -1, 1], "chunk addressing should floor-divide underground y coordinates") and ok
    ok = _assert(positive.get("local_cell", []) == [1, 15, 15], "chunk addressing should produce positive local coordinates") and ok
    ok = _assert(negative.get("chunk_cell", []) == [-1, -2, -1], "chunk addressing should floor-divide negative world coordinates") and ok
    ok = _assert(negative.get("local_cell", []) == [15, 15, 0], "negative world cells should map to in-bounds local coordinates") and ok
    ok = _assert(bool(round_trip.get("valid", false)), "valid chunk/local coordinates should round trip") and ok
    ok = _assert(round_trip.get("world_cell", []) == [17, -1, 31], "chunk/local to world conversion should invert world_to_chunk") and ok
    ok = _assert(not bool(invalid_local.get("valid", true)), "out-of-range local coordinates should fail predictably") and ok
    ok = _assert(invalid_local.get("reason", "") == "local_cell_out_of_bounds", "invalid local coordinates should report a stable failure reason") and ok
    return ok

func _test_projection_to_chunk_boundary_preserves_existing_cell_metadata() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var sample_cells: Array[Vector2i] = [Vector2i(4, 0), Vector2i(4, 8), Vector2i(0, 13)]
    var river_cells: Array[Vector2i] = world.get_river_cells()
    if not river_cells.is_empty():
        sample_cells.append(river_cells[0])
    var cave_cells: Array[Vector2i] = world.get_cave_cells()
    if not cave_cells.is_empty():
        sample_cells.append(cave_cells[0])
    var ok: bool = true
    for pos in sample_cells:
        var cell = world.get_cell(pos)
        var view: Dictionary = world.get_projected_cell_storage_view(pos)
        ok = _assert(bool(view.get("valid", false)), "projected cells should expose a storage-facing view") and ok
        ok = _assert(view.get("projected_cell", []) == [pos.x, pos.y], "storage view should preserve projected identity") and ok
        ok = _assert(view.get("world_cell", [])[0] == pos.x, "projected x should map to world x") and ok
        ok = _assert(view.get("world_cell", [])[1] == int(cell.depth), "projected depth should map to world y") and ok
        var address_round_trip: Dictionary = ChunkAddressingScript.chunk_local_to_world(
            ChunkAddressingScript.array_to_vector3i(view.get("chunk_cell", [])),
            ChunkAddressingScript.array_to_vector3i(view.get("local_cell", [])),
            int(view.get("chunk_size", 16))
        )
        ok = _assert(address_round_trip.get("world_cell", []) == view.get("world_cell", []), "chunk address should round trip back to the storage world cell") and ok
        var projection_round_trip: Dictionary = world.get_projected_cell_for_world_cell(ChunkAddressingScript.array_to_vector3i(view.get("world_cell", [])))
        ok = _assert(bool(projection_round_trip.get("valid", false)), "storage world cell should resolve back to the projection") and ok
        ok = _assert(projection_round_trip.get("projected_cell", []) == [pos.x, pos.y], "world-to-projection round trip should return the same cell") and ok
        var stored_cell: Dictionary = view.get("cell", {})
        ok = _assert(stored_cell.get("terrain", "") == str(cell.terrain), "storage view should preserve terrain compatibility") and ok
        ok = _assert(stored_cell.get("material_key", "") == str(cell.material_key), "storage view should preserve material key") and ok
        ok = _assert(stored_cell.get("strata_key", "") == str(cell.strata_key), "storage view should preserve strata") and ok
        ok = _assert(bool(stored_cell.get("is_river", false)) == bool(cell.is_river), "storage view should preserve river flag") and ok
        ok = _assert(bool(stored_cell.get("is_cave", false)) == bool(cell.is_cave), "storage view should preserve cave flag") and ok
        ok = _assert(int(stored_cell.get("surface_height", 0)) == int(cell.surface_height), "storage view should preserve height metadata") and ok
        ok = _assert(int(stored_cell.get("slope_degrees", 0)) == int(cell.slope_degrees), "storage view should preserve slope metadata") and ok
    return ok

func _test_chunk_boundary_rejects_invalid_projection_coordinates() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var projected_out_of_bounds: Dictionary = world.get_storage_address_for_projected_cell(Vector2i(-1, 0))
    var world_x_out_of_bounds: Dictionary = world.get_projected_cell_for_world_cell(Vector3i(-1, 0, 0))
    var world_depth_out_of_projection: Dictionary = world.get_projected_cell_for_world_cell(Vector3i(0, -99, 0))
    var world_z_out_of_projection: Dictionary = world.get_projected_cell_for_world_cell(Vector3i(0, 0, -1))
    var ok: bool = true
    ok = _assert(not bool(projected_out_of_bounds.get("valid", true)), "out-of-bounds projection cells should fail") and ok
    ok = _assert(projected_out_of_bounds.get("reason", "") == "projected_cell_out_of_bounds", "projection bounds failures should be explicit") and ok
    ok = _assert(not bool(world_x_out_of_bounds.get("valid", true)), "negative world x should not resolve into the current projection") and ok
    ok = _assert(world_x_out_of_bounds.get("reason", "") == "world_cell_out_of_bounds", "world x bounds failures should be explicit") and ok
    ok = _assert(not bool(world_depth_out_of_projection.get("valid", true)), "unknown world y depth should not resolve into the current projection") and ok
    ok = _assert(world_depth_out_of_projection.get("reason", "") == "world_cell_out_of_projection", "world depth failures should be explicit") and ok
    ok = _assert(not bool(world_z_out_of_projection.get("valid", true)), "negative world z display coordinate should not resolve into the current projection") and ok
    ok = _assert(world_z_out_of_projection.get("reason", "") == "world_cell_out_of_projection", "world z projection failures should be explicit") and ok
    return ok

func _test_chunked_world_store_imports_projection_without_mutation() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var before_snapshot: String = _snapshot_text(generated)
    var store = ChunkedWorldStoreScript.new(16)
    var report: Dictionary = store.import_projected_world(world)
    var after_snapshot: String = _snapshot_text(generated)
    var metadata: Dictionary = store.get_metadata()
    var ok: bool = true
    ok = _assert(before_snapshot == after_snapshot, "importing projection into chunk store should not mutate GridWorld") and ok
    ok = _assert(bool(report.get("valid", false)), "chunk store should import the current projection without errors") and ok
    ok = _assert(int(report.get("imported_cells", 0)) == world.width * world.height, "chunk store should import every projected cell") and ok
    ok = _assert(int(report.get("error_count", -1)) == 0, "chunk store import should not report errors") and ok
    ok = _assert(metadata.get("storage_model", "") == "chunked_3d_v1", "chunk store should identify the target storage model") and ok
    ok = _assert(metadata.get("source_storage_model", "") == "stacked_projection_v1", "chunk store should retain its projection source model") and ok
    ok = _assert(metadata.get("cell_payload_schema", "") == "ironveil_cell_payload_v1", "chunk store should expose the cell payload schema") and ok
    ok = _assert(metadata.get("cell_payload_encoding", "") == "dictionary_payload_v1", "chunk store should keep packed cells deferred behind dictionary payloads") and ok
    ok = _assert(int(metadata.get("cell_count", 0)) == world.width * world.height, "chunk store metadata should count imported cells") and ok
    ok = _assert(int(metadata.get("chunk_count", 0)) >= 2, "current projection should occupy surface and underground chunks") and ok
    ok = _assert(bool(store.get_chunk(Vector3i(0, 0, 0)).get("valid", false)), "chunk store should contain the surface chunk") and ok
    ok = _assert(bool(store.get_chunk(Vector3i(0, -1, 0)).get("valid", false)), "chunk store should contain the underground chunk") and ok
    return ok

func _test_chunked_world_store_preserves_projected_cell_payloads() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var store = ChunkedWorldStoreScript.new(16)
    store.import_projected_world(world)
    var sample_cells: Array[Vector2i] = [Vector2i(4, 0), Vector2i(4, 8), Vector2i(0, 13)]
    var river_cells: Array[Vector2i] = world.get_river_cells()
    if not river_cells.is_empty():
        sample_cells.append(river_cells[0])
    var cave_cells: Array[Vector2i] = world.get_cave_cells()
    if not cave_cells.is_empty():
        sample_cells.append(cave_cells[0])
    var ok: bool = true
    for pos in sample_cells:
        var view: Dictionary = world.get_projected_cell_storage_view(pos)
        var stored: Dictionary = store.get_cell(ChunkAddressingScript.array_to_vector3i(view.get("world_cell", [])))
        var source: Dictionary = stored.get("source", {})
        var payload: Dictionary = stored.get("payload", {})
        var source_cell: Dictionary = view.get("cell", {})
        ok = _assert(bool(stored.get("valid", false)), "chunk store should return imported projection cells") and ok
        ok = _assert(stored.get("schema", "") == "ironveil_cell_payload_v1", "stored cells should carry the schema version") and ok
        ok = _assert(stored.get("encoding", "") == "dictionary_payload_v1", "stored cells should carry the payload encoding") and ok
        ok = _assert(source.get("projected_cell", []) == [pos.x, pos.y], "stored cells should retain source projected coordinates") and ok
        ok = _assert(payload.get("terrain", "") == source_cell.get("terrain", ""), "stored payload should preserve terrain") and ok
        ok = _assert(payload.get("material_key", "") == source_cell.get("material_key", ""), "stored payload should preserve material") and ok
        ok = _assert(payload.get("strata_key", "") == source_cell.get("strata_key", ""), "stored payload should preserve strata") and ok
        ok = _assert(bool(payload.get("is_river", false)) == bool(source_cell.get("is_river", false)), "stored payload should preserve river flag") and ok
        ok = _assert(bool(payload.get("is_cave", false)) == bool(source_cell.get("is_cave", false)), "stored payload should preserve cave flag") and ok
        ok = _assert(int(payload.get("surface_height", 0)) == int(source_cell.get("surface_height", 0)), "stored payload should preserve surface height") and ok
        ok = _assert(int(payload.get("slope_degrees", 0)) == int(source_cell.get("slope_degrees", 0)), "stored payload should preserve slope") and ok
    return ok

func _test_chunked_world_store_canonical_output_is_deterministic() -> bool:
    var generated_a: Dictionary = _generated(4242)
    var generated_b: Dictionary = _generated(4242)
    var generated_c: Dictionary = _generated(9001)
    var store_a = ChunkedWorldStoreScript.new(16)
    var store_b = ChunkedWorldStoreScript.new(16)
    var store_c = ChunkedWorldStoreScript.new(16)
    store_a.import_projected_world(generated_a["world"])
    store_b.import_projected_world(generated_b["world"])
    store_c.import_projected_world(generated_c["world"])
    var encoded_a: String = JSON.stringify(store_a.to_canonical_array())
    var encoded_b: String = JSON.stringify(store_b.to_canonical_array())
    var encoded_c: String = JSON.stringify(store_c.to_canonical_array())
    var ok: bool = true
    ok = _assert(encoded_a == encoded_b, "same seed chunk store import should produce identical canonical output") and ok
    ok = _assert(encoded_a != encoded_c, "different seed chunk store import should preserve projection variation") and ok
    ok = _assert(store_a.to_canonical_array().size() == int(store_a.get_metadata().get("cell_count", 0)), "canonical chunk store output should include each stored cell") and ok
    return ok

func _test_actual_chunk_volume_import_fills_one_3d_chunk_without_mutation() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var before_snapshot: String = _snapshot_text(generated)
    var store = ChunkedWorldStoreScript.new(16)
    var report: Dictionary = store.import_actual_chunk_volume(world, Vector3i(0, -1, 0))
    var after_snapshot: String = _snapshot_text(generated)
    var metadata: Dictionary = store.get_metadata()
    var chunk: Dictionary = store.get_chunk(Vector3i(0, -1, 0))
    var chunk_cells: Dictionary = chunk.get("cells", {})
    var top_cell: Dictionary = store.get_cell(Vector3i(4, -1, 4))
    var deep_cell: Dictionary = store.get_cell(Vector3i(4, -16, 4))
    var ok: bool = true
    ok = _assert(before_snapshot == after_snapshot, "importing an actual chunk volume should not mutate GridWorld") and ok
    ok = _assert(bool(report.get("valid", false)), "actual chunk volume import should succeed for the first underground chunk") and ok
    ok = _assert(report.get("import_model", "") == "actual_chunk_volume_v1", "actual chunk volume import should identify its import model") and ok
    ok = _assert(int(report.get("generated_cells", 0)) == 4096, "actual chunk volume import should fill all 16x16x16 cells") and ok
    ok = _assert(int(report.get("expected_cells", 0)) == 4096, "actual chunk volume report should expose the expected chunk volume") and ok
    ok = _assert(int(metadata.get("chunk_count", 0)) == 1, "single-chunk volume import should create exactly one chunk") and ok
    ok = _assert(bool(metadata.get("actual_chunk_volume_active", false)), "metadata should mark actual chunk volume storage as active for this derived store") and ok
    ok = _assert(bool(chunk.get("valid", false)), "actual chunk volume import should create the requested chunk") and ok
    ok = _assert(chunk_cells.size() == 4096, "requested chunk should contain one payload for every local cell") and ok
    ok = _assert(bool(top_cell.get("valid", false)) and top_cell.get("local_cell", []) == [4, 15, 4], "top underground cell should address to local y 15") and ok
    ok = _assert(bool(deep_cell.get("valid", false)) and deep_cell.get("local_cell", []) == [4, 0, 4], "bottom underground cell should address to local y 0") and ok
    ok = _assert(str(top_cell.get("payload", {}).get("strata_key", "")) == "soil", "near-surface underground volume should generate soil") and ok
    ok = _assert(str(deep_cell.get("payload", {}).get("strata_key", "")) == "hard_rock", "deep underground volume should generate hard rock") and ok
    ok = _assert(top_cell.get("source", {}).get("import_model", "") == "actual_chunk_volume_v1", "stored volume cells should retain actual-volume source metadata") and ok
    return ok

func _test_actual_chunk_volume_import_is_deterministic_and_seeded() -> bool:
    var generated_a: Dictionary = _generated(4242)
    var generated_b: Dictionary = _generated(4242)
    var generated_c: Dictionary = _generated(9001)
    var store_a = ChunkedWorldStoreScript.new(16)
    var store_b = ChunkedWorldStoreScript.new(16)
    var store_c = ChunkedWorldStoreScript.new(16)
    store_a.import_actual_chunk_volume(generated_a["world"], Vector3i(0, -1, 0))
    store_b.import_actual_chunk_volume(generated_b["world"], Vector3i(0, -1, 0))
    store_c.import_actual_chunk_volume(generated_c["world"], Vector3i(0, -1, 0))
    var encoded_a: String = JSON.stringify(store_a.to_canonical_array())
    var encoded_b: String = JSON.stringify(store_b.to_canonical_array())
    var encoded_c: String = JSON.stringify(store_c.to_canonical_array())
    var ok: bool = true
    ok = _assert(encoded_a == encoded_b, "same seed actual chunk volume should produce identical canonical output") and ok
    ok = _assert(encoded_a != encoded_c, "different seed actual chunk volume should preserve worldgen variation") and ok
    return ok

func _test_actual_chunk_volume_rejects_chunks_outside_current_projection_bounds() -> bool:
    var generated: Dictionary = _generated(4242)
    var store = ChunkedWorldStoreScript.new(16)
    var report: Dictionary = store.import_actual_chunk_volume(generated["world"], Vector3i(1, -1, 0))
    var ok: bool = true
    ok = _assert(not bool(report.get("valid", true)), "actual chunk import should reject chunks outside the current generated XZ bounds") and ok
    ok = _assert(report.get("reason", "") == "chunk_outside_projected_xz_bounds", "out-of-bounds actual chunk import should report a stable reason") and ok
    ok = _assert(int(store.get_metadata().get("cell_count", -1)) == 0, "failed actual chunk import should leave the derived store empty") and ok
    return ok

func _test_playable_chunk_volume_maps_surface_projection_to_top_layer_without_mutation() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var before_snapshot: String = _snapshot_text(generated)
    var store = ChunkedWorldStoreScript.new(16)
    var report: Dictionary = store.import_playable_chunk_volume(world)
    var after_snapshot: String = _snapshot_text(generated)
    var metadata: Dictionary = store.get_metadata()
    var top_surface_cell: Dictionary = store.get_cell(Vector3i(4, 0, 0))
    var soil_cell: Dictionary = store.get_cell(Vector3i(4, -5, 0))
    var coal_band_cell: Dictionary = store.get_cell(Vector3i(4, -6, 0))
    var bedrock_cell: Dictionary = store.get_cell(Vector3i(4, -14, 0))
    var lava_cell: Dictionary = store.get_cell(Vector3i(4, -15, 0))
    var bottom_cell: Dictionary = store.get_cell(Vector3i(4, -15, 0))
    var projected_surface = world.get_cell(Vector2i(4, 0))
    var seen_materials: Dictionary = {}
    for stored in store.to_canonical_array():
        seen_materials[str(stored.get("payload", {}).get("material_key", ""))] = true
    var ok: bool = true
    ok = _assert(before_snapshot == after_snapshot, "importing the playable chunk volume should not mutate GridWorld") and ok
    ok = _assert(bool(report.get("valid", false)), "playable chunk volume import should succeed for the current 16x16 map") and ok
    ok = _assert(report.get("import_model", "") == "playable_chunk_volume_v1", "playable chunk import should identify its import model") and ok
    ok = _assert(bool(metadata.get("playable_chunk_volume_active", false)), "metadata should mark playable chunk volume storage as active") and ok
    ok = _assert(int(report.get("generated_cells", 0)) == 4096, "playable chunk import should fill all 16x16x16 cells") and ok
    ok = _assert(bool(top_surface_cell.get("valid", false)), "playable chunk should store the surface cell at world y 0") and ok
    ok = _assert(bool(bottom_cell.get("valid", false)) and bottom_cell.get("source", {}).get("volume_local_cell", []) == [4, 0, 0], "playable chunk bottom should retain local y 0 source metadata") and ok
    if bool(top_surface_cell.get("valid", false)) and projected_surface != null:
        ok = _assert(top_surface_cell.get("source", {}).get("volume_local_cell", []) == [4, 15, 0], "playable surface should render from local y 15") and ok
        ok = _assert(str(top_surface_cell.get("payload", {}).get("material_key", "")) == str(projected_surface.material_key), "top playable layer should use the projected surface material") and ok
        ok = _assert(str(top_surface_cell.get("payload", {}).get("strata_key", "")) == str(projected_surface.strata_key), "top playable layer should use the projected surface strata") and ok
    ok = _assert(str(soil_cell.get("payload", {}).get("material_key", "")) in ["DIRT", "CLAY", "GRAVEL"], "compressed cross-section should show soil/clay/gravel below the surface") and ok
    ok = _assert(str(coal_band_cell.get("payload", {}).get("material_key", "")) in ["SOFT_ROCK", "ORE_COAL"], "compressed cross-section should place the coal band below soil") and ok
    ok = _assert(str(bedrock_cell.get("payload", {}).get("material_key", "")) == "BEDROCK", "compressed cross-section should include bedrock above the lava floor") and ok
    ok = _assert(str(lava_cell.get("payload", {}).get("material_key", "")) == "LAVA", "compressed cross-section should include lava at the bottom") and ok
    ok = _assert(seen_materials.has("WATER_FLOW"), "compressed cross-section should render river surface cells as water flow") and ok
    ok = _assert(seen_materials.has("ORE_COPPER") and seen_materials.has("ORE_IRON") and seen_materials.has("ORE_GOLD"), "compressed cross-section should expose deeper ore bands for the renderer") and ok
    return ok

func _test_renderer_draws_playable_chunk_volume_without_mutation() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(4242)
    var surface_resource_id := "resource_chunk_surface_tree"
    sim.resources[surface_resource_id] = {"id": surface_resource_id, "type": "tree", "position": [2, 0]}
    sim.world.set_resource(Vector2i(2, 0), surface_resource_id)
    var before_hash: String = sim.state_hash()
    var renderer = WorldRendererScript.new()
    renderer.sync_from_simulation(sim)
    var after_hash: String = sim.state_hash()
    var chunk_volume: Node = renderer.get_node_or_null("ChunkVolume")
    var grass_mesh: MeshInstance3D = renderer.get_node_or_null("ChunkVolume/ChunkMesh_GRASS") as MeshInstance3D
    var water_mesh: MeshInstance3D = renderer.get_node_or_null("ChunkVolume/ChunkMesh_WATER_FLOW") as MeshInstance3D
    var lava_mesh: MeshInstance3D = renderer.get_node_or_null("ChunkVolume/ChunkMesh_LAVA") as MeshInstance3D
    var bedrock_mesh: MeshInstance3D = renderer.get_node_or_null("ChunkVolume/ChunkMesh_BEDROCK") as MeshInstance3D
    var resource_node: Node3D = renderer.get_node_or_null("Resources/TreeScatter_" + surface_resource_id) as Node3D
    var height_bounds := _surface_height_bounds(sim)
    var ok: bool = true
    ok = _assert(before_hash == after_hash, "rendering playable chunk volume should not mutate simulation state") and ok
    ok = _assert(renderer.get_node_or_null("Terrain") == null, "renderer should not create the legacy projected Terrain root") and ok
    ok = _assert(chunk_volume != null, "renderer should expose a ChunkVolume root for the playable 3D chunk") and ok
    if chunk_volume != null:
        var mesh_count: int = 0
        var bounds := AABB()
        var found_bounds: bool = false
        for child in chunk_volume.get_children():
            if child is MeshInstance3D:
                mesh_count += 1
                var child_bounds: AABB = (child as MeshInstance3D).get_aabb()
                bounds = child_bounds if not found_bounds else bounds.merge(child_bounds)
                found_bounds = true
        ok = _assert(mesh_count > 0 and mesh_count <= 16, "renderer should draw the chunk as a small set of greedy material meshes, got %d" % mesh_count) and ok
        ok = _assert(renderer.get_node_or_null("ChunkVolume/ChunkCell_00_15_00") == null, "renderer should not recreate per-cell chunk mesh instances") and ok
        if found_bounds:
            ok = _assert(absf((bounds.position.y + bounds.size.y) - float(height_bounds.y)) < 0.001, "default chunk mesh should shift whole cells to the highest elevated surface") and ok
            ok = _assert(absf(bounds.position.y - float(height_bounds.x - 16)) < 0.001, "default chunk mesh should shift whole cells to the lowest elevated column floor") and ok
    ok = _assert(grass_mesh != null and grass_mesh.mesh is ArrayMesh, "surface material should render as a greedy ArrayMesh") and ok
    ok = _assert(water_mesh != null and water_mesh.mesh is ArrayMesh, "river surface water should render as a greedy ArrayMesh") and ok
    ok = _assert(lava_mesh != null and lava_mesh.mesh is ArrayMesh, "bottom lava material should render in the greedy chunk mesh") and ok
    ok = _assert(bedrock_mesh != null and bedrock_mesh.mesh is ArrayMesh, "bedrock material should render in the greedy chunk mesh") and ok
    ok = _assert(resource_node != null and resource_node.visible, "surface resources should render through the chunk-local resource path") and ok
    if resource_node != null:
        ok = _assert(absf(resource_node.position.x - 2.0) < 0.15 and absf(resource_node.position.z - 0.0) < 0.15, "surface resources should use chunk-local x/z coordinates with small scatter offsets") and ok
        var expected_tree_y: float = float(sim.world.get_surface_height(Vector2i(2, 0)))
        ok = _assert(absf(resource_node.position.y - expected_tree_y) < 0.001, "tree resources should stand on the elevated cell surface") and ok
        ok = _assert(resource_node.get_node_or_null("Trunk") != null and resource_node.get_node_or_null("CanopyLower") != null, "tree resources should render as scatter parts instead of a single old cube") and ok
    renderer.free()
    return ok

func _test_chunk_volume_cutaway_hides_top_local_layers() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(4242)
    var surface_resource_id := "resource_cutaway_tree"
    sim.resources[surface_resource_id] = {"id": surface_resource_id, "type": "tree", "position": [2, 0]}
    sim.world.set_resource(Vector2i(2, 0), surface_resource_id)
    var renderer = WorldRendererScript.new()
    renderer.set_layer_cutaway_depth(-1)
    renderer.sync_from_simulation(sim)
    var chunk_volume: Node = renderer.get_node_or_null("ChunkVolume")
    var hidden_resource: Node3D = renderer.get_node_or_null("Resources/TreeScatter_" + surface_resource_id) as Node3D
    var height_bounds := _surface_height_bounds(sim)
    var mesh_count: int = 0
    var bounds := AABB()
    var found_bounds: bool = false
    if chunk_volume != null:
        for child in chunk_volume.get_children():
            if child is MeshInstance3D:
                mesh_count += 1
                var child_bounds: AABB = (child as MeshInstance3D).get_aabb()
                bounds = child_bounds if not found_bounds else bounds.merge(child_bounds)
                found_bounds = true
    var ok: bool = true
    ok = _assert(chunk_volume != null and mesh_count > 0 and mesh_count <= 16, "chunk cutaway should keep the greedy mesh node set small") and ok
    ok = _assert(renderer.get_node_or_null("ChunkVolume/ChunkCell_00_15_00") == null, "chunk cutaway should not recreate per-cell chunk nodes") and ok
    if found_bounds:
        ok = _assert(absf((bounds.position.y + bounds.size.y) - float(height_bounds.y - 1)) < 0.001, "chunk cutaway depth -1 should expose one full cell below each elevated surface") and ok
    ok = _assert(hidden_resource != null and not hidden_resource.visible, "chunk cutaway depth -1 should hide resources standing on local y 15") and ok
    renderer.free()
    return ok

func _test_chunked_world_store_debug_comparison_accepts_matching_projection() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var store = ChunkedWorldStoreScript.new(16)
    store.import_projected_world(world)
    var before_snapshot: String = _snapshot_text(generated)
    var report: Dictionary = store.compare_projected_world(world)
    var after_snapshot: String = _snapshot_text(generated)
    var cell_report: Dictionary = store.compare_projected_cell(world, Vector2i(4, 8))
    var ok: bool = true
    ok = _assert(before_snapshot == after_snapshot, "debug comparison should not mutate projected world") and ok
    ok = _assert(bool(report.get("valid", false)), "debug comparison should accept a matching chunk store") and ok
    ok = _assert(int(report.get("inspected_cells", 0)) == world.width * world.height, "debug comparison should inspect every projected cell") and ok
    ok = _assert(int(report.get("mismatch_count", -1)) == 0, "matching projection/store comparison should have no mismatches") and ok
    ok = _assert(int(report.get("missing_count", -1)) == 0, "matching projection/store comparison should have no missing cells") and ok
    ok = _assert(int(report.get("extra_count", -1)) == 0, "matching projection/store comparison should have no extra cells") and ok
    ok = _assert(bool(cell_report.get("valid", false)), "single-cell debug comparison should accept matching data") and ok
    return ok

func _test_chunked_world_store_debug_comparison_reports_payload_mismatch() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var store = ChunkedWorldStoreScript.new(16)
    store.import_projected_world(world)
    var view: Dictionary = world.get_projected_cell_storage_view(Vector2i(4, 8))
    var world_cell := ChunkAddressingScript.array_to_vector3i(view.get("world_cell", []))
    var stored: Dictionary = store.get_cell(world_cell)
    var payload: Dictionary = stored.get("payload", {}).duplicate(true)
    payload["material_key"] = "BROKEN_MATERIAL"
    store.set_cell(world_cell, payload, stored.get("source", {}).duplicate(true))
    var cell_report: Dictionary = store.compare_projected_cell(world, Vector2i(4, 8))
    var world_report: Dictionary = store.compare_projected_world(world)
    var found_material_mismatch: bool = false
    for mismatch in cell_report.get("mismatches", []):
        if str(mismatch.get("type", "")) == "payload_mismatch" and str(mismatch.get("field", "")) == "material_key":
            found_material_mismatch = true
    var ok: bool = true
    ok = _assert(not bool(cell_report.get("valid", true)), "single-cell debug comparison should fail when payload diverges") and ok
    ok = _assert(found_material_mismatch, "debug comparison should report the mismatched payload field") and ok
    ok = _assert(not bool(world_report.get("valid", true)), "world debug comparison should fail when any payload diverges") and ok
    ok = _assert(int(world_report.get("mismatch_count", 0)) > 0, "world debug comparison should count payload mismatches") and ok
    return ok

func _test_chunked_world_store_debug_comparison_reports_missing_and_extra_cells() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var empty_store = ChunkedWorldStoreScript.new(16)
    var missing_report: Dictionary = empty_store.compare_projected_world(world, 5)
    var extra_store = ChunkedWorldStoreScript.new(16)
    extra_store.import_projected_world(world)
    extra_store.set_cell(Vector3i(99, 99, 99), {"material_key": "DEBUG_EXTRA"}, {})
    var extra_report: Dictionary = extra_store.compare_projected_world(world, 5)
    var ok: bool = true
    ok = _assert(not bool(missing_report.get("valid", true)), "empty store comparison should report missing projected cells") and ok
    ok = _assert(int(missing_report.get("missing_count", 0)) == world.width * world.height, "missing comparison should count every absent projected cell") and ok
    ok = _assert(missing_report.get("mismatches", []).size() == 5, "missing comparison should respect mismatch output limits") and ok
    ok = _assert(not bool(extra_report.get("valid", true)), "store comparison should report extra chunk cells") and ok
    ok = _assert(int(extra_report.get("extra_count", 0)) == 1, "extra comparison should count cells outside the projection") and ok
    return ok

func _test_packed_cell_codec_round_trips_current_payloads() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var store = ChunkedWorldStoreScript.new(16)
    store.import_projected_world(world)
    var validation: Dictionary = store.validate_packed_payloads()
    var ok: bool = true
    ok = _assert(bool(validation.get("valid", false)), "packed payload validation should accept imported projection cells") and ok
    ok = _assert(int(validation.get("inspected_cells", 0)) == world.width * world.height, "packed payload validation should inspect every stored cell") and ok
    ok = _assert(int(validation.get("mismatch_count", -1)) == 0, "packed payloads should unpack to the dictionary payloads") and ok
    for stored in store.to_canonical_array():
        var packed_payload: Dictionary = stored.get("packed_payload", {})
        var unpacked: Dictionary = PackedCellCodecScript.unpack_payload(packed_payload)
        ok = _assert(str(packed_payload.get("schema", "")) == "ironveil_packed_cell_v1", "stored cells should carry packed payload schema") and ok
        ok = _assert(unpacked == stored.get("payload", {}), "packed payload should unpack back to the stored dictionary payload") and ok
    return ok

func _test_packed_cell_codec_uses_sidecars_for_unmapped_values() -> bool:
    var payload: Dictionary = {
        "terrain": "custom_terrain",
        "material_key": "CUSTOM_MATERIAL",
        "strata_key": "custom_strata",
        "mining_tier_required": 7,
        "resource_id": "resource_custom",
        "hidden_mine_yield": {"item_type": "custom_ore", "quantity": 3},
        "is_river": true,
        "water_feature": "custom_water",
        "is_cave": true,
        "cave_id": "cave_custom",
        "exposure": "custom_exposure",
        "surface_height": -12,
        "slope_degrees": 42,
    }
    var packed_payload: Dictionary = PackedCellCodecScript.pack_payload(payload)
    var unpacked: Dictionary = PackedCellCodecScript.unpack_payload(packed_payload)
    var refs: Dictionary = packed_payload.get("refs", {})
    var ok: bool = true
    ok = _assert(unpacked == payload, "packed payload sidecars should preserve unmapped compatibility strings") and ok
    ok = _assert(refs.get("material_key", "") == "CUSTOM_MATERIAL", "packed payload should sidecar unmapped material keys") and ok
    ok = _assert(refs.get("terrain", "") == "custom_terrain", "packed payload should sidecar unmapped terrain strings") and ok
    ok = _assert(refs.get("strata_key", "") == "custom_strata", "packed payload should sidecar unmapped strata strings") and ok
    ok = _assert(refs.get("water_feature", "") == "custom_water", "packed payload should sidecar unmapped water features") and ok
    ok = _assert(refs.get("exposure", "") == "custom_exposure", "packed payload should sidecar unmapped exposure values") and ok
    return ok

func _test_chunk_store_comparator_reports_corrupt_packed_payloads() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var store = ChunkedWorldStoreScript.new(16)
    store.import_projected_world(world)
    var view: Dictionary = world.get_projected_cell_storage_view(Vector2i(4, 8))
    var world_cell := ChunkAddressingScript.array_to_vector3i(view.get("world_cell", []))
    var stored: Dictionary = store.get_cell(world_cell)
    var corrupt_packed: Dictionary = stored.get("packed_payload", {}).duplicate(true)
    corrupt_packed["word0"] = int(corrupt_packed.get("word0", 0)) ^ 0xff
    var chunk := ChunkAddressingScript.array_to_vector3i(stored.get("chunk_cell", []))
    var local := ChunkAddressingScript.array_to_vector3i(stored.get("local_cell", []))
    var chunk_key: String = str(chunk.x) + "," + str(chunk.y) + "," + str(chunk.z)
    var local_key: String = str(local.x) + "," + str(local.y) + "," + str(local.z)
    store.chunks[chunk_key]["cells"][local_key]["packed_payload"] = corrupt_packed
    var cell_report: Dictionary = store.compare_projected_cell(world, Vector2i(4, 8))
    var validation: Dictionary = store.validate_packed_payloads()
    var found_packed_mismatch: bool = false
    for mismatch in cell_report.get("mismatches", []):
        if str(mismatch.get("type", "")) == "packed_payload_mismatch":
            found_packed_mismatch = true
    var ok: bool = true
    ok = _assert(not bool(cell_report.get("valid", true)), "projection comparator should fail when packed payload diverges") and ok
    ok = _assert(found_packed_mismatch, "projection comparator should report packed payload mismatches") and ok
    ok = _assert(not bool(validation.get("valid", true)), "packed payload validation should fail on corrupt packed data") and ok
    ok = _assert(int(validation.get("mismatch_count", 0)) > 0, "packed payload validation should count corrupt packed data") and ok
    return ok

func _test_worldgen_storage_diagnostics_report_is_read_only() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(4242)
    var before_hash: String = sim.state_hash()
    var report: Dictionary = sim.get_worldgen_storage_diagnostics()
    var after_hash: String = sim.state_hash()
    var lines: Array[String] = WorldgenDiagnosticsScript.format_report(report)
    var ok: bool = true
    ok = _assert(before_hash == after_hash, "worldgen storage diagnostics should not mutate simulation state") and ok
    ok = _assert(bool(report.get("valid", false)), "worldgen storage diagnostics should pass for a fresh simulation world") and ok
    ok = _assert(str(report.get("summary", "")).begins_with("Worldgen storage diagnostics passed"), "diagnostics should include a concise pass summary") and ok
    ok = _assert(lines.size() >= 4, "diagnostics should format stable log lines") and ok
    ok = _assert(lines[0] == str(report.get("summary", "")), "first diagnostics log line should be the summary") and ok
    ok = _assert(str(lines[1]).contains("import valid=true"), "diagnostics log should include import status") and ok
    ok = _assert(str(lines[2]).contains("projection valid=true"), "diagnostics log should include projection comparison status") and ok
    ok = _assert(str(lines[3]).contains("packed valid=true"), "diagnostics log should include packed validation status") and ok
    return ok

func _test_worldgen_storage_diagnostics_reports_corrupt_store() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var store = ChunkedWorldStoreScript.new(16)
    var import_report: Dictionary = store.import_projected_world(world)
    var view: Dictionary = world.get_projected_cell_storage_view(Vector2i(4, 8))
    var stored: Dictionary = store.get_cell(ChunkAddressingScript.array_to_vector3i(view.get("world_cell", [])))
    var chunk := ChunkAddressingScript.array_to_vector3i(stored.get("chunk_cell", []))
    var local := ChunkAddressingScript.array_to_vector3i(stored.get("local_cell", []))
    var chunk_key: String = str(chunk.x) + "," + str(chunk.y) + "," + str(chunk.z)
    var local_key: String = str(local.x) + "," + str(local.y) + "," + str(local.z)
    store.chunks[chunk_key]["cells"][local_key]["packed_payload"] = {"schema": "broken_packed_schema"}
    var report: Dictionary = WorldgenDiagnosticsScript.build_storage_report_for_store(world, store, import_report)
    var lines: Array[String] = WorldgenDiagnosticsScript.format_report(report)
    var ok: bool = true
    ok = _assert(not bool(report.get("valid", true)), "diagnostics should fail when chunk-store packed payloads are corrupt") and ok
    ok = _assert(str(report.get("summary", "")).begins_with("Worldgen storage diagnostics failed"), "diagnostics should include a concise failure summary") and ok
    ok = _assert(int(report.get("packed_validation", {}).get("mismatch_count", 0)) > 0, "diagnostics should surface packed validation mismatches") and ok
    ok = _assert(str(lines[3]).contains("packed valid=false"), "diagnostics log should show failed packed validation") and ok
    return ok

func _test_chunked_world_read_adapter_matches_standalone_projection_import() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var adapter = ChunkedWorldReadAdapterScript.new()
    adapter.import_projected_world(world)
    var metadata: Dictionary = adapter.get_metadata()
    var sample_cells: Array[Vector2i] = [Vector2i(4, 0), Vector2i(4, 8), Vector2i(0, 13)]
    var river_cells: Array[Vector2i] = world.get_river_cells()
    if not river_cells.is_empty():
        sample_cells.append(river_cells[0])
    var cave_cells: Array[Vector2i] = world.get_cave_cells()
    if not cave_cells.is_empty():
        sample_cells.append(cave_cells[0])
    var ok: bool = true
    ok = _assert(bool(adapter.is_available()), "chunk read adapter should be available after a valid projection import") and ok
    ok = _assert(metadata.get("adapter_model", "") == "chunked_world_read_adapter_v1", "adapter should expose its model") and ok
    ok = _assert(bool(metadata.get("read_only", false)), "adapter should identify as read-only") and ok
    ok = _assert(not bool(metadata.get("authoritative", true)), "standalone projection adapter should not claim simulation authority") and ok
    for pos in sample_cells:
        var projected = world.get_cell(pos)
        var read: Dictionary = adapter.get_cell_by_projected_cell(pos)
        ok = _assert(bool(read.get("valid", false)), "adapter should read projected cells from chunk storage") and ok
        ok = _assert(read.get("projected_cell", []) == [pos.x, pos.y], "adapter should preserve projected coordinates") and ok
        ok = _assert(str(read.get("terrain", "")) == str(projected.terrain), "adapter terrain should match GridWorld") and ok
        ok = _assert(str(read.get("material_key", "")) == str(projected.material_key), "adapter material should match GridWorld") and ok
        ok = _assert(str(read.get("strata_key", "")) == str(projected.strata_key), "adapter strata should match GridWorld") and ok
        ok = _assert(int(read.get("projection_depth", 0)) == int(projected.depth), "adapter depth should match GridWorld") and ok
        ok = _assert(int(read.get("surface_height", 0)) == int(projected.surface_height), "adapter height should match GridWorld") and ok
        ok = _assert(int(read.get("slope_degrees", 0)) == int(projected.slope_degrees), "adapter slope should match GridWorld") and ok
        ok = _assert(bool(read.get("is_river", false)) == bool(projected.is_river), "adapter river flag should match GridWorld") and ok
        ok = _assert(bool(read.get("is_cave", false)) == bool(projected.is_cave), "adapter cave flag should match GridWorld") and ok
        var by_world: Dictionary = adapter.get_cell_by_world_cell(ChunkAddressingScript.array_to_vector3i(read.get("world_cell", [])))
        ok = _assert(by_world.get("projected_cell", []) == [pos.x, pos.y], "adapter world-cell reads should resolve to the same projected source") and ok
    return ok

func _test_chunked_world_read_adapter_is_read_only_for_simulation_state() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(4242)
    var before_hash: String = sim.state_hash()
    var adapter = sim.get_chunked_world_read_adapter()
    var metadata: Dictionary = adapter.get_metadata()
    var read: Dictionary = adapter.get_cell_by_projected_cell(Vector2i(4, 8))
    read["material_key"] = "MUTATED_READ_RESULT"
    read["hidden_mine_yield"] = {"item_type": "mutated"}
    var second_read: Dictionary = adapter.get_cell_by_projected_cell(Vector2i(4, 8))
    var after_hash: String = sim.state_hash()
    var ok: bool = true
    ok = _assert(bool(metadata.get("authoritative", false)), "simulation chunk adapter should read from the authoritative gameplay chunk store") and ok
    ok = _assert(before_hash == after_hash, "building and reading chunk adapter should not mutate simulation state") and ok
    ok = _assert(str(second_read.get("material_key", "")) != "MUTATED_READ_RESULT", "mutating an adapter read result should not mutate adapter storage") and ok
    ok = _assert(str(sim.world.get_cell(Vector2i(4, 8)).material_key) == str(second_read.get("material_key", "")), "adapter should continue to mirror GridWorld after read-result mutation") and ok
    return ok

func _test_authoritative_chunk_store_tracks_gameplay_mining() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(4242)
    var target := Vector2i(4, 1)
    var validation: Dictionary = sim.validate_designation_target("mine", target)
    sim.queue_command(1, "player_001", "DESIGNATE_MINE", target, {"priority": 5})
    _step_ticks(sim, 48)
    var adapter = sim.get_chunked_world_read_adapter()
    var read: Dictionary = adapter.get_cell_by_projected_cell(target)
    var projected = sim.world.get_cell(target)
    var ok: bool = true
    ok = _assert(bool(validation.get("valid", false)), "precondition: selected gameplay cell should be mineable") and ok
    ok = _assert(bool(adapter.get_metadata().get("authoritative", false)), "post-gameplay adapter should be backed by the authoritative store") and ok
    ok = _assert(str(read.get("terrain", "")) == "excavated", "authoritative chunk store should own mined terrain state") and ok
    ok = _assert(str(read.get("material_key", "")) == "AIR", "authoritative chunk store should own mined material state") and ok
    ok = _assert(str(projected.terrain) == str(read.get("terrain", "")) and str(projected.material_key) == str(read.get("material_key", "")), "projected GridWorld should mirror authoritative chunk gameplay state") and ok
    return ok

func _test_chunked_world_read_adapter_projection_snapshot_and_bounds() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var adapter = ChunkedWorldReadAdapterScript.new()
    adapter.import_projected_world(world)
    var snapshot: Array = adapter.to_projection_payload_array()
    var invalid_negative: Dictionary = adapter.get_cell_by_projected_cell(Vector2i(-1, 0))
    var invalid_past_end: Dictionary = adapter.get_cell_by_projected_cell(Vector2i(16, 16))
    var ok: bool = true
    ok = _assert(snapshot.size() == world.width * world.height, "adapter projection snapshot should include every projected cell") and ok
    ok = _assert(snapshot[0].get("projected_cell", []) == [0, 0], "adapter projection snapshot should be sorted by projected row and column") and ok
    ok = _assert(snapshot[snapshot.size() - 1].get("projected_cell", []) == [15, 15], "adapter projection snapshot should end at the final projected cell") and ok
    ok = _assert(not bool(invalid_negative.get("valid", true)), "adapter should reject negative projected coordinates") and ok
    ok = _assert(invalid_negative.get("reason", "") == "projected_cell_out_of_bounds", "adapter negative bounds failure should be explicit") and ok
    ok = _assert(not bool(invalid_past_end.get("valid", true)), "adapter should reject projected coordinates past dimensions") and ok
    ok = _assert(invalid_past_end.get("reason", "") == "projected_cell_out_of_bounds", "adapter max bounds failure should be explicit") and ok
    return ok

func _test_deep_hazards_are_deferred_until_true_vertical_world() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var policy: Dictionary = world.get_deep_hazard_policy()
    var ok: bool = true
    ok = _assert(GridWorldScript.MATERIAL_LAVA == "LAVA", "GridWorld should expose future LAVA material key") and ok
    ok = _assert(not bool(policy.get("enabled", true)), "bedrock and lava hazards should be disabled for early gameplay") and ok
    ok = _assert(policy.get("deferred_until_storage_model", "") == "chunked_3d_v1", "deep hazards should wait for true 3D chunk storage") and ok
    ok = _assert(policy.get("future_materials", []).has("BEDROCK") and policy.get("future_materials", []).has("LAVA"), "hazard policy should reserve bedrock and lava as future materials") and ok
    ok = _assert(policy.get("blocked_by", []).has("pathing_support"), "deep hazards should stay gated on pathing support") and ok
    ok = _assert(policy.get("blocked_by", []).has("mining_support"), "deep hazards should stay gated on mining support") and ok
    ok = _assert(policy.get("blocked_by", []).has("fluid_rules"), "lava should stay gated on fluid rules") and ok
    ok = _assert(_cells_with_material(world, "BEDROCK").is_empty(), "current projection should not generate bedrock cells") and ok
    ok = _assert(_cells_with_material(world, "LAVA").is_empty(), "current projection should not generate lava cells") and ok
    ok = _assert(not world.is_material_mineable_with_tier(GridWorldScript.MATERIAL_BEDROCK, 99), "bedrock should remain unmineable while deferred") and ok
    ok = _assert(not world.is_material_mineable_with_tier(GridWorldScript.MATERIAL_LAVA, 99), "lava should not be a mineable material") and ok
    for z in range(world.height):
        for x in range(world.width):
            var cell = world.get_cell(Vector2i(x, z))
            ok = _assert(cell.material_key != "BEDROCK" and cell.material_key != "LAVA", "deep hazard materials should not appear in generated cells") and ok
            ok = _assert(cell.terrain != "lava" and cell.terrain != "bedrock", "deep hazards should not add early terrain strings") and ok
    return ok

func _test_cell_material_vocabulary_matches_ironveil_keys() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var resources: Dictionary = generated["resources"]
    var ok: bool = true
    ok = _assert(world.get_cell(Vector2i(0, 0)).terrain == "dirt" and world.get_cell(Vector2i(0, 0)).material_key == "DIRT", "starting dirt cells should keep terrain compatibility and use DIRT material") and ok
    ok = _assert(world.get_cell(Vector2i(4, 0)).terrain == "grass" and world.get_cell(Vector2i(4, 0)).material_key == "GRASS", "surface cells should keep grass terrain and use GRASS material") and ok
    ok = _assert(world.get_cell(Vector2i(4, 8)).terrain == "rock" and world.get_cell(Vector2i(4, 8)).material_key == "SOFT_ROCK", "shallow stone layer should keep rock terrain and use SOFT_ROCK material") and ok
    ok = _assert(world.get_cell(Vector2i(0, 13)).terrain == "solid_rock" and world.get_cell(Vector2i(0, 13)).material_key == "HARD_ROCK", "deep solid layer should keep solid_rock terrain and use HARD_ROCK material") and ok
    ok = _assert(GridWorldScript.MATERIAL_AIR == "AIR", "GridWorld should expose AIR material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_DIRT == "DIRT", "GridWorld should expose DIRT material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_CLAY == "CLAY", "GridWorld should expose CLAY material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_GRAVEL == "GRAVEL", "GridWorld should expose GRAVEL material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_SOFT_ROCK == "SOFT_ROCK", "GridWorld should expose SOFT_ROCK material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_HARD_ROCK == "HARD_ROCK", "GridWorld should expose HARD_ROCK material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_BEDROCK == "BEDROCK", "GridWorld should expose BEDROCK material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_LAVA == "LAVA", "GridWorld should expose future LAVA material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_GRASS == "GRASS", "GridWorld should expose GRASS material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_LOOSE_STONE == "LOOSE_STONE", "GridWorld should expose LOOSE_STONE material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_TREE_OAK == "TREE_OAK", "GridWorld should expose TREE_OAK material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_TREE_PINE == "TREE_PINE", "GridWorld should expose TREE_PINE material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_BERRY_BUSH == "BERRY_BUSH", "GridWorld should expose BERRY_BUSH material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_WILD_WHEAT == "WILD_WHEAT", "GridWorld should expose WILD_WHEAT material key") and ok
    ok = _assert(GridWorldScript.MATERIAL_ORE_IRON == "ORE_IRON", "GridWorld should expose future ore material keys") and ok
    for id in resources.keys():
        var resource: Dictionary = resources[id]
        var material_key: String = str(resource.get("material_key", ""))
        if resource.get("type", "") == "tree":
            ok = _assert(material_key in ["TREE_OAK", "TREE_PINE"], "tree resources should use tree material keys") and ok
        elif resource.get("type", "") == "berry":
            ok = _assert(material_key == "BERRY_BUSH", "berry resources should use BERRY_BUSH material") and ok
        elif resource.get("type", "") == "stone":
            ok = _assert(material_key == "LOOSE_STONE", "stone resources should use LOOSE_STONE material") and ok
    return ok

func _test_resource_constraints_follow_ironveil_surface_rules() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var resources: Dictionary = generated["resources"]
    var ok: bool = true
    ok = _assert(_count_resources(resources, "tree") > 0, "Ironveil worldgen should place tree resources") and ok
    ok = _assert(_count_resources(resources, "berry") > 0, "Ironveil worldgen should place berry resources") and ok
    ok = _assert(_count_resources(resources, "stone") > 0, "Ironveil worldgen should place loose stone resources") and ok
    var deepest_scatter_row: int = 0
    for id in resources.keys():
        var resource: Dictionary = resources[id]
        var pos: Array = resource["position"]
        var cell = world.get_cell(Vector2i(int(pos[0]), int(pos[1])))
        deepest_scatter_row = maxi(deepest_scatter_row, int(pos[1]))
        ok = _assert(cell != null, "resource index positions must stay inside world bounds for " + str(id)) and ok
        if cell != null and str(cell.resource_id) != "":
            ok = _assert(str(cell.resource_id) == str(id), "legacy surface cell resource id must agree for " + str(id)) and ok
        ok = _assert(str(resource.get("worldgen_profile", "")) == "ironveil_layered_v1", "generated resources should carry their worldgen profile") and ok
        ok = _assert(bool(resource.get("surface", false)), "scatter resources should be marked as visible surface features") and ok
        ok = _assert(int(resource.get("layer", 0)) == GridWorldScript.SURFACE_LAYER, "scatter resources should use surface-layer metadata even when placed across the full x/z surface") and ok
        if resource["type"] == "stone":
            ok = _assert(int(cell.slope_degrees) < 45, "loose stone scatter should use slope metadata") and ok
        if resource["type"] == "tree":
            ok = _assert(int(cell.slope_degrees) < 35, "tree scatter should use slope metadata") and ok
        if resource["type"] == "berry":
            ok = _assert(int(cell.slope_degrees) < 20, "berry scatter should use slope metadata") and ok
        ok = _assert(not (int(pos[0]) <= 5 and int(pos[1]) <= 3), "starting workyard should remain clear of generated resources") and ok
    ok = _assert(deepest_scatter_row >= int(world.height / 2), "surface scatter should generate across the full visible x/z surface, not just old surface projection rows") and ok
    return ok

func _test_legacy_gathering_still_reads_resource_type_and_terrain() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(4242)
    var tree_pos: Vector2i = _first_resource_position(sim.resources, "tree")
    var berry_pos: Vector2i = _first_resource_position(sim.resources, "berry")
    if not _assert(tree_pos != Vector2i(-1, -1) and berry_pos != Vector2i(-1, -1), "precondition: generated world should include tree and berry resources"):
        return false
    sim.queue_command(1, "player_001", "DESIGNATE_CHOP", tree_pos, {"priority": 5})
    sim.queue_command(2, "player_001", "DESIGNATE_GATHER_FOOD", berry_pos, {"priority": 5})
    _step_ticks(sim, 96)
    var ok: bool = true
    ok = _assert(_count_items_of_type(sim, "wood") == 1, "legacy chop job should still produce wood after material migration") and ok
    ok = _assert(_count_items_of_type(sim, "food") == 1, "legacy berry gather should still produce food after material migration") and ok
    ok = _assert(sim.world.get_cell(tree_pos).terrain == "grass" and sim.world.get_cell(tree_pos).material_key == "GRASS", "depleted tree cell should return to grass terrain/material compatibility") and ok
    ok = _assert(sim.world.get_cell(berry_pos).terrain == "grass" and sim.world.get_cell(berry_pos).material_key == "GRASS", "depleted berry cell should return to grass terrain/material compatibility") and ok
    return ok

func _test_legacy_mining_and_pathing_still_use_terrain_fields() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(4242)
    var target := Vector2i(4, 1)
    var cell = sim.world.get_cell(target)
    cell.terrain = "grass"
    cell.material_key = "GRASS"
    cell.resource_id = ""
    var validation: Dictionary = sim.validate_designation_target("mine", target)
    sim.queue_command(1, "player_001", "DESIGNATE_MINE", target, {"priority": 5})
    _step_ticks(sim, 48)
    var path_step: Vector2i = sim._step_towards(Vector2i(1, 1), Vector2i(2, 1))
    var ok: bool = true
    ok = _assert(bool(validation.get("valid", false)), "legacy mine validation should still accept terrain grass") and ok
    ok = _assert(cell.terrain == "excavated" and cell.material_key == "AIR", "legacy mining should excavate terrain and migrate material to AIR") and ok
    ok = _assert(_count_items_of_type(sim, "dirt") == 1, "legacy mining should still produce dirt from grass terrain") and ok
    ok = _assert(path_step == Vector2i(2, 1), "legacy pathing should still move over terrain-compatible cells") and ok
    return ok

func _test_hidden_shallow_ore_mining_produces_seeded_item_output() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(4242)
    var ore_targets: Array[Vector2i] = _hidden_yield_cells(sim.world, "coal")
    if ore_targets.is_empty():
        ore_targets = _hidden_yield_cells(sim.world, "copper_ore")
    if not _assert(not ore_targets.is_empty(), "precondition: seeded world should include a hidden tier-1 ore output"):
        return false
    var target: Vector2i = ore_targets[0]
    var cell = sim.world.get_cell(target)
    var expected_type: String = str(cell.hidden_mine_yield.get("item_type", ""))
    var expected_quantity: int = int(cell.hidden_mine_yield.get("quantity", 1))
    _excavate_access_column(sim, target)

    var validation: Dictionary = sim.validate_designation_target("mine", target)
    sim.queue_command(1, "player_001", "DESIGNATE_MINE", target, {"priority": 5})
    _step_ticks(sim, 96)

    var ok: bool = true
    ok = _assert(bool(validation.get("valid", false)), "tier-1 mine designation should accept hidden shallow ore host rock") and ok
    ok = _assert(_count_items_of_type(sim, expected_type) == expected_quantity, "mining hidden shallow ore should produce its seeded item output") and ok
    ok = _assert(sim.world.get_cell(target).hidden_mine_yield.is_empty(), "mining should clear hidden ore yield from the excavated cell") and ok
    ok = _assert(sim.world.get_cell(target).material_key == "AIR", "mining hidden ore should excavate the host cell") and ok
    return ok

func _test_gravel_and_clay_mining_outputs_use_hydrology_materials() -> bool:
    var gravel_sim = SimulationScript.new()
    gravel_sim.initialize_new_game(4242)
    var gravel_targets: Array[Vector2i] = gravel_sim.world.get_river_cells()
    if not _assert(not gravel_targets.is_empty(), "precondition: generated world should include river gravel"):
        return false
    var gravel_target: Vector2i = gravel_targets[0]
    gravel_sim.queue_command(1, "player_001", "DESIGNATE_MINE", gravel_target, {"priority": 5})
    _step_ticks(gravel_sim, 64)

    var clay_sim = SimulationScript.new()
    clay_sim.initialize_new_game(4242)
    var clay_targets: Array[Vector2i] = _cells_with_material(clay_sim.world, "CLAY")
    if not _assert(not clay_targets.is_empty(), "precondition: generated world should include riverbank clay"):
        return false
    var clay_target: Vector2i = clay_targets[0]
    _excavate_access_column(clay_sim, clay_target)
    clay_sim.queue_command(1, "player_001", "DESIGNATE_MINE", clay_target, {"priority": 5})
    _step_ticks(clay_sim, 96)

    var ok: bool = true
    ok = _assert(_count_items_of_type(gravel_sim, "gravel") == 1, "mining riverbed gravel should produce gravel") and ok
    ok = _assert(gravel_sim.world.get_cell(gravel_target).material_key == "AIR", "mined gravel riverbed should excavate") and ok
    ok = _assert(_count_items_of_type(clay_sim, "clay") == 1, "mining riverbank clay should produce clay") and ok
    ok = _assert(clay_sim.world.get_cell(clay_target).material_key == "AIR", "mined clay riverbank should excavate") and ok
    return ok

func run() -> bool:
    return _test_seeded_ironveil_generation_is_deterministic() \
        and _test_create_forest_compatibility_uses_ironveil_generator() \
        and _test_ironveil_layer_projection_shape() \
        and _test_explicit_strata_rules_and_mining_tiers() \
        and _test_seeded_hidden_ore_pass_places_current_ores_only() \
        and _test_height_map_and_slope_metadata_are_deterministic() \
        and _test_seeded_river_map_applies_gravel_and_clay_without_fishing_spots() \
        and _test_seeded_cave_voids_expose_underground_projection() \
        and _test_storage_metadata_tracks_current_projection_and_future_chunks() \
        and _test_chunk_addressing_handles_signed_world_cells() \
        and _test_projection_to_chunk_boundary_preserves_existing_cell_metadata() \
        and _test_chunk_boundary_rejects_invalid_projection_coordinates() \
        and _test_chunked_world_store_imports_projection_without_mutation() \
        and _test_chunked_world_store_preserves_projected_cell_payloads() \
        and _test_chunked_world_store_canonical_output_is_deterministic() \
        and _test_actual_chunk_volume_import_fills_one_3d_chunk_without_mutation() \
        and _test_actual_chunk_volume_import_is_deterministic_and_seeded() \
        and _test_actual_chunk_volume_rejects_chunks_outside_current_projection_bounds() \
        and _test_playable_chunk_volume_maps_surface_projection_to_top_layer_without_mutation() \
        and _test_renderer_draws_playable_chunk_volume_without_mutation() \
        and _test_chunk_volume_cutaway_hides_top_local_layers() \
        and _test_chunked_world_store_debug_comparison_accepts_matching_projection() \
        and _test_chunked_world_store_debug_comparison_reports_payload_mismatch() \
        and _test_chunked_world_store_debug_comparison_reports_missing_and_extra_cells() \
        and _test_packed_cell_codec_round_trips_current_payloads() \
        and _test_packed_cell_codec_uses_sidecars_for_unmapped_values() \
        and _test_chunk_store_comparator_reports_corrupt_packed_payloads() \
        and _test_worldgen_storage_diagnostics_report_is_read_only() \
        and _test_worldgen_storage_diagnostics_reports_corrupt_store() \
        and _test_chunked_world_read_adapter_matches_standalone_projection_import() \
        and _test_chunked_world_read_adapter_is_read_only_for_simulation_state() \
        and _test_authoritative_chunk_store_tracks_gameplay_mining() \
        and _test_chunked_world_read_adapter_projection_snapshot_and_bounds() \
        and _test_deep_hazards_are_deferred_until_true_vertical_world() \
        and _test_cell_material_vocabulary_matches_ironveil_keys() \
        and _test_resource_constraints_follow_ironveil_surface_rules() \
        and _test_legacy_gathering_still_reads_resource_type_and_terrain() \
        and _test_legacy_mining_and_pathing_still_use_terrain_fields() \
        and _test_hidden_shallow_ore_mining_produces_seeded_item_output() \
        and _test_gravel_and_clay_mining_outputs_use_hydrology_materials()
