"""Procedural geometry for the Cross River Rail tunnels, stations and portals.

Writes one Wavefront OBJ per (element, ~200 m chunk) plus manifest.json that
lists every mesh (material key, Nanite flag, Unreal placement, expected local
bounds) and every light to spawn.

Geometry is generated in Unreal space (cm, left-handed, Y = South), relative to
each chunk's origin. Because Unreal importers apply their own unit/axis
conversion to OBJ files, the build script first imports small calibration
meshes, measures that conversion and passes its inverse here as `obj_from_ue`,
so the imported meshes land exactly where intended.
"""
import json
import math
import os

from . import config
from .geo import enu_to_ue, enu_dir_to_ue
from .route import (Alignment, TRACK_OFFSET_M, TUBE_RADIUS_M, TUBE_CENTRE_ABOVE_RAIL,
                    GAUGE_M, STATION_HALF_WIDTH, STATION_WALL_TOP, STATION_CROWN,
                    PLATFORM_EDGE, PLATFORM_HEIGHT, TROUGH_HALF_WIDTH)

CHUNK_M = 200.0

# material key -> description (the Unreal build script maps these to material instances)
MATERIALS = {
    "lining": "precast concrete tunnel segments",
    "slab": "track slab concrete",
    "walkway": "walkway concrete",
    "paint_yellow": "safety line paint",
    "steel": "galvanised steel (handrails, trays)",
    "rail": "rail steel",
    "baseplate": "rail fastening baseplates",
    "led": "emissive luminaires",
    "station_wall": "station wall cladding",
    "station_ceiling": "station ceiling",
    "station_floor": "platform floor (terrazzo)",
    "tactile": "tactile ground indicators",
    "psd_frame": "platform screen door frames",
    "psd_glass": "platform screen door glass",
    "trough": "cast-in-place concrete (portal trough)",
}
NON_NANITE = {"psd_glass"}  # translucent materials cannot be Nanite


# --------------------------------------------------------------------- helpers
def rect(x0, y0, x1, y1):
    """Closed CCW rectangle profile."""
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def mirror(profile):
    """Mirror a profile across x=0, preserving 'normal on the left' semantics."""
    return [(-x, y) for (x, y) in reversed(profile)]


def shift(profile, dx=0.0, dy=0.0):
    return [(x + dx, y + dy) for (x, y) in profile]


def circle(cx, cy, r, n):
    return [(cx + r * math.cos(-math.pi / 2 + 2 * math.pi * k / n),
             cy + r * math.sin(-math.pi / 2 + 2 * math.pi * k / n)) for k in range(n)]


def arc_through(x0, y0, crown, n):
    """CCW arc from (x0,y0) over the crown (0,crown) to (-x0,y0)."""
    yc = (x0 * x0 + y0 * y0 - crown * crown) / (2 * (y0 - crown))
    r = crown - yc
    a0 = math.atan2(y0 - yc, x0)
    a1 = math.pi - a0
    return [(r * math.cos(a0 + (a1 - a0) * k / n), yc + r * math.sin(a0 + (a1 - a0) * k / n))
            for k in range(n + 1)]


def frange(a, b, step):
    n = max(1, int(math.ceil((b - a) / step - 1e-9)))
    return [a + (b - a) * i / n for i in range(n + 1)]


def periodic_intervals(a, b, period, length, phase=0.0):
    out, c = [], a + phase
    while c + length <= b:
        out.append((c, c + length))
        c += period
    return out


def clip_intervals(intervals, a, b):
    out = []
    for (p, q) in intervals:
        p2, q2 = max(p, a), min(q, b)
        if q2 - p2 > 1e-6:
            out.append((p2, q2))
    return out


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


