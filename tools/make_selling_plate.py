#!/usr/bin/env python3
"""The selling plate as a shop vehicle (FS25_Hammer): a flat iron grid in an iron frame, 3.0 m x 4.0 m, with three towing eyes at one short end. It is a heavy dynamic object (drag it with a tractor on its eyes or with a winch); it only buys once the Sandbox Hammer has frozen it (scripts/vehicles/SellingPlate.lua).
  python3 tools/make_selling_plate.py [out dir]      -> vehicles/sellingPlate/sellingPlate.i3d and .i3d.shapes
The body is ONE convex box hull (root shape); children: the visual, the exact-fill node trailers tip onto (group FILLABLE), a pallet trigger and a bale trigger (two nodes, one shape), the three attacher joints.
The helpers come from FS25_HorseDynamics/tools (the same shapes writer the horse objects use). Materials: 1 iron, 2 the towing eyes (orange, to find them).
The origin is the plate's bottom (a vehicle's origin stands on the floor). Front = +z (the eyes)."""
import math, os, sys
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, "..", "..", "FS25_HorseDynamics", "tools"))
import make_hitching_post as H
import make_horse_jumps as J
import shapes_io as S
import json

W, L, HT = 3.0, 4.0, 0.12          # width (x), length (z), height of the frame and the bearing bars
FRAME = 0.045                      # frame bar width
PITCH = 0.05                       # bearing bars every 5 cm across, 6 mm thick, along z
BAR_T, BAR_H = 0.006, 0.08
CROSS_PITCH, CROSS_T, CROSS_H = 0.25, 0.010, 0.022      # cross rods along x, at the top
EYE_X = (-1.0, 0.0, 1.0)           # the three towing eyes on the front edge
EYE_Y = 0.07
TRIGGER_H = 1.5                    # half height of the sell volume over the plate: a pile of logs, a stack of pallets

LUG_LEN, LUG_BAR, LUG_LEG, LUG_HALF_W = 0.055, 0.0125, 0.009, 0.055     # the U lug (a staple welded to the end bar: two legs along z, a bar across x) of every bridge hitch and eye; sizes in metres (half extents)
RING_R, RING_r = 0.055, 0.0125                  # the link ring (the O): mean radius and wire radius; its hole (0.085 m) takes two lug bars (0.025 m) with 3.5 cm to spare
RING_REACH = RING_R - RING_r - LUG_BAR          # a lug bar sits this far from the ring's centre when the link is pulled tight
RING_MASS = 40
RING_ROT, RING_TRANS = "80 25 25", "0.02 0.025 0.025"     # how the ring moves on a lug bar: swings freely about it (x), tilts a little, slides a little (the leeway: uneven ground)

LIFT_R, LIFT_r = 0.07, 0.013                      # the lifting lug (red ring, lying flat at the middle of a bridge piece)
LATCH_R, LATCH_r = 0.05, 0.012                  # the winch latch (yellow): a staple on the side bar and a ring hung on it; the winch takes it, the game's attach and BridgeLink never do (joint type winchLatch)
LATCH_Z = {4.0: (-0.9, 0.9), 1.6: (0.0,)}       # where the latches sit along each side bar, by piece length (a pair on the grate, one per side on the short end pieces)

MOUSE_H = 0.095                    # the engraved mouse on the frame's outer sides: this tall (the frame is 0.12 high)
MOUSE_DEPTH = 0.0012
_mice = {}

def engraving(name):
    if name not in _mice:
        _mice[name] = json.load(open(os.path.join(here, name + "_engraving.json")))
    return _mice[name]

