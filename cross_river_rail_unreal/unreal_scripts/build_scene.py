"""Step 1/3 - build the Cross River Rail level.

  * calibrates the OBJ importer's axis/unit conversion
  * generates tunnel, station and portal meshes (crr.meshgen) and imports them
    as Nanite static meshes
  * creates a master material + one material instance per surface type
  * spawns tunnel/station lights, post-processing, sky
  * adds Cesium for Unreal + Google Photorealistic 3D Tiles for the real city
    above ground (if the plugin and a key/token are available)

Re-running is safe: previously generated actors are removed first.
Environment variables: CRR_QUALITY=draft|final, GOOGLE_MAPS_API_KEY or
CESIUM_ION_TOKEN (see README).
"""
import importlib
import json
import os
import shutil
import sys
import time

import unreal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crr_ue as U  # noqa: E402
importlib.reload(U)
from crr_ue import config, log, warn  # noqa: E402
from crr.meshgen import SceneBuilder, write_calibration_objs, obj_from_ue_from_bounds  # noqa: E402

MESH_DIR = config.CONTENT_ROOT + "/Meshes"
MAT_DIR = config.CONTENT_ROOT + "/Materials"

# material key -> (base colour sRGB-ish linear, roughness, metallic, emissive colour, emissive strength, tiling)
SURFACES = {
    "lining":          ((0.42, 0.41, 0.39), 0.85, 0.0, None, 0, 0.35),
    "slab":            ((0.25, 0.245, 0.24), 0.9, 0.0, None, 0, 0.5),
    "walkway":         ((0.36, 0.35, 0.335), 0.88, 0.0, None, 0, 0.5),
    "paint_yellow":    ((0.75, 0.52, 0.03), 0.55, 0.0, None, 0, 1.0),
    "steel":           ((0.55, 0.56, 0.57), 0.45, 1.0, None, 0, 1.0),
    "rail":            ((0.30, 0.27, 0.24), 0.35, 1.0, None, 0, 1.0),
    "baseplate":       ((0.06, 0.06, 0.065), 0.6, 0.2, None, 0, 1.0),
    "led":             ((1.0, 1.0, 1.0), 0.4, 0.0, (1.0, 0.92, 0.80), 60.0, 1.0),
    "station_wall":    ((0.72, 0.72, 0.70), 0.35, 0.0, None, 0, 0.5),
    "station_ceiling": ((0.05, 0.055, 0.06), 0.8, 0.0, None, 0, 0.5),
    "station_floor":   ((0.38, 0.37, 0.355), 0.25, 0.0, None, 0, 0.5),
    "tactile":         ((0.80, 0.55, 0.02), 0.6, 0.0, None, 0, 2.0),
    "psd_frame":       ((0.80, 0.80, 0.82), 0.28, 1.0, None, 0, 1.0),
    "trough":          ((0.48, 0.46, 0.43), 0.9, 0.0, None, 0, 0.35),
}


# ----------------------------------------------------------------- materials
def _expr(mat, cls, x, y, **props):
    e = U.mel.create_material_expression(mat, cls, x, y)
    for k, v in props.items():
        e.set_editor_property(k, v)
    return e


