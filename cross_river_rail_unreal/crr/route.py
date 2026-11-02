"""Cross River Rail alignment model.

IMPORTANT: the detailed design alignment is not public. These waypoints are an
*approximation* assembled from public information (station locations, the
5.9 km twin-tunnel length, ~58 m max depth below Kangaroo Point, ~42 m below
the river, Albert St cavern ~290 m / ~34 m deep, Roma St cavern ~280 m,
Boggo Road ~19 m deep with a ~220 m platform). Replace them with surveyed
coordinates (e.g. from the project EIS / your own GIS trace) if you have them:
everything downstream (meshes, lights, camera) is derived from this table.

Rail levels are metres AHD (top of rail). Tracks are Queensland Rail narrow
gauge (1067 mm). Chainage increases south -> north.
"""
import bisect
import math
from dataclasses import dataclass, field

from . import config
from .geo import geodetic_to_enu, earth_radius_at

GAUGE_M = 1.067
TRACK_OFFSET_M = 7.0       # each track/tube centre is +-7 m from the route centre
TUBE_RADIUS_M = 3.1        # internal radius of the segmental lining (7.2 m TBM)
TUBE_CENTRE_ABOVE_RAIL = 1.6
STATION_HALF_WIDTH = 13.0
STATION_WALL_TOP = 9.0
STATION_CROWN = 15.0
PLATFORM_EDGE = 8.5        # |x| of platform edge (track centre at 7.0)
PLATFORM_HEIGHT = 1.0      # above top of rail
TROUGH_HALF_WIDTH = 9.5


@dataclass
class Waypoint:
    name: str
    lat: float
    lon: float
    rail_ahd: float
    kind: str = "via"      # approach_start|portal|station_start|station_end|via|approach_end
    station: str = ""
    # filled in by Alignment
    e: float = 0.0
    n: float = 0.0
    chainage: float = 0.0


def default_waypoints():
    W = Waypoint
    return [
        W("South approach (Dutton Park)", -27.5012, 153.0255, 12.0, "approach_start"),
        W("Southern portal", -27.4985, 153.0280, 4.0, "portal"),
        W("Boggo Road (S)", -27.4946, 153.0305, -2.0, "station_start", "Boggo Road"),
        W("Boggo Road (N)", -27.4930, 153.0322, -2.0, "station_end", "Boggo Road"),
        W("Woolloongabba (S)", -27.4885, 153.0338, -12.0, "station_start", "Woolloongabba"),
        W("Woolloongabba (N)", -27.4867, 153.0350, -12.0, "station_end", "Woolloongabba"),
        W("Kangaroo Point (deepest)", -27.4805, 153.0345, -31.0),
        W("Under the Brisbane River", -27.4772, 153.0318, -32.0),
        W("City Botanic Gardens", -27.4740, 153.0295, -25.0),
        W("Albert Street (S)", -27.4716, 153.0275, -18.0, "station_start", "Albert Street"),
        W("Albert Street (N)", -27.4698, 153.0256, -18.0, "station_end", "Albert Street"),
        W("Roma Street (S)", -27.4672, 153.0215, -6.0, "station_start", "Roma Street"),
        W("Roma Street (N)", -27.4655, 153.0196, -6.0, "station_end", "Roma Street"),
        W("Northern portal (Normanby)", -27.4605, 153.0138, 8.0, "portal"),
        W("North approach (Victoria Park)", -27.4588, 153.0118, 14.0, "approach_end"),
    ]


def _norm2(x, y):
    d = math.hypot(x, y)
    return (x / d, y / d) if d > 1e-12 else (0.0, 0.0)


def smoothstep(a, b, x):
    if b == a:
        return 1.0 if x >= b else 0.0
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


@dataclass
class Station:
    name: str
    c0: float
    c1: float

    @property
    def length(self):
        return self.c1 - self.c0