def engraved_bar(m, cx, cy, cz, hx, hy, hz, side, zc, mouse, groove):
    """The frame bar as a box whose outer face (side = +1 or -1 in x) has the mouse (tools/make_mouse_engraving.py) cut into it, centred at z = zc: the face is the bar's rectangle minus the mouse's rectangle,
    plus the mouse's own surface, its groove floors and its groove walls. Mesh coordinates: u along the face (to the viewer's right), v up."""
    tmp = H.Mesh()
    H.box(tmp, cx, cy, cz, hx, hy, hz)
    keep = {}
    for tri in tmp.t:
        if all(tmp.n[i][0] == side for i in tri):
            continue
        for i in tri:
            keep.setdefault(i, m.vert(tmp.p[i], tmp.n[i], tmp.uv[i]))
        m.t.append(tuple(keep[i] for i in tri))
    d = engraving(mouse)
    rx0, ry0, rx1, ry1 = d["rect"]
    cxs, cys = (rx0 + rx1) / 2, (ry0 + ry1) / 2
    k = MOUSE_H / (ry1 - ry0 - 12)                                  # (the rect has 6 units of margin each side)
    fx = cx + side * hx                                             # the face plane
    def pt(sx, sy, depth=0.0):                                      # an svg point -> world; the viewer outside sees +z to the left on the +x face
        u = (sx - cxs) * k
        return (fx - side * depth, cy + (-(sy - cys) * k), zc - side * u)
    n_out = (float(side), 0.0, 0.0)
    def flat(points, normal, tris):
        base = [m.vert(p, normal, (0.0, 0.0)) for p in points]
        for a, b, c in zip(tris[0::3], tris[1::3], tris[2::3]):
            pa, pb, pc = points[a], points[b], points[c]
            e1 = tuple(pb[i] - pa[i] for i in range(3)); e2 = tuple(pc[i] - pa[i] for i in range(3))
            cr = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0])
            m.t.append((base[a], base[b], base[c]) if cr[0] * normal[0] > 0 else (base[a], base[c], base[b]))
    flat([pt(x, y) for x, y in d["surface"]["v"]], n_out, d["surface"]["t"])
    surf, m = m, groove                                             # the groove's floor and walls are a darker material of their own (the engraving reads better)
    flat([pt(x, y, MOUSE_DEPTH) for x, y in d["floor"]["v"]], n_out, d["floor"]["t"])
    for ring in d["walls"]:                                         # the walls face into the groove: the groove lies to the left of each ring edge (counter-clockwise outline)
        for i in range(len(ring)):
            (ax, ay), (bx, by) = ring[i], ring[(i + 1) % len(ring)]
            top_a, top_b, bot_a, bot_b = pt(ax, ay), pt(bx, by), pt(ax, ay, MOUSE_DEPTH), pt(bx, by, MOUSE_DEPTH)
            ex, ey = bx - ax, by - ay
            nl = math.hypot(ex, ey)
            if nl < 1e-9:
                continue
            lx, ly = -ey / nl, ex / nl                              # left normal in svg units (y down), into the groove
            w = (0.0, -ly * 1.0, -side * lx)                         # -> world: v = -y, u = x, z = zc - side*u
            vs = [m.vert(q, w, (0.0, 0.0)) for q in (top_a, top_b, bot_b, bot_a)]
            e1 = tuple(top_b[i] - top_a[i] for i in range(3)); e2 = tuple(bot_a[i] - top_a[i] for i in range(3))
            cr = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0])
            if cr[0] * w[0] + cr[1] * w[1] + cr[2] * w[2] > 0:
                m.quad(*vs)
            else:
                m.quad(vs[0], vs[3], vs[2], vs[1])
    # the rest of the face around the mouse's rectangle (four rectangles, shared edges)
    zl, zr = zc - side * (rx0 - cxs) * k, zc - side * (rx1 - cxs) * k
    z0, z1 = min(zl, zr), max(zl, zr)
    yb, yt = cy - (ry1 - cys) * k, cy - (ry0 - cys) * k
    zlo, zhi, ylo, yhi = cz - hz, cz + hz, cy - hy, cy + hy
    for (za, zb, ya, yb2) in ((zlo, z0, ylo, yhi), (z1, zhi, ylo, yhi), (z0, z1, ylo, yb), (z0, z1, yt, yhi)):
        if zb - za > 1e-6 and yb2 - ya > 1e-6:
            q = [surf.vert((fx, ya, za), n_out, (0, 0)), surf.vert((fx, ya, zb), n_out, (0, 0)), surf.vert((fx, yb2, zb), n_out, (0, 0)), surf.vert((fx, yb2, za), n_out, (0, 0))]
            surf.quad(*q) if side < 0 else surf.quad(q[0], q[3], q[2], q[1])
    return surf

RING_NODE = """    <Shape name="%s_ring%d" translation="%.3f %.3f %.3f" shapeId="3" dynamic="true" compound="true" density="0.0005" collisionFilterGroup="0x10004" collisionFilterMask="0xfe3ffb83" linearDamping="0.1" angularDamping="0.5" staticFriction="0.8" dynamicFriction="0.6" castsShadows="false" receiveShadows="false" nonRenderable="true" materialIds="5" clipDistance="300" nodeId="%d">
      <Shape name="link_vis" shapeId="4" castsShadows="true" receiveShadows="true" materialIds="5" clipDistance="300" nodeId="%d"/>
      <TransformGroup name="hitch%d" translation="0 0 %.3f" nodeId="%d"/>
    </Shape>"""

def u_lug(m, x, hz, side):
    """A staple welded to the end bar (side +1: the front, -1: the rear): two legs along z and a bar across x at LUG_LEN from the bar; the link ring hooks the bar."""
    for sx in (-1, 1):
        H.box(m, x + sx * (LUG_HALF_W - LUG_LEG), EYE_Y, side * (hz + LUG_LEN / 2), LUG_LEG, LUG_BAR, LUG_LEN / 2)
    H.box(m, x, EYE_Y, side * (hz + LUG_LEN), LUG_HALF_W, LUG_BAR, LUG_BAR)

def ring_ents():
    """The link ring: a torus standing in the y-z plane (it hooks lug bars that run along x), as its own body: a small collision box and the visual (shape ids 3 and 4)."""
    m = H.Mesh(); H.torus(m, 0, 0, 0, RING_R, RING_r, major=28, minor=8)
    m.p = [(z, y, -x) for x, y, z in m.p]; m.n = [(nz, ny, -nx) for nx, ny, nz in m.n]       # (a quarter turn about y: the torus faced +z, now it faces +x)
    P, N, U, T, subsets = H.merge([(m, 1)])
    vis = H.shape_entity("link_vis", 4, P, N, U, T, subsets, ["link"])
    b = H.Mesh(); H.box(b, 0, 0, 0, 0.0125, RING_R + RING_r, RING_R + RING_r)
    cp, cn, cu, ct, csub = H.merge([(b, 1)])
    body = H.shape_entity("link_body", 3, cp, cn, cu, ct, csub, ["link"], attachments=[(2, J.hull_block((0, 0, 0), (0.0125, RING_R + RING_r, RING_R + RING_r)))])
    return [body, vis]