def build_master_material():
    path = f"{MAT_DIR}/M_CRR_Master"
    if U.eal.does_asset_exist(path):
        return unreal.load_asset(path)
    U.ensure_dir(MAT_DIR)
    mat = U.asset_tools.create_asset("M_CRR_Master", MAT_DIR, unreal.Material, unreal.MaterialFactoryNew())
    E, C = _expr, U.mel.connect_material_expressions
    tc = E(mat, unreal.MaterialExpressionTextureCoordinate, -1400, 0)
    tiling = E(mat, unreal.MaterialExpressionScalarParameter, -1400, 120, parameter_name="Tiling", default_value=0.5)
    uv = E(mat, unreal.MaterialExpressionMultiply, -1200, 40)
    C(tc, "", uv, "A")
    C(tiling, "", uv, "B")
    base_tex = E(mat, unreal.MaterialExpressionTextureSampleParameter2D, -1000, -200, parameter_name="BaseTex",
                 texture=unreal.load_asset("/Engine/EngineResources/WhiteSquareTexture"))
    C(uv, "", base_tex, "UVs")
    tint = E(mat, unreal.MaterialExpressionVectorParameter, -1000, 100, parameter_name="BaseColor",
             default_value=unreal.LinearColor(0.5, 0.5, 0.5, 1))
    base = E(mat, unreal.MaterialExpressionMultiply, -750, -100)
    C(base_tex, "RGB", base, "A")
    C(tint, "", base, "B")
    # large-scale world-space variation (stains / batch-to-batch colour) to kill CG uniformity
    noise = E(mat, unreal.MaterialExpressionNoise, -750, 150, scale=0.0035, output_min=0.0, output_max=1.0, levels=4)
    var = E(mat, unreal.MaterialExpressionScalarParameter, -750, 300, parameter_name="Variation", default_value=0.25)
    one_minus = E(mat, unreal.MaterialExpressionOneMinus, -560, 300)
    C(var, "", one_minus, "")
    dark = E(mat, unreal.MaterialExpressionMultiply, -500, 0)
    C(base, "", dark, "A")
    C(one_minus, "", dark, "B")
    lerp = E(mat, unreal.MaterialExpressionLinearInterpolate, -300, -50)
    C(dark, "", lerp, "A")
    C(base, "", lerp, "B")
    C(noise, "", lerp, "Alpha")
    U.mel.connect_material_property(lerp, "", unreal.MaterialProperty.MP_BASE_COLOR)
    rough = E(mat, unreal.MaterialExpressionScalarParameter, -300, 200, parameter_name="Roughness", default_value=0.8)
    U.mel.connect_material_property(rough, "", unreal.MaterialProperty.MP_ROUGHNESS)
    metal = E(mat, unreal.MaterialExpressionScalarParameter, -300, 300, parameter_name="Metallic", default_value=0.0)
    U.mel.connect_material_property(metal, "", unreal.MaterialProperty.MP_METALLIC)
    ntex = E(mat, unreal.MaterialExpressionTextureSampleParameter2D, -1000, 450, parameter_name="NormalTex",
             sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_NORMAL,
             texture=unreal.load_asset("/Engine/EngineMaterials/FlatNormal"))
    C(uv, "", ntex, "UVs")
    U.mel.connect_material_property(ntex, "RGB", unreal.MaterialProperty.MP_NORMAL)
    ecol = E(mat, unreal.MaterialExpressionVectorParameter, -500, 600, parameter_name="EmissiveColor",
             default_value=unreal.LinearColor(0, 0, 0, 1))
    estr = E(mat, unreal.MaterialExpressionScalarParameter, -500, 750, parameter_name="EmissiveStrength", default_value=0.0)
    emis = E(mat, unreal.MaterialExpressionMultiply, -300, 650)
    C(ecol, "", emis, "A")
    C(estr, "", emis, "B")
    U.mel.connect_material_property(emis, "", unreal.MaterialProperty.MP_EMISSIVE_COLOR)
    U.mel.recompile_material(mat)
    U.eal.save_loaded_asset(mat)
    return mat


def build_glass_material():
    path = f"{MAT_DIR}/M_CRR_Glass"
    if U.eal.does_asset_exist(path):
        return unreal.load_asset(path)
    mat = U.asset_tools.create_asset("M_CRR_Glass", MAT_DIR, unreal.Material, unreal.MaterialFactoryNew())
    U.set_props(mat, blend_mode=unreal.BlendMode.BLEND_TRANSLUCENT, two_sided=True,
                translucency_lighting_mode=unreal.TranslucencyLightingMode.TLM_SURFACE_PER_PIXEL_LIGHTING)
    E = _expr
    col = E(mat, unreal.MaterialExpressionVectorParameter, -400, 0, parameter_name="BaseColor",
            default_value=unreal.LinearColor(0.03, 0.05, 0.05, 1))
    U.mel.connect_material_property(col, "", unreal.MaterialProperty.MP_BASE_COLOR)
    op = E(mat, unreal.MaterialExpressionScalarParameter, -400, 150, parameter_name="Opacity", default_value=0.12)
    U.mel.connect_material_property(op, "", unreal.MaterialProperty.MP_OPACITY)
    r = E(mat, unreal.MaterialExpressionScalarParameter, -400, 250, parameter_name="Roughness", default_value=0.03)
    U.mel.connect_material_property(r, "", unreal.MaterialProperty.MP_ROUGHNESS)
    m = E(mat, unreal.MaterialExpressionScalarParameter, -400, 350, parameter_name="Metallic", default_value=0.0)
    U.mel.connect_material_property(m, "", unreal.MaterialProperty.MP_METALLIC)
    U.mel.recompile_material(mat)
    U.eal.save_loaded_asset(mat)
    return mat