# ----------------------------------------------------------------- mesh builder
class Mesh:
    def __init__(self, name, material, origin_ue):
        self.name, self.material, self.origin = name, material, origin_ue
        self.v, self.uv, self.tris = [], [], []

    def vert(self, p_enu, uv):
        ue = enu_to_ue(*p_enu)
        o = self.origin
        self.v.append((ue[0] - o[0], ue[1] - o[1], ue[2] - o[2]))
        self.uv.append(uv)
        return len(self.v) - 1

    def tri(self, a, b, c, normal_enu):
        """Add a triangle oriented so its geometric normal (in Unreal space)
        agrees with the intended normal."""
        n = enu_dir_to_ue(*normal_enu)
        g = _cross(_sub(self.v[b], self.v[a]), _sub(self.v[c], self.v[a]))
        if _dot(g, n) < 0:
            b, c = c, b
        self.tris.append((a, b, c))

    def quad(self, a, b, c, d, normal_enu):
        self.tri(a, b, c, normal_enu)
        self.tri(a, c, d, normal_enu)

    def empty(self):
        return not self.tris

    def bounds(self):
        xs, ys, zs = zip(*self.v)
        return [min(xs), min(ys), min(zs)], [max(xs), max(ys), max(zs)]

    def write_obj(self, path, obj_from_ue, flip):
        M = obj_from_ue
        with open(path, "w") as f:
            f.write(f"# Cross River Rail procedural mesh: {self.name} ({self.material})\n")
            f.write(f"o {self.name}\n")
            w = f.write
            for (x, y, z) in self.v:
                w("v %.7g %.7g %.7g\n" % (M[0][0] * x + M[0][1] * y + M[0][2] * z,
                                          M[1][0] * x + M[1][1] * y + M[1][2] * z,
                                          M[2][0] * x + M[2][1] * y + M[2][2] * z))
            for (u, v) in self.uv:
                w("vt %.5g %.5g\n" % (u, v))
            for (a, b, c) in self.tris:
                if flip:
                    b, c = c, b
                w("f %d/%d %d/%d %d/%d\n" % (a + 1, a + 1, b + 1, b + 1, c + 1, c + 1))


def sweep(mesh, al, intervals, profile, offset=0.0, closed=False, smooth=False,
          step=2.0, samples=None, caps=False, v_scale=1.0):
    """Extrude a 2D cross-section profile along the alignment.

    profile: list of (x, y) section points (x right, y up, metres, relative to the
             track centre at `offset` and top-of-rail), or a function c -> list.
             The surface normal is on the LEFT of the traversal direction.
    smooth:  share vertices between profile segments (smooth shading).
    samples: optional function (a, b) -> sorted chainages (default: uniform `step`).
    caps:    close the ends of each interval (closed convex profiles only).
    """
    prof_fn = profile if callable(profile) else (lambda c, p=profile: p)
    for (a, b) in intervals:
        cs = samples(a, b) if samples else frange(a, b, step)
        rings = []
        for c in cs:
            (o, fwd, right, up) = al.frame(c)
            pts2 = prof_fn(c)
            ring = []
            for (x, y) in pts2:
                xx = x + offset
                ring.append((o[0] + right[0] * xx, o[1] + right[1] * xx, o[2] + y))
            cum = [0.0]
            for j in range(len(pts2) if closed else len(pts2) - 1):
                (xa, ya), (xb, yb) = pts2[j], pts2[(j + 1) % len(pts2)]
                cum.append(cum[-1] + math.hypot(xb - xa, yb - ya))
            rings.append((c, pts2, ring, right, cum))
        nseg = len(rings[0][1]) if closed else len(rings[0][1]) - 1
        # per-segment 2D normals (left of traversal)
        for k in range(nseg):
            k2 = (k + 1) % len(rings[0][1])
            col_a, col_b = [], []
            for (c, p2, ring, right, cum) in rings:
                vlen = cum[k] * v_scale
                col_a.append(mesh.vert(ring[k], (c, vlen)))
                col_b.append(mesh.vert(ring[k2], (c, cum[k + 1] * v_scale)))
            for i in range(len(rings) - 1):
                c, p2, ring, right, _ = rings[i]
                (x0, y0), (x1, y1) = p2[k], p2[k2]
                nx, ny = -(y1 - y0), (x1 - x0)
                n_enu = (right[0] * nx, right[1] * nx, ny)
                mesh.quad(col_a[i], col_a[i + 1], col_b[i + 1], col_b[i], n_enu)
        if smooth:
            _weld_columns(mesh)
        if caps and closed:
            for (idx, sgn) in ((0, -1.0), (len(rings) - 1, 1.0)):
                c, p2, ring, right, _ = rings[idx]
                _, fwd, _, _ = al.frame(c)
                ids = [mesh.vert(p, (p2[j][0], p2[j][1])) for j, p in enumerate(ring)]
                n = (fwd[0] * sgn, fwd[1] * sgn, 0.0)
                for j in range(1, len(ids) - 1):
                    mesh.tri(ids[0], ids[j], ids[j + 1], n)