def visual(bridge=False, eyes=True, hitches=True, eye_xs=None, hitch_xs=None):
    latch = H.Mesh()
    mouse = "mouse_wrench" if bridge else "mouse_funnel"                  # the bridge pieces hold a wrench, the selling plate a funnel
    iron, eye, hook, groove = H.Mesh(), H.Mesh(), H.Mesh(), H.Mesh()
    paint = H.Mesh()
    hx, hz = W / 2, L / 2
    # the frame: four bars (front and back across, left and right along)
    H.box(iron, 0, HT / 2, hz - FRAME / 2, hx, HT / 2, FRAME / 2)
    H.box(iron, 0, HT / 2, -hz + FRAME / 2, hx, HT / 2, FRAME / 2)
    inner_z = hz - FRAME
    # the TOP of the frame: a white painted line on each bar (3 mm proud), so a piece lying upside down is seen at once
    pw = FRAME * 0.3
    H.box(paint, 0, HT + 0.0015, hz - FRAME / 2, hx - 0.02, 0.0015, pw)
    H.box(paint, 0, HT + 0.0015, -hz + FRAME / 2, hx - 0.02, 0.0015, pw)
    H.box(paint, hx - FRAME / 2, HT + 0.0015, 0, pw, 0.0015, inner_z)
    H.box(paint, -hx + FRAME / 2, HT + 0.0015, 0, pw, 0.0015, inner_z)
    zc = -inner_z + 0.4 + 0.5 * MOUSE_H                                  # the mouse sits near the rear end of each side, on the outer face
    engraved_bar(iron, hx - FRAME / 2, HT / 2, 0, FRAME / 2, HT / 2, inner_z, 1, zc, mouse, groove)
    engraved_bar(iron, -hx + FRAME / 2, HT / 2, 0, FRAME / 2, HT / 2, inner_z, -1, zc, mouse, groove)
    # the bearing bars along z, tops flush with the frame
    n = int(round((W - 2 * FRAME) / PITCH))
    x0 = -hx + FRAME + (W - 2 * FRAME - (n - 1) * PITCH) / 2
    for i in range(n):
        H.box(iron, x0 + i * PITCH, HT - BAR_H / 2, 0, BAR_T / 2, BAR_H / 2, inner_z)
    # the cross rods along x, near the top
    m = int(round(2 * inner_z / CROSS_PITCH))
    for j in range(m + 1):
        z = -inner_z + j * (2 * inner_z / m)
        H.box(iron, 0, HT - CROSS_H / 2, z, hx - FRAME, CROSS_H / 2, CROSS_T / 2)
    # the towing eyes: a lug welded to the front bar and a ring through it (the ring faces +z)
    for x in ((eye_xs if eye_xs is not None else EYE_X) if eyes else ()):
        if bridge:
            u_lug(eye, x, hz, 1)
        else:
            H.box(eye, x, EYE_Y, hz + 0.045, 0.05, 0.035, 0.045)
            H.torus(eye, x, EYE_Y, hz + 0.13, 0.065, 0.016, major=20, minor=8)
    if bridge and hitches:                                         # the hitches at the far end: the same U lug (green); the link ring that hooks it is a body of its own (ring_ents)
        for x in (hitch_xs if hitch_xs is not None else EYE_X):
            u_lug(hook, x, hz, -1)
    if bridge:
        for z in LATCH_Z.get(round(L, 1), ()):
            for side in (-1, 1):
                xb = side * (W / 2 + LUG_LEN)
                for sz in (-1, 1):
                    H.box(latch, side * (W / 2 + LUG_LEN / 2), EYE_Y, z + sz * (LUG_HALF_W - LUG_LEG), LUG_LEN / 2, LUG_BAR, LUG_LEG)
                H.box(latch, xb, EYE_Y, z, LUG_BAR, LUG_BAR, LUG_HALF_W)
                H.torus(latch, xb + side * (LATCH_R - LATCH_r - LUG_BAR), EYE_Y, z, LATCH_R, LATCH_r, major=20, minor=8)
    return iron, eye, hook, groove, latch, paint

def shape_ents(bridge=False, eyes=True, hitches=True, eye_xs=None, hitch_xs=None):
    iron, eye, hook, groove, latch, paint = visual(bridge, eyes, hitches, eye_xs, hitch_xs)
    if bridge:                                                              # materials: iron, the eyes (orange), the hitches (green), the grooves, the winch latches (yellow), the paint, the lifting lug (red)
        lift = H.Mesh()                                                     # the lifting lug: a ring lying flat on the grid at the middle (what a pipe layer's spreader or a telehandler's hook takes): a torus turned 90 degrees about x (no mirror: the winding stays)
        H.torus(lift, 0, 0, 0, LIFT_R, LIFT_r, major=20, minor=8)
        lift.p = [(q[0], -q[2] + HT + LIFT_r, q[1]) for q in lift.p]
        lift.n = [(q[0], -q[2], q[1]) for q in lift.n]
        P, N, U, T, subsets = H.merge([(iron, 1), (eye, 2), (hook, 3), (groove, 4), (latch, 5), (paint, 6), (lift, 7)])
        ents = [H.shape_entity("sellingPlate_vis", 1, P, N, U, T, subsets, ["iron", "eye", "hitch", "groove", "latch", "paint", "lift"])]
    else:
        P, N, U, T, subsets = H.merge([(iron, 1), (eye, 2), (groove, 3), (paint, 4)])
        ents = [H.shape_entity("sellingPlate_vis", 1, P, N, U, T, subsets, ["iron", "eye", "groove", "paint"])]
    def hull_box(name, sid, c, h):
        m = H.Mesh(); H.box(m, c[0], c[1], c[2], h[0], h[1], h[2])
        cp, cn, cu, ct, csub = H.merge([(m, 1)])
        return H.shape_entity(name, sid, cp, cn, cu, ct, csub, ["iron"], attachments=[(2, J.hull_block(c, h))])
    ents.append(hull_box("sellingPlate_body", 2, (0, HT / 2, 0), (W / 2, HT / 2, L / 2)))                     # the root: one flat box
    if bridge:
        return ents
    ents.append(hull_box("sellingPlate_exactFill", 3, (0, 0, 0), (W / 2 - 0.1, 0.01, L / 2 - 0.1)))              # trailers tip onto this (thin slab just above the grid)
    ents.append(hull_box("sellingPlate_trigger", 4, (0, 0, 0), (W / 2 - 0.05, TRIGGER_H, L / 2 - 0.05)))             # pallets, bales and logs on the plate, piled up to 2 x TRIGGER_H above it
    ents.append(hull_box("sellingPlate_playerTrigger", 5, (0, 0, 0), (W / 2 + 1.0, 1.0, L / 2 + 1.0)))           # the player standing next to the plate: the key that sells the logs on it
    return ents

