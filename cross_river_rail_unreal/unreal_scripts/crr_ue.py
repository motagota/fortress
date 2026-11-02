"""Shared helpers for the Unreal Editor scripts (UE 5.3 - 5.6).

Run the entry scripts from the editor: Tools > Execute Python Script..., or in
the Output Log (Python mode):  py "C:/path/to/cross_river_rail_unreal/unreal_scripts/build_scene.py"
"""
import importlib
import os
import sys

import unreal

TOOLKIT_DIR = os.environ.get("CRR_TOOLKIT_DIR") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))
if TOOLKIT_DIR not in sys.path:
    sys.path.insert(0, TOOLKIT_DIR)

import crr.config  # noqa: E402
import crr.geo  # noqa: E402
import crr.route  # noqa: E402
import crr.meshgen  # noqa: E402
import crr.camera  # noqa: E402

# pick up edits without restarting the editor
for _m in (crr.config, crr.geo, crr.route, crr.meshgen, crr.camera):
    importlib.reload(_m)

from crr import config  # noqa: E402

TAG = "CRR_Generated"
asset_tools = unreal.AssetToolsHelpers.get_asset_tools()
eal = unreal.EditorAssetLibrary
mel = unreal.MaterialEditingLibrary


def log(msg):
    unreal.log("[CRR] " + str(msg))


def warn(msg):
    unreal.log_warning("[CRR] " + str(msg))


def actor_sub():
    return unreal.get_editor_subsystem(unreal.EditorActorSubsystem)


def project_saved_dir():
    return os.path.abspath(unreal.Paths.project_saved_dir())


def generated_dir():
    return os.path.join(project_saved_dir(), "CrossRiverRail")


def set_props(obj, **props):
    """set_editor_property for each item, skipping (with a warning) any property
    that does not exist in this engine/plugin version."""
    for k, v in props.items():
        try:
            obj.set_editor_property(k, v)
        except Exception as e:  # noqa: BLE001
            warn(f"{obj.get_name()}: could not set {k}: {e}")


def try_call(obj, names, *args):
    for n in names:
        fn = getattr(obj, n, None)
        if fn:
            try:
                return fn(*args)
            except Exception as e:  # noqa: BLE001
                warn(f"{n} failed: {e}")
    return None


def tag_actor(actor, folder):
    tags = list(actor.tags)
    if TAG not in tags:
        tags.append(TAG)
    actor.set_editor_property("tags", tags)
    actor.set_folder_path("CrossRiverRail/" + folder)


def spawn(cls, location=(0, 0, 0), rotation=(0, 0, 0), folder="Misc", label=None):
    loc = unreal.Vector(*location)
    rot = unreal.Rotator(roll=rotation[0], pitch=rotation[1], yaw=rotation[2])
    a = actor_sub().spawn_actor_from_class(cls, loc, rot)
    tag_actor(a, folder)
    if label:
        a.set_actor_label(label)
    return a


def find_actors(cls=None, tag=TAG):
    out = []
    for a in actor_sub().get_all_level_actors():
        if cls and not isinstance(a, cls):
            continue
        if tag and tag not in [str(t) for t in a.tags]:
            continue
        out.append(a)
    return out


def destroy_generated():
    actors = find_actors()
    if actors:
        actor_sub().destroy_actors(actors)
    log(f"removed {len(actors)} previously generated actors")


def ensure_dir(path):
    if not eal.does_directory_exist(path):
        eal.make_directory(path)


def open_or_create_map():
    les = unreal.get_editor_subsystem(unreal.LevelEditorSubsystem)
    if eal.does_asset_exist(config.MAP_PATH):
        les.load_level(config.MAP_PATH)
    else:
        ensure_dir(config.MAP_PATH.rsplit("/", 1)[0])
        les.new_level(config.MAP_PATH)
    return les


def save_all():
    unreal.EditorLoadingAndSavingUtils.save_dirty_packages(True, True)


def import_obj(path, dest_path, name=None):
    """Import an OBJ as a static mesh (Interchange or legacy importer)."""
    task = unreal.AssetImportTask()
    task.set_editor_property("filename", path)
    task.set_editor_property("destination_path", dest_path)
    if name:
        task.set_editor_property("destination_name", name)
    task.set_editor_property("automated", True)
    task.set_editor_property("replace_existing", True)
    task.set_editor_property("save", False)
    asset_tools.import_asset_tasks([task])
    for p in task.get_editor_property("imported_object_paths") or []:
        obj = unreal.load_asset(p)
        if isinstance(obj, unreal.StaticMesh):
            return obj
    # Some importers don't report paths; fall back to the expected asset name
    guess = f"{dest_path}/{name or os.path.splitext(os.path.basename(path))[0]}"
    obj = unreal.load_asset(guess) if eal.does_asset_exist(guess) else None
    return obj if isinstance(obj, unreal.StaticMesh) else None