def _weld_columns(mesh):
    """Merge coincident vertices with identical UVs (gives smooth normals on import)."""
    seen, remap = {}, {}
    nv, nuv = [], []
    for i, (p, uv) in enumerate(zip(mesh.v, mesh.uv)):
        key = (round(p[0], 2), round(p[1], 2), round(p[2], 2), round(uv[0], 4), round(uv[1], 4))
        j = seen.get(key)
        if j is None:
            j = seen[key] = len(nv)
            nv.append(p)
            nuv.append(uv)
        remap[i] = j
    mesh.v, mesh.uv = nv, nuv
    mesh.tris = [(remap[a], remap[b], remap[c]) for (a, b, c) in mesh.tris
                 if len({remap[a], remap[b], remap[c]}) == 3]


def _clip_convex(poly, keep_positive_x):
    out = []
    s = 1.0 if keep_positive_x else -1.0
    for i in range(len(poly)):
        p, q = poly[i], poly[(i + 1) % len(poly)]
        pin, qin = s * p[0] >= -1e-9, s * q[0] >= -1e-9
        if pin:
            out.append(p)
        if pin != qin:
            t = p[0] / (p[0] - q[0])
            out.append((0.0, p[1] + (q[1] - p[1]) * t))
    return out


def _ray_hit(poly, cx, cy, dx, dy):
    best = float("inf")
    for i in range(len(poly)):
        (x0, y0), (x1, y1) = poly[i], poly[(i + 1) % len(poly)]
        ex, ey = x1 - x0, y1 - y0
        den = dx * ey - dy * ex
        if abs(den) < 1e-12:
            continue
        t = ((x0 - cx) * ey - (y0 - cy) * ex) / den
        u = ((x0 - cx) * dy - (y0 - cy) * dx) / den
        if t > 1e-9 and -1e-9 <= u <= 1 + 1e-9:
            best = min(best, t)
    return cx + dx * best, cy + dy * best


def holed_wall(mesh, al, c, outline, holes, facing, n=48):
    """Planar wall across the route at chainage c: convex `outline` (CCW, section
    coords) with circular holes (cx, cy, r) - at most one hole each side of x=0.
    facing = +1 normal points forward (increasing chainage), -1 backwards."""
    (o, fwd, right, up) = al.frame(c)
    nrm = (fwd[0] * facing, fwd[1] * facing, 0.0)

    def P(x, y):
        return mesh.vert((o[0] + right[0] * x, o[1] + right[1] * x, o[2] + y), (x, y))

    for positive in (True, False):
        half = _clip_convex(outline, positive)
        hs = [h for h in holes if (h[0] > 0) == positive]
        if not hs:
            for j in range(1, len(half) - 1):
                mesh.tri(P(*half[0]), P(*half[j]), P(*half[j + 1]), nrm)
            continue
        (hx, hy, r) = hs[0]
        inner, outer = [], []
        for k in range(n):
            a = 2 * math.pi * k / n
            dx, dy = math.cos(a), math.sin(a)
            inner.append(P(hx + r * dx, hy + r * dy))
            outer.append(P(*_ray_hit(half, hx, hy, dx, dy)))
        for k in range(n):
            k2 = (k + 1) % n
            mesh.quad(inner[k], inner[k2], outer[k2], outer[k], nrm)


