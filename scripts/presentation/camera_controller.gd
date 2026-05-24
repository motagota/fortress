extends Camera3D

@export var pan_speed: float = 10.0
@export var zoom_speed: float = 2.0
@export var rotate_speed: float = 1.5

func _ready() -> void:
    current = true

func _unhandled_input(event: InputEvent) -> void:
    # Presentation-only camera controls; simulation does not read camera state.
    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
            translate_object_local(Vector3(0, 0, -zoom_speed))
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
            translate_object_local(Vector3(0, 0, zoom_speed))

func _process(delta: float) -> void:
    var direction: Vector3 = Vector3.ZERO
    if Input.is_action_pressed("ui_left"):
        direction.x -= 1
    if Input.is_action_pressed("ui_right"):
        direction.x += 1
    if Input.is_action_pressed("ui_up"):
        direction.z -= 1
    if Input.is_action_pressed("ui_down"):
        direction.z += 1
    if direction != Vector3.ZERO:
        global_position += direction.normalized() * pan_speed * delta
