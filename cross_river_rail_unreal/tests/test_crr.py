"""Tests for the pure-Python core. Run:  python3 -m unittest discover -s tests"""
import math
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
os.environ.setdefault("CRR_QUALITY", "draft")

from crr import geo  # noqa: E402
from crr.route import Alignment, TUBE_RADIUS_M, TUBE_CENTRE_ABOVE_RAIL, TRACK_OFFSET_M  # noqa: E402
from crr.meshgen import (SceneBuilder, Mesh, sweep, circle, write_calibration_objs,  # noqa: E402
                         obj_from_ue_from_bounds)
from crr.camera import FlightPath  # noqa: E402


def read_obj(path):
    v, f = [], []
    with open(path) as fh:
        lines = fh.readlines()
    for line in lines:
        if line.startswith("v "):
            v.append(tuple(map(float, line.split()[1:4])))
        elif line.startswith("f "):
            f.append(tuple(int(t.split("/")[0]) - 1 for t in line.split()[1:4]))
    return v, f


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def sub(a, b):
    return tuple(x - y for x, y in zip(a, b))


def matvec(M, p):
    return tuple(sum(M[r][c] * p[c] for c in range(3)) for r in range(3))


def det3(M):
    return (M[0][0] * (M[1][1] * M[2][2] - M[1][2] * M[2][1]) - M[0][1] * (M[1][0] * M[2][2] - M[1][2] * M[2][0])
            + M[0][2] * (M[1][0] * M[2][1] - M[1][1] * M[2][0]))


class GeoTests(unittest.TestCase):
    def test_origin_is_zero(self):
        e, n, u = geo.geodetic_to_enu(-27.47, 153.02, 40, -27.47, 153.02, 40)
        self.assertAlmostEqual(e, 0, 6)
        self.assertAlmostEqual(n, 0, 6)
        self.assertAlmostEqual(u, 0, 6)

    def test_north_east_scale(self):
        e, n, u = geo.geodetic_to_enu(-27.46, 153.02, 0, -27.47, 153.02, 0)
        self.assertAlmostEqual(n, 1108.0, delta=3)        # 0.01 deg latitude ~ 1.108 km
        e, n, u = geo.geodetic_to_enu(-27.47, 153.03, 0, -27.47, 153.02, 0)
        self.assertAlmostEqual(e, 987.5, delta=3)         # 0.01 deg longitude at 27.5 S
        self.assertLess(u, 0)                             # earth curvature drop

    def test_ue_axes(self):
        self.assertEqual(geo.enu_to_ue(1, 2, 3), (100, -200, 300))


class AlignmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.al = Alignment()

    def test_lengths(self):
        self.assertGreater(self.al.portal_n - self.al.portal_s, 5000)
        self.assertLess(self.al.portal_n - self.al.portal_s, 6500)
        self.assertEqual([s.name for s in self.al.stations],
                         ["Boggo Road", "Woolloongabba", "Albert Street", "Roma Street"])
        for s in self.al.stations:
            self.assertTrue(200 < s.length < 320, s)

    def test_design_limits(self):
        self.assertLess(self.al.max_grade(), 0.035)
        self.assertGreater(self.al.min_radius(), 200)

    def test_stations_flat_and_straight(self):
        for s in self.al.stations:
            z = [self.al.rail_ahd(s.c0 + i * s.length / 10) for i in range(11)]
            self.assertLess(max(z) - min(z), 1e-6, s.name)
            h0, h1 = self.al.heading(s.c0 + 2), self.al.heading(s.c1 - 2)
            self.assertGreater(h0[0] * h1[0] + h0[1] * h1[1], 0.99999, s.name)

    def test_profile_continuous(self):
        prev = self.al.rail_ahd(0)
        c = 0.5
        while c < self.al.length:
            z = self.al.rail_ahd(c)
            self.assertLess(abs(z - prev), 0.03, c)
            prev, c = z, c + 0.5

    def test_tunnel_is_underground_relative_to_portals(self):
        lowest = min(self.al.rail_ahd(c) for c in range(int(self.al.portal_s), int(self.al.portal_n), 10))
        self.assertLess(lowest, -25)


