#!/usr/bin/env python3
"""Build the Aureways app icon from the checked-in reference renders.

The mark is described analytically, not traced: the letter A is four straight
edges with circular fillets, the orbit is two elliptical arcs joined by a
tapering cubic at each tip, and the spark is four cubics. Every number below
was fitted to `reference/mark_on_{blue,black,white}_1408.png` (majority vote of
the three renders) and is expressed in that 1408 px reference space; output is
scaled to the 1024 px icon canvas.

    python3 design/app-icon/build_icon.py [--check]

--check re-renders the model and reports IoU against the reference instead of
writing anything.
"""

from __future__ import annotations

import json
import math
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
REFERENCE = ROOT / "reference"
ICON_DIR = REPO / "Aureways" / "AppIcon.icon"
ICON_ASSETS = ICON_DIR / "Assets"
ICONSET = REPO / "Aureways" / "Assets.xcassets" / "AppIcon.appiconset"

ORBIT_BLUE = (0x00, 0x3D, 0xA5)
DEEP_NAVY = (0x00, 0x2B, 0x73)
ICON_WHITE = (0xFF, 0xFF, 0xFF)
DARK_FG = (0xF2, 0xF5, 0xFA)

SRC = 1408.0
CANVAS = 1024.0
S = CANVAS / SRC

# --- fitted geometry, 1408 px reference space -------------------------------

LINES = {                       # leg edges as x = m*y + b
    "lo": (-0.446669, 782.1981),
    "li": (-0.423720, 899.0385),
    "ri": (+0.412913, 533.5741),
    "ro": (+0.437656, 645.1526),
}
A_APEX_R = 64.00                # fillet at the top of the A
A_VEE_R = 14.18                 # fillet at the tip of the counter
A_FOOT_R = 26.28                # fillet at all four bottom corners
A_BOTTOM = 1098.18              # flat bottom of both feet
KNOCKOUT_ARM = 20.6            # clearance the orbit cuts out of the A's arm
KNOCKOUT_LEG = 18.6            # ...and out of the A's lower right leg

ORBIT_OUTER = (710.1268, 679.4097, 472.7748, 127.8232, math.radians(-17.3335))
ORBIT_INNER = (710.1450, 662.5250, 414.5092, 103.4893, math.radians(-17.5457))
ORBIT_T = dict(                 # ellipse parameters, radians
    tip_right=math.radians(299.1533),   # on the outer ellipse
    tip_left=math.radians(238.5165),    # on the inner ellipse
    outer_end=math.radians(204.9480),   # outer edge leaves the ellipse here
    inner_end=math.radians(322.3613),   # inner edge leaves the ellipse here
)
ORBIT_H = (0.3425, 0.2003, 0.6588, 0.4873)      # taper handle lengths

SPARK = dict(cx=1073.0032, cy=346.0068, rx=77.3854, ry=80.6862, k=0.1611)


# --- small vector helpers ---------------------------------------------------

def unit(v):
    n = math.hypot(*v) or 1.0
    return (v[0] / n, v[1] / n)


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1])


def line_x(name, y):
    m, b = LINES[name]
    return m * y + b


def line_dir(name):
    """Direction of the edge with increasing y."""
    return unit((LINES[name][0], 1.0))


def line_meet(n1, n2):
    m1, b1 = LINES[n1]
    m2, b2 = LINES[n2]
    y = (b1 - b2) / (m2 - m1)
    return (m1 * y + b1, y)


def wedge_fillet(n1, n2, r):
    """Circle of radius r inscribed in the downward-opening wedge of two edges.

    Returns (centre, tangent point on n1, tangent point on n2).
    """
    v = line_meet(n1, n2)
    d1, d2 = line_dir(n1), line_dir(n2)
    bis = unit((d1[0] + d2[0], d1[1] + d2[1]))
    half = math.acos(max(-1.0, min(1.0, d1[0] * bis[0] + d1[1] * bis[1])))
    dist = r / math.sin(half)
    tan_len = dist * math.cos(half)
    return ((v[0] + bis[0] * dist, v[1] + bis[1] * dist),
            (v[0] + d1[0] * tan_len, v[1] + d1[1] * tan_len),
            (v[0] + d2[0] * tan_len, v[1] + d2[1] * tan_len))


