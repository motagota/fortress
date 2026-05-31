extends Camera3D

# Presentation-only orthographic top-down camera.
#   W/A/S/D       — pan across the layer (XZ plane)
#   Mouse wheel   — zoom (orthographic size)
#   E / C         — change the active layer (handled by Main, not here)
# The simulation never reads camera state.

@export var pan_speed: float = 18.0
@export var zoom_speed: float = 2.0
@export var min_zoom: float = 8.0
@export var max_zoom: float = 64.0
@export var height: float = 80.0

var _target: Vector3 = Vector3(24.0, 0.0, 24.0)

func _ready() -> void:
    projection = PROJECTION_ORTHOGONAL
    size = 36.0
    current = true
    _apply_transform()

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseButton and event.pressed:
        if event.button_index == MOUSE_BUTTON_WHEEL_UP:
            size = maxf(min_zoom, size - zoom_speed)
            _apply_transform()
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            size = minf(max_zoom, size + zoom_speed)
            _apply_transform()

func _process(delta: float) -> void:
    var direction := Vector3.ZERO
    if Input.is_key_pressed(KEY_A):
        direction.x -= 1.0
    if Input.is_key_pressed(KEY_D):
        direction.x += 1.0
    if Input.is_key_pressed(KEY_W):
        direction.z -= 1.0
    if Input.is_key_pressed(KEY_S):
        direction.z += 1.0
    if direction != Vector3.ZERO:
        _target += direction.normalized() * pan_speed * delta
        _apply_transform()

func focus_on(world_x: float, world_z: float) -> void:
    _target = Vector3(world_x, 0.0, world_z)
    _apply_transform()

func _apply_transform() -> void:
    global_position = Vector3(_target.x, height, _target.z)
    look_at(Vector3(_target.x, 0.0, _target.z), Vector3(0, 0, -1))