def write(out):
    ents = shape_ents()
    hdr = type("Hd", (), {"version": 10, "seed": 73})()
    sf = type("SF", (), {"header": hdr, "entities": [H.Raw(1, e) for e in ents]})()
    S.write(os.path.join(out, "sellingPlate.i3d.shapes"), sf)
    hz = L / 2
    joints = "\n".join('      <TransformGroup name="attacherJoint%d" translation="%.3f %.3f %.3f" nodeId="%d"/>' % (i + 1, x, EYE_Y, hz + 0.13, 10 + i) for i, x in enumerate(EYE_X))
    xml = f'''<?xml version="1.0" encoding="iso-8859-1"?>

<i3D name="sellingPlate" version="1.6" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://i3d.giants.ch/schema/i3d-1.6.xsd">
  <Asset>
    <Export program="make_selling_plate.py" version="1"/>
  </Asset>
  <Files/>
  <Materials>
    <Material name="iron" materialId="1" diffuseColor="0.30 0.31 0.33 1" specularColor="0.45 0.45 0.45"/>
    <Material name="eye" materialId="2" diffuseColor="0.85 0.42 0.05 1" specularColor="0.3 0.3 0.3"/>
    <Material name="groove" materialId="3" diffuseColor="0.11 0.115 0.125 1" specularColor="0.15 0.15 0.15"/>
    <Material name="paint" materialId="4" diffuseColor="0.92 0.92 0.88 1" specularColor="0.2 0.2 0.2"/>
  </Materials>
  <Shapes externalShapesFile="sellingPlate.i3d.shapes">
  </Shapes>
  <Scene>
    <Shape name="sellingPlate_main_component1" shapeId="2" dynamic="true" compound="true" density="0.0005" collisionFilterGroup="0x10004" collisionFilterMask="0xfe3ffb83" linearDamping="0.1" angularDamping="0.5" staticFriction="0.8" dynamicFriction="0.6" castsShadows="false" receiveShadows="false" nonRenderable="true" materialIds="1" clipDistance="300" nodeId="1">
      <Shape name="sellingPlate_vis" shapeId="1" castsShadows="true" receiveShadows="true" materialIds="1,2,3,4" clipDistance="300" nodeId="2"/>
      <Shape name="exactFillRootNode" translation="0 {HT + 0.012:.3f} 0" shapeId="3" kinematic="true" compound="true" collisionFilterGroup="0x40000000" collisionFilterMask="0x20000000" castsShadows="false" receiveShadows="false" nonRenderable="true" materialIds="1" nodeId="3"/>
      <Shape name="palletTrigger" translation="0 {HT + TRIGGER_H:.3f} 0" shapeId="4" kinematic="true" compound="true" trigger="true" collisionFilterGroup="0x20000000" collisionFilterMask="0x10000" castsShadows="false" receiveShadows="false" nonRenderable="true" materialIds="1" nodeId="4"/>
      <Shape name="baleTrigger" translation="0 {HT + TRIGGER_H:.3f} 0" shapeId="4" kinematic="true" compound="true" trigger="true" collisionFilterGroup="0x20000000" collisionFilterMask="0x50000" castsShadows="false" receiveShadows="false" nonRenderable="true" materialIds="1" nodeId="5"/>
      <Shape name="woodTrigger" translation="0 {HT + TRIGGER_H:.3f} 0" shapeId="4" kinematic="true" compound="true" trigger="true" collisionFilterGroup="0x20000000" collisionFilterMask="0x800" castsShadows="false" receiveShadows="false" nonRenderable="true" materialIds="1" nodeId="6"/>
      <Shape name="woodSellPlayerTrigger" translation="0 1.0 0" shapeId="5" kinematic="true" compound="true" trigger="true" collisionFilterGroup="0x20000000" collisionFilterMask="0x100000" castsShadows="false" receiveShadows="false" nonRenderable="true" materialIds="1" nodeId="7"/>
{joints}
    </Shape>
  </Scene>

</i3D>
'''
    open(os.path.join(out, "sellingPlate.i3d"), "w", encoding="iso-8859-1").write(xml)
    print("wrote sellingPlate with %d shape entities" % len(ents))

