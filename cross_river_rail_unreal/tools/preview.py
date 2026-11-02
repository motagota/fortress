"""Dependency-free preview renderer (z-buffer + back-face culling) for the
generated meshes, viewed from the flyby camera. Used to sanity-check geometry
and triangle winding without Unreal:

    python3 -m crr.meshgen generated/meshes          # identity transform
    python3 tools/preview.py generated/meshes 45 out.png [width]

Also writes a plan/profile SVG of the alignment with --plan out.svg.
"""
import json
import math
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from crr.camera import FlightPath  # noqa: E402

COLORS = {
    "lining": (150, 147, 140), "slab": (95, 93, 90), "walkway": (130, 128, 124),
    "paint_yellow": (220, 180, 20), "steel": (170, 172, 176), "rail": (120, 110, 100),
    "baseplate": (50, 50, 52), "led": (255, 245, 220), "station_wall": (215, 213, 205),
    "station_ceiling": (60, 62, 66), "station_floor": (150, 145, 138), "tactile": (230, 175, 20),
    "psd_frame": (200, 202, 208), "psd_glass": (120, 170, 190), "trough": (165, 160, 150),
}


def load_obj(path):
    v, f = [], []
    with open(path) as fh:
        for line in fh:
            if line.startswith("v "):
                _, x, y, z = line.split()
                v.append((float(x), float(y), float(z)))
            elif line.startswith("f "):
                f.append(tuple(int(t.split("/")[0]) - 1 for t in line.split()[1:4]))
    return v, f


def write_png(path, w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))

    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                 + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def render(mesh_dir, t, out, W=480, radius_m=250.0, focal_override=None):
    H = W * 9 // 16
    man = json.load(open(os.path.join(mesh_dir, "manifest.json")))
    fp = FlightPath()
    kf = fp.keyframes()
    k = kf[min(len(kf) - 1, int(t * fp.fps))]
    cam = k["location"]
    _, pitch, yaw = k["rotation"]
    cp, sp, cy, sy = math.cos(math.radians(pitch)), math.sin(math.radians(pitch)), \
        math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    fwd = (cp * cy, cp * sy, sp)
    right = (-sy, cy, 0.0)
    up = (-sp * cy, -sp * sy, cp)
    focal = focal_override or k["focal"]
    fpx = W * focal / 36.0  # 36 mm filmback
    near = 10.0
    zbuf = [1e30] * (W * H)
    img = [18, 18, 22] * (W * H)
    light = fwd
    ntri = 0
    for m in man["meshes"]:
        lo = [a + b for a, b in zip(m["location"], m["bounds_min"])]
        hi = [a + b for a, b in zip(m["location"], m["bounds_max"])]
        d2 = sum(max(l - c, 0, c - h) ** 2 for l, h, c in zip(lo, hi, cam))
        if d2 > (radius_m * 100) ** 2:
            continue
        v, faces = load_obj(os.path.join(mesh_dir, m["file"]))
        o = m["location"]
        col = COLORS.get(m["material"], (200, 0, 200))
        V = []
        for p in v:
            q = (p[0] + o[0] - cam[0], p[1] + o[1] - cam[1], p[2] + o[2] - cam[2])
            V.append((q[0] * right[0] + q[1] * right[1] + q[2] * right[2],
                      q[0] * up[0] + q[1] * up[1] + q[2] * up[2],
                      q[0] * fwd[0] + q[1] * fwd[1] + q[2] * fwd[2], q))
        for (a, b, c) in faces:
            A, B, C = V[a], V[b], V[c]
            if A[2] < near and B[2] < near and C[2] < near:
                continue
            e1 = [B[3][i] - A[3][i] for i in range(3)]
            e2 = [C[3][i] - A[3][i] for i in range(3)]
            n = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0])
            # back-face cull: front side must face the camera (camera at origin)
            if n[0] * A[3][0] + n[1] * A[3][1] + n[2] * A[3][2] >= 0:
                continue
            nl = math.sqrt(n[0] ** 2 + n[1] ** 2 + n[2] ** 2) or 1.0
            shade = 0.25 + 0.75 * abs(n[0] * light[0] + n[1] * light[1] + n[2] * light[2]) / nl
            dist = math.sqrt(A[3][0] ** 2 + A[3][1] ** 2 + A[3][2] ** 2) / 100.0
            shade *= 1.0 / (1.0 + dist / 120.0)
            rgb = (int(col[0] * shade), int(col[1] * shade), int(col[2] * shade))
            if m["material"] == "led":
                rgb = col
            poly = _clip_near([A, B, C], near)
            if len(poly) < 3:
                continue
            P = [(W / 2 + p[0] * fpx / p[2], H / 2 - p[1] * fpx / p[2], p[2]) for p in poly]
            for j in range(1, len(P) - 1):
                ntri += 1
                _raster(P[0], P[j], P[j + 1], W, H, zbuf, img, rgb)
    write_png(out, W, H, img)
    return ntri, k["tag"]


