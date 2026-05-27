# Ironveil World Generation Tasks

Source review:

- `ironveil-world-generation.md` is a strong technical target, but it assumes Unreal C++ chunks, packed `uint32` cells, and a full +80m to -600m 3D volume.
- This Godot project currently uses a deterministic 16x16 simulation grid where rows are grouped into visible depth layers. The first implementation should translate Ironveil concepts into that existing model before expanding storage.
- `ironveil-worldgen.jsx` is a visual/design reference for cell definitions and generation passes. It is useful for constants, labels, thresholds, and ordering, but it is not directly reusable in the Godot runtime.

## Implementation Roadmap

### Task 1: Deterministic Layered Worldgen Foundation

- Replace the ad hoc forest fixture with a named Ironveil-style generator while preserving `create_forest()` compatibility.
- Keep the current 16x16 stacked-layer projection: surface, shallow soil, deeper soil/stone, deep dirt, solid rock.
- Generate starting clearing, dirt workyard, surface grass, shallow dirt, surface stone, trees, and berry bushes from seeded deterministic noise.
- Add tests for same-seed determinism, different-seed variation, layer placement, and resource placement constraints.

### Task 2: Cell Material Vocabulary

- Add canonical material keys matching the Ironveil design: `AIR`, `DIRT`, `CLAY`, `GRAVEL`, `SOFT_ROCK`, `HARD_ROCK`, `BEDROCK`, and surface resource keys.
- Keep existing terrain strings as presentation/gameplay compatibility fields until the simulation can handle packed/material cells directly.
- Add migration tests proving old mining, gathering, pathing, and rendering still read valid terrain/resource data.

### Task 3: Height Map and Surface Shape

- Add a deterministic height map abstraction for XZ columns.
- In the current projection, expose height/slope as metadata used by scatter and future rendering.
- Later, expand from the 16x16 layer projection into true 3D chunks.

### Task 4: Strata and Mining Tiers

- Convert depth bands into explicit strata rules.
- Keep level-one mining limited to grass, dirt, loose stone, and shallow rock.
- Add tool-gated mining for hard rock and future ore cells.

### Task 5: Ore and Oil Passes

- Add seeded ore placement after base strata and cave carving rules exist.
- Start with coal/copper/iron as hidden mine outputs in rock bands.
- Add silver/gold/oil after inventory, tool tiers, and processing chains support them.

### Task 6: Rivers, Lakes, Clay, and Gravel

- Add a precomputed river map over the surface projection.
- Convert river-adjacent dirt to clay and riverbeds to gravel.
- Add fishing spots only after water resources and food jobs support them.

### Task 7: Caves and Vertical Expansion

- Add cave voids as exposed underground cells in the current projection.
- Expand storage toward real 3D chunks once mining and visibility rules need more than stacked rows.

### Task 8: Lava and Deep Hazards

- Add bedrock/lava only after the world model supports deep vertical ranges.
- Keep this out of early gameplay until pathing, mining support, and fluid rules can make it meaningful.

## Current Start Point

The first code slice should deliver Task 1 only. It gives the project a deterministic worldgen surface that is compatible with existing workers, jobs, resources, mining tests, and 3D blockout rendering.
