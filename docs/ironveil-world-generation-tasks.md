# Ironveil World Generation Tasks

Source review:

- `ironveil-world-generation.md` is a strong technical target, but it assumes Unreal C++ chunks, packed `uint32` cells, and a full +80m to -600m 3D volume.
- This Godot project currently uses a deterministic 16x16 simulation grid where rows are grouped into visible depth layers. The first implementation should translate Ironveil concepts into that existing model before expanding storage.
- `ironveil-worldgen.jsx` is a visual/design reference for cell definitions and generation passes. It is useful for constants, labels, thresholds, and ordering, but it is not directly reusable in the Godot runtime.

## Implementation Roadmap

### Task 1: Deterministic Layered Worldgen Foundation - Done

- Replace the ad hoc forest fixture with a named Ironveil-style generator while preserving `create_forest()` compatibility.
- Keep the current 16x16 stacked-layer projection: surface, shallow soil, deeper soil/stone, deep dirt, solid rock.
- Generate starting clearing, dirt workyard, surface grass, shallow dirt, surface stone, trees, and berry bushes from seeded deterministic noise.
- Add tests for same-seed determinism, different-seed variation, layer placement, and resource placement constraints.

### Task 2: Cell Material Vocabulary - Done

- Add canonical material keys matching the Ironveil design: `AIR`, `DIRT`, `CLAY`, `GRAVEL`, `SOFT_ROCK`, `HARD_ROCK`, `BEDROCK`, and surface resource keys.
- Keep existing terrain strings as presentation/gameplay compatibility fields until the simulation can handle packed/material cells directly.
- Add migration tests proving old mining, gathering, pathing, and rendering still read valid terrain/resource data.

### Task 3: Height Map and Surface Shape - Done for Current Projection

- Add a deterministic height map abstraction for XZ columns.
- In the current projection, expose height/slope as metadata used by scatter and future rendering.
- Later, expand from the 16x16 layer projection into true 3D chunks.

### Task 4: Strata and Mining Tiers - Done

- Convert depth bands into explicit strata rules.
- Keep level-one mining limited to grass, dirt, loose stone, and shallow rock.
- Add tool-gated mining for hard rock and future ore cells.

### Task 5: Ore and Oil Passes - Partial by Design

- Add seeded ore placement after base strata and cave carving rules exist.
- Start with coal/copper/iron as hidden mine outputs in rock bands.
- Add silver/gold/oil after inventory, tool tiers, and processing chains support them.

### Task 6: Rivers, Lakes, Clay, and Gravel - Partial by Design

- Add a precomputed river map over the surface projection.
- Convert river-adjacent dirt to clay and riverbeds to gravel.
- Add fishing spots only after water resources and food jobs support them.

### Task 7: Caves and Vertical Expansion - Partial by Design

- Add cave voids as exposed underground cells in the current projection.
- Expand storage toward real 3D chunks once mining and visibility rules need more than stacked rows.

### Task 8: Lava and Deep Hazards - Deferred by Design

- Add bedrock/lava only after the world model supports deep vertical ranges.
- Keep this out of early gameplay until pathing, mining support, and fluid rules can make it meaningful.

### Task 9: Worldgen Architecture and Chunk Storage Boundary - Done for Boundary Slice

- Architecture note: `docs/ironveil-worldgen-chunk-architecture.md`.
- Define the canonical world coordinate model before adding more generation passes:
  - world-space cell coordinates as `(x, y, z)`;
  - chunk coordinates as `(chunk_x, chunk_y, chunk_z)`;
  - local chunk coordinates as `(local_x, local_y, local_z)`;
  - stable conversion functions between world cells, chunk cells, and the existing 16x16 projection.
- Introduce a chunk storage abstraction without removing the existing `GridWorld` projection:
  - keep `GridWorld` as the compatibility facade used by current projected jobs, tests, and rendering;
  - make `ChunkedWorldStore` the authoritative owner for gameplay cell payloads;
  - preserve deterministic snapshots so same-seed tests remain stable.
- Decide the first packed cell schema:
  - reserve fields for material, resource, fluid, visibility, mining tier, strata, and flags;
  - document whether packed cells are introduced immediately or kept as a later serialization layer;
  - avoid changing gameplay systems to packed data until compatibility adapters exist.
- Add tests for coordinate conversion and compatibility:
  - converting projection cells to world/chunk coordinates is deterministic;
  - current `create_forest()` and `generate_ironveil_region()` outputs remain unchanged through the compatibility facade;
  - material, strata, cave, river, and height metadata survive round-trip conversion;
  - out-of-bounds and negative-depth coordinates fail predictably.