LOCK_X, LOCK_Z = 0.9, 1.0          # the clamps of a locked grate: over each steel profile (x = +-0.9, BridgeLink.BEAM_OFFSET_M), 1 m either side of the middle
def lock_ent():
    """The clamps (hidden until the grate is pinned: HandToolHammer.setPinVisuals, node bridgeGrate_lock): per profile and place a plate on top of the grid with two nuts, two J rods and a foot bar under the profile (the profile: top 5 cm under the
    grate's bottom, 12 cm high). The rods go through the GAPS of the grid (a bolt through a bearing bar or a cross rod would be one weak point that every movement pulls on until it breaks): x at the centre of a gap between two bearing bars,
    z at the middle of a mesh between two cross rods."""
    m = H.Mesh()
    hx, inner_z = W / 2, L / 2 - FRAME
    n = int(round((W - 2 * FRAME) / PITCH))
    x0 = -hx + FRAME + (W - 2 * FRAME - (n - 1) * PITCH) / 2
    gaps = [x0 + (i + 0.5) * PITCH for i in range(n - 1)]                     # the centres of the gaps between the bearing bars
    mc = int(round(2 * inner_z / CROSS_PITCH))
    step = 2 * inner_z / mc
    cells = [-inner_z + (j + 0.5) * step for j in range(mc)]                  # the middles between the cross rods
    for sx in (-1, 1):
        for sz in (-1, 1):
            cz = min(cells, key=lambda c: abs(c - sz * LOCK_Z))
            for side in (-1, 1):                                                              # one single-bolt clamp on each edge of the profile, like a grating clip: a saddle plate over the gap, one bolt in the gap, a hook under the flange
                rx = sorted(gaps, key=lambda g: abs(g - (sx * LOCK_X + side * 0.078)))[0]
                toward = -side                                                                # the hook reaches in, under the flange
                H.box(m, rx, HT + 0.004, cz, 0.045, 0.004, 0.03)                              # the saddle plate: rests on the bars either side of the gap
                H.cylinder(m, rx, cz, -0.184, HT + 0.008, 0.004, sides=8)                     # the bolt, in the gap (no bar, no cross rod: nothing drilled)
                H.cylinder(m, rx, cz, HT + 0.008, HT + 0.02, 0.012, sides=6)                  # the nut
                H.box(m, rx + toward * 0.035, -0.178, cz, 0.045, 0.006, 0.015)                # the hook: a foot bar under the profile's lower flange
    p_, n_, u_, t_, sub_ = H.merge([(m, 4)])
    return H.shape_entity("bridgeGrate_lock", 5, p_, n_, u_, t_, sub_, ["groove"])

LIFT_TYPES = ("wheelLoader", "telehandler", "bigBag")
BRIDGE_X = (-1.0, 1.0)             # two joints per end for the bridge pieces (the middle one is gone): the second pair is joined by BridgeLink.lua, the game's attach takes only one
BRIDGE_PARTS = [     # name, title, length (m), eye x positions, hitch x positions, mass (kg), price, text   (an empty tuple: none at that end)
    ("bridgeGrate", "Bridge grate", 4.0, BRIDGE_X, BRIDGE_X, 500, 900, "A flat iron grid with two towing eyes (orange) at one end and two hitches (green) at the other: hitch grates end to end (a tractor's hitch, or the hand winch: hook a joint, the fitting one of the next grate is chosen for you) and fix the outer ones, or the two end pieces, with the Sandbox Hammer to span a gap. Every hitch is a blue link ring hooked on a U lug: it swings and has a little leeway, so the pieces need not lie flush on uneven ground. The game's attach joins two grates with one joint, a second joint of ours takes the other pair: two points hold a grate level for a tractor. Left Shift and a click with the hand winch unhitches."),
    ("bridgeStart", "Bridge start piece", 1.6, (0.0,), BRIDGE_X, 600, 400, "The short grate for the near bank of a bridge: two hitches (green) for the first bridge grate, and one iron ring (orange) at the other end to drag the whole assembly from. Pin it with the Sandbox Hammer, then hitch the first bridge grate to it. Free it weighs like a grate (you can drag it); pinned with the Hammer it becomes 3 t on purpose, so the bridge hanging off it cannot pull it off the bank."),
    ("bridgeEnd", "Bridge end piece", 1.6, BRIDGE_X, (0.0,), 600, 400, "The short grate for the far bank of a bridge: two towing eyes (orange) for the last bridge grate, and one hitch (green) at the other end to drag the whole assembly from. Hitch it to the last bridge grate and pin it with the Sandbox Hammer. Free it weighs like a grate (you can drag it); pinned with the Hammer it becomes 3 t on purpose, so the bridge hanging off it cannot pull it off the bank."),
]