def foot_fillet(name, side, r, y_b=A_BOTTOM):
    """Circle tangent to a leg edge and to the flat bottom.

    side = +1 when the stroke lies at x > line, -1 when it lies at x < line.
    Returns (centre, tangent point on the edge, tangent point on the bottom).
    """
    m, b = LINES[name]
    cy = y_b - r
    cx = m * cy + b + side * r * math.hypot(1.0, m)
    y_t = (cy + m * (cx - b)) / (1.0 + m * m)
    return (cx, cy), (m * y_t + b, y_t), (cx, y_b)


def ell_pt(e, t):
    cx, cy, rx, ry, rot = e
    cr, sr = math.cos(rot), math.sin(rot)
    x, y = rx * math.cos(t), ry * math.sin(t)
    return (cx + x * cr - y * sr, cy + x * sr + y * cr)


def ell_tangent(e, t):
    _, _, rx, ry, rot = e
    cr, sr = math.cos(rot), math.sin(rot)
    x, y = -rx * math.sin(t), ry * math.cos(t)
    return unit((x * cr - y * sr, x * sr + y * cr))


def ell_t_of(e, p):
    cx, cy, rx, ry, rot = e
    dx, dy = p[0] - cx, p[1] - cy
    cr, sr = math.cos(-rot), math.sin(-rot)
    return math.atan2((dx * sr + dy * cr) / ry, (dx * cr - dy * sr) / rx)


def ell_scaled(e, s):
    cx, cy, rx, ry, rot = e
    return (cx, cy, rx * s, ry * s, rot)


def ell_dist(e, p, n=4096):
    """Distance from a point to an ellipse, by dense sampling + refinement."""
    ts = [2 * math.pi * i / n for i in range(n)]
    best = min(ts, key=lambda t: math.hypot(*sub(ell_pt(e, t), p)))
    lo, hi = best - 2 * math.pi / n, best + 2 * math.pi / n
    for _ in range(60):
        a = lo + (hi - lo) / 3
        b = hi - (hi - lo) / 3
        if math.hypot(*sub(ell_pt(e, a), p)) < math.hypot(*sub(ell_pt(e, b), p)):
            hi = b
        else:
            lo = a
    return math.hypot(*sub(ell_pt(e, (lo + hi) / 2), p))


def ell_offset_through(e, t_ref, gap, outward):
    """Translate `e` by `gap` along its normal at t_ref (out- or inward).

    A translation keeps the curvature of the edge it is cutting, so the
    clearance stays even across the stroke; scaling would not.
    """
    cx, cy, rx, ry, rot = e
    tx, ty = ell_tangent(e, t_ref)
    n = (ty, -tx)
    p = ell_pt(e, t_ref)
    if ((p[0] + n[0] - cx) ** 2 + (p[1] + n[1] - cy) ** 2
            < (p[0] - cx) ** 2 + (p[1] - cy) ** 2):
        n = (-n[0], -n[1])          # make n point away from the centre
    s = gap if outward else -gap
    return (cx + n[0] * s, cy + n[1] * s, rx, ry, rot)


def ell_line_hit(e, name, y_hint):
    """Intersection of an ellipse with a leg edge, nearest to y_hint."""
    m, b = LINES[name]
    cx, cy, rx, ry, rot = e
    cr, sr = math.cos(-rot), math.sin(-rot)

    def f(y):
        dx, dy = (m * y + b) - cx, y - cy
        return (((dx * cr - dy * sr) / rx) ** 2
                + ((dx * sr + dy * cr) / ry) ** 2 - 1.0)

    ys = np.linspace(y_hint - 500, y_hint + 500, 20001)
    vals = np.array([f(y) for y in ys])
    roots = []
    for i in np.flatnonzero(np.sign(vals[:-1]) != np.sign(vals[1:])):
        lo, hi = ys[i], ys[i + 1]
        flo = vals[i]
        for _ in range(80):
            mid = (lo + hi) / 2
            if f(mid) * flo <= 0:
                hi = mid
            else:
                lo, flo = mid, f(mid)
        roots.append((lo + hi) / 2)
    if not roots:
        raise ValueError(f"no intersection with {name} near y={y_hint}")
    y = min(roots, key=lambda v: abs(v - y_hint))
    return (m * y + b, y)