class MeshTests(unittest.TestCase):
    def test_lining_faces_inward(self):
        al = Alignment()
        m = Mesh("t", "lining", (0.0, 0.0, 0.0))
        c0 = al.portal_s + 50
        sweep(m, al, [(c0, c0 + 10)], circle(0, TUBE_CENTRE_ABOVE_RAIL, TUBE_RADIUS_M, 24),
              -TRACK_OFFSET_M, closed=True, smooth=True)
        for (a, b, c) in m.tris:
            A, B, C = m.v[a], m.v[b], m.v[c]
            n = cross(sub(B, A), sub(C, A))
            centroid = tuple((A[i] + B[i] + C[i]) / 3 for i in range(3))
            cc = (centroid[0] + centroid[1] + centroid[2])  # noqa: F841
            # tube axis point at the same chainage ~ project: use the centre of this triangle's ring
            ch = al.point(c0 + 5, -TRACK_OFFSET_M, TUBE_CENTRE_ABOVE_RAIL)
            axis_ue = geo.enu_to_ue(*ch)
            to_axis = sub(axis_ue, centroid)
            fwd = geo.enu_dir_to_ue(*al.frame(c0 + 5)[1])
            # remove the along-track component
            d = sum(x * y for x, y in zip(to_axis, fwd))
            to_axis = tuple(t - d * f for t, f in zip(to_axis, fwd))
            self.assertGreater(sum(x * y for x, y in zip(n, to_axis)), 0)

    def test_simulated_importer_roundtrip(self):
        """Simulate an importer that reads OBJ as Y-up metres (UE = 100 * [x, -z, y]),
        calibrate against it, and check positions and facing survive."""
        A = [[100, 0, 0], [0, 0, -100], [0, 100, 0]]          # OBJ -> UE
        with tempfile.TemporaryDirectory() as d:
            bounds = []
            for p in write_calibration_objs(d):
                v, _ = read_obj(p)
                uv = [matvec(A, q) for q in v]
                bounds.append((tuple(min(q[i] for q in uv) for i in range(3)),
                               tuple(max(q[i] for q in uv) for i in range(3))))
            M, s, recentred = obj_from_ue_from_bounds(bounds)
            self.assertAlmostEqual(s, 100)
            self.assertFalse(recentred)
            sb = SceneBuilder(quality="draft")
            sb.chunks = sb.chunks[2:4]                        # keep the test quick
            ref = sb.generate(os.path.join(d, "ref"), None, verbose=False)
            sim = sb.generate(os.path.join(d, "sim"), M, verbose=False)
            flip_importer = det3(A) < 0
            checked = 0
            for mr, ms in zip(ref["meshes"], sim["meshes"]):
                vr, fr = read_obj(os.path.join(d, "ref", mr["file"]))
                vs, fs = read_obj(os.path.join(d, "sim", ms["file"]))
                vs = [matvec(A, q) for q in vs]               # what the importer produces
                for p, q in zip(vr, vs):
                    for i in range(3):
                        self.assertAlmostEqual(p[i], q[i], delta=0.05)
                for (a, b, c), (a2, b2, c2) in zip(fr, fs):
                    if flip_importer:                         # importer preserves facing by flipping
                        b2, c2 = c2, b2
                    nr = cross(sub(vr[b], vr[a]), sub(vr[c], vr[a]))
                    ns = cross(sub(vs[b2], vs[a2]), sub(vs[c2], vs[a2]))
                    if sum(x * x for x in nr) > 1e-6:
                        self.assertGreater(sum(x * y for x, y in zip(nr, ns)), 0)
                        checked += 1
            self.assertGreater(checked, 1000)


class CameraTests(unittest.TestCase):
    def test_smooth_and_continuous(self):
        fp = FlightPath()
        k = fp.keyframes()
        self.assertTrue(120 < fp.duration < 300)
        for a, b in zip(k, k[1:]):
            step = math.dist(a["location"], b["location"]) / 100.0
            self.assertLess(step, 4.0)                       # < 96 m/s
            self.assertLess(abs(b["rotation"][2] - a["rotation"][2]), 2.0)
            self.assertLess(abs(b["rotation"][1] - a["rotation"][1]), 1.0)

    def test_camera_inside_tube(self):
        fp = FlightPath()
        al = fp.al
        for (a, b) in al.tunnel_intervals():
            for c in (a + 20, (a + b) / 2, b - 20):
                p = fp._track_eye(c)
                axis = al.point(c, -TRACK_OFFSET_M, TUBE_CENTRE_ABOVE_RAIL)
                self.assertLess(math.dist(p, axis), TUBE_RADIUS_M - 0.5)


if __name__ == "__main__":
    unittest.main()
