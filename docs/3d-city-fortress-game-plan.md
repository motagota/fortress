# 3D Fortress-City Sim Game Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task. Every implementation task must include conclusive tests: static validators that run in shell, headless Godot 4.6 tests where possible, and manual playtest gates only for visual/feel checks that automation cannot prove.

**Working Title:** Fortress City

**Goal:** Build a 3D Godot 4.6 civilization-building simulation where a small group starts in a forest with nothing and develops into an advanced technological society by gathering natural resources, mining, building infrastructure, researching better technology, and managing increasingly complex supply chains through autonomous units and jobs.

**Architecture:** Use Godot 4.6 with a data-driven, deterministic simulation core separated from 3D presentation. The simulation should be deterministic and testable without rendering: units, jobs, resources, buildings, needs, and time ticks live in scripts/resources that can run in headless tests. The simulation accepts ordered player commands as input and produces reproducible state transitions suitable for future lockstep/server-authoritative multiplayer. 3D scenes visualize the state using simple blockout meshes first, then later art.

**Tech Stack:** Godot 4.6, GDScript, 3D scenes, NavigationRegion3D/NavigationAgent3D or grid navigation, Resource-based data definitions, headless GDScript tests, Python static validators.

---

## Design Pillars

1. **Autonomous workers, player-directed priorities**
   - The player does not directly control units.
   - The player creates designations: chop trees, mine, haul, build, farm, craft, store.
   - Units choose jobs based on skills, permissions, distance, priority, and needs.

2. **Readable 3D settlement simulation**
   - The game is 3D, but clarity beats visual detail.
   - Start with simple blockout meshes, strong colors, labels/icons, and readable unit paths.
   - Camera should make the city easy to inspect from an isometric/RTS-like perspective.

3. **Small systems that combine**
   - Avoid huge one-off features.
   - Jobs, inventories, stockpiles, buildings, needs, and skills should be small composable systems.
   - Example: a `Build Wall` job needs `stone`, which creates `Haul stone`, then `Construct wall`.

4. **Simulation first, art later**
   - The first milestone should prove that units keep a tiny city running using placeholder visuals.
   - Pretty models, animations, combat, weather, diplomacy, and deep worldgen wait until core loops work.

5. **Conclusive tests for systems**
   - Job assignment, resource accounting, hauling, construction, and needs must be tested in headless simulation.
   - Manual testing is for camera feel and visual clarity, not core correctness.

6. **Deterministic simulation for future multiplayer**
   - The authoritative simulation must produce the same result from the same initial state and ordered input commands.
   - Presentation, particles, camera, UI, and animation may be nondeterministic, but they must never feed back into simulation state.
   - Randomness must come from explicit seeded RNG streams stored in simulation state, never global random calls.
   - System iteration order must be stable and sorted by deterministic ids, not scene-tree order, dictionary hash order, or physics callback order.

---

## Core Fantasy

A handful of people wake up in a forest with nothing but their labor. The player helps them turn survival into civilization: chop trees, gather food, mine stone and ore, build shelters, invent better tools, create workshops, establish logistics, unlock power, automate production, and eventually reach advanced technology.

The game should feel like a long arc from primitive survival to complex industry:

- **Forest survival:** forage, chop wood, build basic shelter, store food.
- **Stone and tool age:** mine stone, craft tools, build durable structures.
- **Agrarian settlement:** farming, kitchens, storage, roads, housing, population growth.
- **Metalworking:** ore mining, charcoal/fuel, smelting, forging, stronger tools and machines.
- **Early industry:** workshops, power sources, mechanical logistics, specialized labor.
- **Advanced technology:** electricity, automation, research labs, high-tier materials, complex factories.

The player does not micromanage every action. Instead, they design the civilization's priorities and infrastructure while autonomous units execute the work through job systems and supply chains.

The fun comes from watching a settlement evolve from improvised forest survival into a sophisticated machine where resources, labor, technology, and logistics all depend on one another.

---

## MVP Scope

The first playable slice should be tiny but systemic:

### Player Can

- Move/rotate/zoom a 3D camera.
- Select terrain tiles or build locations.
- Designate trees/rocks/resources for gathering.
- Place stockpile zones.
- Place construction blueprints.
- Inspect units, jobs, resources, and buildings.
- Start/pause/change simulation speed.

