extends RefCounted

const Simulation := preload("res://scripts/simulation/simulation.gd")
const SimClock := preload("res://scripts/simulation/sim_clock.gd")

# ---------------------------------------------------------------------------
# M3: Time controls — pause, play, speed
#
# Verifies that:
#   1. SimClock.advance_steps() returns 0 when paused
#   2. Unpausing resumes tick advancement
#   3. Speed multiplier controls how quickly elapsed frame time becomes ticks
#   4. Sub-tick frame deltas do not advance simulation every rendered frame
#   5. When wired through main.gd's _process loop, pause stops simulation
#      tick progression
# ---------------------------------------------------------------------------

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true


# --- SimClock-level tests ---

func _test_paused_clock_returns_zero() -> bool:
    var ok := true
    var clock := SimClock.new()
    clock.set_paused(true)
    ok = _assert(clock.paused, "clock must be paused after set_paused(true)") and ok

    # While paused, advance_steps must return 0
    var advanced: int = clock.advance_steps()
    ok = _assert(advanced == 0, "paused clock must advance 0 steps, got %d" % advanced) and ok
    ok = _assert(clock.tick == 0, "tick must remain 0 while paused, got %d" % clock.tick) and ok
    return ok


func _test_unpaused_clock_advances() -> bool:
    var ok := true
    var clock := SimClock.new()
    ok = _assert(not clock.paused, "clock must start unpaused") and ok

    var advanced: int = clock.advance_steps(clock.base_tick_interval_seconds)
    ok = _assert(advanced == 1, "unpaused clock at speed 1 must advance 1 step, got %d" % advanced) and ok
    ok = _assert(clock.tick == 1, "tick must be 1 after one advance, got %d" % clock.tick) and ok

    var advanced2: int = clock.advance_steps(clock.base_tick_interval_seconds)
    ok = _assert(advanced2 == 1, "second advance must also be 1 step, got %d" % advanced2) and ok
    ok = _assert(clock.tick == 2, "tick must be 2 after two advances, got %d" % clock.tick) and ok
    return ok


func _test_speed_2x_advances_twice() -> bool:
    var ok := true
    var clock := SimClock.new()
    clock.set_speed(2)

    var advanced: int = clock.advance_steps(clock.base_tick_interval_seconds)
    ok = _assert(advanced == 2, "speed 2 must advance 2 steps per call, got %d" % advanced) and ok
    ok = _assert(clock.tick == 2, "tick must be 2 after one speed-2 advance, got %d" % clock.tick) and ok
    return ok


func _test_speed_4x_advances_four() -> bool:
    var ok := true
    var clock := SimClock.new()
    clock.set_speed(4)

    var advanced: int = clock.advance_steps(clock.base_tick_interval_seconds)
    ok = _assert(advanced == 4, "speed 4 must advance 4 steps per call, got %d" % advanced) and ok
    ok = _assert(clock.tick == 4, "tick must be 4 after one speed-4 advance, got %d" % clock.tick) and ok
    return ok


func _test_set_speed_minimum_is_1() -> bool:
    var ok := true
    var clock := SimClock.new()
    clock.set_speed(0)
    ok = _assert(clock.speed == 1, "speed 0 must clamp to 1, got %d" % clock.speed) and ok

    clock.set_speed(-5)
    ok = _assert(clock.speed == 1, "speed -5 must clamp to 1, got %d" % clock.speed) and ok
    return ok


func _test_pause_then_resume() -> bool:
    var ok := true
    var clock := SimClock.new()

    # Advance 3 ticks
    clock.advance_steps(clock.base_tick_interval_seconds)
    clock.advance_steps(clock.base_tick_interval_seconds)
    clock.advance_steps(clock.base_tick_interval_seconds)
    ok = _assert(clock.tick == 3, "tick must be 3 after 3 advances, got %d" % clock.tick) and ok

    # Pause
    clock.set_paused(true)
    var paused_advance: int = clock.advance_steps()
    ok = _assert(paused_advance == 0, "must advance 0 while paused, got %d" % paused_advance) and ok
    ok = _assert(clock.tick == 3, "tick must remain 3 while paused, got %d" % clock.tick) and ok

    # Resume
    clock.set_paused(false)
    clock.advance_steps(clock.base_tick_interval_seconds)
    ok = _assert(clock.tick == 4, "tick must be 4 after resuming + one advance, got %d" % clock.tick) and ok
    return ok

