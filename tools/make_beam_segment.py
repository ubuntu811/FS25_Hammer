#!/usr/bin/env python3
"""The steel profile under a bridge (FS25_Hammer, scripts/vehicles/BridgeLink.lua beamBuild): one 4 m piece of an H profile (12 cm high, 12 cm wide, flanges 8 mm, web 6 mm) in an i3d with three nodes:
beamRoot (a kinematic compound root with a THIN collision slab on the top face), beamChild (a compound child of the same slab) and beamVisual (the H profile, no collision). The script clones one root and a child per unit (4 m), the visual
once per unit, scaled along its length to fit, and adds the root to physics as ONE body. Collision only on the TOP (2 cm slab): the panels rest on it, nothing else of the profile is solid. Group STATIC_OBJECT (0x2), the default mask (a bridge piece, a
vehicle, the player, the hands and a horse touch it).
  python3 tools/make_beam_segment.py      -> models/beamSegment.i3d and .i3d.shapes   (the shapes writer is FS25_HorseDynamics/tools)"""
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, "..", "..", "FS25_HorseDynamics", "tools"))
import make_hitching_post as H
import make_horse_jumps as J
import shapes_io as S

HB, HH, TF, TW, HL = 0.06, 0.06, 0.008, 0.006, 2.0       # half width, half height, flange, web (thickness), half length (a unit is 4 m: the engine cannot stretch a collision shape, so a long profile is a row of units; the visual is stretched to fit)
SLAB = 0.01                                                   # half thickness of the collision slab on the top face
col = H.Mesh(); H.box(col, 0, HH - SLAB, 0, HB, SLAB, HL)
cp, cn, cu, ct, csub = H.merge([(col, 1)])
colent = H.shape_entity("beamTop", 1, cp, cn, cu, ct, csub, ["steel"], attachments=[(2, J.hull_block((0, HH - SLAB, 0), (HB, SLAB, HL)))])
vis = H.Mesh()
H.box(vis, 0, HH - TF / 2, 0, HB, TF / 2, HL)                 # the upper flange
H.box(vis, 0, -HH + TF / 2, 0, HB, TF / 2, HL)                # the lower flange
H.box(vis, 0, 0, 0, TW / 2, HH - TF, HL)                      # the web
vp, vn, vu, vt, vsub = H.merge([(vis, 1)])
visent = H.shape_entity("beamProfile", 2, vp, vn, vu, vt, vsub, ["steel"])
hdr = type("Hd", (), {"version": 10, "seed": 97})()
sf = type("SF", (), {"header": hdr, "entities": [H.Raw(1, colent), H.Raw(1, visent)]})()
out = os.path.join(here, "..", "models")
os.makedirs(out, exist_ok=True)
S.write(os.path.join(out, "beamSegment.i3d.shapes"), sf)
attrs = 'collisionFilterGroup="0x2" collisionFilterMask="0xfe3ffb83" castsShadows="false" receiveShadows="false" nonRenderable="true" materialIds="1" clipDistance="300"'
open(os.path.join(out, "beamSegment.i3d"), "w", encoding="iso-8859-1").write(f'''<?xml version="1.0" encoding="iso-8859-1"?>

<i3D name="beamSegment" version="1.6" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://i3d.giants.ch/schema/i3d-1.6.xsd">
  <Asset>
    <Export program="make_beam_segment.py" version="1"/>
  </Asset>
  <Files/>
  <Materials>
    <Material name="steel" materialId="1" diffuseColor="0.20 0.21 0.24 1" specularColor="0.6 0.6 0.6"/>
  </Materials>
  <Shapes externalShapesFile="beamSegment.i3d.shapes">
  </Shapes>
  <Scene>
    <TransformGroup name="beam" nodeId="1">
      <Shape name="beamRoot" shapeId="1" kinematic="true" compound="true" {attrs} nodeId="2"/>
      <Shape name="beamChild" shapeId="1" compoundChild="true" {attrs} nodeId="3"/>
      <Shape name="beamVisual" shapeId="2" castsShadows="true" receiveShadows="true" materialIds="1" clipDistance="300" nodeId="4"/>
    </TransformGroup>
  </Scene>

</i3D>
''')
print("wrote", out)