### Units Can

- Idle when no work exists.
- Evaluate available jobs.
- Claim one job at a time.
- Walk to target.
- Perform work over time.
- Pick up/carry/drop resources.
- Deposit items in stockpiles.
- Build simple structures from required resources.
- Track basic needs: hunger, rest, morale placeholder.

### World Has

- Flat or lightly varied 3D terrain grid.
- Resource nodes: trees, stone, berry bushes or food source.
- Stockpile zones.
- Buildings: stockpile marker, hut/bed, workshop, wall/floor block.
- Time ticking in discrete simulation steps.

### Out of MVP

- Combat.
- Procedural world history.
- Deep geology/z-level mining.
- Fluid simulation.
- Complex personality simulation.
- Relationships/families.
- Weather/seasons.
- Trading/caravans.
- Detailed animations.
- Save/load unless we explicitly add it as a task.

---

## Game Loop

1. Player surveys map.
2. Player designates gathering/building work.
3. Job system creates job records.
4. Units evaluate and claim jobs.
5. Units travel to targets.
6. Units work, transform world state, and produce/consume items.
7. Hauling jobs move outputs to stockpiles.
8. Buildings unlock better jobs.
9. Needs pressure the settlement: food, sleep, shelter.
10. Player adjusts priorities and expands.

---

## Main Systems

### 0. Determinism and Future Multiplayer Contract

The MVP is single-player, but the simulation architecture must remain compatible with future multiplayer. Treat this as a hard constraint from the beginning.

Authoritative simulation rules:

- Simulation advances only through fixed ticks and ordered command inputs.
- All player actions become command records: `tick`, `player_id`, `command_type`, `target_cell`, `payload`, and deterministic `command_id`.
- The simulation never reads wall-clock time, frame delta, random globals, mouse state, camera state, scene-tree order, or physics collision order to decide game state.
- Rendering and UI read simulation state; they do not mutate it directly.
- Random events use named seeded RNG streams stored in the simulation snapshot, e.g. `world_rng`, `unit_rng`, `event_rng`.
- Entity ids are deterministic and monotonic, e.g. `unit_000001`, `job_000001`, `item_000001`.
- System updates happen in a documented stable order: commands -> needs -> job generation -> reservations -> unit decisions -> movement -> work completion -> cleanup.
- Ties are broken deterministically by priority, distance, then entity id.
- Save/snapshot serialization must be canonical enough to hash.

Multiplayer path this preserves:

- **Lockstep option:** each client starts from the same snapshot, exchanges ordered commands, and verifies state hashes every N ticks.
- **Server-authoritative option:** server runs the same deterministic simulation and streams snapshots/deltas to clients.

**Testable behaviors:**

- Running the same initial snapshot and same command list twice produces identical canonical state hashes.
- Reordering commands with the same tick but different command ids produces a defined canonical order.
- Job assignment tie-breaks are stable across runs.
- Seeded random resource/event generation is repeatable.
- Presentation-only updates do not alter simulation hash.

### 1. Simulation Clock

- Runs fixed simulation ticks independent of render frames.
- Supports pause, normal speed, fast speed.
- Emits tick events to systems.

**Testable behaviors:**
- Paused clock does not advance simulation.
- Normal speed advances one tick step.
- Fast speed advances multiple steps.
- Systems receive deterministic tick counts.

### 2. Chunk World Model

The world is a 3D volume of cells stored in `ChunkedWorldStore`. Cells are addressed by `world_cell: Vector3i(x, y, z)` where x is east, z is south, and y increases upward (y=0 is the surface reference, negative y is underground).

Each cell payload holds:

- `terrain` and `material_key`: what the cell is made of.
- `walkable`: whether units can stand here.
- `strata_key` and `mining_tier_required`: what tools are needed to excavate.
- `resource_id` and `building_id`: occupant references.
- `is_cave`, `is_river`, `exposure`: environmental flags.
- `surface_height`, `slope_degrees`: terrain shape metadata.