- Do not add lakes, oil, lava, deeper ores, or larger maps in this task. This task creates the storage boundary those features need.

Acceptance criteria:

- A small architecture document or code comments describe the chunk model, coordinate conventions, and compatibility boundary.
- The project exposes a `chunked_3d_v1` target model without switching runtime gameplay to it yet.
- Existing Godot worldgen, mining, gathering, pathing, and rendering tests still pass.
- New chunk coordinate tests pass.

### Task 10: Minimal ChunkedWorldStore Data Owner - Done for Derived Storage Slice

- Add a separate `ChunkedWorldStore` data owner that imports projected `GridWorld` cells through the Task 9 storage boundary.
- Store cells by chunk/local address under the `chunked_3d_v1` target model.
- Keep payloads as dictionary-backed `ironveil_cell_payload_v1` records for now; do not switch to packed binary cells yet.
- Preserve source projected coordinates, display coordinates, material, terrain, strata, resource, cave, river, height, and slope metadata.
- Add tests proving:
  - importing projection data does not mutate `GridWorld`;
  - every projected cell imports into chunk storage;
  - surface and underground chunks are both represented;
  - stored payloads match their projected source cells;
  - canonical chunk-store output is deterministic for the same seed and varies for different seeds.
- Keep the projected compatibility facade available while simulation authority moves into `ChunkedWorldStore`.

### Task 11: Read-Only Chunk Store Projection Inspection - Done

- Add a read-only debug/inspection path for comparing the current `GridWorld` projection against imported `ChunkedWorldStore` cells.
- Compare projected source coordinates, world/chunk/local addresses, payload fields, source metadata, cave/river flags, and height/slope metadata.
- Report clean matches, missing cells, extra cells, and field-level payload/source/address mismatches.
- Keep the comparator non-mutating for both the projection and chunk store.
- Add tests proving:
  - a matching projection/store pair reports valid with zero mismatches;
  - payload corruption is reported at the exact field;
  - an empty store reports missing projected cells;
  - cells outside the projection report as extra chunk cells.
- Keep packed-cell serialization deferred until the debug comparator can guard the conversion.

### Task 12: Packed Cell Serialization Layer - Done for Store Payloads

- Add a versioned packed payload representation for `ChunkedWorldStore` cells.
- Keep dictionary payloads as the authoritative compatibility payload for now.
- Store packed records beside dictionary payloads under `ironveil_packed_cell_v1`.
- Pack material, terrain, strata, mining tier, flags, exposure, water feature, surface height, and slope into integer words.
- Preserve resource ids, cave ids, hidden mine yields, and unmapped compatibility strings through sidecar references.
- Extend the Task 11 comparator so projected cells must match both dictionary payloads and unpacked packed payloads.
- Add tests proving:
  - all current projected payloads pack and unpack without mismatch;
  - unmapped/future strings survive through sidecar references;
  - corrupt packed records are reported by validation and projection comparison.
- Keep simulation authority on chunk dictionary payloads; packed cells remain a serialization/validation layer until gameplay can consume packed ids directly.

### Task 13: Read-Only Worldgen Storage Diagnostics - Done

- Add a read-only diagnostics/logging path around projection, chunk-store, and packed-payload comparison.
- Build diagnostics by comparing the projected `GridWorld` mirror against a `ChunkedWorldStore` and validating packed payloads. Through `Simulation`, diagnostics inspect the authoritative gameplay store.
- Expose simulation-level helpers:
  - `get_worldgen_storage_diagnostics()`;
  - `log_worldgen_storage_diagnostics()`.
- Format stable log lines for import, projection comparison, packed validation, and chunk-store metadata.
- Add tests proving:
  - diagnostics do not mutate simulation state;
  - a fresh generated world reports valid;
  - formatted lines include import/projection/packed status;
  - corrupt chunk-store packed payloads fail diagnostics.
- Diagnostics remain read-only, but they now inspect the simulation-owned authoritative chunk store when called through `Simulation`.

### Task 14: Read-Only Chunked World Adapter - Done

- Add a small read-only adapter that can import the current `GridWorld` projection into `ChunkedWorldStore` and read cells back by projected cell or world cell.
- Keep adapter output as plain dictionaries with `read_only = true`.
- Standalone imported adapters report `authoritative = false`; adapters returned by `Simulation.get_chunked_world_read_adapter()` report `authoritative = true` because they read the gameplay chunk store.
- Expose `Simulation.get_chunked_world_read_adapter()` for diagnostics and future debug tooling.
- Add tests proving:
  - adapter reads match `GridWorld` terrain, material, strata, depth, cave/river flags, height, and slope;
  - world-cell reads resolve back to the same projected source cell;
  - adapter construction and reads do not mutate simulation state;
  - mutating a returned read dictionary does not mutate adapter storage or `GridWorld`;
  - adapter projection snapshots are stable and bounds failures are explicit.
