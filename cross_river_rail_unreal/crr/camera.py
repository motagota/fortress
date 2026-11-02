"""Camera flight path for the flyby.

Shot plan:
  1. Aerial over Dutton Park, descending onto the southern approach tracks.
  2. Into the southern portal, along the northbound (left-hand) tube at driver's
     eye height, through Boggo Road, Woolloongabba, under Kangaroo Point and the
     Brisbane River, Albert Street and Roma Street. In each station the camera
     slows, rises and glides down the centre of the cavern between the platforms.
  3. Out of the northern portal at Normanby and up into an aerial reveal of
     the CBD skyline.
"""
import math

from . import config
from .geo import enu_to_ue, enu_dir_to_ue
from .route import Alignment, TRACK_OFFSET_M, smoothstep

CAMERA_TRACK = -TRACK_OFFSET_M   # northbound runs on the left in Queensland
EYE_TUNNEL = 2.7
EYE_STATION = 5.0
CBD_TARGET = (-27.4690, 153.0250, 90.0)   # lat, lon, AHD: Queen St / Albert St towers


def _bezier(p0, p1, p2, p3, t):
    u = 1 - t
    return tuple(u**3 * a + 3 * u * u * t * b + 3 * u * t * t * c + t**3 * d
                 for a, b, c, d in zip(p0, p1, p2, p3))


def _add(a, b, s=1.0):
    return (a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s)