World generation (`WorldGen`) writes cells directly into `ChunkedWorldStore`. There is no 2D projection layer. Pathfinding, picking, and mutation all operate on `world_cell` coordinates.

**Testable behaviors:**
- `WorldGen.generate()` produces the expected cell count and strata distribution for a given seed.
- Cell lookup by world_cell is deterministic and bounds-safe.
- Mining a cell updates the chunk store payload and is reflected in pathfinding.
- Same seed produces the same canonical chunk store hash.

### 3. Resource and Item Model

Start small:

- `wood`
- `stone`
- `food`
- `tool` later

Items can exist:

- At a world cell.
- In a unit inventory.
- In a stockpile.
- Reserved for a job.

**Testable behaviors:**
- Creating an item increments world item count.
- Reserving an item prevents double assignment.
- Moving item from ground -> unit -> stockpile preserves count.
- Construction consumes required resources exactly once.

### 4. Unit Model

Unit fields:

- `id`
- `display_name`
- `position`
- `inventory`
- `allowed_jobs`
- `skills`
- `current_job_id`
- `needs`: hunger, energy, morale placeholder
- `state`: idle, walking, working, hauling, eating, sleeping

**Testable behaviors:**
- Idle unit claims valid available job.
- Unit does not claim disallowed job type.
- Unit does not claim already claimed job.
- Unit can carry item up to capacity.
- Need thresholds create eat/sleep jobs or alter priority later.

### 5. Job System

Job fields:

- `id`
- `type`
- `target_cell`
- `required_skill`
- `required_items`
- `produced_items`
- `priority`
- `status`: open, claimed, in_progress, complete, failed
- `claimed_by_unit_id`
- `work_remaining_ticks`

Initial job types:

- `CHOP_TREE`
- `MINE_STONE` or `GATHER_STONE`
- `HAUL_ITEM`
- `BUILD_STRUCTURE`
- `GATHER_FOOD`
- `EAT`
- `SLEEP`

**Testable behaviors:**
- Designation creates correct job.
- Highest priority valid job is selected.
- Distance can break ties.
- Completed gather job produces correct item.
- Completed build job consumes input and creates building.
- Failed job releases reservations.

### 6. Pathing / Movement

Start with grid pathfinding for simulation. Visual units can move along grid centers in 3D.

Options:

- Phase 1: deterministic Manhattan pathfinder on a grid for tests.
- Phase 2: integrate NavigationAgent3D for smoother runtime movement.

**Testable behaviors:**
- Finds path around blocked cells.
- Returns no path when target unreachable.
- Unit reaches target after expected ticks.
- Job fails or waits if path unavailable.

### 7. Buildings and Construction

Initial buildings:

- Stockpile zone marker.
- Hut / shelter.
- Bed.
- Workshop.
- Wall block.
- Floor/road tile.

Construction flow:

1. Player places blueprint.
2. Blueprint creates `BUILD_STRUCTURE` job.
3. Required items are reserved or hauling jobs are created.
4. Builder works for N ticks.
5. Blueprint becomes finished building.

**Testable behaviors:**
- Blueprint is not usable before complete.
- Build job waits/fails if resources unavailable.
- Hauling resource to blueprint enables build.
- Finished building updates walkability if wall/road.

### 8. Stockpiles and Logistics

Stockpile zones define where resources should be stored.

Initial rules:

- Each stockpile accepts allowed resource types.
- Loose items generate hauling jobs if a matching stockpile has space.
- Units carry items to stockpile cells.

**Testable behaviors:**
- Loose wood creates haul job to wood stockpile.
- Stockpile does not accept disallowed item.
- Full stockpile rejects more items.
- Item in stockpile is available for construction/crafting.

### 9. Needs and Survival

MVP needs:

- Hunger: increases over time, decreases when eating food.
- Energy: decreases while working, increases while sleeping.
- Morale: placeholder value affected later.

**Testable behaviors:**
- Hunger increases per tick.
- Hungry unit prioritizes eating over ordinary work.
- Eating consumes one food and reduces hunger.
- Tired unit sleeps if bed/sleep spot exists.

### 10. UI / Player Controls

Initial UI:

- Top bar: resources, population, time controls.
- Left tool palette: gather, build, zones, inspect.
- Right inspector: selected unit/building/job details.
- Overlay labels/icons for jobs and units.