# --- path emission (1408 space in, 1024 space out) --------------------------

def P(p):
    return f"{p[0] * S:.3f},{p[1] * S:.3f}"


def circle_arc(centre, r, p0, p1):
    """Minor circular arc from p0 to p1, as an SVG A command."""
    a0 = math.atan2(p0[1] - centre[1], p0[0] - centre[0])
    a1 = math.atan2(p1[1] - centre[1], p1[0] - centre[0])
    d = (a1 - a0) % (2 * math.pi)
    if d > math.pi:
        d -= 2 * math.pi
    sweep = 1 if d > 0 else 0
    return f"A{r * S:.3f},{r * S:.3f} 0 0 {sweep} {P(p1)}"


def ellipse_arc(e, t0, t1, forward):
    """SVG A command along `e` from t0 to t1, travelling in +t or -t."""
    _, _, rx, ry, rot = e
    d = (t1 - t0) % (2 * math.pi) if forward else -((t0 - t1) % (2 * math.pi))
    large = 1 if abs(d) > math.pi else 0
    sweep = 1 if d > 0 else 0
    return (f"A{rx * S:.3f},{ry * S:.3f} {math.degrees(rot):.4f} "
            f"{large} {sweep} {P(ell_pt(e, t1))}")


def cubic(c1, c2, p3):
    return f"C{P(c1)} {P(c2)} {P(p3)}"


def ellipse_arc_minor(e, t0, t1):
    """Shorter of the two ellipse arcs between t0 and t1."""
    return ellipse_arc(e, t0, t1, forward=(t1 - t0) % (2 * math.pi) <= math.pi)


def sample_ellipse(e, t0, t1, forward, step=math.radians(0.5)):
    d = (t1 - t0) % (2 * math.pi) if forward else -((t0 - t1) % (2 * math.pi))
    n = max(8, int(abs(d) / step))
    return [ell_pt(e, t0 + d * i / n) for i in range(n + 1)]


def sample_ellipse_minor(e, t0, t1, step=math.radians(0.5)):
    return sample_ellipse(e, t0, t1, (t1 - t0) % (2 * math.pi) <= math.pi, step)


def sample_circle(centre, r, p0, p1, n=64):
    a0 = math.atan2(p0[1] - centre[1], p0[0] - centre[0])
    a1 = math.atan2(p1[1] - centre[1], p1[0] - centre[0])
    d = (a1 - a0) % (2 * math.pi)
    if d > math.pi:
        d -= 2 * math.pi
    return [(centre[0] + r * math.cos(a0 + d * i / n),
             centre[1] + r * math.sin(a0 + d * i / n)) for i in range(n + 1)]


def sample_cubic(p0, c1, c2, p3, n=96):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        out.append((u ** 3 * p0[0] + 3 * u * u * t * c1[0]
                    + 3 * u * t * t * c2[0] + t ** 3 * p3[0],
                    u ** 3 * p0[1] + 3 * u * u * t * c1[1]
                    + 3 * u * t * t * c2[1] + t ** 3 * p3[1]))
    return out


# --- orbit ------------------------------------------------------------------

