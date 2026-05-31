extends Node3D

# Presentation-only, top-down single-layer renderer. Draws the active layer of
# the layered world as a flat 48x48 grid of colored tiles (floors, walls,
# liquids), with markers for plants, buildings, items, designations and units.
# It reads simulation state and never mutates it.

const C := preload("res://scripts/simulation/world_constants.gd")
const INVALID_CELL := Vector3i(-2147483648, -2147483648, -2147483648)

var active_layer: int = C.SURFACE_Y_MEAN
var hover_cell: Vector3i = INVALID_CELL
var _simulation = null

var _terrain: MeshInstance3D
var _markers: MeshInstance3D
var _units: MeshInstance3D
var _overlay: MeshInstance3D
var _stockpiles: MeshInstance3D
var _preview: MeshInstance3D

func _ready() -> void:
    _resolve_nodes()

func _resolve_nodes() -> void:
    _terrain = _ensure_mesh_node("Terrain")
    _markers = _ensure_mesh_node("Markers")
    _units = _ensure_mesh_node("Units")
    _stockpiles = _ensure_mesh_node("StockpileTiles")
    _preview = _ensure_mesh_node("StockpilePreview")
    _overlay = _ensure_mesh_node("Overlay")

func _ensure_mesh_node(node_name: String) -> MeshInstance3D:
    var existing := get_node_or_null(node_name)
    if existing is MeshInstance3D:
        return existing
    # A node by this name exists but is the wrong type (e.g. a stale placeholder);
    # drop it so we don't keep spawning fresh meshes alongside it every sync.
    if existing != null:
        existing.free()
    var node := MeshInstance3D.new()
    node.name = node_name
    add_child(node)
    return node

func set_active_layer(y: int) -> void:
    active_layer = clampi(y, 0, C.LAYER_COUNT - 1)
    if _simulation != null:
        sync_from_simulation(_simulation)

func set_hover_cell(cell: Vector3i) -> void:
    hover_cell = cell
    if _simulation != null:
        _sync_overlay(_simulation)

func sync_from_simulation(simulation) -> void:
    _simulation = simulation
    _resolve_nodes()
    if simulation == null or simulation.world == null:
        return
    _sync_terrain(simulation)
    _sync_stockpiles(simulation)
    _sync_markers(simulation)
    _sync_units(simulation)
    _sync_overlay(simulation)

# Live preview of a stockpile drag rectangle (cells may be Vector3i or [x,y,z]).
func set_stockpile_preview(cells: Array) -> void:
    _resolve_nodes()
    var data: Dictionary = _new_mesh()
    for raw in cells:
        var cell: Vector3i
        if raw is Vector3i:
            cell = raw
        elif raw is Array and raw.size() >= 3:
            cell = Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))
        else:
            continue
        if cell.y != active_layer:
            continue
        _append_box(data, Vector3(float(cell.x), 0.1, float(cell.z)), Vector3(0.96, 0.04, 0.96), Color(0.35, 0.85, 1.0, 0.4))
    _apply_mesh(_preview, data, true)

func clear_stockpile_preview() -> void:
    _resolve_nodes()
    if _preview != null:
        _preview.mesh = null

# Map a mouse ray onto the active-layer ground plane (render y = 0).
func ray_to_cell(ray_origin: Vector3, ray_direction: Vector3) -> Vector3i:
    if absf(ray_direction.y) < 0.00001:
        return INVALID_CELL
    var t: float = -ray_origin.y / ray_direction.y
    if t < 0.0:
        return INVALID_CELL
    var point: Vector3 = ray_origin + ray_direction * t
    var x: int = int(round(point.x))
    var z: int = int(round(point.z))
    var cell := Vector3i(x, active_layer, z)
    if not C.in_bounds(cell):
        return INVALID_CELL
    return cell

# --- Terrain ------------------------------------------------------------------

