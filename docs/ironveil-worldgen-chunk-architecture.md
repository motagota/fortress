# Ironveil Worldgen Chunk Architecture

This document defines the next storage boundary for moving from the current Godot projection toward real Ironveil-style 3D chunks.

## Current Runtime Shape

The current simulation uses `GridWorld` as a 16x16 compatibility facade. It stores cells by projected `(x, z)` coordinates, and each row belongs to one of five depth bands:

- surface;
- shallow soil;
- shallow stone;
- deep dirt;
- hard rock.

This model remains as a compatibility projection. Gameplay authority now lives in `ChunkedWorldStore`; `GridWorld` is synchronized from chunk payloads so older projected APIs can keep running during the migration. Jobs, items, stockpiles, constructions, units, resources, HUD lists, and dynamic 3D presentation now carry or prefer explicit `world_cell` / `world_cells` data.

## Target Coordinate Model

Use explicit 3D cell coordinates for all future storage-facing APIs:

- `world_cell`: `(x, y, z)`;
- `chunk_cell`: `(chunk_x, chunk_y, chunk_z)`;
- `local_cell`: `(local_x, local_y, local_z)`.

Conventions:

- `x` increases east.
- `z` increases south.
- `y` increases upward.
- Surface-adjacent gameplay should treat `y = 0` as the current playable surface reference until a full heightmap-to-world transform replaces it.
- Underground cells have negative `y`.
- Chunk edge length starts at `16`, matching the current projection width and the reserved `target_chunk_shape` of `[16, 16, 16]`.

## Projection Compatibility

The existing 16x16 projection should map into 3D world cells through a deterministic adapter:

- projected `x` maps to world `x`;
- projected row display position maps to world `z`;
- projected depth maps to world `y`;
- projected layer metadata remains available for compatibility rendering, picking, and tests.

For example, a projected cell with `depth == -2` should become a storage-facing world cell with `y == -2`, while keeping its current `Vector2i(x, row)` identity inside `GridWorld`.

The adapter began as one-way, but the authoritative direction is now:

1. Generate the existing projection for compatibility.
2. Import it into `ChunkedWorldStore` as `authoritative_projected_world_v1`.
3. Apply gameplay writes to chunk payloads.
4. Mirror the authoritative payload back into `GridWorld`.
5. Test that projection and chunk payloads remain identical.

New gameplay systems should read/write chunk payloads first. Existing projected systems may continue to read `GridWorld`, but only as a mirror of the authoritative chunk store. Entity identity should be stored in 3D world cells even when a projected field remains for compatibility.

## Chunk Storage Boundary

Introduce storage-facing objects separately from the gameplay facade:

- `WorldCellCoord`: helper functions or value representation for `(x, y, z)`.
- `ChunkCoord`: helper functions or value representation for `(chunk_x, chunk_y, chunk_z)`.
- `ChunkLocalCoord`: helper functions or value representation for `(local_x, local_y, local_z)`.
- `ChunkAddressing`: conversion helpers between world and chunk/local coordinates.
- `ChunkedWorldStore`: authoritative owner of gameplay cell payloads.

The first implementation uses simple dictionaries and typed helper functions over a packed binary format. Packed cells can follow once the coordinate contract and derived chunk-store import remain stable.

## Packed Cell Direction

The Ironveil design points toward packed cell data. Reserve room conceptually for:

- material key or material id;
- resource id or resource class;
- fluid id and amount;
- strata id;
- mining tier;
- visibility/exposure flags;
- cave/river/hazard flags.

Do not remove `SimCell` yet. Keep `SimCell` as the compatibility projection object while simulation systems are moved onto chunk-backed reads and writes.

The current packed layer uses `ironveil_packed_cell_v1` beside the dictionary payload. It packs common scalar fields into integer words and stores sidecar references for fields that are variable-length or not yet stable ids:

- `word0`: material id, terrain id, strata id, mining tier, and boolean flags.
- `word1`: surface height, slope, exposure id, and water-feature id.
- `refs`: resource id, cave id, hidden mine yield, and unmapped compatibility strings.

The dictionary payload in `ChunkedWorldStore` is the gameplay source of truth. Packed data is validated by unpacking and comparing against both the stored dictionary payload and the live projected `GridWorld` mirror.

## Current Store Slice

`ChunkedWorldStore` is the authoritative data owner under the `chunked_3d_v1` target model. It imports the current `GridWorld` projection through storage views and stores one `ironveil_cell_payload_v1` dictionary payload per projected cell.

The store preserves:

- world, chunk, and local coordinates;
- projected source coordinates;
- terrain and material compatibility fields;
- strata and mining tier;
- resource ids and hidden mine outputs;
- cave and river flags;
- height and slope metadata.

Simulation owns an authoritative chunk store. Gameplay writes such as resource depletion, mining, cave-ins, and completed building placement update chunk payloads first, then mirror those payloads back into `GridWorld` for projected compatibility.

Dynamic gameplay records now expose 3D identity:

- units and loose items carry `world_cell`;
- jobs carry `target_world_cell`;
- stockpiles and constructions carry `world_cells`;
- resources expose `world_cell` in canonical snapshots;
- HUD and dynamic renderer paths prefer those 3D fields and only fall back to projected fields for compatibility.

## Read-Only Inspection

`ChunkedWorldStore` includes a read-only projection comparator. It checks the imported chunk cells against a live `GridWorld` projection without mutating either side.

