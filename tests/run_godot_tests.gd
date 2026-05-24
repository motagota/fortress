extends SceneTree

const TESTS := [
    "res://tests/test_determinism_replay.gd",
    "res://tests/test_command_ordering.gd",
    "res://tests/test_seeded_rng.gd",
    "res://tests/test_simulation_primitives.gd",
    "res://tests/test_job_board.gd",
    "res://tests/test_job_timers.gd",
    "res://tests/test_forest_fixture.gd",
    "res://tests/test_world_shell.gd",
    "res://tests/test_resource_job_completion.gd",
]

func _initialize() -> void:
    var failures: int = 0
    for test_path in TESTS:
        var script: Resource = load(test_path)
        if script == null:
            push_error("Could not load " + test_path)
            failures += 1
            continue
        var test: Variant = script.new()
        var result: bool = test.run()
        if not result:
            failures += 1
    if failures == 0:
        print("All Godot tests passed")
        quit(0)
    else:
        printerr(str(failures) + " Godot test file(s) failed")
        quit(1)
