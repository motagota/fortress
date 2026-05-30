# Ironveil Worldgen Chunk Architecture

This document defines the authoritative chunk-world model that replaced the 2D GridWorld projection, and the direction for expanding toward a true volumetric 3D simulation.

---

## Migration Complete: GridWorld Removed

`GridWorld` (`grid_world.gd`) and its projected `SimCell` objects (`cell.gd`) have been deleted. `ChunkedWorldStore` is the sole authoritative cell store. There is no projection mirror, no sync loop, and no compatibility facade.

---

## Authoritative Coordinate Model

All cell addressing uses explicit 3D world coordinates:

| Axis | Direction | Reference |
|------|-----------|-----------|
| x | increases east | 0–15 current map width |
| z | increases south | 0–N within each depth layer |
| y | increases upward | 0 = surface, negative = underground |

**Current world layout** (5 strata layers, total 256 cells):

| Layer | y | display_z rows | Strata |
|-------|---|---------------|--------|
| Surface | 0 | 0–3 | surface |
| Soil | -1 | 0–2 | soil |
| Soft rock | -2 | 0–2 | soft_rock |
| Deep soil | -3 | 0–2 | deep_soil |
| Hard rock | -4 | 0–2 | hard_rock |

This is the starting volume. The intent is to expand it vertically and horizontally as gameplay warrants.

---

## Current File Structure

```
scripts/simulation/
├── world_constants.gd        — TERRAIN_*, MATERIAL_*, STRATA_*, MINING_TIER_* constants
├── worldgen.gd               — WorldGen: generates all cells directly into ChunkedWorldStore
├── chunked_world_store.gd    — ChunkedWorldStore: sole authoritative cell store
├── chunk_addressing.gd       — ChunkAddressing: world↔chunk↔local coordinate math
├── chunked_world_read_adapter.gd — read-only inspection adapter
├── simulation.gd             — Simulation: uses ChunkedWorldStore directly, no GridWorld
└── ...
```

`grid_world.gd` and `cell.gd` no longer exist.

---

## Movement and Pathfinding in 3D Space

Movement neighbors are computed directly from world_cell coordinates — no projection layer needed:

- **Horizontal:** `(x±1, y, z)` and `(x, y, z±1)` — if target is walkable and in chunk store
- **Vertical up:** `(x, y+1, z)` — valid if current cell is EXCAVATED
- **Vertical down:** `(x, y-1, z)` — valid if target cell is EXCAVATED

`_can_step_between_world_cells` reads chunk payloads directly; no SimCell objects are needed.

---

## Cell Payload Schema

Each cell stored in `ChunkedWorldStore` carries an `ironveil_cell_payload_v1` dictionary:

```
terrain, material_key, walkable, strata_key, mining_tier_required,
resource_id, building_id, hidden_mine_yield, is_river, river_id,
distance_to_river, water_feature, is_cave, cave_id, exposure,
surface_height, slope_degrees
```

World generation (`worldgen.gd`) writes these directly via `store.set_cell(world_cell, payload, source)`.

---

## World Generation Flow

```
WorldGen.generate(store, resources, seed)
  ├── _generate_height_map()       — per surface (x, display_z) column
  ├── _generate_river_map()        — surface river path
  ├── _generate_cave_map()         — soft_rock and hard_rock cave voids
  ├── layer × display_z × x loop  — base strata, initial clear, cave/hydrology rules
  ├── surface resource pass        — trees, stones, berry bushes
  ├── fallback resource placement  — guarantee at least one of each type
  └── _apply_hidden_ore_pass()     — coal, copper, iron in underground strata
```

All cells are written as `world_cell = Vector3i(x, depth_y, display_z)` directly into `ChunkedWorldStore`.

---

## Diagnostics and Inspection

`ChunkedWorldReadAdapter` reads from `ChunkedWorldStore` by world_cell or (x, z) surface coordinate.  
`WorldgenDiagnostics` is in the process of being simplified now that the GridWorld comparison path no longer exists.

---

## Feature Gates (still deferred)

The following require true volumetric cells (many y-levels, not just 5) before they are useful:

- True caves across many y-levels
- Lakes and water volumes
- Oil deposits and fluid extraction
- Lava and deep hazards
- Bedrock layers
- Silver/gold/deep ore economy
- Large world streaming

---

## Next Slices: Expanding the 3D World

The codebase is now GridWorld-free. The next direction is expanding the volumetric depth and world size:

### Slice 19 — True vertical mining depth
- Worldgen generates cells from `y = +2` (hills) down to `y = -15` (deep bedrock)
- Each (x, z) column has one cell per y-level rather than one per depth-band
- Pathfinding already handles arbitrary y-levels; renderer needs cutaway depth extended

### Slice 20 — Wider surface footprint
- Expand from 16×4 surface to 32×32 or configurable XZ size
- Chunk addressing already supports arbitrary world extents

### Slice 21 — Full cave and void systems
- Cave generators carve continuous voids across many y-levels
- Exposure tracking correctly marks which cells see sky vs cave ceiling

### Slice 22 — Underground construction
- Buildings may be placed underground in excavated cells
- Stockpiles track y-depth; hauling paths respect vertical movement cost