func _sync_terrain(simulation) -> void:
    var world = simulation.world
    var data: Dictionary = _new_mesh()
    for z in range(world.depth):
        for x in range(world.width):
            var addr := Vector3i(x, active_layer, z)
            var cell = world.peek_cell(addr)
            var center := Vector3(float(x), 0.0, float(z))
            if cell.has_wall():
                # Solid rock stays hidden until a neighbouring cell is opened up
                # (mined/channelled/exposed), so only revealed faces are drawn.
                if not _wall_is_exposed(world, addr):
                    continue
                _append_box(data, center + Vector3(0, 0.4, 0), Vector3(0.98, 0.8, 0.98), _material_color(cell.wall_material))
            elif cell.has_liquid():
                _append_box(data, center + Vector3(0, 0.04, 0), Vector3(0.98, 0.08, 0.98), _liquid_color(cell.liquid_type))
            elif cell.has_floor():
                _append_box(data, center, Vector3(0.98, 0.06, 0.98), _floor_color(cell))
            else:
                # Open cell: peek one layer down so pits/shafts read as recessed.
                var below = world.peek_cell(addr + Vector3i(0, -1, 0))
                if below.has_wall() or below.has_floor():
                    _append_box(data, center + Vector3(0, -0.55, 0), Vector3(0.9, 0.06, 0.9), _dim(_below_color(below)))
    _apply_mesh(_terrain, data, false)

func _below_color(cell) -> Color:
    if cell.has_wall():
        return _material_color(cell.wall_material)
    if cell.has_liquid():
        return _liquid_color(cell.liquid_type)
    return _floor_color(cell)

func _floor_color(cell) -> Color:
    if cell.band == C.BAND_SURFACE:
        return Color(0.28, 0.55, 0.24)
    return _material_color(cell.floor_material)

# A wall cell is only revealed when at least one of its six neighbours is open
# (no wall) — i.e. it borders dug-out/exposed space. Fully enclosed rock is hidden.
func _wall_is_exposed(world, cell: Vector3i) -> bool:
    for offset in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1), Vector3i(0, 1, 0), Vector3i(0, -1, 0)]:
        var neighbor: Vector3i = cell + offset
        if not world.in_bounds(neighbor):
            continue
        if not world.peek_cell(neighbor).has_wall():
            return true
    return false

# --- Stockpiles ---------------------------------------------------------------

func _sync_stockpiles(simulation) -> void:
    var data: Dictionary = _new_mesh()
    for stockpile_id in simulation.stockpiles.keys():
        var stockpile = simulation.stockpiles[stockpile_id]
        for cell in stockpile.cells:
            if cell.y != active_layer:
                continue
            _append_box(data, Vector3(float(cell.x), 0.08, float(cell.z)), Vector3(0.96, 0.04, 0.96), Color(0.2, 0.62, 0.9, 0.45))
    _apply_mesh(_stockpiles, data, true)

# --- Markers (plants, buildings, items) ---------------------------------------

func _sync_markers(simulation) -> void:
    var world = simulation.world
    var data: Dictionary = _new_mesh()
    for z in range(world.depth):
        for x in range(world.width):
            var cell = world.peek_cell(Vector3i(x, active_layer, z))
            var center := Vector3(float(x), 0.0, float(z))
            if cell.has_plant():
                _append_box(data, center + Vector3(0, 0.55, 0), Vector3(0.5, 0.7, 0.5), _plant_color(cell.plant))
            if cell.building_id != "":
                _append_box(data, center + Vector3(0, 0.3, 0), Vector3(0.7, 0.5, 0.7), Color(0.62, 0.45, 0.22))
            if cell.has_stair():
                _append_box(data, center + Vector3(-0.28, 0.12, 0.0), Vector3(0.22, 0.16, 0.72), Color(0.78, 0.78, 0.86))
                _append_box(data, center + Vector3(0.0, 0.26, 0.0), Vector3(0.22, 0.30, 0.72), Color(0.85, 0.85, 0.92))
                _append_box(data, center + Vector3(0.28, 0.40, 0.0), Vector3(0.22, 0.48, 0.72), Color(0.92, 0.92, 0.99))
    for item_id in simulation.items.keys():
        var item = simulation.items[item_id]
        if item.holder_unit_id != "" or item.position.y != active_layer:
            continue
        _append_box(data, Vector3(float(item.position.x), 0.42, float(item.position.z)), Vector3(0.55, 0.5, 0.55), _item_color(item.item_type))
    _apply_mesh(_markers, data, false)

