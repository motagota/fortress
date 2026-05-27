extends RefCounted

const SimulationScript = preload("res://scripts/simulation/simulation.gd")
const ItemScript = preload("res://scripts/simulation/item.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func run() -> bool:
    var ok: bool = true
    ok = _test_stockpile_creation_sorts_cells_and_filters() and ok
    ok = _test_stockpile_designation_uses_explicit_zone_cells() and ok
    ok = _test_stockpile_designation_rejects_overlapping_zones() and ok
    ok = _test_stockpile_resize_expands_and_shrinks_bounds() and ok
    ok = _test_stockpile_resize_rejects_overlap_with_other_zones() and ok
    ok = _test_stockpile_resize_rejects_occupied_shrink_edges() and ok
    ok = _test_stockpile_modes_control_storage_and_supply() and ok
    ok = _test_stockpile_mode_command_updates_canonical_state() and ok
    ok = _test_item_reservations_are_unique_and_releasable() and ok
    ok = _test_stockpiles_and_reservations_are_canonical_snapshot_state() and ok
    return ok

func _test_stockpile_creation_sorts_cells_and_filters() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(7)
    var stockpile_id: String = sim.create_stockpile([Vector2i(4, 4), Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 2)], ["wood", "stone"])
    var stockpile = sim.stockpiles[stockpile_id]
    var snapshot: Dictionary = stockpile.to_canonical_dict()
    var ok: bool = true
    ok = _assert(stockpile.accepts_item_type("wood"), "stockpile should accept whitelisted wood") and ok
    ok = _assert(not stockpile.accepts_item_type("food"), "stockpile should reject non-whitelisted item types") and ok
    ok = _assert(snapshot["zone_type"] == "stockpile", "stockpile should serialize as a stockpile zone") and ok
    ok = _assert(JSON.stringify(snapshot["accepted_item_types"]) == JSON.stringify(["stone", "wood"]), "accepted item types should serialize sorted") and ok
    ok = _assert(JSON.stringify(snapshot["cells"]) == JSON.stringify([[2, 2], [3, 2], [4, 4]]), "stockpile cells should serialize sorted and deduplicated") and ok
    return ok

func _test_stockpile_designation_uses_explicit_zone_cells() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(71)
    var cells: Array[Vector2i] = [Vector2i(3, 3), Vector2i(4, 3), Vector2i(3, 4), Vector2i(4, 4)]
    var result: Dictionary = sim.queue_stockpile_designation_command(1, "player_001", Vector2i(3, 3), ["wood"], cells)
    sim.step_tick()

    var ok: bool = true
    ok = _assert(result["valid"], "valid stockpile zone designation should queue") and ok
    ok = _assert(sim.stockpiles.size() == 1, "queued stockpile zone command should create one stockpile") and ok
    if sim.stockpiles.size() == 1:
        var stockpile = sim.stockpiles[sim.stockpiles.keys()[0]]
        ok = _assert(JSON.stringify(stockpile.to_canonical_dict()["cells"]) == JSON.stringify([[3, 3], [3, 4], [4, 3], [4, 4]]), "stockpile command must use the explicit dragged cells instead of expanding from a seed") and ok
    return ok

func _test_stockpile_designation_rejects_overlapping_zones() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(74)
    var first_id: String = sim.create_stockpile([Vector2i(2, 2), Vector2i(2, 3)], ["wood"])
    var direct_id: String = sim.create_stockpile([Vector2i(2, 3), Vector2i(3, 3)], ["stone"])
    var queued_result: Dictionary = sim.queue_stockpile_designation_command(1, "player_001", Vector2i(2, 2), ["food"], [Vector2i(2, 2), Vector2i(3, 2)])

    var ok: bool = true
    ok = _assert(first_id != "", "precondition: first stockpile should be created") and ok
    ok = _assert(direct_id == "", "direct stockpile creation should reject cells that overlap an existing zone") and ok
    ok = _assert(not queued_result["valid"], "queued stockpile designation should reject cells that overlap an existing zone") and ok
    ok = _assert(str(queued_result["warning"]).contains("overlap"), "overlap rejection should explain the reason") and ok
    ok = _assert(sim.stockpiles.size() == 1, "overlap rejection should not add another stockpile") and ok
    ok = _assert(sim.command_queue.size() == 0, "overlap rejection should not enqueue a command") and ok
    return ok