def orbit_shape():
    """(svg d, polyline) for the ribbon: two ellipse arcs + a taper per tip."""
    eo, ei = ORBIT_OUTER, ORBIT_INNER
    tR, tL = ORBIT_T["tip_right"], ORBIT_T["tip_left"]
    tOe, tIe = ORBIT_T["outer_end"], ORBIT_T["inner_end"]
    hO1, hO2, hI1, hI2 = ORBIT_H

    p_r, p_l = ell_pt(eo, tR), ell_pt(ei, tL)
    q_o, q_i = ell_pt(eo, tOe), ell_pt(ei, tIe)

    ch = math.hypot(*sub(p_l, q_o))
    d0, d1 = ell_tangent(eo, tOe), ell_tangent(ei, tL)
    c1 = (q_o[0] + d0[0] * hO1 * ch, q_o[1] + d0[1] * hO1 * ch)
    c2 = (p_l[0] - d1[0] * hO2 * ch, p_l[1] - d1[1] * hO2 * ch)

    ch2 = math.hypot(*sub(p_r, q_i))
    e0, e1 = ell_tangent(ei, tIe), ell_tangent(eo, tR)
    c3 = (q_i[0] - e0[0] * hI1 * ch2, q_i[1] - e0[1] * hI1 * ch2)
    c4 = (p_r[0] + e1[0] * hI2 * ch2, p_r[1] + e1[1] * hI2 * ch2)

    d = " ".join([
        f"M{P(p_r)}",
        ellipse_arc(eo, tR, tOe, forward=True),
        cubic(c1, c2, p_l),
        ellipse_arc(ei, tL, tIe, forward=False),
        cubic(c3, c4, p_r),
        "Z",
    ])
    poly = ([p_r] + sample_ellipse(eo, tR, tOe, True)
            + sample_cubic(q_o, c1, c2, p_l)
            + sample_ellipse(ei, tL, tIe, False)
            + sample_cubic(q_i, c3, c4, p_r))
    return d, poly


# --- letter A ---------------------------------------------------------------

def knockout_edges():
    """The two offset ellipses that cut the A's right stroke."""
    tR, tL = ORBIT_T["tip_right"], ORBIT_T["tip_left"]
    tOe, tIe = ORBIT_T["outer_end"], ORBIT_T["inner_end"]
    TWO = 2 * math.pi

    def on_ribbon(outer, t):
        """Is t inside the swept part of the ring (not the open sector)?"""
        if outer:
            return (t - tR) % TWO <= (tOe - tR) % TWO
        return (tL - t) % TWO <= (tL - tIe) % TWO

    def stroke_t(e, outer):
        """Parameter where the ring's edge crosses the right stroke's centre."""
        best, bt = None, 0.0
        for i in range(20000):
            t = TWO * i / 20000
            if not on_ribbon(outer, t):
                continue
            x, y = ell_pt(e, t)
            if not 400 < y < 1000:
                continue
            mid = (line_x("ri", y) + line_x("ro", y)) / 2
            if best is None or abs(x - mid) < best:
                best, bt = abs(x - mid), t
        if best is None:
            raise ValueError("ring edge never crosses the right stroke")
        return bt

    cut_arm = ell_offset_through(ORBIT_INNER, stroke_t(ORBIT_INNER, False),
                                KNOCKOUT_ARM, outward=False)
    cut_leg = ell_offset_through(ORBIT_OUTER, stroke_t(ORBIT_OUTER, True),
                                KNOCKOUT_LEG, outward=True)
    return cut_arm, cut_leg