The comparator reports:

- matching projection/store pairs;
- missing chunk-store cells;
- extra chunk-store cells outside the projection;
- payload mismatches by field;
- source coordinate mismatches;
- world/chunk/local address mismatches.

This comparison path should be used as the guardrail for packed payload serialization and later gameplay migration.

## Diagnostics Logging

`WorldgenDiagnostics` builds a read-only storage report for the current projection. It imports `GridWorld` into a derived `ChunkedWorldStore`, runs projection comparison, validates packed payloads, and returns a structured report plus stable log lines.

`Simulation` exposes this through:

- `get_worldgen_storage_diagnostics()`;
- `log_worldgen_storage_diagnostics()`.

Diagnostics are read-only. They inspect the authoritative chunk store and verify that the projected `GridWorld` mirror still matches it without changing deterministic simulation state.

## Debug UI Diagnostics

The existing `GameHud` exposes the storage diagnostics report through a hidden read-only panel. It can be toggled with the `D` key or the `D Worldgen` HUD button.

The panel displays the same stable formatted lines as diagnostics logging:

- summary;
- projection import status;
- projection-vs-chunk-store comparison;
- packed payload validation;
- chunk-store metadata.

The panel reads through `Simulation.get_worldgen_storage_diagnostics()` and remains a read-only UI. The gameplay data source behind that report is the authoritative chunk store.

## Read-Only Adapter

`ChunkedWorldReadAdapter` reads chunk-store payloads back by projected cell or world cell. Standalone adapters can still import a projection for tests, but `Simulation.get_chunked_world_read_adapter()` returns the authoritative gameplay store.

Adapter reads return dictionaries marked:

- `read_only = true`;
- `authoritative = true` when returned by `Simulation`, because it reads the gameplay chunk store.

The adapter is useful for diagnostics, debug UI, and migration tests. It does not mutate state, but when it wraps `Simulation` storage it reads the same chunk payloads that own gameplay authority.

## Feature Gates

The following features should remain gated until chunk storage is real and gameplay can reason about vertical space:

- true caves across many `y` levels;
- lakes and water volumes;
- oil deposits and fluid extraction;
- lava and heat/deep hazards;
- bedrock layers;
- silver/gold/deep ore economy;
- large world streaming.

## First Implementation Slice

The first code slice added only the boundary:

- coordinate conversion helpers;
- projection-to-world mapping;
- chunk/local addressing tests;
- metadata round-trip tests from existing projected cells;
- storage metadata reporting `chunked_3d_v1` as the target model.

It should not enlarge the world, switch the renderer, or change worker pathing.

The second storage slice added `ChunkedWorldStore` as a derived owner:

- projection import;
- chunk-grouped dictionary payloads;
- deterministic canonical output;
- tests proving no mutation of the existing projection.

The third storage slice added read-only debug inspection:

- full projection-vs-store comparison;
- single-cell comparison;
- missing/extra cell reports;
- field-level payload mismatch reports.

The fourth storage slice added packed payload serialization:

- versioned `ironveil_packed_cell_v1` records;
- integer packed words plus sidecar refs;
- packed/unpacked validation;
- comparator coverage for corrupted packed data.

The fifth storage slice added read-only diagnostics/logging:

- import/projection/packed validation report;
- stable formatted log lines;
- simulation-level report/log helpers;
- state-mutation tests.

The sixth storage slice added a read-only adapter:

- projected-cell reads from chunk-store payloads;
- world-cell reads from chunk-store payloads;
- projection snapshot reads;
- explicit authoritative metadata when reading the simulation-owned store;
- state-mutation tests.

The seventh storage slice exposed diagnostics in the existing HUD:

- hidden worldgen diagnostics panel;
- `D` key and HUD button toggle;
- formatted projection/chunk-store/packed-payload report;
- mutation tests for the presentation sync path.

The eighth storage slice starts the actual 3D chunk data path:

- `ChunkedWorldStore.import_actual_chunk_volume()` fills one exact 16x16x16 chunk, starting with the first underground chunk at `(0, -1, 0)`;
- generated chunk cells use the same dictionary and packed payload schemas as the projection-derived store;
- exact projected cells are preserved when the current projection can resolve a world coordinate;
- intermediate vertical cells are generated from simple strata rules so the chunk is a real volume rather than a sparse projection;
- actual-volume imports remain derived visualization/debug data and are rejected when the requested chunk falls outside the current generated XZ bounds.

The ninth storage slice made the chunk store authoritative for projected gameplay:

- `Simulation` owns an `authoritative_projected_world_v1` `ChunkedWorldStore`;
- resource depletion, mining, collapse, and completed building placement write chunk payloads first;
- `GridWorld` is now a compatibility mirror for existing projected APIs;
- `Simulation.get_chunked_world_read_adapter()` exposes read-only authoritative chunk data.

The tenth storage slice moved dynamic gameplay identity and rendering overlays toward 3D:

- units, items, jobs, stockpiles, resources, and constructions publish world-cell coordinates in canonical state;
- movement and item creation update projected compatibility fields and world-cell identity together;
- job assignment distance uses 3D world-cell distance;
- dynamic meshes for items, stockpiles, jobs, units, buildings, and resource scatter prefer world-cell coordinates.

The next storage slice should move pathing, validation, and command targeting reads directly onto chunk queries instead of reading the `GridWorld` mirror.