**Testable behaviors:**
- UI buttons create correct current tool mode.
- Selecting a unit populates inspector data.
- Placing a build command creates blueprint/job.
- Time controls call simulation clock correctly.

### 11. Technology Progression and Research

Technology is the long-term spine of the game. New eras unlock by satisfying concrete material, building, knowledge, and labor requirements rather than by abstract points alone.

Tech unlock examples:

- **Primitive survival:** hand gathering, wood shelter, campfire, basic stockpile.
- **Stone tools:** requires stone + wood + crafting spot; unlocks faster chopping/mining and stone construction.
- **Farming:** requires gathered seeds/food knowledge; unlocks farm plots, food storage, kitchens.
- **Mining:** requires stone tools; unlocks ore extraction and underground/rock resource nodes.
- **Charcoal and smelting:** requires wood supply + furnace; unlocks metal bars.
- **Forging:** requires metal bars + forge; unlocks metal tools, weapons later, machine parts.
- **Mechanical power:** requires refined materials; unlocks mills, powered workshops, conveyors later.
- **Electricity:** requires copper/iron/coal or alternate fuel chain; unlocks generators, wires, lights, advanced workshops.
- **Automation:** requires electricity + machine parts; unlocks automated production buildings and high-throughput logistics.

Research should remain deterministic:

- Research progress advances on fixed ticks.
- Research tasks consume documented inputs.
- Unlock order is defined by tech graph prerequisites.
- Any random discovery events use seeded simulation RNG.

**Testable behaviors:**

- Locked building/job cannot be created before prerequisite tech.
- Completing prerequisite resources/buildings/research unlocks the next tech.
- Research consumes required inputs exactly once.
- Same initial state and command sequence produces same tech unlock tick.

### 12. Production Chains and Industry

Supply chains should start simple and become the main strategic challenge.

Early chain examples:

```text
Tree -> Log -> Plank -> Shelter
Berry Bush -> Food -> Meal -> Fed Unit
Stone Node -> Stone -> Stone Tool -> Faster Gathering
```

Mid-game chain examples:

```text
Tree -> Log -> Charcoal -> Furnace Fuel
Ore Node -> Ore -> Metal Bar -> Metal Tool
Grain Farm -> Grain -> Flour -> Bread -> Meal
```

Late-game chain examples:

```text
Coal + Water -> Steam Power -> Powered Workshop
Copper Ore -> Copper Bar -> Wire -> Electrical Grid
Iron Bar + Machine Parts -> Conveyor -> Automated Logistics
Advanced Materials -> Research Lab -> Advanced Tech
```

**Testable behaviors:**

- Production recipes require correct inputs and produce correct outputs.
- Missing input stalls production without deleting resources.
- Multi-step chains conserve resources across transforms.
- Buildings only advertise jobs unlocked by current tech.
- Higher-tier tools improve job speed through deterministic modifiers.

---

## Proposed Godot Project Structure

```text
fortress/
├── project.godot
├── scenes/
│   ├── Main.tscn
│   ├── world/WorldRoot.tscn
│   ├── units/UnitView.tscn
│   ├── buildings/BuildingView.tscn
│   └── ui/GameHud.tscn
├── scripts/
│   ├── main.gd
│   ├── simulation/
│   │   ├── simulation.gd
│   │   ├── sim_clock.gd
│   │   ├── world_constants.gd       ← terrain/material/strata/mining-tier constants
│   │   ├── worldgen.gd              ← generates cells directly into ChunkedWorldStore
│   │   ├── chunked_world_store.gd   ← authoritative 3D cell store
│   │   ├── chunk_addressing.gd      ← world↔chunk↔local coordinate math
│   │   ├── chunked_world_read_adapter.gd
│   │   ├── unit.gd
│   │   ├── job.gd
│   │   ├── job_board.gd
│   │   ├── item.gd
│   │   ├── stockpile.gd
│   │   ├── building_definition.gd
│   │   ├── construction_record.gd
│   │   ├── technology.gd
│   │   ├── recipe.gd
│   │   └── production_building.gd
│   ├── presentation/
│   │   ├── world_renderer.gd
│   │   ├── unit_view.gd
│   │   └── camera_controller.gd
│   └── ui/
│       ├── game_hud.gd
│       └── inspector_panel.gd
├── resources/
│   ├── jobs/
│   ├── buildings/
│   ├── technologies/
│   ├── recipes/
│   └── items/
├── tests/
│   ├── static_project_checks.py
│   ├── run_godot_tests.gd
│   ├── test_sim_clock.gd
│   ├── test_chunk_world.gd          ← replaces test_grid_world.gd
│   ├── test_job_board.gd
│   ├── test_determinism_replay.gd
│   ├── test_command_ordering.gd
│   ├── test_seeded_rng.gd
│   ├── test_unit_jobs.gd
│   ├── test_resources_stockpiles.gd
│   ├── test_construction.gd
│   └── test_needs.gd
└── docs/
    ├── 3d-city-fortress-game-plan.md
    ├── ironveil-worldgen-chunk-architecture.md
    └── ironveil-world-generation-tasks.md
```