def build_material_instances():
    master, glass = build_master_material(), build_glass_material()
    out = {}
    for key, (col, rough, metal, ecol, estr, tiling) in SURFACES.items():
        path = f"{MAT_DIR}/MI_CRR_{key}"
        if U.eal.does_asset_exist(path):
            out[key] = unreal.load_asset(path)  # keep user edits (e.g. swapped-in Fab textures)
            continue
        mi = U.asset_tools.create_asset(f"MI_CRR_{key}", MAT_DIR, unreal.MaterialInstanceConstant,
                                        unreal.MaterialInstanceConstantFactoryNew())
        U.mel.set_material_instance_parent(mi, master)
        U.mel.set_material_instance_vector_parameter_value(mi, "BaseColor", unreal.LinearColor(*col, 1))
        U.mel.set_material_instance_scalar_parameter_value(mi, "Roughness", rough)
        U.mel.set_material_instance_scalar_parameter_value(mi, "Metallic", metal)
        U.mel.set_material_instance_scalar_parameter_value(mi, "Tiling", tiling)
        if ecol:
            U.mel.set_material_instance_vector_parameter_value(mi, "EmissiveColor", unreal.LinearColor(*ecol, 1))
            U.mel.set_material_instance_scalar_parameter_value(mi, "EmissiveStrength", estr)
            U.mel.set_material_instance_scalar_parameter_value(mi, "Variation", 0.0)
        U.mel.update_material_instance(mi)
        U.eal.save_loaded_asset(mi)
        out[key] = mi
    out["psd_glass"] = glass
    return out


# --------------------------------------------------------------- calibration
def calibrate_importer(work_dir):
    """Import three axis-aligned calibration meshes and derive the 3x3 matrix
    A (OBJ -> Unreal). Returns (obj_from_ue = A^-1, scale)."""
    calib_dir = os.path.join(work_dir, "calib")
    paths = write_calibration_objs(calib_dir)
    dest = MESH_DIR + "/_Calibration"
    bounds = []
    for p in paths:
        mesh = U.import_obj(p, dest)
        if not mesh:
            raise RuntimeError("Calibration import failed - is OBJ import available in this engine?")
        box = mesh.get_bounding_box()
        bounds.append(((box.min.x, box.min.y, box.min.z), (box.max.x, box.max.y, box.max.z)))
    inv, s, recentred = obj_from_ue_from_bounds(bounds)
    if recentred:
        warn("importer appears to re-centre meshes; per-mesh bounds correction will compensate")
    log(f"OBJ importer: 1 OBJ unit = {s:g} UE units; UE->OBJ matrix {inv}")
    U.eal.delete_directory(dest)
    return inv, s


# ------------------------------------------------------------------- meshes
def import_meshes(manifest, mesh_dir, mats):
    U.ensure_dir(MESH_DIR)
    n = len(manifest["meshes"])
    placed = 0
    with unreal.ScopedSlowTask(n, "Importing Cross River Rail meshes") as task:
        task.make_dialog(True)
        for i, m in enumerate(manifest["meshes"]):
            if task.should_cancel():
                break
            task.enter_progress_frame(1, m["name"])
            mesh = U.import_obj(os.path.join(mesh_dir, m["file"]), MESH_DIR, m["name"])
            if not mesh:
                warn(f"import failed: {m['file']}")
                continue
            if m["nanite"]:
                ns = mesh.get_editor_property("nanite_settings")
                ns.enabled = True
                try:
                    ns.fallback_relative_error = 0.0
                except Exception:  # noqa: BLE001
                    pass
                mesh.set_editor_property("nanite_settings", ns)
            mesh.set_material(0, mats[m["material"]])
            # place, correcting for any importer re-centring
            box = mesh.get_bounding_box()
            loc = list(m["location"])
            exp_min = m["bounds_min"]
            act_min = (box.min.x, box.min.y, box.min.z)
            for k in range(3):
                loc[k] += exp_min[k] - act_min[k]
            folder = "Stations" if "Station" in m["name"] or "PSD" in m["name"] else \
                "Portals" if ("Trough" in m["name"] or "Portal" in m["name"]) else "Tunnel"
            actor = U.actor_sub().spawn_actor_from_object(mesh, unreal.Vector(*loc), unreal.Rotator(0, 0, 0))
            U.tag_actor(actor, folder + "/Meshes")
            actor.set_actor_label(m["name"].replace("SM_CRR_", ""))
            smc = actor.static_mesh_component
            smc.set_editor_property("mobility", unreal.ComponentMobility.STATIC)
            placed += 1
    U.eal.save_directory(MESH_DIR, only_if_is_dirty=True, recursive=True)
    log(f"placed {placed}/{n} meshes")


