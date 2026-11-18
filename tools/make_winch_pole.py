#!/usr/bin/env python3
"""The winch pole and the winch anchor as shop vehicles (FS25_Hammer). The pole: a wide iron base plate with an upright post and winch latches (yellow, the same latch as on the bridge grates: a winch takes it, the game's attach never does) and one towing eye (orange) on the plate to drag it with.
  python3 tools/make_winch_pole.py [out dir]      -> vehicles/winchPole/winchPole.i3d, .i3d.shapes, .xml and vehicles/winchAnchor/... (the anchor: a small plate with one upright ring standing right on it, the same four bolts, no post)
Free it is a light dynamic object that stands on its plate (drag it by the eye with a tractor or the hand winch, put it where you want); pinned with the Sandbox Hammer it weighs 3 t (HandToolHammer.PIN_MASS_T) and is held by the pin joint.
Collision: the plate is the root box, the post a compound child box. The mask lacks the VEHICLE bit (0x10000, 0xfe3efb83: the earlier 0xfe2ffb83 removed the PLAYER bit by mistake): a bridge piece, a tractor and anything else in that group passes through it (a pinned pole plate touching a pinned start piece shook the whole chain at a load, 2026-11-17); the player, the hands, a horse, the terrain and objects still touch it. Origin = the plate's bottom, front = +z (the eye). Materials: 1 iron, 2 the eye, 3 groove (the mouse, nearly black), 4 the latches, 5 the anchor bolts (dark steel)."""
import math, os, sys
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import make_selling_plate as M
H, J, S = M.H, M.J, M.S

BASE_H = 0.12                         # the plate is as high as the bridge frames (the engraved mouse is 9.5 cm)
EYE_Y = 0.07
# per part: plate half width, the post (round, radius and top; None = a short square pedestal instead), the latches (side along x, height), mass, bolt inset from the plate edge, shop text
PARTS = {
    "winchPole": dict(half=0.55, post=(0.07, 2.2), col_post=True, latches=[(1, 1.90), (-1, 1.90), (1, 0.45)], turn=False, mass=120, inset=0.14, price=300, title="Winch pole", mouse_h=None,
        text="A wide iron plate with an upright post and three winch latches (yellow: two at the top on opposite sides, one low). Light enough to carry in your hands (the hands tool takes up to 200 kg), or drag it by the orange eye on the plate (a tractor, or the hand winch): stand it where you want it, and pin it with the Sandbox Hammer: pinned it weighs 3 t, cannot be lifted and does not move, so a winch can pull a bridge against it. Only a winch takes a latch (the tractor's winch rope, the hand winch)."),
    "winchAnchor": dict(half=0.35, post=(0.06, BASE_H), col_post=False, latches=[(1, BASE_H + 0.10)], turn=True, mass=60, inset=0.1, price=120, title="Winch anchor", mouse_h=None,
        text="A small iron plate with one winch latch (yellow), an upright ring standing right on the plate, flat on the ground: the anchor for a guy line or a winch pull where a pole is too much. Light enough to carry in your hands (the hands tool takes up to 200 kg), or drag it by the orange eye: lay it where you want it, and pin it with the Sandbox Hammer: four bolt heads appear, it weighs 3 t, cannot be lifted and does not move. Only a winch takes the latch (the tractor's winch rope, the hand winch)."),
}
CUR = "winchPole"
def C(key): return PARTS[CUR][key]

