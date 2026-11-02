"""All tunables in one place. Override any value with an environment variable
of the same name prefixed with CRR_ (e.g. CRR_QUALITY=draft)."""
import os


def _env(name, default, cast=str):
    v = os.environ.get("CRR_" + name)
    return cast(v) if v not in (None, "") else default


# --- Geo-referencing -------------------------------------------------------
# Unreal world origin == Cesium georeference origin. Placed near Albert Street
# station so the whole 6.5 km route sits within ~3.5 km of the origin.
ORIGIN_LAT = _env("ORIGIN_LAT", -27.4706, float)
ORIGIN_LON = _env("ORIGIN_LON", 153.0263, float)

# Height of the AHD (Australian Height Datum, ~mean sea level) above the WGS84
# ellipsoid in Brisbane. Google Photorealistic 3D Tiles use ellipsoid heights,
# our rail levels are in AHD. ~40-41 m in Brisbane; verify with the
# Geoscience Australia AUSGeoid2020 calculator for your exact spot.
GEOID_SEPARATION_M = _env("GEOID_SEPARATION_M", 40.6, float)

# Global nudge (metres) if the portals don't sit exactly on the 3D tiles.
VERTICAL_ADJUST_M = _env("VERTICAL_ADJUST_M", 0.0, float)

# --- Geometry quality ------------------------------------------------------
# "final": segmental-lining ring joints, rail baseplates, 2 m sampling.
# "draft": ~10x fewer triangles, for blocking out the camera quickly.
QUALITY = _env("QUALITY", "final")

# --- Unreal content locations ---------------------------------------------
CONTENT_ROOT = _env("CONTENT_ROOT", "/Game/CrossRiverRail")
MAP_PATH = CONTENT_ROOT + "/Maps/CRR_Flyby"
SEQUENCE_PATH = CONTENT_ROOT + "/Cinematics/LS_CRR_Flyby"

# --- Above-ground photoreal city (Cesium for Unreal) -----------------------
# Either a Google Map Tiles API key (Photorealistic 3D Tiles) or a Cesium ion
# token (ion asset 2275207 is Google Photorealistic 3D Tiles). Never commit
# keys - pass them as environment variables.
GOOGLE_MAPS_API_KEY = os.environ.get("GOOGLE_MAPS_API_KEY", "")
CESIUM_ION_TOKEN = os.environ.get("CESIUM_ION_TOKEN", "")
CESIUM_ION_GOOGLE_ASSET_ID = 2275207
TILESET_MAX_SSE = _env("TILESET_MAX_SSE", 8.0, float)  # lower = sharper

# Sun position (local Brisbane time, AEST = UTC+10, no daylight saving).
SUN_YEAR = _env("SUN_YEAR", 2026, int)
SUN_MONTH = _env("SUN_MONTH", 8, int)
SUN_DAY = _env("SUN_DAY", 15, int)
SUN_SOLAR_TIME = _env("SUN_SOLAR_TIME", 16.5, float)  # 4:30 pm, warm low sun
SUN_TIME_ZONE = 10.0

# --- Flyby -------------------------------------------------------------------
FPS = _env("FPS", 24, int)
# Camera speeds (m/s) per region of the flight.
SPEED_AERIAL = _env("SPEED_AERIAL", 55.0, float)
SPEED_TROUGH = _env("SPEED_TROUGH", 28.0, float)
SPEED_TUNNEL = _env("SPEED_TUNNEL", 60.0, float)
SPEED_STATION = _env("SPEED_STATION", 14.0, float)
SPEED_FINAL = _env("SPEED_FINAL", 35.0, float)

# --- Render -----------------------------------------------------------------
RES_X = _env("RES_X", 3840, int)
RES_Y = _env("RES_Y", 2160, int)
RENDER_PRESET = _env("RENDER_PRESET", "final")  # draft | final | pathtraced
OUTPUT_DIR = _env("OUTPUT_DIR", "")  # default: <Project>/Saved/MovieRenders/CRR