---

## Milestones

## Milestone 0: Foundation and Test Harness

**Goal:** Create a clean Godot 4.6 3D project and automated tests before game systems.

### Tasks

1. Create `project.godot` targeting Godot 4.6 and `scenes/Main.tscn`.
2. Create `tests/static_project_checks.py` that initially fails for missing systems.
3. Create `tests/run_godot_tests.gd` test runner.
4. Add a minimal `Main` 3D scene with camera/light/world root/HUD placeholder.
5. Verify static tests pass and Godot headless test runner runs where Godot 4.6 exists.

### Conclusive Tests

```bash
python3 tests/static_project_checks.py
```

Expected: validates file structure, Godot 4.6 config marker, main scene path, 3D root scene, and test files.

```bash
godot4 --headless --path . --script res://tests/run_godot_tests.gd
```

Expected: exits 0 with empty/smoke test pass.

---

## Milestone 1: Deterministic Simulation Core

**Goal:** Build the non-rendered simulation foundation with deterministic replay/hash guarantees for a future multiplayer path.

### Tasks

1. Implement `sim_clock.gd`.
2. Implement `world_constants.gd`, `worldgen.gd`, `chunked_world_store.gd`, and `chunk_addressing.gd`.
3. Implement `item.gd`, `unit.gd`, `job.gd`, and `job_board.gd`.
4. Implement deterministic command queue and canonical command ordering.
5. Implement deterministic id allocation for units, jobs, items, buildings, and commands.
6. Implement seeded RNG streams owned by simulation state.
7. Implement canonical state serialization and `state_hash()`.
8. Implement deterministic tick update in `simulation.gd`.

### Conclusive Tests

- `test_sim_clock.gd`: pause/speed/tick events.
- `test_chunk_world.gd`: cell placement, world-cell bounds, walkability, and worldgen determinism.
- `test_job_board.gd`: job creation, claiming, priority, completion.
- `test_determinism_replay.gd`: same snapshot + same commands + same tick count produces identical `state_hash()` across repeated runs.
- `test_command_ordering.gd`: commands for the same tick are applied in canonical `(tick, command_id)` order.
- `test_seeded_rng.gd`: same seed creates same resource/event sequence; different seed creates a different sequence.

Expected: all simulation core tests pass headless without opening a window.

---

## Milestone 2: Units Claim and Complete Jobs

**Goal:** Units can autonomously do simple jobs.

### Tasks

1. Add job selection rules.
2. Add unit state machine.
3. Add work timers.
4. Add job completion effects for `GATHER_WOOD`, `GATHER_STONE`, and `GATHER_FOOD`.

### Conclusive Tests

- Idle unit claims highest priority valid job.
- Disallowed jobs are skipped.
- Two units do not claim the same exclusive job.
- Completing gather job creates correct item.
- Failed job releases claim/reservations.

---

## Milestone 3: 3D Blockout World and Camera

**Goal:** Show the simulation in 3D with simple placeholder visuals.

### Tasks

1. Create terrain grid renderer using cubes/planes.
2. Create resource node blockout meshes.
3. Create unit placeholder scene.
4. Create camera controller.
5. Sync visual positions from simulation state.