def visual():
    iron, eye, groove, latch, bolt = H.Mesh(), H.Mesh(), H.Mesh(), H.Mesh(), H.Mesh()
    half = C("half"); post_r, post_top = C("post")
    M.engraved_bar(iron, 0, BASE_H / 2, 0, half, BASE_H / 2, half, 1, 0.0, "mouse_anchor", groove)      # the plate, the anchor mouse (assets/mouse_anchor.png) on its +x face
    if CUR == "winchPole":
        H.cylinder(iron, 0, 0, BASE_H, post_top, post_r)
    elif post_top > BASE_H + 1e-6:
        H.box(iron, 0, (BASE_H + post_top) / 2, 0, post_r, (post_top - BASE_H) / 2, post_r)           # a pedestal (none for the anchor: the ring stands right on the plate, no lever arm)
    for sx in (-1, 1):                                                  # the anchor bolts: a hex head on a round washer at each corner, towards the ground
        for sz in (-1, 1):
            cx, cz = sx * (half - C("inset")), sz * (half - C("inset"))
            H.cylinder(bolt, cx, cz, BASE_H, BASE_H + 0.012, 0.075, sides=20)
            H.cylinder(bolt, cx, cz, BASE_H + 0.012, BASE_H + 0.062, 0.05, sides=6)
    # (no orange towing eye any more: the pole is carried by hand, or lifted by its winch latches)
    if C("turn"):                                                    # the anchor: an eye bolt, the ring stands upright right on the plate (its plane faces the side, x), its foot in a low collar
        H.box(latch, 0, post_top + 0.02, 0, 0.035, 0.02, 0.035)
        H.torus(latch, 0, post_top + 0.04 + M.LATCH_R - M.LATCH_r - 0.02, 0, M.LATCH_R, M.LATCH_r, major=20, minor=8)
        latch.p = [(-q[2] + 0.0, q[1], q[0]) for q in latch.p]
        latch.n = [(-q[2], q[1], q[0]) for q in latch.n]
        return iron, eye, groove, latch, bolt
    for side, y in C("latches"):                                     # a staple on the post (two legs along x, a bar across z) and a ring hung on it
        xb = side * (post_r + M.LUG_LEN)
        for sz in (-1, 1):
            H.box(latch, side * (post_r + M.LUG_LEN / 2), y, sz * (M.LUG_HALF_W - M.LUG_LEG), M.LUG_LEN / 2, M.LUG_BAR, M.LUG_LEG)
        H.box(latch, xb, y, 0, M.LUG_BAR, M.LUG_BAR, M.LUG_HALF_W)
        H.torus(latch, xb + side * (M.LATCH_R - M.LATCH_r - M.LUG_BAR), y, 0, M.LATCH_R, M.LATCH_r, major=20, minor=8)
    return iron, eye, groove, latch, bolt

def shapes():
    iron, eye, groove, latch, bolt = visual()
    P, N, U, T, subsets = H.merge([(iron, 1), (groove, 3), (latch, 4)])
    ents = [H.shape_entity(CUR + "_vis", 1, P, N, U, T, subsets, ["iron", "groove", "latch"])]
    def hull_box(name, sid, c, h):
        m = H.Mesh(); H.box(m, c[0], c[1], c[2], h[0], h[1], h[2])
        cp, cn, cu, ct, csub = H.merge([(m, 1)])
        return H.shape_entity(name, sid, cp, cn, cu, ct, csub, ["iron"], attachments=[(2, J.hull_block(c, h))])
    half = C("half"); post_r, post_top = C("post")
    ents.append(hull_box(CUR + "_base", 2, (0, BASE_H / 2, 0), (half, BASE_H / 2, half)))
    if C("col_post"):
        ents.append(hull_box(CUR + "_post", 3, (0, (BASE_H + post_top) / 2, 0), (post_r, (post_top - BASE_H) / 2, post_r)))
    bp, bn, bu, bt, bsub = H.merge([(bolt, 5)])                      # the anchor bolts: a node of their own, hidden until the Hammer pins the part (HandToolHammer.setPinVisuals)
    ents.append(H.shape_entity(CUR + "_bolts", 4 if C("col_post") else 3, bp, bn, bu, bt, bsub, ["bolt"]))
    return ents

_UNUSED_TEXT = "A wide iron plate with an upright post and three winch latches (yellow: two at the top on opposite sides, one low). Drag it by the orange eye on the plate (a tractor, or the hand winch), stand it where you want it, and pin it with the Sandbox Hammer: pinned it weighs 3 t and does not move, so a winch can pull a bridge against it. Only a winch takes a latch (the tractor's winch rope, the hand winch)."