def spawn_lights(manifest):
    for L in manifest["lights"]:
        if L["type"] == "point":
            a = U.spawn(unreal.PointLight, L["location"], folder=L["folder"] + "/Lights")
        else:
            a = U.spawn(unreal.RectLight, L["location"], (0, -90, L.get("yaw_deg", 0)),
                        folder=L["folder"] + "/Lights")
        c = a.light_component
        U.set_props(c, intensity_units=unreal.LightUnits.LUMENS)
        U.set_props(c, intensity=L["lumens"], attenuation_radius=L["radius_cm"], cast_shadows=L["shadows"],
                    use_temperature=True, temperature=L["temperature"], mobility=unreal.ComponentMobility.MOVABLE)
        if L["type"] == "rect":
            U.set_props(c, source_width=L["width_cm"], source_height=L["height_cm"], barn_door_angle=60.0)
        else:
            U.set_props(c, source_radius=5.0, soft_source_radius=20.0)
    log(f"spawned {len(manifest['lights'])} lights")


# --------------------------------------------------------------- atmosphere
def setup_post_process():
    ppv = U.spawn(unreal.PostProcessVolume, folder="Lighting", label="PPV_CRR")
    ppv.set_editor_property("unbound", True)
    ppv.set_editor_property("priority", 10.0)
    s = ppv.get_editor_property("settings")

    def ov(name, value):
        try:
            s.set_editor_property("override_" + name, True)
            s.set_editor_property(name, value)
        except Exception as e:  # noqa: BLE001
            warn(f"post-process {name}: {e}")
    ov("dynamic_global_illumination_method", unreal.DynamicGlobalIlluminationMethod.LUMEN)
    ov("reflection_method", unreal.ReflectionMethod.LUMEN)
    ov("lumen_final_gather_quality", 2.0)
    ov("lumen_reflection_quality", 2.0)
    ov("lumen_scene_detail", 2.0)
    ov("lumen_scene_lighting_quality", 2.0)
    ov("lumen_max_trace_distance", 20000.0)
    # Natural eye adaptation daylight <-> tunnel
    ov("auto_exposure_method", unreal.AutoExposureMethod.AEM_HISTOGRAM)
    ov("auto_exposure_min_brightness", -3.0)
    ov("auto_exposure_max_brightness", 15.0)
    ov("auto_exposure_speed_up", 1.5)
    ov("auto_exposure_speed_down", 1.2)
    ov("auto_exposure_bias", 0.3)
    ov("bloom_intensity", 0.35)
    ov("vignette_intensity", 0.3)
    ov("scene_fringe_intensity", 0.15)
    ov("film_grain_intensity", 0.08)
    ov("motion_blur_amount", 0.5)
    ov("motion_blur_max", 5.0)
    ov("white_temp", 6200.0)
    ov("local_exposure_highlight_contrast_scale", 0.8)
    ov("local_exposure_shadow_contrast_scale", 0.8)
    ppv.set_editor_property("settings", s)