def a_shape(knockout=True):
    """(list of svg d, list of polylines) for the letter A."""
    apex_c, apex_l, apex_r = wedge_fillet("lo", "ro", A_APEX_R)
    vee_c, vee_l, vee_r = wedge_fillet("li", "ri", A_VEE_R)
    ro_c, ro_e, ro_b = foot_fillet("ro", -1, A_FOOT_R)
    ri_c, ri_e, ri_b = foot_fillet("ri", +1, A_FOOT_R)
    li_c, li_e, li_b = foot_fillet("li", -1, A_FOOT_R)
    lo_c, lo_e, lo_b = foot_fillet("lo", +1, A_FOOT_R)
    R = A_FOOT_R

    if not knockout:
        d = " ".join([
            f"M{P(apex_l)}", circle_arc(apex_c, A_APEX_R, apex_l, apex_r),
            f"L{P(ro_e)}", circle_arc(ro_c, R, ro_e, ro_b),
            f"L{P(ri_b)}", circle_arc(ri_c, R, ri_b, ri_e),
            f"L{P(vee_r)}", circle_arc(vee_c, A_VEE_R, vee_r, vee_l),
            f"L{P(li_e)}", circle_arc(li_c, R, li_e, li_b),
            f"L{P(lo_b)}", circle_arc(lo_c, R, lo_b, lo_e),
            "Z",
        ])
        poly = (sample_circle(apex_c, A_APEX_R, apex_l, apex_r)
                + [ro_e] + sample_circle(ro_c, R, ro_e, ro_b)
                + [ri_b] + sample_circle(ri_c, R, ri_b, ri_e)
                + [vee_r] + sample_circle(vee_c, A_VEE_R, vee_r, vee_l)
                + [li_e] + sample_circle(li_c, R, li_e, li_b)
                + [lo_b] + sample_circle(lo_c, R, lo_b, lo_e))
        return [d], [poly]

    cut_arm, cut_leg = knockout_edges()
    arm_ro = ell_line_hit(cut_arm, "ro", 700)
    arm_ri = ell_line_hit(cut_arm, "ri", 700)
    leg_ro = ell_line_hit(cut_leg, "ro", 780)
    leg_ri = ell_line_hit(cut_leg, "ri", 780)
    t_arm = (ell_t_of(cut_arm, arm_ro), ell_t_of(cut_arm, arm_ri))
    t_leg = (ell_t_of(cut_leg, leg_ri), ell_t_of(cut_leg, leg_ro))

    body = " ".join([
        f"M{P(apex_l)}", circle_arc(apex_c, A_APEX_R, apex_l, apex_r),
        f"L{P(arm_ro)}", ellipse_arc_minor(cut_arm, t_arm[0], t_arm[1]),
        f"L{P(vee_r)}", circle_arc(vee_c, A_VEE_R, vee_r, vee_l),
        f"L{P(li_e)}", circle_arc(li_c, R, li_e, li_b),
        f"L{P(lo_b)}", circle_arc(lo_c, R, lo_b, lo_e),
        "Z",
    ])
    body_poly = (sample_circle(apex_c, A_APEX_R, apex_l, apex_r)
                 + [arm_ro] + sample_ellipse_minor(cut_arm, *t_arm)
                 + [vee_r] + sample_circle(vee_c, A_VEE_R, vee_r, vee_l)
                 + [li_e] + sample_circle(li_c, R, li_e, li_b)
                 + [lo_b] + sample_circle(lo_c, R, lo_b, lo_e))

    leg = " ".join([
        f"M{P(leg_ri)}", ellipse_arc_minor(cut_leg, t_leg[0], t_leg[1]),
        f"L{P(ro_e)}", circle_arc(ro_c, R, ro_e, ro_b),
        f"L{P(ri_b)}", circle_arc(ri_c, R, ri_b, ri_e),
        "Z",
    ])
    leg_poly = (sample_ellipse_minor(cut_leg, *t_leg)
                + [ro_e] + sample_circle(ro_c, R, ro_e, ro_b)
                + [ri_b] + sample_circle(ri_c, R, ri_b, ri_e))
    return [body, leg], [body_poly, leg_poly]


# --- spark ------------------------------------------------------------------

def spark_shape():
    cx, cy = SPARK["cx"], SPARK["cy"]
    rx, ry, k = SPARK["rx"], SPARK["ry"], SPARK["k"]
    tips = [(cx, cy - ry), (cx + rx, cy), (cx, cy + ry), (cx - rx, cy)]
    ctrl = [(cx + k * rx, cy - k * ry), (cx + k * rx, cy + k * ry),
            (cx - k * rx, cy + k * ry), (cx - k * rx, cy - k * ry)]
    d = [f"M{P(tips[0])}"]
    poly = []
    for i in range(4):
        p0, p3, c = tips[i], tips[(i + 1) % 4], ctrl[i]
        d.append(cubic(c, c, p3))
        poly += sample_cubic(p0, c, c, p3)
    d.append("Z")
    return " ".join(d), poly


# --- raster + verification --------------------------------------------------