### Conclusive Tests

Static:

- Required scenes/scripts exist.
- Main scene contains `Camera3D`, `DirectionalLight3D`, `WorldRoot`, and `GameHud`.

Godot headless/smoke:

- Instantiating `Main.tscn` creates expected node tree.
- Spawning simulation with N units creates N `UnitView` nodes.
- Updating simulation moves visual units to expected positions.

Manual:

- Camera pan/rotate/zoom feels usable.
- Terrain/resource/unit visuals are readable.

---

## Milestone 4: Player Designations

**Goal:** Player can create work by interacting with the 3D world.

### Tasks

1. Add tool mode system: inspect, gather wood, gather stone, gather food.
2. Add grid-cell picking from mouse raycast.
3. Add designation overlay markers.
4. Convert designations into jobs.

### Conclusive Tests

- Setting gather tool changes active tool mode.
- Clicking a tree cell creates one `CHOP_TREE` job.
- Clicking invalid terrain creates no job and returns warning.
- Duplicate designation does not create duplicate job.

Manual:

- Mouse selection aligns with visible cells.
- Designation markers are visible and clear.

---

## Milestone 5: Stockpiles and Hauling

**Goal:** Resources move through the city instead of teleporting.

### Tasks

1. Add stockpile zone model.
2. Add item locations.
3. Add hauling jobs.
4. Add unit inventory/carrying.
5. Add stockpile visualization.

### Conclusive Tests

- Loose item plus valid stockpile creates haul job.
- Hauler picks item up, item location becomes unit inventory.
- Hauler deposits item, item location becomes stockpile.
- Resource counts remain conserved.
- Full/disallowed stockpile rejects item.

---

## Milestone 6: Construction

**Goal:** Player places blueprints and units build them using resources.

### Tasks

1. Add building definitions.
2. Add blueprint placement.
3. Add required resource reservation.
4. Add build jobs.
5. Add completed building state/visuals.

### Conclusive Tests

- Placing wall blueprint creates build job.
- Build job waits when required stone unavailable.
- Stockpiled stone is reserved and consumed.
- Completed wall exists and updates walkability.
- Blueprint cannot be completed twice.

---

## Milestone 7: Needs and City Pressure

**Goal:** Settlement requires food/rest management.

### Tasks

1. Add hunger and energy needs to units.
2. Add eat behavior and food consumption.
3. Add sleep behavior and rest spots/beds.
4. Add warnings for starving/exhausted units.

### Conclusive Tests

- Hunger increases over ticks.
- Hungry unit prioritizes eating over low-priority work.
- Eating consumes food and reduces hunger.
- Energy decreases during work.
- Sleeping restores energy.

---

## Milestone 8: Technology and Production Chains

**Goal:** Turn the settlement from survival into civilization progression by unlocking better buildings, jobs, tools, and production recipes.

### Tasks

1. Add technology graph model.
2. Add recipe model.
3. Add crafting/production jobs.
4. Add simple workshop building.
5. Add tech prerequisites for buildings/jobs.
6. Add deterministic research/progress commands.

### Conclusive Tests

- Locked recipe/building cannot be used before tech unlock.
- Crafting stone tools consumes wood/stone and produces tool.
- Stone tools deterministically improve gather/mine work speed.
- Smelting chain consumes ore + fuel and produces metal bar.
- Same replay unlocks the same tech at the same tick.

---

## Milestone 9: MVP Playable Loop

**Goal:** A small settlement can gather, haul, build, eat, rest, craft better tools, unlock early mining/production, and be inspected.

### Acceptance Scenario

Starting state:

- 5 units.
- Forest clearing with no built infrastructure.
- 10 trees.
- 10 stone nodes.
- 3 shallow ore nodes locked behind early mining/tool progression.
- 5 food nodes.
- No stockpile zone yet.
- No shelter yet.
- Primitive survival tech unlocked only.

Player actions:

1. Designate 5 trees.
2. Create wood stockpile.
3. Place shelter blueprint requiring wood.
4. Designate stone gathering.
5. Create crafting spot/workshop.
6. Queue stone tool recipe.
7. Use stone tools to unlock/perform early mining.
8. Start simulation.