class Alignment:
    """Horizontal Hermite spline (exactly straight through stations) + vertical
    profile of straight grades joined by parabolic vertical curves."""

    def __init__(self, waypoints=None, step=0.5):
        self.wp = waypoints or default_waypoints()
        self.lat0, self.lon0 = config.ORIGIN_LAT, config.ORIGIN_LON
        self.h0 = config.GEOID_SEPARATION_M          # UE Z = 0 at ~AHD 0
        self.R_earth = earth_radius_at(self.lat0)
        for w in self.wp:
            w.e, w.n, _ = geodetic_to_enu(w.lat, w.lon, self.h0, self.lat0, self.lon0, self.h0)
        self._build_horizontal(step)
        self._build_vertical()
        self.stations = []
        for i, w in enumerate(self.wp):
            if w.kind == "station_start":
                self.stations.append(Station(w.station, w.chainage, self.wp[i + 1].chainage))
        portals = [w.chainage for w in self.wp if w.kind == "portal"]
        self.portal_s, self.portal_n = portals[0], portals[-1]
        self.c_start, self.c_end = 0.0, self.length

    # ---------------------------------------------------------------- horizontal
    def _build_horizontal(self, step):
        P = [(w.e, w.n) for w in self.wp]
        m = len(P)
        dirs = []
        for i, w in enumerate(self.wp):
            if w.kind == "station_start":
                d = _norm2(P[i + 1][0] - P[i][0], P[i + 1][1] - P[i][1])
            elif w.kind == "station_end":
                d = _norm2(P[i][0] - P[i - 1][0], P[i][1] - P[i - 1][1])
            elif i == 0:
                d = _norm2(P[1][0] - P[0][0], P[1][1] - P[0][1])
            elif i == m - 1:
                d = _norm2(P[i][0] - P[i - 1][0], P[i][1] - P[i - 1][1])
            else:
                d = _norm2(P[i + 1][0] - P[i - 1][0], P[i + 1][1] - P[i - 1][1])
            dirs.append(d)
        # Dense sampling of each Hermite segment
        pts = [P[0]]
        wp_index = [0]
        for i in range(m - 1):
            (x0, y0), (x1, y1) = P[i], P[i + 1]
            L = math.hypot(x1 - x0, y1 - y0)
            t0 = (dirs[i][0] * L, dirs[i][1] * L)
            t1 = (dirs[i + 1][0] * L, dirs[i + 1][1] * L)
            k = max(8, int(L / 0.25))
            for j in range(1, k + 1):
                t = j / k
                h00 = 2 * t**3 - 3 * t**2 + 1
                h10 = t**3 - 2 * t**2 + t
                h01 = -2 * t**3 + 3 * t**2
                h11 = t**3 - t**2
                pts.append((h00 * x0 + h10 * t0[0] + h01 * x1 + h11 * t1[0],
                            h00 * y0 + h10 * t0[1] + h01 * y1 + h11 * t1[1]))
            wp_index.append(len(pts) - 1)
        cum = [0.0]
        for a, b in zip(pts, pts[1:]):
            cum.append(cum[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
        for w, idx in zip(self.wp, wp_index):
            w.chainage = cum[idx]
        self.length = cum[-1]
        # Resample uniformly by arc length
        n = int(self.length / step) + 1
        self.step = self.length / (n - 1)
        self._c = [i * self.step for i in range(n)]
        self._xy = []
        j = 0
        for c in self._c:
            while j < len(cum) - 2 and cum[j + 1] < c:
                j += 1
            seg = cum[j + 1] - cum[j]
            t = 0.0 if seg <= 0 else (c - cum[j]) / seg
            t = min(1.0, max(0.0, t))
            a, b = pts[j], pts[j + 1]
            self._xy.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))

    # ------------------------------------------------------------------ vertical
    def _build_vertical(self, vc_max=160.0, station_pad=45.0):
        pvis = []
        for i, w in enumerate(self.wp):
            if w.kind == "station_start":
                pvis.append((w.chainage - station_pad, w.rail_ahd))
            elif w.kind == "station_end":
                pvis.append((w.chainage + station_pad, w.rail_ahd))
            else:
                pvis.append((w.chainage, w.rail_ahd))
        pvis.sort()
        self._pvi = pvis
        flats = [(w.chainage, self.wp[i + 1].chainage) for i, w in enumerate(self.wp)
                 if w.kind == "station_start"]
        self._curves = []
        for i in range(1, len(pvis) - 1):
            (cp, zp), (c, z), (cn, zn) = pvis[i - 1], pvis[i], pvis[i + 1]
            g1 = (z - zp) / (c - cp)
            g2 = (zn - z) / (cn - c)
            L = min(vc_max, c - cp, cn - c)
            for (f0, f1) in flats:  # never let a vertical curve reach a platform
                if c <= f0:
                    L = min(L, 2 * (f0 - c))
                elif c >= f1:
                    L = min(L, 2 * (c - f1))
            if abs(g2 - g1) > 1e-9 and L > 1.0:
                self._curves.append((c - L / 2, c + L / 2, c, z, g1, g2, L))

    def rail_ahd(self, c):
        for (a, b, cv, zv, g1, g2, L) in self._curves:
            if a <= c <= b:
                x = c - a
                return zv - g1 * L / 2 + g1 * x + (g2 - g1) * x * x / (2 * L)
        p = self._pvi
        if c <= p[0][0]:
            g = (p[1][1] - p[0][1]) / (p[1][0] - p[0][0])
            return p[0][1] + g * (c - p[0][0])
        if c >= p[-1][0]:
            g = (p[-1][1] - p[-2][1]) / (p[-1][0] - p[-2][0])
            return p[-1][1] + g * (c - p[-1][0])
        i = bisect.bisect_right([q[0] for q in p], c) - 1
        (c0, z0), (c1, z1) = p[i], p[i + 1]
        return z0 + (z1 - z0) * (c - c0) / (c1 - c0)

    def grade(self, c, d=1.0):
        return (self.rail_ahd(c + d) - self.rail_ahd(c - d)) / (2 * d)

    # ------------------------------------------------------------------ queries
    def _xy_at(self, c):
        c = min(max(c, 0.0), self.length)
        f = c / self.step
        i = min(int(f), len(self._xy) - 2)
        t = f - i
        a, b = self._xy[i], self._xy[i + 1]
        return a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t

    def heading(self, c):
        """Unit horizontal forward vector (east, north)."""
        d = 1.0
        a = self._xy_at(max(0.0, c - d))
        b = self._xy_at(min(self.length, c + d))
        return _norm2(b[0] - a[0], b[1] - a[1])

    def frame(self, c):
        """(origin_enu, forward_enu, right_enu, up_enu) at chainage c; origin is the
        route centre-line at top-of-rail level. Cross-sections are vertical planes."""
        e, n = self._xy_at(c)
        fx, fy = self.heading(c)
        # Extrapolate linearly beyond the ends
        if c < 0 or c > self.length:
            cc = min(max(c, 0.0), self.length)
            e += fx * (c - cc)
            n += fy * (c - cc)
        u = self.rail_ahd(c) + config.VERTICAL_ADJUST_M - (e * e + n * n) / (2 * self.R_earth)
        return (e, n, u), (fx, fy, 0.0), (fy, -fx, 0.0), (0.0, 0.0, 1.0)

    def point(self, c, x=0.0, y=0.0):
        """ENU point at chainage c, lateral offset x (right +), height y above rail."""
        (o, f, r, up) = self.frame(c)
        return (o[0] + r[0] * x, o[1] + r[1] * x, o[2] + y)

    def enu_from_geodetic(self, lat, lon, ahd):
        return geodetic_to_enu(lat, lon, ahd + self.h0 + config.VERTICAL_ADJUST_M,
                               self.lat0, self.lon0, self.h0)

    # ------------------------------------------------------------------ regions
    def station_at(self, c):
        for s in self.stations:
            if s.c0 <= c <= s.c1:
                return s
        return None

    def tunnel_intervals(self):
        """Bored/mined twin-tube intervals (portal-to-portal minus stations)."""
        out, a = [], self.portal_s
        for s in self.stations:
            out.append((a, s.c0))
            a = s.c1
        out.append((a, self.portal_n))
        return out

    def trough_intervals(self):
        return [(self.c_start, self.portal_s), (self.portal_n, self.c_end)]

    def region(self, c):
        if c < self.portal_s or c > self.portal_n:
            return "trough"
        return "station" if self.station_at(c) else "tunnel"

    def min_radius(self, c0=None, c1=None, d=20.0):
        c0 = self.c_start + d if c0 is None else c0
        c1 = self.c_end - d if c1 is None else c1
        best, c = float("inf"), c0
        while c <= c1:
            h0, h1 = self.heading(c - d), self.heading(c + d)
            ang = abs(math.atan2(h0[0] * h1[1] - h0[1] * h1[0], h0[0] * h1[0] + h0[1] * h1[1]))
            if ang > 1e-9:
                best = min(best, 2 * d / ang)
            c += 5.0
        return best

    def max_grade(self, c0=None, c1=None):
        c0 = self.c_start if c0 is None else c0
        c1 = self.c_end if c1 is None else c1
        g, c = 0.0, c0 + 1
        while c < c1 - 1:
            g = max(g, abs(self.grade(c)))
            c += 5.0
        return g

    def summary(self):
        lines = [f"Route length (approach to approach): {self.length:8.1f} m",
                 f"Tunnel portal to portal:             {self.portal_n - self.portal_s:8.1f} m",
                 f"Minimum horizontal radius:           {self.min_radius():8.1f} m",
                 f"Maximum grade:                       {self.max_grade() * 100:8.2f} %"]
        for s in self.stations:
            lines.append(f"  {s.name:<15} ch {s.c0:7.1f}-{s.c1:7.1f}  len {s.length:5.1f} m  "
                         f"rail {self.rail_ahd((s.c0 + s.c1) / 2):6.1f} m AHD")
        return "\n".join(lines)
