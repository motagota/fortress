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
    ok = _test_loose_matching_item_creates_haul_job() and ok
    ok = _test_unit_carries_item_to_stockpile_and_counts_update() and ok
    ok = _test_two_units_do_not_reserve_same_item() and ok
    ok = _test_stockpile_cells_accept_only_one_item_each() and ok
    ok = _test_supply_only_stockpile_moves_items_to_storage_stockpile() and ok
    ok = _test_no_valid_stockpile_leaves_loose_item_in_place() and ok
    return ok

func _add_item(sim, item_id: String, item_type: String, quantity: int, cell: Vector2i) -> void:
    sim.items[item_id] = ItemScript.new(item_id, item_type, quantity, cell)

func _step_until_no_active_haul_jobs(sim, max_steps: int = 80) -> int:
    var steps: int = 0
    for _i in range(max_steps):
        sim.step_tick()
        steps += 1
        var active: bool = false
        for job_id in sim.job_board.jobs.keys():
            var job = sim.job_board.jobs[job_id]
            if job.type == "HAUL_ITEM" and job.status != "complete":
                active = true
                break
        if not active:
            return steps
    return steps

func _haul_jobs(sim) -> Array:
    var jobs: Array = []
    for job_id in sim.job_board.sorted_job_ids():
        var job = sim.job_board.jobs[job_id]
        if job.type == "HAUL_ITEM":
            jobs.append(job)
    return jobs

func _stockpiled_quantity(sim, stockpile_id: String, item_type: String) -> int:
    var total: int = 0
    for item_id in sim.items.keys():
        var item = sim.items[item_id]
        if item.stockpile_id == stockpile_id and item.item_type == item_type:
            total += item.quantity
    return total

func _test_loose_matching_item_creates_haul_job() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(31)
    var stockpile_id: String = sim.create_stockpile([Vector2i(4, 1)], ["wood"])
    _add_item(sim, "item_loose_wood", "wood", 2, Vector2i(1, 1))

    sim.step_tick()

    var jobs: Array = _haul_jobs(sim)
    var ok: bool = true
    ok = _assert(jobs.size() == 1, "one loose wood item with a matching stockpile must create one haul job") and ok
    if jobs.size() == 1:
        ok = _assert(jobs[0].target_cell == Vector2i(1, 1), "haul job target should be the loose item cell first") and ok
        ok = _assert(jobs[0].required_items.get("item_id", "") == "item_loose_wood", "haul job must record the item being hauled") and ok
        ok = _assert(jobs[0].required_items.get("stockpile_id", "") == stockpile_id, "haul job must record the destination stockpile") and ok
        ok = _assert(sim.items["item_loose_wood"].reserved_by_job_id == jobs[0].id, "creating a haul job must reserve the loose item") and ok
    return ok

func _test_unit_carries_item_to_stockpile_and_counts_update() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(32)
    var stockpile_id: String = sim.create_stockpile([Vector2i(4, 1)], ["wood"])
    _add_item(sim, "item_loose_wood", "wood", 3, Vector2i(1, 1))

    var steps: int = _step_until_no_active_haul_jobs(sim, 80)

    var item = sim.items["item_loose_wood"]
    var ok: bool = true
    ok = _assert(steps < 80, "haul job should complete within 80 ticks") and ok
    ok = _assert(item.position == Vector2i(4, 1), "hauled item must end at the stockpile cell") and ok
    ok = _assert(item.stockpile_id == stockpile_id, "hauled item must be assigned to the destination stockpile") and ok
    ok = _assert(item.holder_unit_id == "", "hauled item must be dropped by the carrying unit on completion") and ok
    ok = _assert(item.reserved_by_job_id == "", "haul completion must clear the item reservation") and ok
    ok = _assert(_stockpiled_quantity(sim, stockpile_id, "wood") == 3, "stockpile count should include the hauled item quantity") and ok
    return ok

func _test_two_units_do_not_reserve_same_item() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(33)
    sim.create_stockpile([Vector2i(4, 1), Vector2i(4, 2)], ["wood"])
    _add_item(sim, "item_single_wood", "wood", 1, Vector2i(1, 1))

    sim.step_tick()
    sim.step_tick()

    var haul_jobs: Array = _haul_jobs(sim)
    var item = sim.items["item_single_wood"]
    var claimers: Dictionary = {}
    for unit_id in sim.units.keys():
        var unit = sim.units[unit_id]
        if unit.current_job_id != "":
            claimers[unit.current_job_id] = true
    var ok: bool = true
    ok = _assert(haul_jobs.size() == 1, "a reserved loose item must not generate duplicate haul jobs") and ok
    ok = _assert(item.reserved_by_job_id != "", "the loose item should be reserved by its single haul job") and ok
    ok = _assert(claimers.size() <= 1, "no more than one unit may claim the haul job for a single item") and ok
    return ok