func _test_stockpile_resize_expands_and_shrinks_bounds() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(72)
    var stockpile_id: String = sim.create_stockpile([Vector2i(2, 2), Vector2i(2, 3), Vector2i(3, 2), Vector2i(3, 3)], ["wood"])
    var expand_result: Dictionary = sim.queue_stockpile_resize_command(1, "player_001", stockpile_id, "east", 1)
    sim.step_tick()
    var shrink_result: Dictionary = sim.queue_stockpile_resize_command(2, "player_001", stockpile_id, "north", -1)
    sim.step_tick()

    var ok: bool = true
    ok = _assert(expand_result["valid"], "east expand resize command should queue for a valid stockpile") and ok
    ok = _assert(shrink_result["valid"], "north shrink resize command should queue when the removed edge is empty") and ok
    ok = _assert(JSON.stringify(sim.stockpiles[stockpile_id].to_canonical_dict()["cells"]) == JSON.stringify([[2, 3], [3, 3], [4, 3]]), "stockpile resize should update the zone bounds canonically") and ok
    return ok

func _test_stockpile_resize_rejects_overlap_with_other_zones() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(75)
    var stockpile_a: String = sim.create_stockpile([Vector2i(2, 2), Vector2i(2, 3)], ["wood"])
    var stockpile_b: String = sim.create_stockpile([Vector2i(3, 2), Vector2i(3, 3)], ["wood"])

    var result: Dictionary = sim.queue_stockpile_resize_command(1, "player_001", stockpile_a, "east", 1)

    var ok: bool = true
    ok = _assert(stockpile_a != "" and stockpile_b != "", "precondition: adjacent non-overlapping stockpiles should be created") and ok
    ok = _assert(not result["valid"], "stockpile resize should reject expansion into another stockpile zone") and ok
    ok = _assert(str(result["warning"]).contains("overlap"), "resize overlap rejection should explain the reason") and ok
    ok = _assert(sim.command_queue.size() == 0, "invalid overlapping resize should not enqueue a command") and ok
    ok = _assert(JSON.stringify(sim.stockpiles[stockpile_a].to_canonical_dict()["cells"]) == JSON.stringify([[2, 2], [2, 3]]), "rejected overlapping resize should leave source stockpile unchanged") and ok
    ok = _assert(JSON.stringify(sim.stockpiles[stockpile_b].to_canonical_dict()["cells"]) == JSON.stringify([[3, 2], [3, 3]]), "rejected overlapping resize should leave target stockpile unchanged") and ok
    return ok

func _test_stockpile_resize_rejects_occupied_shrink_edges() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(73)
    var stockpile_id: String = sim.create_stockpile([Vector2i(2, 2), Vector2i(2, 3), Vector2i(3, 2), Vector2i(3, 3)], ["wood"])
    var item = ItemScript.new("item_edge_wood", "wood", 1, Vector2i(2, 2))
    item.stockpile_id = stockpile_id
    sim.items[item.id] = item

    var result: Dictionary = sim.queue_stockpile_resize_command(1, "player_001", stockpile_id, "west", -1)

    var ok: bool = true
    ok = _assert(not result["valid"], "shrinking a stockpile edge that contains an item should be rejected") and ok
    ok = _assert(sim.command_queue.size() == 0, "invalid stockpile shrink should not enqueue a command") and ok
    ok = _assert(JSON.stringify(sim.stockpiles[stockpile_id].to_canonical_dict()["cells"]) == JSON.stringify([[2, 2], [2, 3], [3, 2], [3, 3]]), "rejected shrink should leave stockpile cells unchanged") and ok
    return ok

func _test_stockpile_modes_control_storage_and_supply() -> bool:
    var storage_sim = SimulationScript.new()
    storage_sim.initialize_new_game(76)
    var storage_id: String = storage_sim.create_stockpile([Vector2i(3, 3)], ["stone"], "storage")
    var storage_item = ItemScript.new("item_storage_stone", "stone", 2, Vector2i(3, 3))
    storage_item.stockpile_id = storage_id
    storage_sim.items[storage_item.id] = storage_item
    storage_sim.create_construction("wall_block", Vector2i(5, 2), 1)

    var supply_sim = SimulationScript.new()
    supply_sim.initialize_new_game(77)
    var supply_id: String = supply_sim.create_stockpile([Vector2i(4, 4)], ["wood"], "supply")
    supply_sim.items["item_loose_wood"] = ItemScript.new("item_loose_wood", "wood", 1, Vector2i(1, 1))
    supply_sim.step_tick()

    var ok: bool = true
    ok = _assert(storage_sim.job_board.to_canonical_array().size() == 0, "storage-only stockpiles should not supply construction jobs") and ok
    ok = _assert(storage_sim.items["item_storage_stone"].reserved_by_job_id == "", "storage-only stockpiled items should remain unreserved by construction") and ok
    ok = _assert(supply_sim.job_board.to_canonical_array().size() == 0, "supply-only stockpiles should not request loose items for storage") and ok
    ok = _assert(supply_sim.items["item_loose_wood"].stockpile_id == "", "supply-only stockpiles should leave loose matching items unassigned") and ok
    return ok