- Use the adapter for read-only diagnostics/debug inspection; gameplay writes go through the simulation-owned authoritative store.

### Task 15: Debug UI Storage Diagnostics - Done

- Expose the read-only worldgen storage diagnostics report in the existing `GameHud`.
- Add a hidden worldgen diagnostics panel that can be toggled from the HUD button or `D` key.
- Populate the panel from `Simulation.get_worldgen_storage_diagnostics()` only while the panel is visible.
- Show the same stable import, projection comparison, packed validation, and chunk-store metadata lines used by diagnostics logging.
- Add tests proving:
  - the `D` key toggles the diagnostics panel;
  - the panel displays a passing projection/chunk-store/packed-payload report;
  - syncing the diagnostics panel does not mutate simulation state.
- Keep the panel read-only. It may display authoritative chunk-store data, but it must not mutate workers, jobs, resources, mining, pathing, or rendering.

### Task 16: Actual 3D Chunk Volume - Started

- Add `ChunkedWorldStore.import_actual_chunk_volume()` as the first true-volume chunk import.
- Fill one exact 16x16x16 chunk instead of only storing the projected cells that happen to map into chunk space.
- Keep the same payload and packed-cell schemas so validation tooling can continue to inspect the data.
- Preserve exact projection payloads when a generated world coordinate maps back to the current stacked projection.
- Generate intermediate underground volume cells from strata rules until full vertical worldgen owns those cells directly.
- Keep actual-volume imports derived for rendering/debugging; gameplay authority is the simulation-owned projected chunk store.

### Task 17: Authoritative Projected Chunk Store - Done for Gameplay Write Authority

- Add a simulation-owned `ChunkedWorldStore` imported as `authoritative_projected_world_v1`.
- Treat chunk dictionary payloads as the authoritative gameplay cell state.
- Keep `GridWorld` as a synchronized projected mirror while remaining compatibility APIs still require `(x, z)` fields.
- Route gameplay writes for resource depletion, mining, collapse, and completed building placement through authoritative chunk payload updates.
- Expose `Simulation.get_chunked_world_read_adapter()` against the authoritative store with `authoritative = true` and `read_only = true`.
- Include authoritative chunk metadata and canonical cells in deterministic simulation snapshots.
- Add tests proving mined gameplay state is owned by the authoritative chunk store and mirrored into `GridWorld`.

### Task 18: 3D Gameplay Identity for Dynamic Systems - Done for First Migration Slice

- Add 3D world-cell identity to dynamic gameplay records:
  - units and items expose `world_cell`;
  - jobs expose `target_world_cell`;
  - stockpiles and constructions expose `world_cells`;
  - resources expose `world_cell` in canonical snapshots.
- Update simulation creation and movement paths so projected compatibility fields and 3D world-cell fields stay synchronized.
- Use 3D job distance for job assignment when workers choose among equally prioritized jobs.
- Move dynamic 3D presentation overlays for items, stockpiles, jobs, units, resources, and buildings to prefer world-cell fields instead of projected pairs.
- Update HUD job and worker lists to display 3D coordinates.
- Keep projected fields temporarily as compatibility inputs for command targeting, picking, pathing, and existing tests.

## Current Implementation State

Tasks 1-18 have been translated into the current Godot projection and architecture boundary. Tasks 1-4 are implemented as active gameplay/worldgen behavior. Tasks 5-8 have early slices plus explicit deferral gates where the full Ironveil design depends on inventory progression, processing chains, fluid rules, or true 3D chunks. Task 9 adds the chunk coordinate and projection compatibility boundary. Task 10 adds a `ChunkedWorldStore` data owner. Task 11 adds read-only projection-vs-store inspection. Task 12 adds packed serialization beside dictionary payloads. Task 13 adds read-only diagnostics/logging around the storage comparison path. Task 14 adds a read-only adapter. Task 15 exposes the diagnostics report in the existing HUD. Task 16 starts true-volume chunk generation for rendering/debugging. Task 17 makes the simulation-owned projected chunk store authoritative for gameplay writes while `GridWorld` remains a synchronized compatibility projection. Task 18 moves dynamic gameplay identity and presentation overlays to 3D world-cell coordinates while keeping projected command/picking/pathing compatibility fields.

The next code slice should move pathing, validation, command targeting, and mining reads directly onto authoritative chunk queries instead of reading the `GridWorld` mirror. It should keep projected fields only as edge compatibility for mouse picking and existing command payloads while those inputs migrate to explicit `world_cell` addresses.