def _clip_near(poly, near):
    out = []
    for i in range(len(poly)):
        p, q = poly[i], poly[(i + 1) % len(poly)]
        pin, qin = p[2] >= near, q[2] >= near
        if pin:
            out.append(p)
        if pin != qin:
            t = (near - p[2]) / (q[2] - p[2])
            out.append(tuple(p[k] + (q[k] - p[k]) * t for k in range(3)) + (None,))
    return out


def _raster(a, b, c, W, H, zbuf, img, rgb):
    minx, maxx = max(0, int(min(a[0], b[0], c[0]))), min(W - 1, int(max(a[0], b[0], c[0])) + 1)
    miny, maxy = max(0, int(min(a[1], b[1], c[1]))), min(H - 1, int(max(a[1], b[1], c[1])) + 1)
    if minx > maxx or miny > maxy:
        return
    area = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    if abs(area) < 1e-9:
        return
    ia, ib, ic = 1 / a[2], 1 / b[2], 1 / c[2]
    for y in range(miny, maxy + 1):
        py = y + 0.5
        for x in range(minx, maxx + 1):
            px = x + 0.5
            w0 = ((b[0] - px) * (c[1] - py) - (b[1] - py) * (c[0] - px)) / area
            w1 = ((c[0] - px) * (a[1] - py) - (c[1] - py) * (a[0] - px)) / area
            w2 = 1 - w0 - w1
            if w0 < 0 or w1 < 0 or w2 < 0:
                continue
            z = 1 / (w0 * ia + w1 * ib + w2 * ic)
            i = y * W + x
            if z < zbuf[i]:
                zbuf[i] = z
                img[3 * i:3 * i + 3] = rgb


def plan_svg(out):
    from crr.route import Alignment
    al = Alignment()
    fp = FlightPath(al)
    xs = [p[0] for p in fp.pts]
    ys = [p[1] for p in fp.pts]
    x0, x1, y0, y1 = min(xs) - 100, max(xs) + 100, min(ys) - 100, max(ys) + 100
    S = 700 / max(x1 - x0, y1 - y0)

    def X(e):
        return (e - x0) * S

    def Y(n):
        return (y1 - n) * S
    w, h = (x1 - x0) * S, (y1 - y0) * S
    cam = " ".join(f"{X(p[0]):.1f},{Y(p[1]):.1f}" for p in fp.pts[::5])
    rail = " ".join(f"{X(e):.1f},{Y(n):.1f}" for (e, n) in al._xy[::20])
    prof_w, prof_h = 700, 200
    zs = [al.rail_ahd(c) for c in range(0, int(al.length), 10)]
    zmin, zmax = min(zs) - 5, max(zs) + 20
    prof = " ".join(f"{c * 10 * prof_w / al.length:.1f},{(zmax - z) * prof_h / (zmax - zmin):.1f}"
                    for c, z in enumerate(zs))
    st = "".join(
        f'<line x1="{X(al.point(s.c0)[0]):.1f}" y1="{Y(al.point(s.c0)[1]):.1f}" '
        f'x2="{X(al.point(s.c1)[0]):.1f}" y2="{Y(al.point(s.c1)[1]):.1f}" stroke="#d33" stroke-width="7"/>'
        f'<text x="{X(al.point(s.c1)[0]) + 8:.1f}" y="{Y(al.point(s.c1)[1]):.1f}" font-size="13">{s.name}</text>'
        for s in al.stations)
    stp = "".join(
        f'<rect x="{s.c0 * prof_w / al.length:.1f}" y="0" width="{s.length * prof_w / al.length:.1f}" '
        f'height="{prof_h}" fill="#d33" opacity="0.15"/>' for s in al.stations)
    zero = (zmax - 0) * prof_h / (zmax - zmin)
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{max(w + 140, prof_w + 20):.0f}" height="{h + prof_h + 70:.0f}"
 font-family="sans-serif"><rect width="100%" height="100%" fill="#fff"/>
<g transform="translate(10,10)"><polyline points="{cam}" fill="none" stroke="#39f" stroke-width="1.5" stroke-dasharray="4 3"/>
<polyline points="{rail}" fill="none" stroke="#222" stroke-width="3"/>{st}
<text x="0" y="14" font-size="14">Plan (north up). Black: alignment, red: stations, blue dashed: camera</text></g>
<g transform="translate(10,{h + 50:.0f})"><text x="0" y="-8" font-size="14">Profile: rail level m AHD ({zmin:.0f} to {zmax:.0f}); grey = AHD 0</text>
{stp}<line x1="0" x2="{prof_w}" y1="{zero:.1f}" y2="{zero:.1f}" stroke="#aaa"/>
<polyline points="{prof}" fill="none" stroke="#222" stroke-width="2"/></g></svg>'''
    open(out, "w").write(svg)


if __name__ == "__main__":
    if sys.argv[1] == "--plan":
        plan_svg(sys.argv[2])
    else:
        W = int(sys.argv[4]) if len(sys.argv) > 4 else 480
        n, tag = render(sys.argv[1], float(sys.argv[2]), sys.argv[3], W)
        print(f"{sys.argv[3]}: {n} triangles rasterised ({tag})")
