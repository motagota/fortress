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
    ok = _assert(JSON.stringify(snapshot["accepted_item_types"]) == JSON.stringify(["stone", "wood"]), "accepted item types should serialize sorted") and ok
    ok = _assert(JSON.stringify(snapshot["cells"]) == JSON.stringify([[2, 2], [3, 2], [4, 4]]), "stockpile cells should serialize sorted and deduplicated") and ok
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
