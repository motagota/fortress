# Ironveil World Generation Tasks

## Implementation Roadmap

### Task 1: Deterministic Layered Worldgen Foundation — Done

Replace the ad hoc forest fixture with a named Ironveil-style generator while preserving `create_forest()` compatibility. Generate starting clearing, dirt workyard, surface grass, shallow dirt, surface stone, trees, and berry bushes from seeded deterministic noise.

### Task 2: Cell Material Vocabulary — Done

Add canonical material keys: `AIR`, `DIRT`, `CLAY`, `GRAVEL`, `SOFT_ROCK`, `HARD_ROCK`, `BEDROCK`, and surface resource keys.

### Task 3: Height Map and Surface Shape — Done

Add a deterministic height map abstraction for XZ columns. Expose height/slope as metadata used by scatter and rendering.

### Task 4: Strata and Mining Tiers — Done

Convert depth bands into explicit strata rules. Level-one mining limited to grass, dirt, loose stone, and shallow rock.

### Task 5: Ore and Oil Passes — Partial by Design

Seeded ore placement after base strata. Coal/copper/iron as hidden mine outputs in rock bands. Silver/gold/oil deferred until processing chains support them.

### Task 6: Rivers, Lakes, Clay, and Gravel — Partial by Design

Precomputed river map over the surface projection. River-adjacent dirt to clay, riverbeds to gravel. Fishing deferred until water resources and food jobs are ready.

### Task 7: Caves and Vertical Expansion — Partial by Design

Cave voids as exposed underground cells. Deeper volumetric expansion tracked in Tasks 19–22 below.

### Task 8: Lava and Deep Hazards — Deferred

Add bedrock/lava only after full vertical world model supports deep Y-ranges.

### Task 9: Worldgen Architecture and Chunk Storage Boundary — Done

Define canonical world coordinate model (x, y, z), chunk coordinates, local coordinates, and stable conversion functions. Introduce ChunkAddressing and ChunkedWorldStore as the authoritative boundary.

### Task 10: Minimal ChunkedWorldStore Data Owner — Done

ChunkedWorldStore imports projected GridWorld cells through the Task 9 boundary. Dictionary-backed `ironveil_cell_payload_v1` records stored per cell.

### Task 11: Read-Only Chunk Store Projection Inspection — Done

Read-only comparator checks GridWorld projection against ChunkedWorldStore. Reports matching pairs, missing cells, extra cells, and field-level mismatches.

### Task 12: Packed Cell Serialization Layer — Done

Versioned `ironveil_packed_cell_v1` packed records stored beside dictionary payloads. Validated by unpacking and comparing against the dictionary payload.

### Task 13: Read-Only Worldgen Storage Diagnostics — Done

Read-only diagnostics around projection/store/packed comparison. `Simulation.get_worldgen_storage_diagnostics()` and `log_worldgen_storage_diagnostics()`.

### Task 14: Read-Only Chunked World Adapter — Done

`ChunkedWorldReadAdapter` reads chunk-store payloads by projected cell or world cell. Returned by `Simulation.get_chunked_world_read_adapter()` with `authoritative = true`.

### Task 15: Debug UI Storage Diagnostics — Done

Hidden worldgen diagnostics panel in `GameHud`, toggled by `D` key. Displays projection/chunk-store/packed-payload report from `Simulation.get_worldgen_storage_diagnostics()`.

### Task 16: Actual 3D Chunk Volume — Done (for rendering/debugging slice)

`ChunkedWorldStore.import_actual_chunk_volume()` fills one exact 16×16×16 chunk with volume cells. Intermediate underground cells generated from strata rules.

### Task 17: Authoritative Projected Chunk Store — Done

Simulation owns an `authoritative_projected_world_v1` ChunkedWorldStore. Gameplay writes (mining, resource depletion, cave-ins, building placement) go through chunk payloads. GridWorld kept as a synchronized compatibility mirror.

### Task 18: 3D Gameplay Identity for Dynamic Systems — Done

Units, items, jobs, stockpiles, constructions, and resources carry `world_cell` / `world_cells`. Movement, item creation, and job distance use 3D coordinates. Dynamic renderer prefers world-cell fields.

---

### Task 19: Complete GridWorld Removal — In Progress

**Goal:** Delete `grid_world.gd` and `cell.gd`. Make `ChunkedWorldStore` and `WorldGen` the sole source of world truth with no projection mirror.

