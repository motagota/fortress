"""WGS84 geodesy and the ENU <-> Unreal coordinate mapping used by Cesium for
Unreal (Unreal +X = East, +Y = South, +Z = Up, centimetres)."""
import math

WGS84_A = 6378137.0
WGS84_F = 1.0 / 298.257223563
WGS84_E2 = WGS84_F * (2.0 - WGS84_F)


def geodetic_to_ecef(lat, lon, h):
    la, lo = math.radians(lat), math.radians(lon)
    s, c = math.sin(la), math.cos(la)
    n = WGS84_A / math.sqrt(1.0 - WGS84_E2 * s * s)
    return ((n + h) * c * math.cos(lo), (n + h) * c * math.sin(lo), (n * (1 - WGS84_E2) + h) * s)


def geodetic_to_enu(lat, lon, h, lat0, lon0, h0):
    """Exact ECEF-based East/North/Up (metres) of a point relative to origin."""
    x, y, z = geodetic_to_ecef(lat, lon, h)
    x0, y0, z0 = geodetic_to_ecef(lat0, lon0, h0)
    dx, dy, dz = x - x0, y - y0, z - z0
    la, lo = math.radians(lat0), math.radians(lon0)
    sl, cl, so, co = math.sin(la), math.cos(la), math.sin(lo), math.cos(lo)
    e = -so * dx + co * dy
    n = -sl * co * dx - sl * so * dy + cl * dz
    u = cl * co * dx + cl * so * dy + sl * dz
    return e, n, u


def earth_radius_at(lat):
    """Gaussian mean radius of curvature (m)."""
    la = math.radians(lat)
    s2 = math.sin(la) ** 2
    return WGS84_A * math.sqrt(1 - WGS84_E2) / (1 - WGS84_E2 * s2)


def enu_to_ue(e, n, u):
    """ENU metres -> Unreal centimetres (left-handed, Y = South)."""
    return (e * 100.0, -n * 100.0, u * 100.0)


def enu_dir_to_ue(e, n, u):
    return (e, -n, u)