Expected autonomous outcome:

- Units chop trees.
- Wood items appear.
- Haulers move wood to stockpile/blueprint.
- Builder constructs shelter.
- Units gather stone.
- Crafter makes stone tool from wood/stone.
- Stone tool or related tech unlock improves resource gathering/mining.
- Early mining produces ore or unlocks the next production step.
- Hungry units eat if food is available.
- City state remains inspectable and no resources duplicate/disappear.

### Conclusive Tests

Create an integration headless test:

```bash
godot4 --headless --path . --script res://tests/test_mvp_city_loop.gd
```

Expected:

- After fixed tick count, shelter is built.
- At least one resource item was hauled.
- Stone tool is crafted from gathered materials.
- Early mining/tool progression unlock occurs deterministically.
- No unit has invalid job reference.
- Total resource accounting balances.
- Final `state_hash()` matches expected value for the fixture.
- No failed assertions.

Manual playtest:

- Run for 10 minutes.
- Player can understand what units are doing.
- Camera and UI are usable.
- No obvious deadlock in basic loop.

---

## First Vertical Slice Recommendation

Start with this smallest impressive loop:

**“Five units build a shelter from gathered wood while keeping food stocked.”**

This proves:

- 3D world exists.
- Units are autonomous.
- Job assignment works.
- Gathering works.
- Hauling works.
- Construction works.
- Needs matter.
- Player direction matters.

Avoid mining, crafting chains, combat, and deep procedural generation until this loop is solid.

---

## Implementation Order Summary

1. Project/test harness.
2. Simulation clock.
3. Deterministic command queue, seeded RNG, ids, canonical state hash.
4. Chunk world (`WorldGen` + `ChunkedWorldStore`, no projection layer).
5. Units/jobs/items data models.
6. Job assignment and completion.
7. 3D blockout visualization (chunk-based renderer, no GridWorld).
8. Camera and HUD.
9. Designation tools (world-cell picking).
10. Stockpiles and hauling.
11. Construction (surface and underground).
12. Needs.
13. Technology graph and recipes.
14. Crafting/production chains.
15. Vertical world expansion (deeper mining, wider map).
16. MVP city-loop integration test.
17. Manual playtest and tuning.

---

## Risks and Design Constraints

### Risk: Accidental nondeterminism blocks future multiplayer

Mitigation: simulation code may not use frame delta, wall-clock time, global random functions, unordered dictionary iteration, scene-tree order, physics callback order, or presentation state for authoritative decisions. Add replay/hash tests in Milestone 1 and keep them in every later milestone.

### Risk: Too much Dwarf Fortress complexity too early

Mitigation: start with the current 16×4 surface footprint and 5 strata layers, few resources, few jobs. Expand z-levels only after the core loop is solid (see Task 20 in worldgen tasks).

### Risk: 3D visuals obscure simulation state

Mitigation: strong overlays, labels, debug views, simple icons, and inspector panels.

### Risk: Godot navigation complexity slows progress

Mitigation: start with deterministic grid pathfinding; upgrade visual movement later.

### Risk: Job system deadlocks

Mitigation: write tests for reservations, unreachable jobs, failed jobs, and resource conservation.

### Risk: Tests become brittle due scene formatting

Mitigation: static tests should validate intent and node presence, not exact `.tscn` formatting beyond necessary names/paths.

---

## Definition of Done for MVP

The MVP is done when:

- Godot 4.6 project opens and runs.
- Static validator passes.
- Headless simulation tests pass.
- Deterministic replay/hash tests pass.
- Main 3D scene loads with camera, terrain, units, resources, and HUD.
- Player can designate gathering, stockpiles, construction, and early crafting/production.
- Units autonomously gather, haul, build, eat, rest, craft, and mine.
- Stockpile/resource accounting is correct.
- Tech graph gates buildings/jobs/recipes correctly.
- At least one progression step from primitive survival to better technology is playable, e.g. stone tools or early mining.
- MVP city-loop integration test passes with expected final `state_hash()`.
- Manual 10-minute playtest confirms the loop is understandable and does not deadlock.
- No combat, deep worldgen, advanced animation, or other scope creep is required for MVP.