**Changes:**
- `WorldGen` (`worldgen.gd`) generates cells directly into `ChunkedWorldStore` using `(x, depth_y, display_z)` world cells. No GridWorld created at startup.
- `world_constants.gd` owns all `TERRAIN_*`, `MATERIAL_*`, `STRATA_*`, `MINING_TIER_*` constants.
- `Simulation.initialize_new_game()` calls `WorldgenScript.generate(chunk_world_store, resources, seed)` — no GridWorld.
- All simulation mutation methods (`_mine_cell_authoritative`, `_collapse_cell_authoritative`, `_clear_resource_authoritative`, `_set_building_on_cell_authoritative`) accept `world_cell: Vector3i` directly.
- Pathfinding (`_movement_world_neighbors`, `_can_step_between_world_cells`) queries chunk store directly. No GridWorld iteration.
- `WorldRenderer._sync_chunk_volume()` reads from `simulation.chunk_world_store` directly — no `import_playable_chunk_volume(grid_world)`.
- Raycasting (`ray_to_world_cell`) intersects visible chunk cells — no GridWorld parameter.
- Delete `grid_world.gd`, `cell.gd`. Remove all preloads and references.
- Simplify `worldgen_diagnostics.gd` (no GridWorld comparison path).
- Simplify `chunked_world_read_adapter.gd` (no `import_projected_world` path).

**Acceptance criteria:**
- `grid_world.gd` and `cell.gd` do not exist.
- Game launches and units gather, mine, haul, and build correctly.
- Mouse picking and hover work on surface and underground cells.
- No reference to `GridWorld`, `SimCell`, `projected_cell` (beyond transitional public API) remains in simulation or renderer.

---

### Task 20: True Vertical Mining Depth

**Goal:** Expand the world from 5 depth strata (y=0 to y=-4) to a full vertical column (y=+2 to y=-15 or configurable). Each (x, z) position has one cell per y-level.

**Changes:**
- `WorldGen` generates cells in a full `(x, y, z)` volume loop where z is the north-south axis (0 to WORLD_DEPTH_Z-1) and y spans the full vertical range.
- Strata rules map y-values to material types: grass/soil near surface, soft rock below, hard rock and eventual bedrock at deep levels.
- Height map drives the surface y-level per (x, z) column — cells above surface height are AIR.
- Pathfinding already handles arbitrary y-levels; renderer cutaway depth extended to show deeper layers.
- Mining designation valid for any y-level cell that is mineable.

**Acceptance criteria:**
- World contains cells from y=+2 (hills) to y=-12 (deep rock).
- Mining into deep rock reveals hard rock / coal / iron strata.
- Camera layer cutaway can be shifted down to reveal underground cells.
- Pathfinding routes through excavated vertical shafts.

---

### Task 21: Wider Surface Footprint

**Goal:** Expand the playable surface from 16×4 to a configurable XZ size (e.g. 32×32).

**Changes:**
- `WorldGen.WORLD_WIDTH` and `WORLD_DEPTH_Z` become constructor parameters.
- Chunk addressing already supports multi-chunk spans; no fundamental changes needed.
- WorldRenderer iterates the visible chunk region rather than a fixed 16-cell range.
- Camera bounds updated to match the larger world.

**Acceptance criteria:**
- World generates without errors at 32×32 surface size.
- Resource density is consistent (not all resources bunched in one corner).
- Rendering covers the full map without gaps.

---

### Task 22: Full Cave and Void Systems

**Goal:** Cave generators carve continuous voids across many y-levels. Exposure tracking correctly marks which cells see sky vs cave ceiling.

**Changes:**
- Cave carving operates on the full vertical column; a cave at (x, z) removes cells across a range of y-values.
- `exposure` field: `"sky"` = unobstructed column above reaches open air; `"cave"` = above cell is solid (natural ceiling); `"covered"` = above cell is player-built.
- Pathfinding routes through connected cave voids.
- Renderer distinguishes sky-exposed and cave-interior cells by color/shading.

**Acceptance criteria:**
- Cave voids span multiple y-levels.
- Units can path through cave passages.
- Cave cells are visually distinct from sky-exposed cells in the renderer.

---

### Task 23: Underground Construction

**Goal:** Buildings can be placed in underground excavated cells (not just at the surface).

**Changes:**
- Blueprint placement valid for any walkable world cell regardless of y-level.
- Stockpile zones accept underground cells.
- Hauling paths route vertically through excavated shafts to reach underground stockpiles or construction sites.
- Building visualization renders correctly at underground y-levels using existing `_render_position_for_world_cell`.

**Acceptance criteria:**
- Player can place a stockpile in an excavated underground cell.
- Units haul items down a shaft to an underground stockpile.
- A simple building (e.g. workshop) can be constructed underground.

---

## Current Implementation State

Tasks 1–18 are complete. Task 19 (GridWorld removal) is in progress — `worldgen.gd` and `world_constants.gd` created, `simulation.gd` being rewritten, `world_renderer.gd` and `main.gd` updates pending.

Tasks 20–23 describe the 3D world expansion that becomes possible once the GridWorld layer is gone and `ChunkedWorldStore` owns the full simulation with no projection constraints.
