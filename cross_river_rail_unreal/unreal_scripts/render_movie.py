"""Step 3/3 - render the flyby with Movie Render Queue.

Presets (CRR_RENDER_PRESET):
  draft      - 1 sample, TSR, quick check of timing and framing
  final      - Lumen, 16 temporal sub-samples (clean motion blur + converged GI), 4K
  pathtraced - Path Tracer, 64 samples/frame (slowest, most photoreal)

Output: PNG sequence (or EXR with CRR_OUTPUT_FORMAT=exr) in
<Project>/Saved/MovieRenders/CRR. Encode with ffmpeg (see README).

Needs the "Movie Render Queue" plugin enabled.
"""
import importlib
import os
import sys

import unreal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crr_ue as U  # noqa: E402
importlib.reload(U)
from crr_ue import config, log, warn  # noqa: E402

PRESETS = {
    "draft":      dict(spatial=1, temporal=1, aa=unreal.AntiAliasingMethod.AAM_TSR, warm=32, render_warm=8),
    "final":      dict(spatial=1, temporal=16, aa=unreal.AntiAliasingMethod.AAM_NONE, warm=150, render_warm=64),
    "pathtraced": dict(spatial=1, temporal=64, aa=unreal.AntiAliasingMethod.AAM_NONE, warm=150, render_warm=0),
}

CVARS_COMMON = {
    "r.MotionBlurQuality": 4,
    "r.DepthOfFieldQuality": 4,
    "r.BloomQuality": 5,
    "r.Tonemapper.Quality": 5,
    "r.SSR.Quality": 4,
    "r.Streaming.FullyLoadUsedTextures": 1,
    "r.Nanite.MaxPixelsPerEdge": 0.5,
    "r.Shadow.Virtual.SMRT.RayCountLocal": 16,
    "r.Shadow.Virtual.SMRT.SamplesPerRayLocal": 8,
    "r.Shadow.Virtual.SMRT.RayCountDirectional": 16,
    "r.Shadow.Virtual.SMRT.SamplesPerRayDirectional": 8,
    "r.Lumen.Reflections.DownsampleFactor": 1,
    "r.Lumen.TranslucencyReflections.FrontLayer.Enable": 1,
    "r.Lumen.ScreenProbeGather.DownsampleFactor": 8,
    "r.VolumetricFog.GridPixelSize": 4,
    "r.VolumetricFog.GridSizeZ": 128,
}
CVARS_PATHTRACED = {
    "r.PathTracing.ProgressDisplay": 0,
    "r.PathTracing.MaxBounces": 8,
}

_executor = None  # keep a reference so the executor isn't garbage collected


def _cvar(setting, name, value):
    try:
        setting.add_or_update_console_variable(name, float(value))
    except Exception:  # noqa: BLE001
        try:
            cv = setting.get_editor_property("console_variables")
            cv[name] = float(value)
            setting.set_editor_property("console_variables", cv)
        except Exception as e:  # noqa: BLE001
            warn(f"cvar {name}: {e}")


def main():
    global _executor
    preset_name = config.RENDER_PRESET.lower()
    P = PRESETS[preset_name]
    out_dir = config.OUTPUT_DIR or os.path.join(os.path.abspath(unreal.Paths.project_saved_dir()),
                                                "MovieRenders", "CRR", preset_name)
    subsystem = unreal.get_editor_subsystem(unreal.MoviePipelineQueueSubsystem)
    queue = subsystem.get_queue()
    queue.delete_all_jobs()
    job = queue.allocate_new_job(unreal.MoviePipelineExecutorJob)
    job.set_editor_property("job_name", f"CRR_Flyby_{preset_name}")
    job.set_editor_property("sequence", unreal.SoftObjectPath(config.SEQUENCE_PATH))
    job.set_editor_property("map", unreal.SoftObjectPath(config.MAP_PATH))
    cfg = job.get_configuration()

    if preset_name == "pathtraced":
        cfg.find_or_add_setting_by_class(unreal.MoviePipelineDeferredPass_PathTracer)
    else:
        cfg.find_or_add_setting_by_class(unreal.MoviePipelineDeferredPassBase)

    fmt = os.environ.get("CRR_OUTPUT_FORMAT", "png").lower()
    if fmt == "exr":
        img = cfg.find_or_add_setting_by_class(unreal.MoviePipelineImageSequenceOutput_EXR)
        U.set_props(img, compression=unreal.EXRCompressionFormat.PIZ)
    else:
        cfg.find_or_add_setting_by_class(unreal.MoviePipelineImageSequenceOutput_PNG)

    out = cfg.find_or_add_setting_by_class(unreal.MoviePipelineOutputSetting)
    U.set_props(out, output_directory=unreal.DirectoryPath(out_dir),
                file_name_format="{sequence_name}.{frame_number}",
                output_resolution=unreal.IntPoint(config.RES_X, config.RES_Y),
                zero_pad_frame_numbers=5, override_existing_output=True)

    aa = cfg.find_or_add_setting_by_class(unreal.MoviePipelineAntiAliasingSetting)
    U.set_props(aa, spatial_sample_count=P["spatial"], temporal_sample_count=P["temporal"],
                override_anti_aliasing=True, anti_aliasing_method=P["aa"],
                engine_warm_up_count=P["warm"], render_warm_up_count=P["render_warm"],
                use_camera_cut_for_warm_up=False, render_warm_up_frames=P["render_warm"] > 0)

    game = cfg.find_or_add_setting_by_class(unreal.MoviePipelineGameOverrideSetting)
    U.set_props(game, cinematic_quality_settings=True, flush_streaming_managers=True)

    cv = cfg.find_or_add_setting_by_class(unreal.MoviePipelineConsoleVariableSetting)
    cvars = dict(CVARS_COMMON)
    if preset_name == "pathtraced":
        cvars.update(CVARS_PATHTRACED)
    for k, v in cvars.items():
        _cvar(cv, k, v)

    log(f"rendering preset '{preset_name}' at {config.RES_X}x{config.RES_Y} -> {out_dir}")

    def _done(executor, success):
        log(f"render finished, success={success}. Frames in {out_dir}")

    _executor = subsystem.render_queue_with_executor(unreal.MoviePipelinePIEExecutor)
    if _executor:
        try:
            _executor.on_executor_finished_delegate.add_callable_unique(_done)
        except Exception:  # noqa: BLE001
            pass


main()
