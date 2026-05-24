extends RefCounted

const SimulationScript = preload("res://scripts/simulation/simulation.gd")
const SimClockScript = preload("res://scripts/simulation/sim_clock.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func run() -> bool:
    var ok: bool = true
    ok = _test_fixed_tick_clock() and ok
    ok = _test_monotonic_id_allocator_resets_from_seed_state() and ok
    ok = _test_command_queue_has_total_canonical_order() and ok
    ok = _test_canonical_snapshot_is_hash_source() and ok
    return ok

func _test_fixed_tick_clock() -> bool:
    var clock = SimClockScript.new()
    clock.set_speed(3)
    var advanced: int = clock.advance_steps()
    var ok: bool = true
    ok = _assert(advanced == 3, "clock should advance exactly speed ticks") and ok
    ok = _assert(clock.tick == 3, "clock tick should be deterministic monotonic integer") and ok
    clock.set_paused(true)
    ok = _assert(clock.advance_steps() == 0, "paused clock should not advance") and ok
    ok = _assert(clock.tick == 3, "paused clock should preserve tick") and ok
    clock.set_paused(false)
    clock.set_speed(0)
    ok = _assert(clock.advance_steps() == 1, "clock speed should clamp to at least one fixed tick") and ok
    return ok

func _test_monotonic_id_allocator_resets_from_seed_state() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(99)
    var first_job: String = sim.allocate_id("job")
    var second_job: String = sim.allocate_id("job")
    var first_building: String = sim.allocate_id("building")
    var ok: bool = true
    ok = _assert(first_job == "job_000001", "job ids should start at one after initialization") and ok
    ok = _assert(second_job == "job_000002", "job ids should be monotonic per prefix") and ok
    ok = _assert(first_building == "building_000001", "id allocator should keep independent prefix counters") and ok
    sim.initialize_new_game(99)
    ok = _assert(sim.allocate_id("job") == "job_000001", "new deterministic sim state should reset id counters") and ok
    return ok

func _test_command_queue_has_total_canonical_order() -> bool:
    var a = SimulationScript.new()
    var b = SimulationScript.new()
    a.initialize_new_game(12)
    b.initialize_new_game(12)
    var first: Dictionary = a.make_command(5, "player_b", "DESIGNATE_GATHER_STONE", Vector2i(4, 4), {"z": 2, "a": 1}, "cmd_same")
    var second: Dictionary = a.make_command(5, "player_a", "DESIGNATE_CHOP", Vector2i(3, 3), {"z": 2, "a": 1}, "cmd_same")
    a.queue_existing_command(first)
    a.queue_existing_command(second)
    b.queue_existing_command(second.duplicate(true))
    b.queue_existing_command(first.duplicate(true))
    var a_queue: String = JSON.stringify(a.canonical_snapshot()["command_queue"])
    var b_queue: String = JSON.stringify(b.canonical_snapshot()["command_queue"])
    return _assert(a_queue == b_queue, "command queue must have a total canonical order even when external command ids collide")

func _test_canonical_snapshot_is_hash_source() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(321)
    var snapshot: Dictionary = sim.canonical_snapshot()
    var expected_hash: String = JSON.stringify(snapshot).sha256_text()
    var ok: bool = true
    ok = _assert(sim.state_hash() == expected_hash, "state_hash should hash canonical_snapshot serialization") and ok
    ok = _assert(snapshot.has("rng_streams"), "canonical snapshot should include RNG streams") and ok
    ok = _assert(snapshot["rng_streams"].has("world_rng"), "canonical snapshot should include named world RNG stream") and ok
    ok = _assert(snapshot["rng_streams"]["world_rng"].has("state"), "RNG streams should serialize their current state") and ok
    return ok