func _test_stockpile_mode_command_updates_canonical_state() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(78)
    var stockpile_id: String = sim.create_stockpile([Vector2i(3, 3)], ["stone"], "storage")
    var item = ItemScript.new("item_supply_stone", "stone", 2, Vector2i(3, 3))
    item.stockpile_id = stockpile_id
    sim.items[item.id] = item
    sim.create_construction("wall_block", Vector2i(5, 2), 1)
    var mode_result: Dictionary = sim.queue_stockpile_mode_command(1, "player_001", stockpile_id, "supply")
    sim.step_tick()

    var snapshot: Dictionary = sim.stockpiles[stockpile_id].to_canonical_dict()
    var ok: bool = true
    ok = _assert(mode_result["valid"], "valid stockpile mode command should queue") and ok
    ok = _assert(snapshot["storage_mode"] == "supply", "stockpile mode command should update canonical storage mode") and ok
    ok = _assert(sim.job_board.to_canonical_array().size() == 1, "changing a stockpile to supply should make its items available to waiting construction") and ok
    ok = _assert(sim.items["item_supply_stone"].reserved_by_job_id != "", "supply stockpile items should be reservable by build jobs") and ok
    return ok

func _test_item_reservations_are_unique_and_releasable() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(8)
    var item = ItemScript.new("item_manual", "wood", 3, Vector2i(5, 5))
    sim.items[item.id] = item
    var ok: bool = true
    ok = _assert(sim.reserve_item_for_job("item_manual", "job_a"), "first reservation should succeed") and ok
    ok = _assert(not sim.reserve_item_for_job("item_manual", "job_b"), "second reservation by another job should fail") and ok
    ok = _assert(sim.reserve_item_for_job("item_manual", "job_a"), "same job should be able to idempotently reserve the same item") and ok
    ok = _assert(item.reserved_by_job_id == "job_a", "item should record reserving job id") and ok
    sim.release_item_reservation("item_manual", "job_b")
    ok = _assert(item.reserved_by_job_id == "job_a", "non-owner release should not clear reservation") and ok
    sim.release_item_reservation("item_manual", "job_a")
    ok = _assert(item.reserved_by_job_id == "", "owner release should clear reservation") and ok
    return ok

func _test_stockpiles_and_reservations_are_canonical_snapshot_state() -> bool:
    var a = SimulationScript.new()
    var b = SimulationScript.new()
    a.initialize_new_game(9)
    b.initialize_new_game(9)
    var id_b: String = b.create_stockpile([Vector2i(6, 1), Vector2i(1, 6)], ["stone", "wood"])
    var id_a: String = a.create_stockpile([Vector2i(1, 6), Vector2i(6, 1)], ["wood", "stone"])
    a.items["item_b"] = ItemScript.new("item_b", "stone", 1, Vector2i(6, 1))
    a.items["item_a"] = ItemScript.new("item_a", "wood", 1, Vector2i(1, 6))
    b.items["item_a"] = ItemScript.new("item_a", "wood", 1, Vector2i(1, 6))
    b.items["item_b"] = ItemScript.new("item_b", "stone", 1, Vector2i(6, 1))
    a.assign_item_to_stockpile("item_a", id_a)
    a.reserve_item_for_job("item_b", "job_000002")
    b.reserve_item_for_job("item_b", "job_000002")
    b.assign_item_to_stockpile("item_a", id_b)
    var a_snapshot: Dictionary = a.canonical_snapshot()
    var b_snapshot: Dictionary = b.canonical_snapshot()
    var ok: bool = true
    ok = _assert(a_snapshot.has("stockpiles"), "canonical snapshot should include stockpiles") and ok
    ok = _assert(JSON.stringify(a_snapshot["stockpiles"]) == JSON.stringify(b_snapshot["stockpiles"]), "stockpiles should serialize canonically independent of input ordering") and ok
    ok = _assert(JSON.stringify(a_snapshot["items"]) == JSON.stringify(b_snapshot["items"]), "item location and reservation fields should serialize canonically") and ok
    ok = _assert(a.state_hash() == b.state_hash(), "state_hash should include canonical stockpile and reservation state") and ok
    return ok