# --- Units --------------------------------------------------------------------

func _sync_units(simulation) -> void:
    var data: Dictionary = _new_mesh()
    for unit_id in simulation.units.keys():
        var unit = simulation.units[unit_id]
        if unit.position.y != active_layer:
            continue
        _append_box(data, Vector3(float(unit.position.x), 0.6, float(unit.position.z)), Vector3(0.5, 0.9, 0.5), Color(0.95, 0.86, 0.4))
    _apply_mesh(_units, data, false)

# --- Overlay (designations + hover) -------------------------------------------

func _sync_overlay(simulation) -> void:
    var data: Dictionary = _new_mesh()
    for job_id in simulation.job_board.sorted_job_ids():
        var job = simulation.job_board.jobs[job_id]
        if job.target_cell.y != active_layer:
            continue
        var color: Color = _designation_color(job.type)
        if color.a <= 0.0:
            continue
        _append_box(data, Vector3(float(job.target_cell.x), 0.9, float(job.target_cell.z)), Vector3(0.9, 0.05, 0.9), color)
    if hover_cell != INVALID_CELL and hover_cell.y == active_layer:
        _append_box(data, Vector3(float(hover_cell.x), 0.98, float(hover_cell.z)), Vector3(1.0, 0.06, 1.0), Color(1.0, 0.95, 0.35, 0.55))
    _apply_mesh(_overlay, data, true)

# --- Colors -------------------------------------------------------------------

func _material_color(material_key: String) -> Color:
    match material_key:
        C.MATERIAL_GRASS: return Color(0.28, 0.55, 0.24)
        C.MATERIAL_DIRT: return Color(0.50, 0.34, 0.18)
        C.MATERIAL_CLAY: return Color(0.58, 0.42, 0.26)
        C.MATERIAL_SAND: return Color(0.80, 0.74, 0.46)
        C.MATERIAL_GRAVEL: return Color(0.42, 0.42, 0.38)
        C.MATERIAL_LOOSE_STONE: return Color(0.55, 0.55, 0.58)
        C.MATERIAL_SOFT_ROCK: return Color(0.44, 0.44, 0.50)
        C.MATERIAL_HARD_ROCK: return Color(0.26, 0.26, 0.30)
        C.MATERIAL_BEDROCK: return Color(0.10, 0.10, 0.12)
        C.MATERIAL_WOOD: return Color(0.55, 0.36, 0.16)
        C.MATERIAL_ORE_COAL: return Color(0.12, 0.12, 0.13)
        C.MATERIAL_ORE_COPPER: return Color(0.78, 0.42, 0.20)
        C.MATERIAL_ORE_IRON: return Color(0.64, 0.30, 0.22)
        C.MATERIAL_ORE_SILVER: return Color(0.80, 0.80, 0.86)
        C.MATERIAL_ORE_GOLD: return Color(0.92, 0.74, 0.22)
    return Color(0.5, 0.5, 0.5)

func _liquid_color(liquid_type: String) -> Color:
    if liquid_type == C.LIQUID_MAGMA:
        return Color(0.95, 0.28, 0.06)
    return Color(0.16, 0.40, 0.86, 0.9)

func _plant_color(plant: String) -> Color:
    match plant:
        C.PLANT_TREE_PINE: return Color(0.10, 0.34, 0.20)
        C.PLANT_TREE_OAK: return Color(0.16, 0.44, 0.18)
        C.PLANT_BERRY_BUSH: return Color(0.62, 0.12, 0.20)
        C.PLANT_WILD_WHEAT: return Color(0.80, 0.70, 0.28)
    return Color(0.2, 0.5, 0.2)