def write_static_twin(name, title, length, out):
    """The baked twin of a bridge piece (FS25_Hammer BridgeBake.lua): a static placeable with the SAME shapes file: the look, the hull as a static collision shape, the link rings and the clips as pure looks
    (perfectly aligned, they do nothing), a test and a clear area. vehicles/<name>/<name>_static.i3d and <name>_placeable.xml, next to the vehicle's own files (one directory: the shapes file is found without a ../)."""
    import re
    od = os.path.join(out, name)
    vtxt = open(os.path.join(od, name + ".i3d"), encoding="iso-8859-1").read()
    head = vtxt[:vtxt.index("<Scene>")]
    head = re.sub(r'<Asset>.*?</Asset>', '<Asset>\n    <Export program="make_selling_plate.py" version="1"/>\n  </Asset>', head, flags=re.S)
    head = head.replace('i3D name="%s"' % name, 'i3D name="%s_static"' % name)
    rings = re.findall(r'name="%s_ring\d+" translation="([^"]+)"' % name, vtxt)
    hz, W_ = length / 2, 3.0
    nid = [1]
    def nxt():
        nid[0] += 1
        return nid[0]
    lines = []
    lines.append('    <TransformGroup name="%s_static" nodeId="1">' % name)
    lines.append('      <TransformGroup name="clearAreas" nodeId="%d">' % nxt())
    lines.append('        <TransformGroup name="clearArea1Start" translation="%.3f 0 %.3f" nodeId="%d">' % (-W_ / 2, -hz, nxt()))
    lines.append('          <TransformGroup name="clearArea1Width" translation="%.3f 0 0" nodeId="%d"/>' % (W_, nxt()))
    lines.append('          <TransformGroup name="clearArea1Height" translation="0 0 %.3f" nodeId="%d"/>' % (length, nxt()))
    lines.append('        </TransformGroup>')
    lines.append('      </TransformGroup>')
    lines.append('      <TransformGroup name="testAreas" nodeId="%d">' % nxt())
    lines.append('        <TransformGroup name="testArea1Start" translation="%.3f 0 %.3f" nodeId="%d">' % (-W_ / 2, -hz, nxt()))
    lines.append('          <TransformGroup name="testArea1End" translation="%.3f 0 %.3f" nodeId="%d"/>' % (W_, length, nxt()))
    lines.append('        </TransformGroup>')
    lines.append('      </TransformGroup>')
    lines.append('      <TransformGroup name="mesh" nodeId="%d">' % nxt())
    lines.append('        <Shape name="%s_vis" shapeId="1" static="true" castsShadows="true" receiveShadows="true" materialIds="1,2,3,4,6,7,8" clipDistance="300" nodeId="%d"/>' % (name, nxt()))
    lines.append('        <Shape name="col" shapeId="2" static="true" density="0" collisionFilterGroup="0x3e" collisionFilterMask="0xfffffbff" castsShadows="false" receiveShadows="false" nonRenderable="true" materialIds="1" nodeId="%d"/>' % nxt())
    for i, tr in enumerate(rings):
        lines.append('        <Shape name="ring%d" translation="%s" shapeId="4" static="true" castsShadows="true" receiveShadows="true" materialIds="5" clipDistance="300" nodeId="%d"/>' % (i + 1, tr, nxt()))
    if name == "bridgeGrate":
        lines.append('        <Shape name="clips" shapeId="5" static="true" castsShadows="true" receiveShadows="true" materialIds="4" clipDistance="300" nodeId="%d"/>' % nxt())
    lines.append('      </TransformGroup>')
    lines.append('    </TransformGroup>')
    xml = head + "<Scene>\n" + "\n".join(lines) + "\n  </Scene>\n\n</i3D>\n"
    open(os.path.join(od, name + "_static.i3d"), "w", encoding="iso-8859-1").write(xml)
    px = f'''<?xml version="1.0" encoding="utf-8" standalone="no" ?>
<placeable type="simplePlaceable" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="../../../../../shared/xml/schema/placeable.xsd">
    <annotation>{title}, baked (FS25_Hammer BridgeBake.lua), made by tools/make_selling_plate.py: the static twin of the vehicle.</annotation>

    <storeData>
        <name>{title} (baked)</name>
        <image>vehicles/{name}/store_{name}.dds</image>
        <price>0</price>
        <functions>
            <function>The baked form of a bridge piece: made by the Hammer's bake command, never bought.</function>
        </functions>
        <lifetime>1000</lifetime>
        <dailyUpkeep>0</dailyUpkeep>
        <rotation>0</rotation>
        <brand>NONE</brand>
        <species>placeable</species>
        <category>misc</category>
        <canBeSold>false</canBeSold>
        <showInStore>false</showInStore>
        <vertexBufferMemoryUsage>0</vertexBufferMemoryUsage>
        <indexBufferMemoryUsage>0</indexBufferMemoryUsage>
        <textureMemoryUsage>0</textureMemoryUsage>
        <audioMemoryUsage>0</audioMemoryUsage>
        <instanceVertexBufferMemoryUsage>0</instanceVertexBufferMemoryUsage>
        <instanceIndexBufferMemoryUsage>0</instanceIndexBufferMemoryUsage>
    </storeData>

    <base>
        <filename>vehicles/{name}/{name}_static.i3d</filename>
        <boughtWithFarmland>false</boughtWithFarmland>
        <canBeRenamed>false</canBeRenamed>
    </base>

    <placement useRandomYRotation="false" useManualYRotation="true">
        <testAreas>
            <testArea startNode="testArea1Start" endNode="testArea1End" />
        </testAreas>
    </placement>

    <clearAreas>
        <clearArea startNode="clearArea1Start" widthNode="clearArea1Width" heightNode="clearArea1Height"/>
    </clearAreas>

    <indoorAreas />

    <tipOcclusionUpdateAreas />

    <i3dMappings>
        <i3dMapping id="clearAreas" node="0>0" />
        <i3dMapping id="clearArea1Start" node="0>0|0" />
        <i3dMapping id="clearArea1Width" node="0>0|0|0" />
        <i3dMapping id="clearArea1Height" node="0>0|0|1" />
        <i3dMapping id="testAreas" node="0>1" />
        <i3dMapping id="testArea1Start" node="0>1|0" />
        <i3dMapping id="testArea1End" node="0>1|0|0" />
    </i3dMappings>

</placeable>
'''
    open(os.path.join(od, name + "_placeable.xml"), "w", encoding="utf-8").write(px)

