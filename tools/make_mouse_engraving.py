#!/usr/bin/env python3
"""Turns assets/mouse_wrench_engraving.svg (stroked line art) into the 2D polygons of an engraving, tools/mouse_engraving.json, for make_selling_plate.py (which only needs plain python).
Needs shapely and mapbox_earcut (a venv): the strokes become grooves (buffered lines, merged), the groove region is triangulated (the floor), and so is the rest of the bounding rectangle (the surface).
  python3 tools/make_mouse_engraving.py [name]     name = mouse_wrench (default) or mouse_funnel: assets/<name>_engraving.svg -> tools/<name>_engraving.json
(units: the svg's own box, y down; the generator scales and flips). Paths (M L C Q Z), circles and ellipses (with a rotate transform) are read; a stroke-width on an element wins over the one on the group.
A traced bitmap wins over the svg: assets/<name>_trace.geojson (potrace output of the original picture: magick assets/mouse_wrench_original.webp -colorspace Gray -threshold 50% t.pbm; potrace -b geojson --flat -t 8 -a 1.0 -O 0.4 -o assets/mouse_wrench_trace.geojson t.pbm) is the groove region itself, scaled to TRACE_H units tall.
Layers (svg only): the file is read bottom to top; an element with occludes="1" hides everything drawn before it inside its (first, closed) outline: the wrench in front of the mouse, the paws in front of the wrench."""
import json, os, re, sys
import numpy as np
import mapbox_earcut as earcut
from shapely.geometry import LineString, Polygon, box
from shapely.ops import unary_union
from shapely.geometry.polygon import orient

here = os.path.dirname(os.path.abspath(__file__))
NAME = sys.argv[1] if len(sys.argv) > 1 else "mouse_wrench"
SVG = os.path.join(here, "..", "assets", NAME + "_engraving.svg")
OUT = os.path.join(here, NAME + "_engraving.json")
STEPS, CAP_SEGS, SIMPLIFY, MARGIN = 14, 2, 0.35, 6.0
TRACE = os.path.join(here, "..", "assets", NAME + "_trace.geojson")
TRACE_H, TRACE_FATTEN = 382.0, 0.4          # the traced mouse is this many units tall (the size of the hand-drawn one); lines grow by this much each side (the thinnest whiskers get a little bolder)

def traced():
    d = json.load(open(TRACE)); polys = []
    for f in d["features"]:
        c = f["geometry"]["coordinates"]; polys.append(Polygon(c[0], c[1:]).buffer(0))
    g = unary_union(polys); x0, y0, x1, y1 = g.bounds; k = TRACE_H / (y1 - y0)
    from shapely import affinity
    g = affinity.affine_transform(g, [k, 0, 0, -k, -x0 * k + 60, y1 * k + 80])          # (potrace has y up: flipped back, y down like the svg)
    return g.buffer(TRACE_FATTEN, quad_segs=2)


def bez(pts, n):
    out = []
    for i in range(1, n + 1):
        t = i / n
        q = list(pts)
        while len(q) > 1:
            q = [((1 - t) * a[0] + t * b[0], (1 - t) * a[1] + t * b[1]) for a, b in zip(q, q[1:])]
        out.append(q[0])
    return out

def parse_path(d):
    tokens = re.findall(r"[MLCQZ]|-?\d+\.?\d*", d)
    subs, cur, pos, start, i, cmd = [], [], None, None, 0, None
    while i < len(tokens):
        if tokens[i] in "MLCQZ":
            cmd = tokens[i]; i += 1
            if cmd == "Z":
                if cur and start is not None:
                    cur.append(start)
                subs.append(cur); cur = []; continue
        need = {"M": 2, "L": 2, "C": 6, "Q": 4}[cmd]
        v = [float(x) for x in tokens[i:i + need]]; i += need
        pts = list(zip(v[0::2], v[1::2]))
        if cmd == "M":
            if cur: subs.append(cur)
            cur, pos, start = [pts[0]], pts[0], pts[0]; cmd = "L"          # (further pairs after M are line-tos)
        elif cmd == "L":
            cur.append(pts[0]); pos = pts[0]
        else:
            cur += bez([pos] + pts, STEPS); pos = pts[-1]
    if cur: subs.append(cur)
    return [s for s in subs if len(s) > 1]