def _dist(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


class FlightPath:
    def __init__(self, al=None, fps=None):
        self.al = al or Alignment()
        self.fps = fps or config.FPS
        self._build_polyline()
        self._build_timing()

    # ------------------------------------------------------------- geometry
    def _track_eye(self, c):
        """Camera position while riding the alignment (ENU)."""
        al = self.al
        x, y = CAMERA_TRACK, EYE_TUNNEL
        for s in al.stations:
            # inside the cavern only: blend to the centre line and up
            k = smoothstep(s.c0 + 2, s.c0 + 55, c) * (1 - smoothstep(s.c1 - 55, s.c1 - 2, c))
            if k > 0:
                x = CAMERA_TRACK * (1 - k)
                y = EYE_TUNNEL + (EYE_STATION - EYE_TUNNEL) * k
        return al.point(c, x, y)

    def _build_polyline(self):
        al = self.al
        pts, tags = [], []
        # 1. aerial approach
        c0 = al.c_start
        start_rail = self._track_eye(c0)
        f0 = al.frame(c0)[1]
        p0 = al.enu_from_geodetic(-27.5085, 153.0205, 230.0)
        p3 = _add(start_rail, f0, -60.0)
        p2 = _add(_add(p3, f0, -260.0), (0, 0, 1), 25.0)
        p1 = _add(p0, (0, 0, 1), -40.0)
        n = 400
        for i in range(n):
            pts.append(_bezier(p0, p1, p2, p3, i / n))
            tags.append("aerial")
        # straight lead-in to the start of the rail model
        for i in range(30):
            pts.append(_add(p3, f0, 60.0 * i / 30))
            tags.append("trough")
        # 2. ride the alignment
        c = c0
        while c <= al.c_end:
            pts.append(self._track_eye(c))
            tags.append(al.region(c))
            c += 1.0
        # 3. climb-out and CBD reveal
        c1 = al.c_end
        end_rail = self._track_eye(c1)
        f1 = al.frame(c1)[1]
        q0 = end_rail
        q1 = _add(_add(end_rail, f1, 380.0), (0, 0, 1), 60.0)
        # arc up and around over Victoria Park so we arrive heading at the CBD
        cbd = al.enu_from_geodetic(*CBD_TARGET)
        q3 = al.enu_from_geodetic(-27.4588, 153.0212, 210.0)
        to_cbd = tuple(b - a for a, b in zip(q3, cbd))
        d = math.sqrt(to_cbd[0] ** 2 + to_cbd[1] ** 2)
        q2 = _add(q3, (to_cbd[0] / d, to_cbd[1] / d, 0.0), -450.0)
        q2 = _add(q2, (0, 0, 1), -60.0)
        for i in range(1, n + 1):
            pts.append(_bezier(q0, q1, q2, q3, i / n))
            tags.append("final")
        self.pts, self.tags = pts, tags
        self.s = [0.0]
        for a, b in zip(pts, pts[1:]):
            self.s.append(self.s[-1] + _dist(a, b))
        self.cbd = al.enu_from_geodetic(*CBD_TARGET)

    def _build_timing(self):
        sp = {"aerial": config.SPEED_AERIAL, "trough": config.SPEED_TROUGH,
              "tunnel": config.SPEED_TUNNEL, "station": config.SPEED_STATION,
              "final": config.SPEED_FINAL}
        v = [sp[t] for t in self.tags]
        # smooth the speed profile (~120 m window) for gentle accel/decel
        n, w = len(v), 120
        pre = [0.0]
        for x in v:
            pre.append(pre[-1] + x)
        vs = []
        for i in range(n):
            a, b = max(0, i - w), min(n, i + w + 1)
            vs.append((pre[b] - pre[a]) / (b - a))
        # ease out over the last 400 m to a slow drift
        total = self.s[-1]
        for i in range(n):
            k = smoothstep(total - 400, total, self.s[i])
            vs[i] = vs[i] * (1 - k) + 6.0 * k
        self.v = vs
        self.t = [0.0]
        for i in range(1, n):
            ds = self.s[i] - self.s[i - 1]
            self.t.append(self.t[-1] + ds / (0.5 * (vs[i] + vs[i - 1])))
        self.duration = self.t[-1]

    # --------------------------------------------------------------- sampling
    def _at_s(self, s):
        s = min(max(s, 0.0), self.s[-1])
        lo, hi = 0, len(self.s) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if self.s[mid] <= s:
                lo = mid
            else:
                hi = mid
        seg = self.s[hi] - self.s[lo]
        k = 0.0 if seg <= 0 else (s - self.s[lo]) / seg
        a, b = self.pts[lo], self.pts[hi]
        return tuple(x + (y - x) * k for x, y in zip(a, b)), lo

    def _s_at_t(self, t):
        t = min(max(t, 0.0), self.duration)
        lo, hi = 0, len(self.t) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if self.t[mid] <= t:
                lo = mid
            else:
                hi = mid
        seg = self.t[hi] - self.t[lo]
        k = 0.0 if seg <= 0 else (t - self.t[lo]) / seg
        return self.s[lo] + (self.s[hi] - self.s[lo]) * k

    def sample(self, t):
        """-> dict(pos_enu, look_enu, tag, focal)"""
        s = self._s_at_t(t)
        p, i = self._at_s(s)
        tag = self.tags[i]
        # look ~1.6 s ahead (speed is already smoothed, so this varies smoothly)
        v = self.v[i]
        look_ahead = min(150.0, max(30.0, 1.6 * v + (60.0 if tag in ("aerial", "final") else 0.0)))
        ahead, _ = self._at_s(s + look_ahead)
        if _dist(ahead, p) < 1.0:
            ahead = _add(p, self.al.frame(self.al.c_end)[1], 50.0)
        # final segment: swing the view onto the CBD skyline
        s_final = self.s[self.tags.index("final")]
        k = smoothstep(s_final + 300, self.s[-1] - 50, s)
        look = tuple(a + (b - a) * k for a, b in zip(ahead, self.cbd))
        focal = {"aerial": 35.0, "final": 30.0, "station": 18.0}.get(tag, 20.0)
        return {"pos": p, "look": look, "tag": tag, "focal": focal}

    def keyframes(self, smooth_s=0.5):
        """Per-frame Unreal transforms: list of dict(frame, location(cm), rotation
        (roll, pitch, yaw) deg, focal_mm). Yaw unwrapped, rotation & focal smoothed."""
        nf = int(math.ceil(self.duration * self.fps)) + 1
        raw = []
        for f in range(nf):
            smp = self.sample(f / self.fps)
            loc = enu_to_ue(*smp["pos"])
            d = enu_dir_to_ue(*(b - a for a, b in zip(smp["pos"], smp["look"])))
            yaw = math.degrees(math.atan2(d[1], d[0]))
            pitch = math.degrees(math.atan2(d[2], math.hypot(d[0], d[1])))
            raw.append([f, loc, pitch, yaw, smp["focal"], smp["tag"]])
        for i in range(1, nf):  # unwrap yaw
            while raw[i][3] - raw[i - 1][3] > 180:
                raw[i][3] -= 360
            while raw[i][3] - raw[i - 1][3] < -180:
                raw[i][3] += 360
        w = max(1, int(smooth_s * self.fps))
        out = []
        for i in range(nf):
            a, b = max(0, i - w), min(nf, i + w + 1)
            wa = max(0, i - 3 * w)
            pitch = sum(r[2] for r in raw[a:b]) / (b - a)
            yaw = sum(r[3] for r in raw[a:b]) / (b - a)
            fb = min(nf, i + 3 * w + 1)
            focal = sum(r[4] for r in raw[wa:fb]) / (fb - wa)
            out.append({"frame": raw[i][0], "location": raw[i][1], "rotation": (0.0, pitch, yaw),
                        "focal": focal, "tag": raw[i][5]})
        return out

    def chapters(self):
        """(time_s, label) markers, handy for Sequencer section markers."""
        out, last = [], None
        al = self.al
        for i, tg in enumerate(self.tags):
            label = tg
            if tg == "station":
                c_guess = None
                p = self.pts[i]
                for s in al.stations:
                    mid = al.point((s.c0 + s.c1) / 2)
                    if _dist(mid, p) < s.length:
                        c_guess = s.name
                label = c_guess or "station"
            if label != last:
                out.append((self.t[i], label))
                last = label
        return out