# -------------------------------------------------------------------- the scene
class SceneBuilder:
    def __init__(self, al=None, quality=None):
        self.al = al or Alignment()
        self.q = (quality or config.QUALITY).lower()
        self.final = self.q != "draft"
        self.step = 2.0 if self.final else 5.0
        self.lights = []
        n_chunks = int(math.ceil(self.al.length / CHUNK_M))
        self.chunks = [(i * CHUNK_M, min(self.al.length, (i + 1) * CHUNK_M)) for i in range(n_chunks)]

    # ---- element definitions: each yields (name, material, fn(mesh, a, b)) --------
    def elements(self):
        al, step = self.al, self.step
        tunnels = al.tunnel_intervals()
        whole = [(al.c_start, al.c_end)]
        stations = [(s.c0, s.c1) for s in al.stations]
        troughs = al.trough_intervals()
        R, CY = TUBE_RADIUS_M, TUBE_CENTRE_ABOVE_RAIL
        segs = 48 if self.final else 24
        els = []

        def lining_samples(a, b):
            if not self.final:
                return frange(a, b, step)
            ring = 1.6
            cs = {a, b}
            k = math.ceil(a / ring)
            while k * ring < b:
                c = k * ring
                for d in (0.0, 0.012, 0.042, 0.054, 0.8):
                    if a < c + d < b:
                        cs.add(c + d)
                k += 1
            return sorted(cs)

        def lining_profile(c):
            g = 0.0
            if self.final:
                d = c % 1.6
                g = 0.018 if (0.011 < d < 0.043) else 0.0
            return circle(0.0, CY, R + g, segs)

        for side, off in (("L", -TRACK_OFFSET_M), ("R", TRACK_OFFSET_M)):
            # walkway faces the other tube (cross passages), cable trays on the outer wall
            inner = (lambda p: p) if off < 0 else mirror
            outer = mirror if off < 0 else (lambda p: p)
            els += [
                (f"Lining_{side}", "lining",
                 lambda m, iv, off=off: sweep(m, al, iv, lining_profile, off, closed=True,
                                              smooth=True, samples=lining_samples), tunnels),
                (f"Slab_{side}", "slab",
                 lambda m, iv, off=off: sweep(m, al, iv, [(-2.52, -0.2), (2.52, -0.2)], off, step=step),
                 tunnels),
                (f"Walkway_{side}", "walkway",
                 lambda m, iv, off=off, f=inner: sweep(
                     m, al, iv, f([(1.4, -0.2), (1.4, 0.6), (2.95, 0.6)]), off, step=step), tunnels),
                (f"SafetyLine_{side}", "paint_yellow",
                 lambda m, iv, off=off, f=inner: sweep(
                     m, al, iv, f([(1.42, 0.603), (1.57, 0.603)]), off, step=step), tunnels),
                (f"Handrail_{side}", "steel",
                 lambda m, iv, off=off, f=inner: sweep(
                     m, al, iv, f(rect(2.72, 1.45, 2.77, 1.5)), off, closed=True, step=step), tunnels),
                (f"CableTrays_{side}", "steel",
                 lambda m, iv, off=off, f=outer: [sweep(
                     m, al, iv, f(rect(2.6, y, 2.95, y + 0.08)), off, closed=True, step=step)
                     for y in (1.15, 1.6, 2.05)], tunnels),
                (f"Luminaires_{side}", "led",
                 lambda m, iv, off=off: sweep(
                     m, al, [p for (a, b) in iv for p in periodic_intervals(a, b, 6.0, 1.2, 3.0)],
                     rect(0.75, 4.33, 1.05, 4.41) if off < 0 else rect(-1.05, 4.33, -0.75, 4.41),
                     off, closed=True, caps=True, step=1.2), tunnels),
            ]

        # rails + baseplates on both tracks, end to end
        rail = [(-0.065, -0.172), (0.065, -0.172), (0.065, -0.160), (0.010, -0.140),
                (0.010, -0.045), (0.035, -0.038), (0.035, 0.0), (-0.035, 0.0),
                (-0.035, -0.038), (-0.010, -0.045), (-0.010, -0.140), (-0.065, -0.160)]
        rx = GAUGE_M / 2 + 0.035
        for side, off in (("L", -TRACK_OFFSET_M), ("R", TRACK_OFFSET_M)):
            els.append((f"Rails_{side}", "rail",
                        lambda m, iv, off=off: [sweep(m, al, iv, shift(rail, dx), off, closed=True, step=step)
                                                for dx in (-rx, rx)], whole))
            if self.final:
                els.append((f"Baseplates_{side}", "baseplate",
                            lambda m, iv, off=off: [sweep(
                                m, al, [p for (a, b) in iv for p in periodic_intervals(a, b, 0.7, 0.35)],
                                rect(dx - 0.17, -0.2, dx + 0.17, -0.172), off, closed=True, caps=True,
                                step=0.35) for dx in (-rx, rx)], whole))

        # stations
        W, WT, CR, PE, PH = STATION_HALF_WIDTH, STATION_WALL_TOP, STATION_CROWN, PLATFORM_EDGE, PLATFORM_HEIGHT
        arc = arc_through(W, WT, CR, 32 if self.final else 16)
        plat_r = [(PE, -0.2), (PE, PH), (W, PH)]
        els += [
            ("StationTrackbed", "slab", lambda m, iv: sweep(m, al, iv, [(-PE, -0.2), (PE, -0.2)], step=step), stations),
            ("StationPlatformEdges", "trough",
             lambda m, iv: [sweep(m, al, iv, p, step=step) for p in ([(PE, -0.2), (PE, PH)], mirror([(PE, -0.2), (PE, PH)]))],
             stations),
            ("StationPlatforms", "station_floor",
             lambda m, iv: [sweep(m, al, iv, p, step=step, v_scale=1.0) for p in ([(PE, PH), (W, PH)], mirror([(PE, PH), (W, PH)]))],
             stations),
            ("StationTactile", "tactile",
             lambda m, iv: [sweep(m, al, iv, p, step=step) for p in
                            ([(PE + 0.15, PH + 0.004), (PE + 0.45, PH + 0.004)],
                             mirror([(PE + 0.15, PH + 0.004), (PE + 0.45, PH + 0.004)]))], stations),
            ("StationWalls", "station_wall",
             lambda m, iv: [sweep(m, al, iv, p, step=step) for p in ([(W, PH), (W, WT)], mirror([(W, PH), (W, WT)]))],
             stations),
            ("StationCeiling", "station_ceiling", lambda m, iv: sweep(m, al, iv, arc, smooth=True, step=step), stations),
            ("StationLightStrips", "led",
             lambda m, iv: [sweep(m, al, [(a + 6, b - 6) for (a, b) in iv], rect(x - 0.15, 6.2, x + 0.15, 6.3),
                                  closed=True, caps=True, step=step) for x in (-10.8, 0.0, 10.8)], stations),
            ("StationLightBeams", "steel",
             lambda m, iv: [sweep(m, al, [(a + 6, b - 6) for (a, b) in iv], rect(x - 0.2, 6.3, x + 0.2, 6.6),
                                  closed=True, caps=True, step=step) for x in (-10.8, 0.0, 10.8)], stations),
        ]

        def psd_posts(iv):
            return [p for (a, b) in iv for p in periodic_intervals(a + 12, b - 12, 2.4, 0.12)]

        def psd_glass(iv):
            out = []
            for (a, b) in iv:
                posts = periodic_intervals(a + 12, b - 12, 2.4, 0.12)
                out += [(p[1], q[0]) for p, q in zip(posts, posts[1:])]
            return out

        gx = PE + 0.26
        els += [
            ("PSDFrames", "psd_frame",
             lambda m, iv: [
                 [sweep(m, al, psd_posts(iv), f(rect(gx - 0.06, PH, gx + 0.06, PH + 2.25)), closed=True, caps=True, step=0.12),
                  sweep(m, al, [(a + 12, b - 12) for (a, b) in iv], f(rect(gx - 0.12, PH + 2.1, gx + 0.12, PH + 2.4)),
                        closed=True, caps=True, step=step),
                  sweep(m, al, [(a + 12, b - 12) for (a, b) in iv], f(rect(gx - 0.05, PH, gx + 0.05, PH + 0.08)),
                        closed=True, caps=True, step=step)]
                 for f in ((lambda p: p), mirror)], stations),
            ("PSDGlass", "psd_glass",
             lambda m, iv: [sweep(m, al, psd_glass(iv), f(p), step=2.4)
                            for f in ((lambda p: p), mirror)
                            for p in ([(gx, PH + 0.08), (gx, PH + 2.1)], [(gx, PH + 2.1), (gx, PH + 0.08)])],
             stations),
        ]

        # portal troughs
        def wall_h(c):
            d = min(abs(c - al.portal_s), abs(c - al.portal_n))
            return max(1.0, 9.5 - d * (8.5 / 250.0))
        TW = TROUGH_HALF_WIDTH
        els += [
            ("TroughFloor", "slab", lambda m, iv: sweep(m, al, iv, [(-TW, -0.2), (TW, -0.2)], step=step), troughs),
            ("TroughWalls", "trough",
             lambda m, iv: [sweep(m, al, iv, lambda c, f=f: f([(TW, -0.2), (TW, wall_h(c)), (TW + 0.4, wall_h(c)),
                                                                 (TW + 0.4, -0.2)]), step=step)
                            for f in ((lambda p: p), mirror)], troughs),
        ]
        return els

    def walls(self):
        """Walls at fixed chainages: (chainage, name, material, outline, facing)."""
        al = self.al
        holes = [(-TRACK_OFFSET_M, TUBE_CENTRE_ABOVE_RAIL, TUBE_RADIUS_M),
                 (TRACK_OFFSET_M, TUBE_CENTRE_ABOVE_RAIL, TUBE_RADIUS_M)]
        cav = [(-STATION_HALF_WIDTH, -1.6), (STATION_HALF_WIDTH, -1.6)] + \
            arc_through(STATION_HALF_WIDTH, STATION_WALL_TOP, STATION_CROWN, 32)
        head = rect(-TROUGH_HALF_WIDTH - 0.4, -1.6, TROUGH_HALF_WIDTH + 0.4, 10.5)
        out = [(al.portal_s, "PortalHeadwall_S", "trough", head, -1),
               (al.portal_n, "PortalHeadwall_N", "trough", head, +1)]
        for s in al.stations:
            nm = s.name.replace(" ", "")
            out += [(s.c0, f"StationEndWall_{nm}_S", "station_wall", cav, +1),
                    (s.c1, f"StationEndWall_{nm}_N", "station_wall", cav, -1)]
        return [w + (holes,) for w in out]

    def build_lights(self):
        al = self.al
        L = []
        for (a, b) in al.tunnel_intervals():
            for off in (-TRACK_OFFSET_M, TRACK_OFFSET_M):
                x = off + (0.9 if off < 0 else -0.9)
                for (p, q) in periodic_intervals(a, b, 30.0, 1.2, 3.0):
                    L.append({"type": "point", "enu": al.point((p + q) / 2, x, 4.1),
                              "lumens": 2500.0, "radius_cm": 2200.0, "temperature": 4300.0,
                              "shadows": False, "folder": "Tunnel"})
        for s in al.stations:
            for c in frange(s.c0 + 10, s.c1 - 10, 15.0):
                for x in (-10.8, 0.0, 10.8):
                    L.append({"type": "rect", "enu": al.point(c, x, 6.15), "lumens": 6000.0,
                              "radius_cm": 3000.0, "temperature": 4000.0, "shadows": x == 0.0,
                              "width_cm": 30.0, "height_cm": 1400.0,
                              "yaw_deg": _yaw_ue(al, c), "folder": f"Stations/{s.name}"})
        for L_ in L:
            L_["location"] = list(enu_to_ue(*L_.pop("enu")))
        return L

    # ---------------------------------------------------------------- generation
    def generate(self, out_dir, obj_from_ue=None, verbose=True):
        M = obj_from_ue or [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        det = (M[0][0] * (M[1][1] * M[2][2] - M[1][2] * M[2][1])
               - M[0][1] * (M[1][0] * M[2][2] - M[1][2] * M[2][0])
               + M[0][2] * (M[1][0] * M[2][1] - M[1][1] * M[2][0]))
        flip = det < 0
        os.makedirs(out_dir, exist_ok=True)
        manifest = {"quality": self.q, "origin": [config.ORIGIN_LAT, config.ORIGIN_LON],
                    "meshes": [], "lights": self.build_lights()}
        tri_total = 0

        def emit(mesh):
            nonlocal tri_total
            if mesh.empty():
                return
            fn = mesh.name + ".obj"
            mesh.write_obj(os.path.join(out_dir, fn), M, flip)
            bmin, bmax = mesh.bounds()
            manifest["meshes"].append({"name": mesh.name, "file": fn, "material": mesh.material,
                                       "nanite": mesh.material not in NON_NANITE,
                                       "location": list(mesh.origin), "bounds_min": bmin, "bounds_max": bmax,
                                       "triangles": len(mesh.tris)})
            tri_total += len(mesh.tris)
            if verbose:
                print(f"  {mesh.name:<34} {len(mesh.tris):>8} tris")

        for (name, mat, fn, intervals) in self.elements():
            for ci, (a, b) in enumerate(self.chunks):
                iv = clip_intervals(intervals, a, b)
                if not iv:
                    continue
                origin = enu_to_ue(*self.al.point(a))
                m = Mesh(f"SM_CRR_{name}_{ci:02d}", mat, origin)
                fn(m, iv)
                emit(m)
        for (c, name, mat, outline, facing, holes) in self.walls():
            m = Mesh(f"SM_CRR_{name}", mat, enu_to_ue(*self.al.point(c)))
            holed_wall(m, self.al, c, outline, holes, facing)
            emit(m)
        manifest["triangles"] = tri_total
        with open(os.path.join(out_dir, "manifest.json"), "w") as f:
            json.dump(manifest, f, indent=1)
        if verbose:
            print(f"Total: {len(manifest['meshes'])} meshes, {tri_total:,} triangles, "
                  f"{len(manifest['lights'])} lights -> {out_dir}")
        return manifest


def _yaw_ue(al, c):
    fx, fy = al.heading(c)
    d = enu_dir_to_ue(fx, fy, 0.0)
    return math.degrees(math.atan2(d[1], d[0]))


def obj_from_ue_from_bounds(bounds, size=100.0):
    """Given the imported bounds (min_xyz, max_xyz) of the X, Y and Z calibration
    meshes, return (obj_from_ue 3x3, scale, recentred?). The importer mapping is
    assumed to be a uniform scale times a signed axis permutation (true for the
    OBJ/FBX importers)."""
    cols, recentred = [], False
    for mn, mx in bounds:
        ext = [b - a for a, b in zip(mn, mx)]
        j = max(range(3), key=lambda i: ext[i])
        scale = ext[j] / size
        sign = 1.0 if abs(mx[j]) >= abs(mn[j]) else -1.0
        if min(abs(mn[j]), abs(mx[j])) > 0.05 * ext[j]:
            recentred = True
        col = [0.0, 0.0, 0.0]
        col[j] = sign * scale
        cols.append(col)
    if sorted(max(range(3), key=lambda i: abs(c[i])) for c in cols) != [0, 1, 2]:
        raise ValueError(f"calibration axes are not a permutation: {cols}")
    A = [[cols[c][r] for c in range(3)] for r in range(3)]   # A[r][c]: column c = image of OBJ axis c
    s = max(abs(v) for v in cols[0])
    inv = [[A[c][r] / (s * s) for c in range(3)] for r in range(3)]
    return inv, s, recentred


def write_calibration_objs(out_dir, size=100.0):
    """Three thin tetrahedra, each long along one OBJ axis. Importing them and
    reading their bounds reveals the importer's axis/unit conversion."""
    os.makedirs(out_dir, exist_ok=True)
    paths = []
    for axis, nm in enumerate("XYZ"):
        L = [1.0, 1.0, 1.0]
        L[axis] = size
        verts = [(0, 0, 0), (L[0], 0, 0), (0, L[1], 0), (0, 0, L[2])]
        p = os.path.join(out_dir, f"SM_CRR_Calib{nm}.obj")
        with open(p, "w") as f:
            f.write(f"o SM_CRR_Calib{nm}\n")
            for v in verts:
                f.write("v %g %g %g\n" % v)
            f.write("f 1 3 2\nf 1 2 4\nf 1 4 3\nf 2 3 4\n")
        paths.append(p)
    return paths


if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "generated", "meshes")
    SceneBuilder().generate(out)