def write(out, name):
    global CUR
    CUR = name
    TITLE, TEXT, MASS = C("title"), C("text"), C("mass")
    half = C("half"); post_r, post_top = C("post")
    os.makedirs(out, exist_ok=True)
    ents = shapes()
    hdr = type("Hd", (), {"version": 10, "seed": 83})()
    sf = type("SF", (), {"header": hdr, "entities": [H.Raw(1, e) for e in ents]})()
    S.write(os.path.join(out, name + ".i3d.shapes"), sf)
    kids = ['      <Shape name="%s_vis" shapeId="1" castsShadows="true" receiveShadows="true" materialIds="1,3,4" clipDistance="300" nodeId="2"/>' % name]
    nid, idx = 3, 1
    maps = ['        <i3dMapping id="%s_main_component1" node="0>" />' % name]
    if C("col_post"):
        kids.append('      <Shape name="%s_col2" shapeId="3" compoundChild="true" static="false" density="0.0005" collisionFilterGroup="0x10004" collisionFilterMask="0xfe3efb83" castsShadows="false" receiveShadows="false" nonRenderable="true" materialIds="1" nodeId="%d"/>' % (name, nid))
        nid += 1; idx += 1
    latch_xml = []
    for i, (side, y) in enumerate(C("latches")):
        x = side * (post_r + M.LUG_LEN + 2 * M.LATCH_R - M.LATCH_r - M.LUG_BAR)
        if C("turn"):
            x, y = 0.0, post_top + 0.04 + M.LATCH_R - M.LATCH_r - 0.02           # the node sits in the middle of the upright ring
        kids.append('      <TransformGroup name="latch%d" translation="%.3f %.3f 0" nodeId="%d"/>' % (i + 1, x, y, nid))
        maps.append('        <i3dMapping id="latch%d" node="0>%d" />' % (i + 1, idx))
        latch_xml.append('        <attacherJoint node="latch%d" jointType="winchLatch" />' % (i + 1))
        nid += 1; idx += 1
    kids.append('      <Shape name="%s_bolts" shapeId="%d" visibility="false" castsShadows="true" receiveShadows="true" materialIds="5" clipDistance="300" nodeId="%d"/>' % (name, 4 if C("col_post") else 3, nid))
    maps.append('        <i3dMapping id="bolts" node="0>%d" />' % idx)
    i3d = f'''<?xml version="1.0" encoding="iso-8859-1"?>

<i3D name="{name}" version="1.6" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://i3d.giants.ch/schema/i3d-1.6.xsd">
  <Asset>
    <Export program="make_winch_pole.py" version="2"/>
  </Asset>
  <Files/>
  <Materials>
    <Material name="iron" materialId="1" diffuseColor="0.30 0.31 0.33 1" specularColor="0.45 0.45 0.45"/>
    <Material name="eye" materialId="2" diffuseColor="0.85 0.42 0.05 1" specularColor="0.3 0.3 0.3"/>
    <Material name="groove" materialId="3" diffuseColor="0.015 0.015 0.02 1" specularColor="0.05 0.05 0.05"/>
    <Material name="latch" materialId="4" diffuseColor="0.95 0.78 0.05 1" specularColor="0.3 0.3 0.3"/>
    <Material name="bolt" materialId="5" diffuseColor="0.13 0.135 0.15 1" specularColor="0.6 0.6 0.6"/>
  </Materials>
  <Shapes externalShapesFile="{name}.i3d.shapes">
  </Shapes>
  <Scene>
    <Shape name="{name}_main_component1" shapeId="2" dynamic="true" compound="true" density="0.0005" collisionFilterGroup="0x10004" collisionFilterMask="0xfe3efb83" linearDamping="0.3" angularDamping="2" staticFriction="0.8" dynamicFriction="0.6" castsShadows="false" receiveShadows="false" nonRenderable="true" materialIds="1" clipDistance="300" nodeId="1">
{chr(10).join(kids)}
    </Shape>
  </Scene>

</i3D>
'''
    open(os.path.join(out, name + ".i3d"), "w", encoding="iso-8859-1").write(i3d)
    vx = f'''<?xml version="1.0" encoding="utf-8" standalone="no" ?>
<vehicle type="{name}" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="../../../../shared/xml/schema/vehicle.xsd">
    <annotation>{TITLE} (FS25_Hammer), made by tools/make_winch_pole.py.</annotation>

    <storeData>
        <name>
            <en>{TITLE}</en>
        </name>
        <functions>
            <function>{TEXT}</function>
        </functions>
        <image>vehicles/{name}/store_{name}.dds</image>
        <price>{C("price")}</price>
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
            <settings cameraXRot="-25" cameraYRot="35" />
        </storeIconRendering>
        <audioMemoryUsage>0</audioMemoryUsage>
    </storeData>

    <base>
        <typeDesc>{TITLE}</typeDesc>
        <filename>vehicles/{name}/{name}.i3d</filename>
        <size width="{2 * half + 0.2:.1f}" length="{2 * half + 0.4:.1f}" height="{post_top + 0.2:.1f}" lengthOffset="0"/>
        <canBeReset>true</canBeReset>
        <supportsPickUp>true</supportsPickUp>
        <components maxMass="4000">
            <component centerOfMass="0 {0.35 if C("col_post") else 0.08} 0" solverIterationCount="10" mass="{MASS}"/>
        </components>
        <showInVehicleMenu>true</showInVehicleMenu>
        <mapHotspot available="false" />
        <input allowed="false"/>
    </base>

    <!-- the winch latches: only a winch takes them (joint type winchLatch of FS25_Hammer) -->
    <attacherJoints>
{chr(10).join(latch_xml)}
    </attacherJoints>

    <i3dMappings>
{chr(10).join(maps)}
    </i3dMappings>
</vehicle>
'''
    open(os.path.join(out, name + ".xml"), "w", encoding="utf-8").write(vx)
    print("wrote %s: %d shape entities, %d latches" % (name, len(ents), len(C("latches"))))

if __name__ == "__main__":
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "vehicles")
    for name in PARTS:
        write(os.path.join(root, name), name)