def strokes():
    text = re.sub(r"<!--.*?-->", "", open(SVG, encoding="utf-8").read(), flags=re.S)
    g = re.search(r'<g\b[^>]*stroke-width="([\d.]+)"', text)
    default_w = float(g.group(1)) if g else 9.0
    shapes = []
    for m in re.finditer(r"<(path|circle|ellipse)\b([^>]*)/?>", text):
        tag, attrs = m.group(1), m.group(2)
        sw = re.search(r'stroke-width="([\d.]+)"', attrs)
        w = float(sw.group(1)) if sw else default_w
        if tag == "path":
            subs = parse_path(re.search(r'\bd="([^"]*)"', attrs).group(1))
            if 'occludes="1"' in attrs and shapes:
                hidden = Polygon(subs[0]).buffer(0)                        # (an open outline is closed by its chord)
                shapes = [unary_union(shapes).difference(hidden)]
            for sub in subs:
                shapes.append(LineString(sub).buffer(w / 2, quad_segs=CAP_SEGS))
        else:
            num = lambda k: float(re.search(r'\b' + k + r'="([\d.\-]+)"', attrs).group(1))
            cx, cy = num("cx"), num("cy")
            rx, ry = (num("rx"), num("ry")) if tag == "ellipse" else (num("r"), num("r"))
            rot = re.search(r'rotate\(([\d.\-]+)', attrs)
            ang = np.radians(float(rot.group(1))) if rot else 0.0       # (rotate about the ellipse's own centre in these files)
            ring = []
            for a in np.linspace(0, 2 * np.pi, 49):
                x, y = rx * np.cos(a), ry * np.sin(a)
                ring.append((cx + x * np.cos(ang) - y * np.sin(ang), cy + x * np.sin(ang) + y * np.cos(ang)))
            shapes.append(LineString(ring).buffer(w / 2, quad_segs=CAP_SEGS))
    return unary_union(shapes)

def triangulate(geom):
    verts, tris = [], []
    for poly in (geom.geoms if hasattr(geom, "geoms") else [geom]):
        poly = orient(poly, 1.0)
        rings = [list(poly.exterior.coords)[:-1]] + [list(r.coords)[:-1] for r in poly.interiors]
        flat, ends, n = [], [], 0
        for r in rings:
            flat += r; n += len(r); ends.append(n)
        idx = earcut.triangulate_float64(np.array(flat, dtype=np.float64), np.array(ends, dtype=np.uint32))
        base = len(verts)
        verts += flat
        tris += [int(k) + base for k in idx]
    return verts, tris

G = (traced() if os.path.exists(TRACE) else strokes()).simplify(SIMPLIFY)
x0, y0, x1, y1 = G.bounds
R = box(x0 - MARGIN, y0 - MARGIN, x1 + MARGIN, y1 + MARGIN)
S = R.difference(G)
fv, ft = triangulate(G)
sv, st = triangulate(S)
r2 = lambda v: [[round(p[0], 2), round(p[1], 2)] for p in v]
rings = []
for poly in (G.geoms if hasattr(G, "geoms") else [G]):
    poly = orient(poly, 1.0)
    for r in [poly.exterior] + list(poly.interiors):
        rings.append(r2(list(r.coords)[:-1]))
data = {"rect": [R.bounds[0], R.bounds[1], R.bounds[2], R.bounds[3]], "floor": {"v": r2(fv), "t": ft}, "surface": {"v": r2(sv), "t": st}, "walls": rings}
json.dump(data, open(OUT, "w"), separators=(",", ":"))
print("groove area %.0f of rect %.0f; floor %d tris, surface %d tris, %d wall quads, %d rings; area check %.3f" % (G.area, R.area, len(ft) // 3, len(st) // 3, sum(len(r) for r in rings), len(rings), abs(R.area - G.area - S.area)))
