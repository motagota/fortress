#!/usr/bin/env python3
from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REQUIRED_FILES = [
    'run_tests.sh',
    'project.godot',
    'scenes/Main.tscn',
    'scenes/world/WorldRoot.tscn',
    'scenes/units/UnitView.tscn',
    'scenes/ui/GameHud.tscn',
    'scripts/main.gd',
    'scripts/simulation/simulation.gd',
    'scripts/simulation/sim_clock.gd',
    'scripts/simulation/deterministic_rng.gd',
    'scripts/simulation/grid_world.gd',
    'scripts/simulation/cell.gd',
    'scripts/simulation/unit.gd',
    'scripts/simulation/job.gd',
    'scripts/simulation/job_board.gd',
    'scripts/simulation/item.gd',
    'scripts/simulation/stockpile.gd',
    'scripts/simulation/building_definition.gd',
    'scripts/simulation/construction_record.gd',
    'scripts/presentation/world_renderer.gd',
    'scripts/presentation/camera_controller.gd',
    'scripts/ui/game_hud.gd',
    'tests/run_godot_tests.gd',
    'tests/test_determinism_replay.gd',
    'tests/test_command_ordering.gd',
    'tests/test_simulation_primitives.gd',
    'tests/test_forest_fixture.gd',
    'tests/test_seeded_rng.gd',
    'tests/test_world_generation.gd',
    'tests/test_world_shell.gd',
    'tests/test_job_board.gd',
    'tests/test_job_timers.gd',
    'tests/test_resource_job_completion.gd',
    'tests/test_unit_job_lifecycle.gd',
    'tests/test_tool_modes.gd',
    'tests/test_grid_picking_designations.gd',
    'tests/test_stockpile_model.gd',
    'tests/test_hauling_jobs.gd',
    'tests/test_building_model.gd',
]

SIM_REQUIRED_SNIPPETS = [
    'const WORLD_WIDTH := 16',
    'const WORLD_HEIGHT := 16',
    'const INITIAL_UNIT_COUNT := 3',
    'var command_queue',
    'func queue_command',
    'func step_tick',
    'func canonical_snapshot',
    'func state_hash',
    'command_queue.sort_custom',
]

FORBIDDEN_SIM_SNIPPETS = [
    'Time.',
    'OS.get_ticks',
    'randf(',
    'randi(',
    'randomize(',
    'get_tree()',
    '_process(delta',
    '_physics_process(delta',
]


def fail(msg: str) -> None:
    print(f'FAIL: {msg}')
    sys.exit(1)


def read(rel: str) -> str:
    path = ROOT / rel
    if not path.exists():
        fail(f'missing required file {rel}')
    return path.read_text(encoding='utf-8')


def assert_contains(rel: str, needle: str) -> None:
    text = read(rel)
    if needle not in text:
        fail(f'{rel} must contain {needle!r}')


def main() -> int:
    for rel in REQUIRED_FILES:
        if not (ROOT / rel).exists():
            fail(f'missing required file {rel}')

    project = read('project.godot')
    if 'config/name="Fortress City"' not in project:
        fail('project.godot must name the project Fortress City')
    if 'run/main_scene="res://scenes/Main.tscn"' not in project:
        fail('project.godot must set scenes/Main.tscn as main scene')
    if 'config/features=PackedStringArray("4.6"' not in project:
        fail('project.godot must carry a Godot 4.6 feature marker')
    if 'display/window/size/mode=3' not in project:
        fail('project.godot must start the game in fullscreen window mode')

    main_scene = read('scenes/Main.tscn')
    for token in ['type="Node3D"', 'name="WorldRoot"', 'type="Camera3D"', 'type="DirectionalLight3D"', 'name="GameHud"']:
        if token not in main_scene:
            fail(f'Main.tscn must include {token}')

    sim = read('scripts/simulation/simulation.gd')
    for snippet in SIM_REQUIRED_SNIPPETS:
        if snippet not in sim:
            fail(f'simulation.gd missing deterministic foundation snippet {snippet!r}')
    for snippet in FORBIDDEN_SIM_SNIPPETS:
        if snippet in sim:
            fail(f'simulation.gd must not use nondeterministic/presentation API {snippet!r}')

    assert_contains('scripts/simulation/deterministic_rng.gd', 'func next_u32')
    assert_contains('scripts/simulation/deterministic_rng.gd', 'func get_state')
    assert_contains('scripts/simulation/grid_world.gd', 'func create_forest')
    assert_contains('scripts/simulation/grid_world.gd', 'func generate_ironveil_region')
    assert_contains('tests/run_godot_tests.gd', 'test_world_generation.gd')
    assert_contains('scripts/simulation/job_board.gd', 'func get_best_open_job_for_unit')
    assert_contains('scripts/presentation/world_renderer.gd', 'func sync_from_simulation')
    assert_contains('scripts/presentation/world_renderer.gd', 'func _sync_designations')
    assert_contains('scripts/presentation/world_renderer.gd', 'Designations')
    assert_contains('scripts/presentation/world_renderer.gd', 'simulation state')
    assert_contains('tests/run_godot_tests.gd', 'test_determinism_replay.gd')
    assert_contains('tests/run_godot_tests.gd', 'test_forest_fixture.gd')
    assert_contains('tests/run_godot_tests.gd', 'test_tool_modes.gd')
    assert_contains('tests/run_godot_tests.gd', 'test_grid_picking_designations.gd')
    assert_contains('tests/run_godot_tests.gd', 'test_stockpile_model.gd')
    assert_contains('tests/run_godot_tests.gd', 'test_hauling_jobs.gd')
    assert_contains('tests/run_godot_tests.gd', 'test_building_model.gd')
    assert_contains('scripts/simulation/stockpile.gd', 'func accepts_item_type')
    assert_contains('scripts/simulation/simulation.gd', 'func create_stockpile')
    assert_contains('scripts/simulation/simulation.gd', 'func reserve_item_for_job')
    assert_contains('scripts/simulation/simulation.gd', 'func create_haul_jobs_for_loose_items')
    assert_contains('scripts/simulation/simulation.gd', 'func get_building_definition')
    assert_contains('scripts/simulation/simulation.gd', 'func create_construction')
    assert_contains('scripts/simulation/building_definition.gd', 'wall_block')
    assert_contains('scripts/simulation/construction_record.gd', 'completed_building_id')
    assert_contains('scripts/simulation/job.gd', '"HAUL_ITEM"')
    assert_contains('tests/test_world_shell.gd', 'UnitView')
    assert_contains('scripts/main.gd', 'func set_active_tool_mode')
    assert_contains('scripts/main.gd', 'func _handle_grid_cell_designation')
    assert_contains('scripts/presentation/world_renderer.gd', 'func ray_to_grid_cell')
    assert_contains('scripts/simulation/simulation.gd', 'func validate_designation_target')
    assert_contains('scripts/simulation/simulation.gd', 'has_open_job_at')
    assert_contains('scripts/ui/game_hud.gd', 'signal tool_mode_requested')

    runner = read('run_tests.sh')
    if '/mnt/d/dev/fortress' in runner:
        fail('run_tests.sh must not hard-code the Windows checkout as /mnt/d/dev/fortress')
    for snippet in ['BASH_SOURCE[0]', 'PROJECT_ROOT', 'GODOT', '/d/dev/godot', 'command -v godot', '/tmp/Godot_v4.6-stable_linux.x86_64']:
        if snippet not in runner:
            fail(f'run_tests.sh missing portable runner snippet {snippet!r}')

    print('static project checks passed')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