func _test_stockpile_cells_accept_only_one_item_each() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(35)
    var stockpile_id: String = sim.create_stockpile([Vector2i(4, 1), Vector2i(4, 2)], ["wood"])
    _add_item(sim, "item_loose_wood_a", "wood", 1, Vector2i(1, 1))
    _add_item(sim, "item_loose_wood_b", "wood", 1, Vector2i(1, 2))
    _add_item(sim, "item_loose_wood_c", "wood", 1, Vector2i(1, 3))

    sim.step_tick()

    var destinations: Dictionary = {}
    for job in _haul_jobs(sim):
        var raw: Array = job.required_items.get("destination_cell", [])
        destinations[JSON.stringify(raw)] = true
    var ok: bool = true
    ok = _assert(_haul_jobs(sim).size() == 2, "two-cell stockpile should request only two loose items at a time") and ok
    ok = _assert(destinations.size() == 2, "haul jobs must reserve distinct stockpile cells") and ok

    _step_until_no_active_haul_jobs(sim, 80)
    ok = _assert(sim.items["item_loose_wood_a"].position != sim.items["item_loose_wood_b"].position, "hauled stockpile items must not stack on the same cell") and ok
    ok = _assert(_stockpiled_quantity(sim, stockpile_id, "wood") == 2, "full stockpile should contain one item per cell") and ok
    sim.step_tick()
    ok = _assert(_haul_jobs(sim).size() == 0, "completed haul jobs should be removed and full stockpile must not request another loose item") and ok
    ok = _assert(sim.items["item_loose_wood_c"].stockpile_id == "", "extra item should stay loose when no stockpile cell is empty") and ok
    return ok

func _test_supply_only_stockpile_moves_items_to_storage_stockpile() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(36)
    var supply_id: String = sim.create_stockpile([Vector2i(2, 2)], ["wood"], "supply")
    var storage_id: String = sim.create_stockpile([Vector2i(5, 2)], ["wood"], "storage")
    var item = ItemScript.new("item_stockpiled_wood", "wood", 1, Vector2i(2, 2))
    item.stockpile_id = supply_id
    sim.items[item.id] = item

    sim.step_tick()

    var jobs: Array = _haul_jobs(sim)
    var ok: bool = true
    ok = _assert(jobs.size() == 1, "item in a supply-only stockpile should create a relocation haul job when storage is available") and ok
    if jobs.size() == 1:
        ok = _assert(jobs[0].required_items.get("source_stockpile_id", "") == supply_id, "relocation haul job should record the source supply stockpile") and ok
        ok = _assert(jobs[0].required_items.get("stockpile_id", "") == storage_id, "relocation haul job should target the storage stockpile") and ok
    _step_until_no_active_haul_jobs(sim, 80)
    ok = _assert(sim.items["item_stockpiled_wood"].stockpile_id == storage_id, "relocated item should be assigned to the storage stockpile") and ok
    ok = _assert(sim.items["item_stockpiled_wood"].position == Vector2i(5, 2), "relocated item should be moved to the storage stockpile cell") and ok
    return ok

func _test_no_valid_stockpile_leaves_loose_item_in_place() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(34)
    sim.create_stockpile([Vector2i(4, 1)], ["stone"])
    _add_item(sim, "item_loose_food", "food", 1, Vector2i(2, 2))

    sim.step_tick()
    sim.step_tick()

    var item = sim.items["item_loose_food"]
    var ok: bool = true
    ok = _assert(_haul_jobs(sim).size() == 0, "loose item with no accepting stockpile must not create a haul job") and ok
    ok = _assert(item.position == Vector2i(2, 2), "loose item with no valid stockpile must remain in place") and ok
    ok = _assert(item.stockpile_id == "", "loose item with no valid stockpile must stay unassigned") and ok
    ok = _assert(item.reserved_by_job_id == "", "loose item with no valid stockpile must not be reserved") and ok
    return ok