def write_bridge(out):
    """The bridge pieces: the same grid and frame as the plate, no selling station; three towing eyes at the front end (input joints) and three hitches at the rear end (output joints) that take another grate's eye. The two end pieces are short and have only one of the two."""
    global L
    keep = L
    try:
        for name, title, length, eye_xs, hitch_xs, mass, price, text in BRIDGE_PARTS:
            L = length
            eyes_on, hitches_on = len(eye_xs) > 0, len(hitch_xs) > 0
            ents = shape_ents(bridge=True, eyes=eyes_on, hitches=hitches_on, eye_xs=eye_xs, hitch_xs=hitch_xs)
            if hitches_on:
                ents += ring_ents()                                 # shape ids 3 (the ring's body) and 4 (its visual)
            if name == "bridgeGrate":
                ents.append(lock_ent())                             # shape id 5
            hdr = type("Hd", (), {"version": 10, "seed": 79})()
            sf = type("SF", (), {"header": hdr, "entities": [H.Raw(1, e) for e in ents]})()
            od = os.path.join(out, name); os.makedirs(od, exist_ok=True)
            S.write(os.path.join(od, name + ".i3d.shapes"), sf)
            hz = L / 2
            kids, idx, nid = ['      <Shape name="%s_vis" shapeId="1" castsShadows="true" receiveShadows="true" materialIds="1,2,3,4,6,7,8" clipDistance="300" nodeId="2"/>' % name], 1, 4
            maps = ['        <i3dMapping id="%s_main_component1" node="0>" />' % name]
            eye_xml, hitch_xml, rings, joint_xml, comp_xml = [], [], [], [], []
            if eyes_on:                                                    # (the bridge's own eyes first: BridgeLink counts input joints by index, the lifting joints come after them)
                for i, x in enumerate(eye_xs):
                    kids.append('      <TransformGroup name="attacherJoint%d" translation="%.3f %.3f %.3f" nodeId="%d"/>' % (i + 1, x, EYE_Y, hz + LUG_LEN, nid)); maps.append('        <i3dMapping id="attacherJoint%d" node="0>%d" />' % (i + 1, idx)); idx += 1; nid += 1
                    eye_xml.append('            <inputAttacherJoint node="attacherJoint%d" jointType="trailer" attacherHeight="0.3" />' % (i + 1))
            if eyes_on:
                for k, jt in enumerate(LIFT_TYPES):                    # the lifting joints: a pipe layer's spreader holds a pipe at ONE point, the middle, with a joint of type wheelLoader or telehandler (pipeTraverse xml of FSM_Pipe_Layer_Pack), a big bag lifter with bigBag
                    kids.append('      <TransformGroup name="lift%d" translation="0 %.3f 0" nodeId="%d"/>' % (k + 1, HT, nid)); maps.append('        <i3dMapping id="lift%d" node="0>%d" />' % (k + 1, idx)); idx += 1; nid += 1
                    eye_xml.append('            <inputAttacherJoint node="lift%d" jointType="%s"%s />' % (k + 1, jt, ' hardAttach="true"' if jt != "bigBag" else ""))
            if hitches_on:
                for i, x in enumerate(hitch_xs):                       # per hitch: a joint node on the lug bar (the component joint of the ring), and the ring as its own component with the hitch node at its far end
                    kids.append('      <TransformGroup name="ringJoint%d" translation="%.3f %.3f %.3f" nodeId="%d"/>' % (i + 1, x, EYE_Y, -hz - LUG_LEN, nid)); maps.append('        <i3dMapping id="ringJoint%d" node="0>%d" />' % (i + 1, idx)); idx += 1; nid += 1
                    comp = len(rings) + 2
                    rings.append(RING_NODE % (name, i + 1, x, EYE_Y, -hz - LUG_LEN - RING_REACH, nid, nid + 1, i + 1, -RING_REACH, nid + 2))
                    maps.append('        <i3dMapping id="hitch%d" node="%d>1" />' % (i + 1, comp - 1)); nid += 3
                    comp_xml.append('            <component centerOfMass="0 0 0" solverIterationCount="30" mass="%d"/>' % RING_MASS)
                    joint_xml.append('            <joint component1="1" component2="%d" node="ringJoint%d" rotLimit="%s" transLimit="%s" enableCollision="false"/>' % (comp, i + 1, RING_ROT, RING_TRANS))
                    hitch_xml.append('        <attacherJoint node="hitch%d" jointType="trailer" lowerRotLimit="%s" lowerTransLimit="%s" lockDownTransLimit="false" allowsJointLimitMovement="false" />' % (i + 1, RING_ROT, RING_TRANS))
            latch_xml = []
            for i, z in enumerate([z for z in LATCH_Z.get(round(L, 1), ()) for _ in (0, 1)]):
                side = -1 if i % 2 == 0 else 1
                kids.append('      <TransformGroup name="latch%d" translation="%.3f %.3f %.3f" nodeId="%d"/>' % (i + 1, side * (W / 2 + LUG_LEN + 2 * LATCH_R - LATCH_r - LUG_BAR), EYE_Y, z, nid)); maps.append('        <i3dMapping id="latch%d" node="0>%d" />' % (i + 1, idx)); idx += 1; nid += 1
                latch_xml.append('        <attacherJoint node="latch%d" jointType="winchLatch" />' % (i + 1))
            if name == "bridgeGrate":
                kids.append('      <Shape name="bridgeGrate_lock" shapeId="5" visibility="false" castsShadows="true" receiveShadows="true" materialIds="4" clipDistance="300" nodeId="%d"/>' % nid); maps.append('        <i3dMapping id="lock" node="0>%d" />' % idx); idx += 1; nid += 1
            xml = f'''<?xml version="1.0" encoding="iso-8859-1"?>

<i3D name="{name}" version="1.6" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://i3d.giants.ch/schema/i3d-1.6.xsd">
  <Asset>
    <Export program="make_selling_plate.py" version="1"/>
  </Asset>
  <Files/>
  <Materials>
    <Material name="iron" materialId="1" diffuseColor="0.30 0.31 0.33 1" specularColor="0.45 0.45 0.45"/>
    <Material name="eye" materialId="2" diffuseColor="0.85 0.42 0.05 1" specularColor="0.3 0.3 0.3"/>
    <Material name="hitch" materialId="3" diffuseColor="0.10 0.62 0.25 1" specularColor="0.3 0.3 0.3"/>
    <Material name="groove" materialId="4" diffuseColor="0.11 0.115 0.125 1" specularColor="0.15 0.15 0.15"/>
    <Material name="link" materialId="5" diffuseColor="0.16 0.30 0.78 1" specularColor="0.5 0.5 0.5"/>
    <Material name="latch" materialId="6" diffuseColor="0.95 0.78 0.05 1" specularColor="0.3 0.3 0.3"/>
    <Material name="paint" materialId="7" diffuseColor="0.92 0.92 0.88 1" specularColor="0.2 0.2 0.2"/>
    <Material name="lift" materialId="8" diffuseColor="0.78 0.08 0.08 1" specularColor="0.35 0.35 0.35"/>
  </Materials>
  <Shapes externalShapesFile="{name}.i3d.shapes">
  </Shapes>
  <Scene>
    <Shape name="{name}_main_component1" shapeId="2" dynamic="true" compound="true" density="0.0005" collisionFilterGroup="0x10004" collisionFilterMask="0xfe3ffb83" linearDamping="0.3" angularDamping="2" staticFriction="0.8" dynamicFriction="0.6" castsShadows="false" receiveShadows="false" nonRenderable="true" materialIds="1" clipDistance="300" nodeId="1">
{chr(10).join(kids)}
    </Shape>
{chr(10).join(rings)}
  </Scene>

</i3D>
'''
            open(os.path.join(od, name + ".i3d"), "w", encoding="iso-8859-1").write(xml)
            attach = ("\n    <attachable>\n        <inputAttacherJoints>\n" + "\n".join(eye_xml) + "\n        </inputAttacherJoints>\n    </attachable>\n") if eyes_on else ""
            joints = ("\n    <!-- the hitches at the rear end sit on the link rings (bodies of their own, hooked on the lug bars by the component joints above): a ring swings freely about its bar and has a little leeway, so pieces need not lie flush on uneven ground -->\n    <attacherJoints>\n" + "\n".join(hitch_xml) + "\n" + "\n".join(latch_xml) + "\n    </attacherJoints>\n") if hitches_on else ""
            vx = f'''<?xml version="1.0" encoding="utf-8" standalone="no" ?>
<vehicle type="{name}" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="../../../../shared/xml/schema/vehicle.xsd">
    <annotation>{title} (FS25_Hammer), made by tools/make_selling_plate.py.</annotation>

    <storeData>
        <name>
            <en>{title}</en>
        </name>
        <functions>
            <function>{text}</function>
        </functions>
        <image>vehicles/{name}/store_{name}.dds</image>
        <price>{price}</price>
        <lifetime>1000</lifetime>
        <category>SANDBOX_WORKS</category>
        <brand>NONE</brand>
        <showInStore>true</showInStore>
        <canBeSold>true</canBeSold>
        <allowLeasing>false</allowLeasing>
        <financeCategory>OTHER</financeCategory>
        <vertexBufferMemoryUsage>0</vertexBufferMemoryUsage>
        <indexBufferMemoryUsage>0</indexBufferMemoryUsage>
        <textureMemoryUsage>0</textureMemoryUsage>
        <instanceVertexBufferMemoryUsage>0</instanceVertexBufferMemoryUsage>
        <instanceIndexBufferMemoryUsage>0</instanceIndexBufferMemoryUsage>
        <storeIconRendering>
            <settings cameraXRot="-35" cameraYRot="35" />
        </storeIconRendering>
        <audioMemoryUsage>0</audioMemoryUsage>
    </storeData>

    <base>
        <typeDesc>{title}</typeDesc>
        <filename>vehicles/{name}/{name}.i3d</filename>
        <size width="3.2" length="{length + 0.4:.1f}" height="0.3" lengthOffset="0"/>
        <canBeReset>true</canBeReset>
        <supportsPickUp>true</supportsPickUp>
        <components maxMass="{max(4000, mass + 2000) if name == "bridgeGrate" else 40000}">
            <component centerOfMass="0 0.06 0" solverIterationCount="10" mass="{mass}"/>
{chr(10).join(comp_xml)}
{chr(10).join(joint_xml)}
        </components>
        <showInVehicleMenu>true</showInVehicleMenu>
        <mapHotspot available="false" />
        <input allowed="false"/>
    </base>
{joints}{attach}
    <i3dMappings>
{chr(10).join(maps)}
    </i3dMappings>
</vehicle>
'''
            open(os.path.join(od, name + ".xml"), "w", encoding="utf-8").write(vx)
            write_static_twin(name, title, length, out)
            print("wrote %s: %.1f m, eyes %s, hitches %s" % (name, length, list(eye_xs), list(hitch_xs)))
    finally:
        L = keep

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "vehicles", "sellingPlate")
    os.makedirs(out, exist_ok=True)
    write(out)
    write_bridge(os.path.join(out, ".."))