def setup_sky_and_city():
    has_cesium = hasattr(unreal, "CesiumGeoreference") and hasattr(unreal, "Cesium3DTileset")
    if has_cesium:
        for a in U.actor_sub().get_all_level_actors():   # reuse an existing georeference
            if isinstance(a, unreal.CesiumGeoreference):
                georef = a
                break
        else:
            georef = U.spawn(unreal.CesiumGeoreference, folder="City", label="CesiumGeoreference")
        llh = unreal.Vector(config.ORIGIN_LON, config.ORIGIN_LAT, config.GEOID_SEPARATION_M)
        if U.try_call(georef, ["set_origin_longitude_latitude_height"], llh) is None:
            U.set_props(georef, origin_longitude=config.ORIGIN_LON, origin_latitude=config.ORIGIN_LAT,
                        origin_height=config.GEOID_SEPARATION_M)
        ts = None
        if config.GOOGLE_MAPS_API_KEY or config.CESIUM_ION_TOKEN:
            ts = U.spawn(unreal.Cesium3DTileset, folder="City", label="Google Photorealistic 3D Tiles")
            if config.GOOGLE_MAPS_API_KEY:
                U.try_call(ts, ["set_tileset_source"], unreal.TilesetSource.FROM_URL)
                U.try_call(ts, ["set_url"], "https://tile.googleapis.com/v1/3dtiles/root.json?key="
                           + config.GOOGLE_MAPS_API_KEY)
            else:
                U.try_call(ts, ["set_tileset_source"], unreal.TilesetSource.FROM_CESIUM_ION)
                U.try_call(ts, ["set_ion_asset_id"], config.CESIUM_ION_GOOGLE_ASSET_ID)
                U.try_call(ts, ["set_ion_access_token"], config.CESIUM_ION_TOKEN)
            U.try_call(ts, ["set_maximum_screen_space_error"], config.TILESET_MAX_SSE)
            # keep tiles loaded around the camera during Movie Render Queue warm-up
            U.set_props(ts, enable_frustum_culling=False, maximum_cached_bytes=4 * 1024 ** 3)
        else:
            warn("No GOOGLE_MAPS_API_KEY / CESIUM_ION_TOKEN set: the above-ground city is skipped. "
                 "Add a Cesium3DTileset manually (Cesium panel > Google Photorealistic 3D Tiles).")
        if hasattr(unreal, "CesiumSunSky"):
            sky = U.spawn(unreal.CesiumSunSky, folder="Lighting", label="CesiumSunSky")
            U.set_props(sky, solar_time=config.SUN_SOLAR_TIME, day=config.SUN_DAY, month=config.SUN_MONTH,
                        year=config.SUN_YEAR, time_zone=config.SUN_TIME_ZONE, use_daylight_saving_time=False)
            U.try_call(sky, ["update_sun"])
        else:
            _plain_sky()
    else:
        warn("Cesium for Unreal plugin not enabled: using a plain sky with no city. "
             "Install it from Fab for the photoreal above-ground shots.")
        _plain_sky()
    fog = U.spawn(unreal.ExponentialHeightFog, (0, 0, 0), folder="Lighting", label="HeightFog")
    U.set_props(fog.component, fog_density=0.004, fog_height_falloff=0.05, volumetric_fog=True)
    U.spawn(unreal.VolumetricCloud, folder="Lighting", label="Clouds")


def _plain_sky():
    sun = U.spawn(unreal.DirectionalLight, (0, 0, 50000), (0, -18, 115), "Lighting", "Sun")
    U.set_props(sun.light_component, intensity=10.0, atmosphere_sun_light=True, use_temperature=True,
                temperature=5200.0, mobility=unreal.ComponentMobility.MOVABLE)
    U.spawn(unreal.SkyAtmosphere, folder="Lighting", label="SkyAtmosphere")
    sl = U.spawn(unreal.SkyLight, folder="Lighting", label="SkyLight")
    U.set_props(sl.light_component, real_time_capture=True, mobility=unreal.ComponentMobility.MOVABLE)


# --------------------------------------------------------------------- main
def main():
    t0 = time.time()
    U.open_or_create_map()
    U.destroy_generated()
    work = U.generated_dir()
    obj_from_ue, scale = calibrate_importer(work)
    mesh_dir = os.path.join(work, "meshes")
    if os.path.isdir(mesh_dir):
        shutil.rmtree(mesh_dir)
    log(f"generating meshes ({config.QUALITY}) -> {mesh_dir}")
    manifest = SceneBuilder().generate(mesh_dir, obj_from_ue, verbose=False)
    log(f"{len(manifest['meshes'])} meshes, {manifest['triangles']:,} triangles")
    mats = build_material_instances()
    import_meshes(manifest, mesh_dir, mats)
    spawn_lights(manifest)
    setup_post_process()
    setup_sky_and_city()
    with open(os.path.join(work, "last_build.json"), "w") as f:
        json.dump({"quality": config.QUALITY, "meshes": len(manifest["meshes"])}, f)
    U.save_all()
    log(f"build complete in {time.time() - t0:.0f}s. Next: create_flyby.py")


main()