func _test_sub_tick_frame_deltas_accumulate_without_running_every_frame() -> bool:
    var ok := true
    var clock := SimClock.new()
    var frame_delta: float = 1.0 / 60.0

    var advanced_first_frame: int = clock.advance_steps(frame_delta)
    ok = _assert(advanced_first_frame == 0, "one 60fps frame must be below the 1x tick interval, got %d ticks" % advanced_first_frame) and ok
    ok = _assert(clock.tick == 0, "tick must remain 0 after one 60fps frame, got %d" % clock.tick) and ok

    var total_advanced: int = advanced_first_frame
    for _f in range(29):
        total_advanced += clock.advance_steps(frame_delta)
    ok = _assert(total_advanced == 1, "30 frames at 60fps should advance exactly 1 sim tick, got %d" % total_advanced) and ok
    ok = _assert(clock.tick == 1, "clock tick should be 1 after accumulated half-second, got %d" % clock.tick) and ok
    return ok

# --- Main-level integration test ---
# Simulates main.gd's _process loop: on each frame, call sim_clock.advance_steps()
# then call simulation.step_tick() that many times.

func _test_main_loop_pause_stops_simulation_tick() -> bool:
    var ok := true
    var sim: Simulation = Simulation.new()
    sim.initialize_new_game(42)
    var clock := SimClock.new()

    var start_tick: int = sim.tick

    # Simulate enough frame time for multiple 1x ticks
    for _f in range(3):
        var n: int = clock.advance_steps(clock.base_tick_interval_seconds)
        for _i in range(n):
            sim.step_tick()
    ok = _assert(sim.tick > start_tick, "sim tick must advance after 3 process frames, got %d" % sim.tick) and ok

    var tick_before_pause: int = sim.tick

    # Pause + 5 more process frames
    clock.set_paused(true)
    for _f in range(5):
        var n2: int = clock.advance_steps(clock.base_tick_interval_seconds)
        for _i in range(n2):
            sim.step_tick()
    ok = _assert(sim.tick == tick_before_pause, "sim tick must not change while pausing during %d frames, got %d expected %d" % [5, sim.tick, tick_before_pause]) and ok

    # Resume + 2 more process frames
    clock.set_paused(false)
    var resume_tick: int = sim.tick
    for _f in range(2):
        var n3: int = clock.advance_steps(clock.base_tick_interval_seconds)
        for _i in range(n3):
            sim.step_tick()
    ok = _assert(sim.tick > resume_tick, "sim tick must advance again after resume, got %d" % sim.tick) and ok
    return ok


func _test_main_loop_speed_2x_advances_faster() -> bool:
    var ok := true
    var sim: Simulation = Simulation.new()
    sim.initialize_new_game(42)
    var clock := SimClock.new()
    clock.set_speed(2)

    var start_tick: int = sim.tick

    # Simulate 5 base tick intervals at speed 2: each interval steps 2 ticks
    for _f in range(5):
        var n: int = clock.advance_steps(clock.base_tick_interval_seconds)
        ok = _assert(n == 2, "speed 2 must advance 2 per frame, got %d" % n) and ok
        for _i in range(n):
            sim.step_tick()

    var expected: int = start_tick + 10
    ok = _assert(sim.tick == expected, "after 5 frames at speed 2 tick must be %d, got %d" % [expected, sim.tick]) and ok
    return ok


# --- runner ---

func run() -> bool:
    var ok: bool = true
    ok = _test_paused_clock_returns_zero() and ok
    ok = _test_unpaused_clock_advances() and ok
    ok = _test_speed_2x_advances_twice() and ok
    ok = _test_speed_4x_advances_four() and ok
    ok = _test_set_speed_minimum_is_1() and ok
    ok = _test_pause_then_resume() and ok
    ok = _test_sub_tick_frame_deltas_accumulate_without_running_every_frame() and ok
    ok = _test_main_loop_pause_stops_simulation_tick() and ok
    ok = _test_main_loop_speed_2x_advances_faster() and ok
    return ok