def svg_doc(paths, fill, bg=None, rule="nonzero"):
    if isinstance(fill, tuple):
        fill = "#{:02X}{:02X}{:02X}".format(*fill)
    head = (f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{int(CANVAS)}" '
            f'height="{int(CANVAS)}" viewBox="0 0 {int(CANVAS)} {int(CANVAS)}" '
            f'fill="none">\n')
    body = ""
    if bg is not None:
        body += ('  <rect width="{0}" height="{0}" fill="#{1:02X}{2:02X}{3:02X}"'
                 "/>\n".format(int(CANVAS), *bg))
    for d in paths:
        body += (f'  <path fill="{fill}" fill-rule="{rule}" '
                 f'shape-rendering="geometricPrecision" d="{d}"/>\n')
    return head + body + "</svg>\n"


def rasterize(polys, size, ss=4):
    n = int(size * ss)
    k = size / SRC * ss
    img = Image.new("L", (n, n), 0)
    draw = ImageDraw.Draw(img)
    for poly in polys:
        draw.polygon([(x * k, y * k) for x, y in poly], fill=255)
    small = img.resize((int(size), int(size)), Image.Resampling.BOX)
    return np.array(small)


def reference_mask():
    """Majority vote of the three reference renders, at 1408."""
    votes = None
    for name, light_fg in (("mark_on_blue_1408.png", True),
                           ("mark_on_black_1408.png", True),
                           ("mark_on_white_1408.png", False)):
        im = np.array(Image.open(REFERENCE / name).convert("RGB"), dtype=np.float32)
        lum = 0.299 * im[:, :, 0] + 0.587 * im[:, :, 1] + 0.114 * im[:, :, 2]
        m = (lum > 140) if light_fg else (lum < 140)
        votes = m.astype(np.uint8) if votes is None else votes + m
    return votes >= 2


def model_polys(knockout=True):
    a_ds, a_polys = a_shape(knockout)
    o_d, o_poly = orbit_shape()
    s_d, s_poly = spark_shape()
    return a_ds + [o_d, s_d], a_polys + [o_poly, s_poly]


def check():
    ref = reference_mask()
    _, polys = model_polys(knockout=True)
    got = rasterize(polys, SRC, ss=2) > 127
    inter = int((got & ref).sum())
    union = int((got | ref).sum())
    print(f"mark IoU vs reference = {inter / union:.4f}")
    print(f"  reference px {int(ref.sum())}  model px {int(got.sum())}")
    print(f"  miss {int((ref & ~got).sum())}  extra {int((got & ~ref).sum())}")
    vis = np.zeros((int(SRC), int(SRC), 3), np.uint8)
    vis[ref] = (235, 70, 70)
    vis[got] = (250, 205, 60)
    vis[got & ref] = (150, 250, 150)
    Image.fromarray(vis).save(ROOT / "_diag_overlay.png")
    print("wrote", (ROOT / "_diag_overlay.png").relative_to(REPO))
    return inter / union


# --- outputs ----------------------------------------------------------------

def srgb(rgb, a=1.0):
    r, g, b = rgb
    return f"srgb:{r / 255:.5f},{g / 255:.5f},{b / 255:.5f},{a:.5f}"


