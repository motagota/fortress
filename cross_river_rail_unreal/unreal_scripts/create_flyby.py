"""Step 2/3 - create the Level Sequence with a Cine Camera flying the route.

Keys every frame (location, rotation, focal length) from crr.camera.FlightPath,
adds a camera-cut track and chapter markers (station names) in Sequencer.
Re-running replaces the sequence and camera.
"""
import importlib
import os
import sys

import unreal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crr_ue as U  # noqa: E402
importlib.reload(U)
from crr_ue import config, log, warn  # noqa: E402
from crr.camera import FlightPath  # noqa: E402

CAM_LABEL = "CRR_FlybyCamera"


def _channels(section):
    for n in ("get_all_channels", "get_channels"):
        fn = getattr(section, n, None)
        if fn:
            return list(fn())
    raise RuntimeError("cannot read Sequencer channels")


def _binding_id(seq, binding):
    attempts = [
        lambda: seq.get_portable_binding_id(seq, binding),
        lambda: unreal.MovieSceneSequenceExtensions.get_portable_binding_id(seq, seq, binding),
        lambda: seq.get_binding_id(binding),
        lambda: seq.make_binding_id(binding, unreal.MovieSceneObjectBindingSpace.LOCAL),
    ]
    for a in attempts:
        try:
            return a()
        except Exception:  # noqa: BLE001
            continue
    raise RuntimeError("cannot create camera binding id for the camera-cut track")


def _add_track(owner, cls):
    for n in ("add_track", "add_master_track"):
        fn = getattr(owner, n, None)
        if fn:
            try:
                return fn(cls)
            except Exception:  # noqa: BLE001
                continue
    raise RuntimeError(f"cannot add {cls}")


def main():
    U.open_or_create_map()
    fp = FlightPath()
    keys = fp.keyframes()
    nf = len(keys)
    log(f"flight: {fp.duration:.1f}s, {nf} frames @ {fp.fps} fps")

    # fresh sequence
    folder, name = config.SEQUENCE_PATH.rsplit("/", 1)
    U.ensure_dir(folder)
    if U.eal.does_asset_exist(config.SEQUENCE_PATH):
        U.eal.delete_asset(config.SEQUENCE_PATH)
    seq = U.asset_tools.create_asset(name, folder, unreal.LevelSequence, unreal.LevelSequenceFactoryNew())
    seq.set_display_rate(unreal.FrameRate(fp.fps, 1))
    seq.set_playback_start(0)
    seq.set_playback_end(nf)

    # fresh camera
    for a in U.find_actors(unreal.CineCameraActor):
        if a.get_actor_label() == CAM_LABEL:
            U.actor_sub().destroy_actor(a)
    k0 = keys[0]
    cam = U.spawn(unreal.CineCameraActor, k0["location"], k0["rotation"], "Camera", CAM_LABEL)
    comp = cam.get_cine_camera_component()
    U.set_props(comp, filmback=unreal.CameraFilmbackSettings(sensor_width=36.0, sensor_height=20.25),
                current_aperture=5.6, current_focal_length=k0["focal"])
    focus = comp.get_editor_property("focus_settings")
    U.set_props(focus, focus_method=unreal.CameraFocusMethod.MANUAL, manual_focus_distance=3000.0)
    comp.set_editor_property("focus_settings", focus)

    binding = seq.add_possessable(cam)

    # transform
    tr = binding.add_track(unreal.MovieScene3DTransformTrack)
    sec = tr.add_section()
    sec.set_range(0, nf)
    ch = _channels(sec)  # loc x,y,z, rot x(roll),y(pitch),z(yaw), scale x,y,z
    with unreal.ScopedSlowTask(nf, "Keying flyby camera") as task:
        task.make_dialog(True)
        for k in keys:
            task.enter_progress_frame(1)
            f = unreal.FrameNumber(k["frame"])
            x, y, z = k["location"]
            roll, pitch, yaw = k["rotation"]
            for c, v in zip(ch[:6], (x, y, z, roll, pitch, yaw)):
                c.add_key(f, v)

    # focal length (wide in the tunnels, longer for the aerials)
    try:
        cb = seq.add_possessable(comp)
        ft = cb.add_track(unreal.MovieSceneFloatTrack)
        ft.set_property_name_and_path("CurrentFocalLength", "CurrentFocalLength")
        fs = ft.add_section()
        fs.set_range(0, nf)
        fch = _channels(fs)[0]
        for k in keys[::6] + [keys[-1]]:
            fch.add_key(unreal.FrameNumber(k["frame"]), k["focal"])
    except Exception as e:  # noqa: BLE001
        warn(f"focal-length track skipped: {e}")

    # camera cut
    cut = _add_track(seq, unreal.MovieSceneCameraCutTrack)
    cs = cut.add_section()
    cs.set_range(0, nf)
    cs.set_camera_binding_id(_binding_id(seq, binding))

    # chapter markers
    try:
        tick = seq.get_tick_resolution()
        ticks_per_frame = tick.numerator / tick.denominator / fp.fps
        for t, label in fp.chapters():
            mf = unreal.MovieSceneMarkedFrame()
            mf.set_editor_property("frame_number", unreal.FrameNumber(int(round(t * fp.fps * ticks_per_frame))))
            mf.set_editor_property("label", label)
            seq.add_marked_frame(mf)
    except Exception as e:  # noqa: BLE001
        warn(f"markers skipped: {e}")

    U.eal.save_loaded_asset(seq)
    U.save_all()
    try:
        unreal.LevelSequenceEditorBlueprintLibrary.open_level_sequence(seq)
    except Exception:  # noqa: BLE001
        pass
    log(f"sequence ready: {config.SEQUENCE_PATH}. Next: render_movie.py")


main()