func _item_color(item_type: String) -> Color:
    match item_type:
        "wood": return Color(0.55, 0.36, 0.16)
        "stone": return Color(0.6, 0.6, 0.62)
        "food": return Color(0.85, 0.3, 0.3)
        "meal": return Color(0.95, 0.6, 0.2)
        "dirt": return Color(0.5, 0.34, 0.18)
        "coal": return Color(0.1, 0.1, 0.1)
        "iron_ore": return Color(0.64, 0.3, 0.22)
        "copper_ore": return Color(0.78, 0.42, 0.2)
    return Color(0.8, 0.8, 0.4)

func _designation_color(job_type: String) -> Color:
    match job_type:
        "MINE_WALL": return Color(0.95, 0.85, 0.2, 0.6)
        "CHANNEL_FLOOR": return Color(0.85, 0.55, 0.2, 0.6)
        "BUILD_STAIR": return Color(0.5, 0.8, 0.95, 0.6)
        "CHOP_TREE": return Color(0.4, 0.85, 0.4, 0.6)
        "GATHER_FOOD": return Color(0.9, 0.4, 0.7, 0.6)
        "BUILD_CONSTRUCTION": return Color(0.7, 0.7, 0.9, 0.6)
    return Color(0, 0, 0, 0)

func _dim(color: Color) -> Color:
    return Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, color.a)

# --- Mesh building helpers ----------------------------------------------------

func _new_mesh() -> Dictionary:
    return {
        "vertices": PackedVector3Array(),
        "normals": PackedVector3Array(),
        "colors": PackedColorArray(),
        "indices": PackedInt32Array(),
    }

func _apply_mesh(node: MeshInstance3D, data: Dictionary, transparent: bool) -> void:
    if node == null:
        return
    var vertices: PackedVector3Array = data["vertices"]
    if vertices.is_empty():
        node.mesh = null
        return
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = data["normals"]
    arrays[Mesh.ARRAY_COLOR] = data["colors"]
    arrays[Mesh.ARRAY_INDEX] = data["indices"]
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    node.mesh = mesh
    node.material_override = _make_material(transparent)

func _make_material(transparent: bool) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.vertex_color_use_as_albedo = true
    material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
    material.cull_mode = BaseMaterial3D.CULL_BACK
    if transparent:
        material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    return material

func _append_box(data: Dictionary, center: Vector3, size: Vector3, color: Color) -> void:
    var half := size * 0.5
    var x0 := center.x - half.x
    var x1 := center.x + half.x
    var y0 := center.y - half.y
    var y1 := center.y + half.y
    var z0 := center.z - half.z
    var z1 := center.z + half.z
    _quad(data, [Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0)], Vector3.UP, color)
    _quad(data, [Vector3(x0, y0, z1), Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1)], Vector3.DOWN, color)
    _quad(data, [Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3(x0, y0, z1)], Vector3.BACK, _shade(color, 0.85))
    _quad(data, [Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y0, z0)], Vector3.FORWARD, _shade(color, 0.7))
    _quad(data, [Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1)], Vector3.RIGHT, _shade(color, 0.8))
    _quad(data, [Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3(x0, y0, z0)], Vector3.LEFT, _shade(color, 0.75))

func _shade(color: Color, factor: float) -> Color:
    return Color(color.r * factor, color.g * factor, color.b * factor, color.a)

func _quad(data: Dictionary, quad: Array, normal: Vector3, color: Color) -> void:
    var vertices: PackedVector3Array = data["vertices"]
    var normals: PackedVector3Array = data["normals"]
    var colors: PackedColorArray = data["colors"]
    var indices: PackedInt32Array = data["indices"]
    var start: int = vertices.size()
    for vertex in quad:
        vertices.append(vertex)
        normals.append(normal)
        colors.append(color)
    indices.append(start)
    indices.append(start + 1)
    indices.append(start + 2)
    indices.append(start)
    indices.append(start + 2)
    indices.append(start + 3)