def icon_json():
    """The Icon Composer document.

    Matches what Icon Composer itself writes, so opening the .icon in the GUI
    and saving does not fight this script:

    - the background is the built-in `automatic-gradient` over Orbit Blue, not
      a flat solid — same hue, brighter toward the top;
    - each layer's default fill is `automatic` (it resolves to white over that
      background), with an explicit `#F2F5FA` for the dark appearance;
    - there is no top-level `fill-specializations`. A dark background value
      there is inert: ictool renders the Dark rendition's ground near-black on
      both macOS and iOS whatever you put in it (measured — see
      docs/brand/app-icon.md §5.2). Deep Navy stays the dark colour for the
      flat colourways and the pre-macOS-26 fallback instead.
    """
    dark_fg = {"solid": srgb(DARK_FG)}
    white = {"solid": "extended-gray:1.00000,1.00000"}

    def layer(image, name, opacity=1):
        return {
            "blend-mode-specializations": [
                {"appearance": "tinted", "value": "normal"}],
            "fill-specializations": [
                {"value": "automatic"},
                {"appearance": "dark", "value": dark_fg},
                {"appearance": "tinted", "value": white},
            ],
            "glass": True,
            "hidden": False,
            "image-name": image,
            "name": name,
            "opacity": opacity,
            "position": {"scale": 1, "translation-in-points": [0, 0]},
        }

    doc = {
        "color-space-for-untagged-svg-colors": "display-p3",
        "fill": {"automatic-gradient": srgb(ORBIT_BLUE)},
        "groups": [
            {
                "blur-material": 0.5,
                "hidden": False,
                "layers": [layer("A.svg", "Letter A")],
                "lighting": "individual",
                "opacity": 1,
                "shadow": {"kind": "layer-color", "opacity": 0.5},
                "specular": True,
                "translucency": {"enabled": False, "value": 0.4},
            },
            {
                "blur-material": 0.4,
                "hidden": False,
                "layers": [layer("Orbit.svg", "Orbit")],
                "lighting": "individual",
                "opacity": 1,
                "shadow": {"kind": "neutral", "opacity": 0.35},
                "specular": True,
                "translucency": {"enabled": True, "value": 0.35},
            },
            {
                "blur-material": 0.25,
                "hidden": False,
                "layers": [layer("Spark.svg", "Spark")],
                "lighting": "individual",
                "opacity": 1,
                "shadow": {"kind": "none", "opacity": 0.3},
                "specular": True,
                "translucency": {"enabled": True, "value": 0.55},
            },
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    return json.dumps(doc, indent=2) + "\n"


ICONSET_SLOTS = [
    ("16x16", "1x", 16), ("16x16", "2x", 32),
    ("32x32", "1x", 32), ("32x32", "2x", 64),
    ("128x128", "1x", 128), ("128x128", "2x", 256),
    ("256x256", "1x", 256), ("256x256", "2x", 512),
    ("512x512", "1x", 512), ("512x512", "2x", 1024),
]

# ictool's rendition names — camel case, no spaces.
RENDITIONS = ["Default", "Dark", "ClearLight", "ClearDark",
              "TintedLight", "TintedDark", "Mono"]


def write_text(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    print("wrote", path.relative_to(REPO))


def save_png(img: Image.Image, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG", optimize=True)
    print("wrote", path.relative_to(REPO), img.size)


def flat_png(polys, size, fg, bg=None):
    """Render the flat mark at `size` px, anti-aliased."""
    alpha = rasterize(polys, size, ss=4)
    n = int(size)
    if bg is None:
        arr = np.zeros((n, n, 4), np.uint8)
        arr[:, :, 0], arr[:, :, 1], arr[:, :, 2] = fg
        arr[:, :, 3] = alpha
        return Image.fromarray(arr, "RGBA")
    a = (alpha.astype(np.float32) / 255.0)[:, :, None]
    arr = np.array(bg, np.float32)[None, None, :] * (1 - a) \
        + np.array(fg, np.float32)[None, None, :] * a
    return Image.fromarray(arr.round().astype(np.uint8), "RGB")


def export_composer_preview():
    """Export the Default/Dark previews and prove every rendition renders."""
    ictool = Path("/Applications/Xcode-beta.app/Contents/Applications/"
                  "Icon Composer.app/Contents/Executables/ictool")
    if not ictool.exists():
        ictool = Path("/Applications/Xcode.app/Contents/Applications/"
                      "Icon Composer.app/Contents/Executables/ictool")
    if not ictool.exists():
        print("ictool not found — skipping Icon Composer previews")
        return

    def export(rendition, px, dest):
        r = subprocess.run(
            [str(ictool), str(ICON_DIR), "--export-image",
             "--output-file", str(dest), "--platform", "macOS",
             "--rendition", rendition, "--width", str(px), "--height", str(px),
             "--scale", "1"],
            capture_output=True, text=True)
        ok = r.returncode == 0 and dest.exists()
        if not ok:
            print(f"  ictool {rendition}: rc={r.returncode} "
                  f"{(r.stderr + r.stdout).strip()[:160]}")
        return ok

    for rendition, out in (("Default", "preview_composer_default.png"),
                           ("Dark", "preview_composer_dark.png")):
        tmp = Path(f"/tmp/aureways-{rendition.lower()}.png")
        if export(rendition, 1024, tmp):
            shutil.copy(tmp, ROOT / out)
            print("wrote", (ROOT / out).relative_to(REPO))

    # Every appearance the system can ask for must render; a layer the glass
    # engine chokes on only shows up here, not in Default.
    bad = [r for r in RENDITIONS
           if not export(r, 256, Path(f"/tmp/aureways-check-{r}.png"))]
    print(f"renditions: {len(RENDITIONS) - len(bad)}/{len(RENDITIONS)} ok"
          + (f" — FAILED: {', '.join(bad)}" if bad else ""))


def build():
    a_ds, a_polys = a_shape(knockout=True)
    o_d, o_poly = orbit_shape()
    s_d, s_poly = spark_shape()
    mark_ds = a_ds + [o_d, s_d]
    mark_polys = a_polys + [o_poly, s_poly]

    # Icon Composer layers: white, no background, no pre-clipped corners.
    write_text(ROOT / "A.svg", svg_doc(a_ds, ICON_WHITE))
    write_text(ROOT / "Orbit.svg", svg_doc([o_d], ICON_WHITE))
    write_text(ROOT / "Spark.svg", svg_doc([s_d], ICON_WHITE))
    ICON_ASSETS.mkdir(parents=True, exist_ok=True)
    for name in ("A.svg", "Orbit.svg", "Spark.svg"):
        shutil.copy(ROOT / name, ICON_ASSETS / name)
        print("wrote", (ICON_ASSETS / name).relative_to(REPO))
    write_text(ICON_DIR / "icon.json", icon_json())

    # Flat colourways.
    write_text(ROOT / "logo_on_white.svg", svg_doc(mark_ds, ORBIT_BLUE))
    write_text(ROOT / "logo_on_dark.svg", svg_doc(mark_ds, ICON_WHITE))
    write_text(ROOT / "logo_default.svg",
               svg_doc(mark_ds, ICON_WHITE, bg=ORBIT_BLUE))
    write_text(ROOT / "logo_dark.svg", svg_doc(mark_ds, DARK_FG, bg=DEEP_NAVY))

    save_png(flat_png(mark_polys, CANVAS, ICON_WHITE, ORBIT_BLUE),
             ROOT / "logo_default_1024.png")
    save_png(flat_png(mark_polys, CANVAS, DARK_FG, DEEP_NAVY),
             ROOT / "logo_dark_1024.png")
    save_png(flat_png(mark_polys, CANVAS, ORBIT_BLUE),
             ROOT / "logo_on_white_1024.png")
    save_png(flat_png(mark_polys, CANVAS, ICON_WHITE),
             ROOT / "logo_on_dark_1024.png")
    for px in (16, 32, 64, 128, 256):
        save_png(flat_png(mark_polys, px, ICON_WHITE, ORBIT_BLUE),
                 ROOT / f"preview_{px}.png")

    # Flattened fallback iconset.
    ICONSET.mkdir(parents=True, exist_ok=True)
    images = []
    for size, scale, px in ICONSET_SLOTS:
        fname = f"icon_{size.replace('x', '')}@{scale}.png"
        save_png(flat_png(mark_polys, px, ICON_WHITE, ORBIT_BLUE),
                 ICONSET / fname)
        images.append({"filename": fname, "idiom": "mac",
                       "scale": scale, "size": size})
    write_text(ICONSET / "Contents.json",
               json.dumps({"images": images,
                           "info": {"author": "xcode", "version": 1}},
                          indent=2) + "\n")
    export_composer_preview()


def main():
    if "--check" in sys.argv:
        check()
        return
    build()
    check()


if __name__ == "__main__":
    main()


