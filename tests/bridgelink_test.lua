-- run: lua tests/bridgelink_test.lua   (a fake engine: the second joint between two hitched bridge pieces)
g_currentModName = "FS25_Hammer"
SpecializationUtil = { registerEventListener = function() end }
local nodes = {}
function entityExists(n) return nodes[n] ~= nil end
function getWorldTranslation(n) return nodes[n][1], nodes[n][2], nodes[n][3] end
function localDirectionToWorld(n, x, y, z) return x, y, z end
local removed, created = {}, {}
Logging = { info = function() end }
function getAngularVelocity() return 0, 0, 0 end
function removeJoint(i) removed[#removed + 1] = i end
JointConstructor = { new = function()
    local c = { limits = {}, calls = {} }
    function c:setActors(a, b) self.a, self.b = a, b end
    function c:setJointWorldPositions(...) self.pos = { ... } end
    function c:setTranslationLimit(axis, on, lo, hi) self.limits[#self.limits + 1] = { "t", axis, on, lo, hi } end
    function c:setRotationLimit(axis, lo, hi) self.limits[#self.limits + 1] = { "r", axis, lo, hi } end
    function c:setJointWorldAxes() end
    function c:setJointWorldNormals() end
    function c:setEnableCollision(v) self.collision = v end
    function c:finalize() created[#created + 1] = self; return 100 + #created end
    return c
end }
dofile("scripts/vehicles/BridgeLink.lua")
local K = BridgeLink.SPEC_TABLE_NAME

local pass, fail = 0, 0
local function check(name, cond) if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name) end end

-- two pieces: A (the hitches at z = 0, x = -1 and +1), B (the eyes: x -1 and +1, a little away at first)
nodes[1], nodes[2] = { -1, 0, 0 }, { 1, 0, 0 }                         -- A's hitch nodes
nodes[11], nodes[12] = { -1, 0, 3 }, { 1, 0, 3 }                       -- B's eye nodes (still 3 m away)
nodes[50], nodes[60] = { 0, 0, 0 }, { 0, 0, 0.5 }                      -- component nodes
local attaching = true
local implement = { attachingIsInProgress = true }
local A = { isServer = true, isDeleted = false, components = { { node = 50 } }, spec_attacherJoints = { attacherJoints = { { jointTransform = 1 }, { jointTransform = 2 } } }, raiseActive = function() end,
            getImplementByObject = function(_, o) return o == nil and nil or implement end }
local B = { isServer = true, isDeleted = false, components = { { node = 60 } }, spec_attachable = { inputAttacherJoints = { { node = 11 }, { node = 12 } } } }
A[K], B[K] = {}, {}
BridgeLink.onLoad(A); BridgeLink.onLoad(B)

-- the game hitched hitch 1 to eye 1
BridgeLink.onPostAttachImplement(A, B, 1, 1, false)
check("an attach of another bridge piece is pending", A[K].pending[B] ~= nil)
BridgeLink.onUpdate(A, 16)
check("while the attach is in progress nothing is joined", #created == 0 and A[K].pending[B] ~= nil)
implement.attachingIsInProgress = false
BridgeLink.onUpdate(A, 16)
check("not settled (the other pair is 3 m apart): wait", #created == 0 and A[K].pending[B] ~= nil)
nodes[11], nodes[12], nodes[60] = { -1, 0, 0.01 }, { 1, 0, 0.01 }, { 0, 0, 0.01 }
BridgeLink.onUpdate(A, 16)
local j = created[1]
check("settled: a joint between the two bodies at the second pair (the other hitch and the other eye)", j ~= nil and j.a == 50 and j.b == 60 and j.pos[1] == 1 and j.pos[6] == 0.01)
local function lim(kind, axis) for _, l in ipairs(j.limits) do if l[1] == kind and l[2] == axis then return l end end end
check("... a little leeway in the three translation axes, the ring swings 80 degrees about the bar (x) and tilts 25 about the others, no collision between the pair", j ~= nil and #j.limits == 6 and j.collision == false
    and lim("t", 0)[5] == 0.02 and lim("t", 0)[4] == -0.02 and lim("t", 1)[5] == 0.025 and math.abs(lim("r", 0)[3] + math.rad(80)) < 1e-9 and math.abs(lim("r", 1)[4] - math.rad(25)) < 1e-9 and math.abs(lim("r", 2)[4] - math.rad(25)) < 1e-9)
check("... and the pending entry is done, the joint remembered", A[K].pending[B] == nil and A[K].links[B] == 101)
-- detach removes it
BridgeLink.onPreDetachImplement(A, { object = B })
check("unhitched: the joint is removed", removed[1] == 101 and A[K].links[B] == nil)
-- hitched with one pair, the other pair 1 m apart: it swings closed by itself
BridgeLink.onPreDetachImplement(A, { object = B })
created = {}
nodes[11], nodes[12], nodes[60] = { -1, 0, 0 }, { 1, 0, 1.0 }, { 0, 0, 0.5 }
BridgeLink.onPostAttachImplement(A, B, 1, 1, false)
BridgeLink.onUpdate(A, 16)
check("one pair joined, the other 1 m apart: a pull starts by itself, no joint yet", A[K].pulls[B] ~= nil and A[K].pending[B] == nil and #created == 0)
BridgeLink.onPreDetachImplement(A, { object = B })
nodes[12] = { 1, 0, 3.0 }
BridgeLink.onPostAttachImplement(A, B, 1, 1, false)
BridgeLink.onUpdate(A, 16)
check("3 m apart: no automatic swing", A[K].pulls[B] == nil and A[K].pending[B] ~= nil)
for _ = 1, 200 do BridgeLink.onUpdate(A, 1000) end
check("3 m apart for minutes: still watching (no give-up while hitched)", A[K].pending[B] ~= nil and A[K].pulls[B] == nil)
nodes[12] = { 1, 0, 1.0 }
BridgeLink.onUpdate(A, 300)
check("brought within 2 m later (by hand): the swing starts by itself", A[K].pulls[B] ~= nil and A[K].pending[B] == nil)
BridgeLink.onPreDetachImplement(A, { object = B })
nodes[11], nodes[12], nodes[60] = { -1, 0, 0.01 }, { 1, 0, 0.01 }, { 0, 0, 0.01 }
-- a swing that stalls (both ends of the loose piece held) at 15 cm: a loose joint is made, its slack the gap plus 3 cm
BridgeLink.onPreDetachImplement(A, { object = B })
created = {}
nodes[11], nodes[12], nodes[60] = { -1, 0, 0.15 }, { 1, 0, 0.15 }, { 0, 0, 0.15 }
A[K].pulls[B] = { a = 2, b = 12, ms = 0 }
for _ = 1, 11 do BridgeLink.updatePulls(A, A[K], 1000) end
check("a swing that stalls at 15 cm: a loose joint is made after the stall time", #created == 1 and A[K].pulls[B] == nil and A[K].links[B] ~= nil)
local function limOf(j, kind, axis) for _, l in ipairs(j.limits) do if l[1] == kind and l[2] == axis then return l end end end
check("... with 18 cm of slack in translation (gap + 3 cm), the rotation limits as before", created[1] ~= nil and math.abs(limOf(created[1], "t", 0)[5] - 0.18) < 1e-6 and math.abs(limOf(created[1], "r", 0)[4] - math.rad(80)) < 1e-9)
BridgeLink.onPreDetachImplement(A, { object = B })
-- a swing that stalls at 60 cm gives up as before
created = {}
nodes[12], nodes[60] = { 1, 0, 0.6 }, { 0, 0, 0.3 }
A[K].pulls[B] = { a = 2, b = 12, ms = 0 }
for _ = 1, 5 do BridgeLink.updatePulls(A, A[K], 1000) end
check("a stall at 60 cm is too far for a loose joint: no joint", #created == 0 and A[K].pulls[B] ~= nil)
A[K].pulls[B] = nil
nodes[11], nodes[12], nodes[60] = { -1, 0, 0.01 }, { 1, 0, 0.01 }, { 0, 0, 0.01 }
-- the ring: the hitch sits on a component of its own, the joint is made between that and the other piece's body
nodes[70] = { 1, 0, 0 }
A.getParentComponent = function(_, n) return n == 2 and 70 or 50 end
created = {}
BridgeLink.onPostAttachImplement(A, B, 1, 1, false)
nodes[11], nodes[12], nodes[60] = { -1, 0, 0.01 }, { 1, 0, 0.01 }, { 0, 0, 0.01 }
BridgeLink.onUpdate(A, 16)
check("the joint's first body is the ring that carries the hitch", created[1] ~= nil and created[1].a == 70 and created[1].b == 60)
-- re-attached from a savegame: joined at once even when the points are a few cm apart
BridgeLink.onPreDetachImplement(A, { object = B })
created = {}
nodes[12] = { 1, 0, 0.15 }
BridgeLink.onPostAttachImplement(A, B, 1, 1, true)
BridgeLink.onUpdate(A, 16)
check("from a savegame: no 5 cm wait", #created == 1)
BridgeLink.onPreDetachImplement(A, { object = B })
created = {}
nodes[12] = { 1, 0, 0.15 }
BridgeLink.onPostAttachImplement(A, B, 1, 1, true)
g_currentMission = { vehicleSystem = { vehicles = { A, B } } }
BridgeLink.onSavegameLoaded()
check("SAVEGAME_LOADED (before the pre-simulation): the second joint of a saved attach is made without waiting for an update", #created == 1 and A[K].pending[B] == nil and A[K].links[B] ~= nil)
g_currentMission = nil
check("a joint made on a load is loose and waits for its upgrade", A[K].upgrade[B] ~= nil)
local keepUp = A[K].upgrade[B]
BridgeLink.onUpdate(A, BridgeLink.LOAD_UPGRADE_MS + 100)
check("the upgrade is off by default: the loose joint stays, nothing is swung", A[K].links[B] ~= nil and A[K].pulls[B] == nil and next(A[K].upgrade) == nil)
A[K].upgrade = { [B] = keepUp }
BridgeLink.LOAD_UPGRADE = true
BridgeLink.onUpdate(A, BridgeLink.LOAD_UPGRADE_MS + 100)
check("some seconds into the game the swing takes over to close it for real", A[K].upgrade[B] == nil and A[K].links[B] == nil and A[K].pulls[B] ~= nil)
A[K].pulls[B] = nil

BridgeLink.onPreDetachImplement(A, { object = B })
A.getParentComponent = nil
-- a non-bridge object and a client are ignored
BridgeLink.onPostAttachImplement(A, { }, 1, 1, false)
check("something that is not a bridge piece is ignored", next(A[K].pending) == nil)
local client = { isServer = false, [K] = { pending = {}, links = {}, pulls = {} } }
BridgeLink.onPostAttachImplement(client, B, 1, 1, false)
check("a client does nothing", next(client[K].pending) == nil)
-- pieces without a second pair: the pending entry is dropped
local C = { isServer = true, isDeleted = false, components = { { node = 50 } }, spec_attacherJoints = { attacherJoints = { { jointTransform = 1 } } }, raiseActive = function() end, getImplementByObject = function() return { attachingIsInProgress = false } end, [K] = { pending = {}, links = {}, pulls = {} } }
BridgeLink.onPostAttachImplement(C, B, 1, 1, false)
BridgeLink.onUpdate(C, 16)
check("one hitch only: no second pair, nothing joined, the entry is dropped", #created == 1 and next(C[K].pending) == nil)
-- not hitched any more: dropped
A[K].pending[B] = { hitch = 1, eye = 1, ms = 0 }
A.getImplementByObject = function() return nil end
BridgeLink.onUpdate(A, 16)
check("no longer hitched: the pending entry goes", A[K].pending[B] == nil and #created == 1)
-- deleted: the links go
A[K].links[B] = 555
BridgeLink.onDelete(A)
check("a deleted piece removes its joints", removed[#removed] == 555)

-- the winch asks for the second pair: the loose piece is swung about the hitched pair until the points meet, then the joint is made
local ang, lin = {}, {}
function setAngularVelocity(n, x, y, z) ang[#ang + 1] = { n, x, y, z } end
function setLinearVelocity(n, x, y, z) lin[#lin + 1] = { n, x, y, z } end
nodes[3], nodes[4] = { 0, 0, 0 }, { 2, 0, 0 }                                 -- P (attacher): the hitched pair at x=0, and its second hitch at x=2
nodes[13], nodes[14] = { 0, 0, 0 }, { 2, 0, 0.6 }                            -- Q (loose): the hitched eye at x=0, its second eye 0.6 m off
nodes[70], nodes[71] = { 1, 0, 0 }, { 1, 0, 0.3 }
created, removed = {}, {}
local impl = { attachingIsInProgress = false, jointDescIndex = 1 }
local P = { isServer = true, isDeleted = false, components = { { node = 70 } }, spec_attacherJoints = { attacherJoints = { { jointTransform = 3 }, { jointTransform = 4 } } }, raiseActive = function() end,
            getImplementByObject = function() return impl end, getAttacherJointByJointDescIndex = function(_, i) return { jointTransform = 3 } end, getAttacherVehicle = function() return nil end }
local Q = { isServer = true, isDeleted = false, components = { { node = 71 } }, spec_attachable = { inputAttacherJoints = { { node = 13 }, { node = 14 } } }, getAttacherVehicle = function() return P end }
P[K], Q[K] = {}, {}
BridgeLink.onLoad(P); BridgeLink.onLoad(Q)
local ok = BridgeLink.bridgeLinkPair(Q, P, 14, 4)
check("the request is taken from the object's side", ok == true and P[K].pulls[Q] ~= nil and P[K].pulls[Q].a == 4 and P[K].pulls[Q].b == 14)
BridgeLink.onUpdate(P, 16)
check("not met yet: the loose piece swings (angular velocity set), no joint", #ang == 1 and #created == 0 and ang[1][1] == 71 and ang[1][3] ~= 0)
check("the swing turns the eye towards the hitch: eye at +z of the hitch means a positive yaw", ang[1][3] > 0 and math.abs(ang[1][3]) <= BridgeLink.PULL_RAD_S + 1e-9)
do
    local pp = { ms = 10000, bestMs = 10000 }
    check("boost: 1 while the gap shrinks", BridgeLink.boostOf(pp) == 1)
    pp.ms = 10000 + BridgeLink.BOOST_RAMP_MS
    check("boost: full when stuck for the ramp time", BridgeLink.boostOf(pp) == BridgeLink.BOOST_MAX)
end
nodes[14] = { 2, 0, 0.01 }
BridgeLink.onUpdate(P, 16)
check("met: the locked joint is made and the pull is over", #created == 1 and P[K].pulls[Q] == nil and P[K].links[Q] ~= nil)
-- both pinned: refused
P.hdPinned, Q.hdPinned = true, true
local ok2, why = BridgeLink.bridgeLinkPair(Q, P, 14, 4)
check("both pinned: refused with a reason", ok2 == false and why ~= nil)
-- the pinned side stays, the other swings
P.hdPinned, Q.hdPinned = nil, true
nodes[14] = { 2, 0, 0.6 }
ang = {}
BridgeLink.bridgeLinkPair(Q, P, 14, 4)
BridgeLink.onUpdate(P, 16)
check("the attacher is the loose one: it is the one that swings", #ang == 1 and ang[1][1] == 70)
-- the whole side beyond the new joint turns: a piece that hangs on the loose one goes with it; if that one is pinned the other side swings instead
P.hdPinned, Q.hdPinned = nil, nil
nodes[14] = { 2, 0, 0.6 }
nodes[72] = { 3, 0, 1 }
local R = { isServer = true, isDeleted = false, components = { { node = 72 } }, getAttacherVehicle = function() return Q end }
R[K] = {}
Q.getAttachedImplements = function() return { { object = R } } end
ang = {}
BridgeLink.bridgeLinkPair(Q, P, 14, 4)
BridgeLink.onUpdate(P, 16)
local movedNodes = {}
for _, a in ipairs(ang) do movedNodes[a[1]] = true end
check("what hangs on the loose piece turns with it (a chain is swung as a whole)", movedNodes[71] and movedNodes[72] and not movedNodes[70])
R.hdPinned = true
ang = {}
BridgeLink.onUpdate(P, 16)
check("a pinned piece beyond the loose one holds that side: the attacher side swings", #ang >= 1 and ang[1][1] == 70 and not (ang[1][1] == 71))
R.hdPinned = nil; P.hdPinned = true; R.hdPinned = true
ang = {}
BridgeLink.onUpdate(P, 16)
check("both sides held: nothing is swung", #ang == 0)
P.hdPinned, R.hdPinned = nil, nil
Q.getAttachedImplements = nil
P[K].pulls[Q] = nil
-- the second pair is measured to the lug bar, a taut link's span away: the hanging ring's own node is not the target
do
    nodes[90], nodes[91] = { 1, 0, 0 }, { 1, 0, 0.1 }                  -- the bar; the eye 10 cm from it
    local bar = { a = 1, b = 91, bar = 90 }
    check("an eye 10 cm from the bar is 4 cm outside a taut link (6 cm)", math.abs(BridgeLink.gapOf(bar) - 0.04) < 1e-9)
    nodes[91] = { 1, 0, 0.05 }
    check("inside the span: no gap at all", BridgeLink.gapOf(bar) == 0)
    check("without a bar the plain distance of the nodes", math.abs(BridgeLink.gapOf({ a = 2, b = 12 }) - math.sqrt(0 + 0 + 0.15 ^ 2)) < 0.2)
    local W = { components = { { node = 1 }, { node = 70 } }, componentJoints = { { componentIndices = { 1, 2 }, jointNode = 90 } }, getParentComponent = function(_, n) return n == 3 and 70 or 1 end }
    check("the bar of a hitch is the joint node of the component joint that carries its ring", BridgeLink.barOf(W, 3) == 90 and BridgeLink.barOf(W, 4) == nil)
end
-- not hitched: refused
local ok3 = BridgeLink.bridgeLinkPair(P, { [K] = {}, getAttacherVehicle = function() return nil end }, 3, 13)
check("pieces that are not hitched together: refused", ok3 == false)

-- the connection flags: colours by state, and the console text
local green, yellow, orange, red = { 0, 1, 0 }, { 1, 1, 0 }, { 1, 0.3, 0 }, { 1, 0, 0 }
local function same(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] end
check("flag: the game's pair together is green", same(BridgeLink.statusColor({ gap = 0.02 }, true), green))
check("flag: the game's pair pulled apart is orange", same(BridgeLink.statusColor({ gap = 0.3 }, true), orange))
check("flag: a second joint, joined and together: green", same(BridgeLink.statusColor({ state = "ok" }, false), green))
check("flag: a second joint being closed: yellow", same(BridgeLink.statusColor({ state = "closing" }, false), yellow))
check("flag: a second joint pulled apart: orange", same(BridgeLink.statusColor({ state = "apart" }, false), orange))
check("flag: no second joint: red", same(BridgeLink.statusColor({ state = "none" }, false), red))
check("flag height: joined 5, closing 3, apart 2, none 1; the game's pair 5 together / 2 apart", BridgeLink.statusHeight({ state = "ok" }, false) == 5 and BridgeLink.statusHeight({ state = "closing" }, false) == 3 and BridgeLink.statusHeight({ state = "apart" }, false) == 2 and BridgeLink.statusHeight({ state = "none" }, false) == 1 and BridgeLink.statusHeight({ gap = 0.01 }, true) == 5 and BridgeLink.statusHeight({ gap = 0.4 }, true) == 2)
check("the console command switches the flags off and on", (BridgeLink.consoleStatus(BridgeLink, "off"):find("flags off", 1, true) ~= nil) and BridgeLink.STATUS_ON == false and (BridgeLink.consoleStatus(BridgeLink, "on"):find("flags on", 1, true) ~= nil) and BridgeLink.STATUS_ON == true)

-- the placement guide: spans, layout, which n is the active one
local function near(a, b) return math.abs(a - b) < 1e-6 end
check("span with 3 grates: 0.8 + 0.8 + 12 + 4 joints of 0.17 m", near(BridgeLink.guideSpan(3), 1.6 + 12 + 4 * 0.17))
local lay = BridgeLink.guideLayout(100, 50, 0, 1)            -- a start piece at (100, 50) facing +z
check("the near poles stand 2.15 m either side of the start piece", near(math.abs(lay.near[1].x - 100), 2.15) and near(math.abs(lay.near[2].x - 100), 2.15) and near(lay.near[1].z, 50))
check("the spans run along the facing: the end piece of 3 grates is 14.28 m ahead, its poles beside it", near(lay.spans[3].z, 50 + 14.28) and near(lay.spans[3].x, 100) and near(math.abs(lay.spans[3].poles[1].x - 100), 2.15))
check("no span beyond the limit", #lay.spans > 9 and BridgeLink.guideSpan(#lay.spans + 1) > BridgeLink.GUIDE_MAX_M)
check("the player 14 m ahead beside the axis: the 3 grate layout is the active one", BridgeLink.guideActive(lay, 100, 50, 0, 1, 103, 64) == 3)
check("the player behind the start piece, or far to the side: none", BridgeLink.guideActive(lay, 100, 50, 0, 1, 100, 40) == nil and BridgeLink.guideActive(lay, 100, 50, 0, 1, 130, 64) == nil)
local diag = BridgeLink.guideLayout(0, 0, 0.6, 0.8)
check("a slanted facing keeps the poles at right angles to it", near(diag.near[1].x * 0.6 + diag.near[1].z * 0.8, 0))

-- the far bank found along the axis
local function canyon(x, z) local d = x; if d < 10 then return 50 elseif d < 70 then return 40 else return 50 end end
local farAt, nn, w = BridgeLink.guideSuggest(canyon, 0, 0, 1, 0, 50)
check("a canyon from 10 to 70 m: the bank is at 70 m, the gap 60 m wide", farAt == 70 and w == 60)
check("the suggested n is the first span that reaches 70.8 m: 17 grates (72.7 m)", nn == 17 and BridgeLink.guideSpan(17) >= 70.8 and BridgeLink.guideSpan(16) < 70.8)
check("flat ground: no suggestion", BridgeLink.guideSuggest(function() return 50 end, 0, 0, 1, 0, 50) == nil)
check("a canyon that never ends within the scan: none", BridgeLink.guideSuggest(function(x) return x < 10 and 50 or 30 end, 0, 0, 1, 0, 50) == nil)

-- the far hill by rays: a horizontal ray hits its foot, steps up find the lip
local hillCast = function(up) if up > 8 then return nil end return 66 + 2 * up end
local lip, lipUp, first, nr = BridgeLink.guideFromRays(hillCast)
check("rays: the hill's foot at 67 m, its lip at 81 m (8 m up), the first span that reaches it", first == 67 and lip == 66 + 2 * 8 and lipUp == 8 and nr ~= nil and BridgeLink.guideSpan(nr) >= lip + 0.8 and BridgeLink.guideSpan(nr - 1) < lip + 0.8)
check("rays: nothing ahead at the deck height: none (a lower bank is the terrain scan's)", BridgeLink.guideFromRays(function() return nil end) == nil)
check("rays: a hit under 3 m is the start piece's own ground", BridgeLink.guideFromRays(function() return 1.5 end) == nil)
check("rays: a hill that never ends is no bank", BridgeLink.guideFromRays(function(up) return 50 + up end) == nil)

-- a pole that stands there already: the zone, the span it belongs to, the partner square
local la = { x = 0, z = 0, fx = 0, fz = 1 }
local lly = BridgeLink.guideLayout(0, 0, 0, 1)                         -- axis +z, right = -x ... (rx = -fz = -1, rz = fx = 0)
local m = BridgeLink.guidePartner(la, lly, { x = -2.0, z = 15.28 })   -- 1 m past the 3 grate span (14.28), 2 m to the side
check("a pole beside the 3 grate end piece spot: far zone, n = 3, the partner on the other side at the same distance", m ~= nil and m.zone == "far" and m.n == 3 and near(m.partner.x, 2.0) and near(m.partner.z, 15.28))
local mn = BridgeLink.guidePartner(la, lly, { x = 2.3, z = 0.5 })
check("a pole beside the start piece: near zone, the partner mirrored", mn ~= nil and mn.zone == "near" and near(mn.partner.x, -2.3) and near(mn.partner.z, 0.5))
check("a pole on the axis or far to the side: not a pole of this bridge", BridgeLink.guidePartner(la, lly, { x = 0.3, z = 14.28 }) == nil and BridgeLink.guidePartner(la, lly, { x = 6, z = 14.28 }) == nil)
check("a pole between two spans belongs to the nearer one", (BridgeLink.guidePartner(la, lly, { x = 2.1, z = 8.0 }) or {}).n == 1)

-- the end piece that is there
check("a pinned end piece 1 m off the 3 grate spot, on the axis: n = 3", BridgeLink.guideEndAt(la, lly, { x = 0.4, z = 15.28 }) == 3)
check("an end piece beside the start piece or far off the axis: none", BridgeLink.guideEndAt(la, lly, { x = 0, z = 1 }) == nil and BridgeLink.guideEndAt(la, lly, { x = 5, z = 14 }) == nil)

-- the speed guard: a piece thrown at 40 m/s is slowed to 12, a quiet one is left alone
local vel, ang = { 40, 0, 0 }, { 0, 0, 1 }
getLinearVelocity = function() return vel[1], vel[2], vel[3] end
getAngularVelocity = function() return ang[1], ang[2], ang[3] end
setLinearVelocity = function(_, x, y, z) vel = { x, y, z } end
setAngularVelocity = function(_, x, y, z) ang = { x, y, z } end
local piece = { node = 1, vehicle = { configFileName = "x/bridgeGrate.xml" } }
nodes[1] = { 0, 0, 0 }
local f1 = BridgeLink.guardOne(piece, 5000)
check("a piece at 40 m/s is slowed to the limit, direction kept", near(vel[1], BridgeLink.GUARD_MAX_MS) and near(f1, BridgeLink.GUARD_MAX_MS / 40))
vel, ang = { 3, 0, 0 }, { 0, 0, 1 }
check("a piece at 3 m/s turning 1 rad/s is left alone", BridgeLink.guardOne(piece, 9000) == 1 and vel[1] == 3)
vel, ang = { 0, 2, 0 }, { 0, 20, 0 }
BridgeLink.guardOne(piece, 20000)
check("a piece turning at 20 rad/s is slowed to the limit", near(ang[2], BridgeLink.GUARD_MAX_RAD_S) and vel[2] == 2)

-- the axis aimed at a placed end piece
local fx2, fz2 = BridgeLink.guideAimed({ x = 0, z = 0, fx = -1, fz = 0 }, { { x = -66.7, z = -4.8 } })
check("a start piece facing -x with the end piece 4.8 m to the side at 66.7 m: the axis turns towards it (4.1 deg)", near(math.deg(math.atan2(-fz2, -fx2)), math.deg(math.atan2(4.8, 66.7))) and near(fx2 * fx2 + fz2 * fz2, 1))
local gx, gz = BridgeLink.guideAimed({ x = 0, z = 0, fx = -1, fz = 0 }, { { x = -20, z = -15 } })
check("an end piece more than 10 degrees off the facing does not turn the axis", gx == -1 and gz == 0)
local hx, hz = BridgeLink.guideAimed({ x = 0, z = 0, fx = -1, fz = 0 }, {})
check("no end piece: the facing", hx == -1 and hz == 0)

-- the fit: two pieces placed by eye (the user's real numbers)
local fit = BridgeLink.guideFit({ x = -564.4, y = 54.5, z = 1671.6 }, { x = -630.9, y = 51.5, z = 1666.9 })
check("the fit takes 16 grates for a 66.7 m distance (64.3 / 68.5 are the spans)", fit ~= nil and fit.n == 16)
check("both ideal places lie on the line through the two centres, a span apart (along the slope)", (function()
    local dx, dz = fit.stop.x - fit.start.x, fit.stop.z - fit.start.z
    local across = (fit.start.x - -564.4) * fit.uz - (fit.start.z - 1671.6) * fit.ux     -- the start's offset from the line through the real start along u
    return near(math.sqrt(dx * dx + dz * dz + fit.dh * fit.dh), BridgeLink.guideSpan(16)) and math.abs(across) < 1e-6
end)())
check("the shortfall is shared: each piece moves the same distance, outwards", near(fit.startMove, fit.stopMove) and fit.startAlong < 0 and fit.stopAlong < 0)
check("the ideal yaw is the same for both: atan2(-ux, -uz)", near(fit.yaw, math.deg(math.atan2(-fit.ux, -fit.uz))) and fit.yaw > 85 and fit.yaw < 87)
check("the turn is taken the short way round", near(BridgeLink.guideTurn(350, 10), 20) and near(BridgeLink.guideTurn(10, 350), -20) and near(BridgeLink.guideTurn(88, 85.9), -2.1))
check("two pieces closer than 3 m: no fit", BridgeLink.guideFit({ x = 0, y = 0, z = 0 }, { x = 2, y = 0, z = 0 }) == nil)
local ended = BridgeLink.guideEndFor({ x = 0, z = 0, fx = -1, fz = 0 }, { { x = -66, z = -5 }, { x = 30, z = 0 }, { x = -20, z = 40 } })
check("the end piece for a start piece: the one in front within 35 degrees, not behind or far to the side", ended ~= nil and ended.x == -66)

-- fixed pieces stay, the other one goes to its place on the line
local S0, E0 = { x = -564.4, y = 54.5, z = 1671.6 }, { x = -630.9, y = 51.5, z = 1666.9 }
local fa = BridgeLink.guideFit(S0, E0, true, false)
check("the start piece pinned: it stays, the end piece moves the whole 1.76 m, along the line", near(fa.start.x, S0.x) and near(fa.start.z, S0.z) and near(fa.stopMove, math.abs(fa.excess) / math.sqrt(1 + (fa.dh / fa.lh) ^ 2) * 1.0, 0.05) == false or fa.stopMove > 1.5)
local fb = BridgeLink.guideFit(S0, E0, false, true)
check("the end piece pinned: it stays, the start piece moves", near(fb.stop.x, E0.x) and near(fb.stop.z, E0.z) and fb.startMove > 1.5)
local fc = BridgeLink.guideFit(S0, E0, true, true)
check("both pinned: nothing moves, the excess is reported", fc.startMove == 0 and fc.stopMove == 0 and fc.excess < -1.7)
local fd = BridgeLink.guideFit(S0, E0)
check("both loose: the correction is shared", near(fd.startMove, fd.stopMove) and fd.startMove < 1)

-- a rectangle is green when the piece is within 0.2 m of it and turned within 1.5 degrees
check("a piece 0.1 m off and 1 degree turned fits", BridgeLink.guideFitOk({ x = 0.1, z = 0, yaw = 85 }, { x = 0, z = 0 }, 86))
check("a piece 0.5 m off does not, nor one turned 3 degrees", not BridgeLink.guideFitOk({ x = 0.5, z = 0, yaw = 86 }, { x = 0, z = 0 }, 86) and not BridgeLink.guideFitOk({ x = 0, z = 0, yaw = 83 }, { x = 0, z = 0 }, 86))

-- snapping: within 5 cm and 3 degrees, and not already exactly there
check("snap: 3 cm and 2 degrees off the place: wanted", BridgeLink.snapWanted({ x = 0.03, z = 0, yaw = 88 }, { x = 0, z = 0 }, 86, BridgeLink.SNAP_M, BridgeLink.SNAP_DEG))
check("snap: 20 cm off, or turned 6 degrees: not wanted (it is for the last centimetres)", not BridgeLink.snapWanted({ x = 0.2, z = 0, yaw = 86 }, { x = 0, z = 0 }, 86, BridgeLink.SNAP_M, BridgeLink.SNAP_DEG) and not BridgeLink.snapWanted({ x = 0.01, z = 0, yaw = 92 }, { x = 0, z = 0 }, 86, BridgeLink.SNAP_M, BridgeLink.SNAP_DEG))
check("snap: already there (3 mm, a tenth of a degree): nothing to do", not BridgeLink.snapWanted({ x = 0.003, z = 0, yaw = 86.1 }, { x = 0, z = 0 }, 86, BridgeLink.SNAP_M, BridgeLink.SNAP_DEG))
check("snap: a pole has no yaw to check", BridgeLink.snapWanted({ x = 0.04, z = 0 }, { x = 0, z = 0 }, nil, BridgeLink.SNAP_POLE_M, BridgeLink.SNAP_DEG))

-- the guide wires: both fixed, a pinned pole in each square
local fixedFit = BridgeLink.guideFit({ x = 0, y = 0, z = 0 }, { x = 68.4, y = 0, z = 0 }, true, true)       -- along +x
local rr = { x = fixedFit.start.x + (-fixedFit.uz) * 2.15, z = fixedFit.start.z + fixedFit.ux * 2.15 }
local polesAll = {
    { x = 0.1, z = 2.15, pinned = true, vehicle = "nearL" }, { x = 0, z = -2.2, pinned = true, vehicle = "nearR" },
    { x = 68.4, z = 2.1, pinned = true, vehicle = "farL" }, { x = 68.5, z = -2.0, pinned = false, vehicle = "farR" } }
local wp = BridgeLink.autoWirePairs(fixedFit, polesAll)
check("guide wires: only the side with a pinned pole near AND far gets a pair", #wp == 1 and wp[1].near.vehicle == "nearL" and wp[1].far.vehicle == "farL")
polesAll[4].pinned = true
check("guide wires: all four poles pinned: two pairs", #BridgeLink.autoWirePairs(fixedFit, polesAll) == 2)
check("guide wires: a pole 3 m from the square does not count", #BridgeLink.autoWirePairs(fixedFit, { { x = 3, z = 5, pinned = true }, { x = 68.4, z = 2.1, pinned = true } }) == 0)

-- the measured gap
local lo, med, hi = BridgeLink.gapStats({ 0.30, 0.10, 0.21, 0.25, 0.18 })
check("gap stats: min, median, max", near(lo, 0.10) and near(med, 0.21) and near(hi, 0.30))
local _, med2 = BridgeLink.gapStats({ 0.2, 0.4 })
check("gap stats: the median of two is their mean", near(med2, 0.3))
check("gap stats: nothing measured", BridgeLink.gapStats({}) == nil)
check("a grate is 2 m to its centre, an end piece 0.8 m, anything else unknown", BridgeLink.pieceHalf({ typeName = "FS25_Hammer.bridgeGrate" }) == 2.0 and BridgeLink.pieceHalf({ typeName = "x.bridgeEnd" }) == 0.8 and BridgeLink.pieceHalf({ typeName = "tractor" }) == nil)

-- the gap first, then the hill beyond it
local bumpy = function(x, z) if x >= 22 and x < 24 then return 51 elseif x >= 10 and x < 70 then return 40 else return 50 end end   -- a 1 m bump at 22 m INSIDE... (not a canyon edge)
local flatBump = function(x, z) if x >= 22 and x < 24 then return 51 else return 50 end end
check("gap start: flat ground with a bump has no canyon", BridgeLink.guideGapStart(flatBump, 0, 0, 1, 0, 50) == nil)
check("gap start: the canyon begins where the ground is 1.5 m under the deck", BridgeLink.guideGapStart(function(x) return x < 10 and 50 or 40 end, 0, 0, 1, 0, 50) == 10)
local lip2, up2, first2, n2 = BridgeLink.guideFromRays(function(up) if up > 6 then return nil end return 56 + up * 1.5 end, 10)
check("rays from the gap's start: the distances count from the start piece (10 m + 56 ...)", lip2 ~= nil and first2 == 10 + 56 + 0.5 * 1.5 and lip2 == 10 + 56 + 6 * 1.5 and n2 ~= nil and BridgeLink.guideSpan(n2) >= lip2 + 0.8)

-- the steel profiles
local plan, key1 = BridgeLink.beamPlan({ x = 0, y = 54.5, z = 0 }, { x = 68.4, y = 51.5, z = 0 })
check("beams: two profiles 0.9 m either side of the line, their top 5 cm under the pieces' bottoms (the axis 11 cm under)", plan ~= nil and #plan >= 8 and near(math.abs(plan[1].a.z - plan[4].a.z), 1.8) and near(plan[1].a.y, 54.5 - 0.11) and near(plan[1].b.y, 51.5 - 0.11))
check("kerbs: one per side, 1.78 m from the line (face 1.72), from 0.8 m inside each end piece, turned on its side toward the middle", plan[7] ~= nil and plan[8] ~= nil and plan[7].up ~= nil and near(math.abs(plan[7].a.z), 1.78) and near(plan[7].a.z, -plan[8].a.z) and near(plan[7].a.x, 0.8) and near(plan[7].b.x, 68.4 - 0.8) and near(plan[7].up[3] + plan[8].up[3], 0))
local _, key2 = BridgeLink.beamPlan({ x = 0.004, y = 54.5, z = -0.003 }, { x = 68.4, y = 51.501, z = 0 })
local _, key3 = BridgeLink.beamPlan({ x = 0, y = 54.5, z = 0 }, { x = 68.5, y = 51.5, z = 0 })
check("beams: a stub runs 2.8 m on into each bank, 35 cm lower at its far end", near(plan[2].a.x, plan[1].a.x - 2.8) and near(plan[2].a.y, plan[1].a.y - 0.35) and near(plan[2].b.x, plan[1].a.x) and near(plan[3].b.x, plan[1].b.x + 2.8) and near(plan[3].b.y, plan[1].b.y - 0.35))
check("beams: a millimetre of jitter does not rebuild them, 10 cm of a chain's pull neither, 30 cm does, and the first time always builds", not BridgeLink.beamMoved(key1, key2) and not BridgeLink.beamMoved(key1, key3) and BridgeLink.beamMoved(key1, select(2, BridgeLink.beamPlan({ x = 0, y = 54.5, z = 0 }, { x = 68.7, y = 51.5, z = 0 }))) and BridgeLink.beamMoved(nil, key1))
check("beams: two pieces closer than 3 m: none", BridgeLink.beamPlan({ x = 0, y = 0, z = 0 }, { x = 2, y = 0, z = 0 }) == nil)

-- a pole's lower eye (local +x) towards the other end
local function plocal(yaw) local r = math.rad(yaw); return math.cos(r), -math.sin(r) end
local px1, pz1 = plocal(BridgeLink.poleYawFor(1, 0))
check("pole yaw: for a direction along +x the pole's +x points along +x", near(px1, 1) and near(pz1, 0))
local px2, pz2 = plocal(BridgeLink.poleYawFor(0, 1))
check("pole yaw: for a direction along +z the pole's +x points along +z", near(px2, 0) and near(pz2, 1))
local dx3, dz3 = -0.9974, -0.0723
local l3 = math.sqrt(dx3 * dx3 + dz3 * dz3); dx3, dz3 = dx3 / l3, dz3 / l3
local px3, pz3 = plocal(BridgeLink.poleYawFor(dx3, dz3))
check("pole yaw: for the real line (-0.9974, -0.0723) the +x points along it", near(px3, dx3) and near(pz3, dz3))
check("snap: a pole 0.4 m from its square is wanted, whatever its angle (and an angle alone is enough)", BridgeLink.snapWanted({ x = 0.4, z = 0, yaw = 170 }, { x = 0, z = 0 }, 10, BridgeLink.SNAP_POLE_M, 181) and BridgeLink.snapWanted({ x = 0.001, z = 0, yaw = 100 }, { x = 0, z = 0 }, 10, BridgeLink.SNAP_POLE_M, 181))

-- home: which piece is thrown, which rests somewhere new
local H0 = { 10, 5, 10 }
local function stn() return { tries = 0 } end
check("home: a piece at 3 m/s a metre from home in normal play: nothing", BridgeLink.homeVerdict(stn(), { 11, 5, 10 }, H0, 3, false, 1e9, 500) == nil)
check("home: 44 m/s is a throw", BridgeLink.homeVerdict(stn(), { 11, 5, 10 }, H0, 44, false, 1e9, 500) == "thrown")
local stj = stn(); stj.last = { 10, 5, 10 }
check("home: a jump of 400 m between two looks (the game's reset to shop) is a throw", BridgeLink.homeVerdict(stj, { 400, 5, 10 }, H0, 0.1, false, 1e9, 500) == "thrown")
check("home: in the first 20 s after a load 8 m from home is a throw, 8 m from home later is not", BridgeLink.homeVerdict(stn(), { 18, 5, 10 }, H0, 1, false, 5000, 500) == "thrown" and BridgeLink.homeVerdict(stn(), { 18, 5, 10 }, H0, 1, false, 60000, 500) == nil)
check("home: a piece in the hands is not 'thrown' by the load window", BridgeLink.homeVerdict(stn(), { 18, 5, 10 }, H0, 1, true, 5000, 500) == nil)
local str = stn()
local r1 = BridgeLink.homeVerdict(str, { 30, 5, 10 }, H0, 0.05, false, 60000, 1500)
local r2 = BridgeLink.homeVerdict(str, { 30, 5, 10 }, H0, 0.05, false, 60000, 1500)
check("home: 3 s of rest 20 m from home: that is home now", r1 == nil and r2 == "rehome")
check("home: a piece at rest at home is left alone", BridgeLink.homeVerdict(stn(), { 10, 5, 10 }, H0, 0, false, 60000, 5000) == nil)

check("home saved: a piece saved 400 m from its saved home was thrown and saved; 3 m is a normal move", BridgeLink.homeSavedFar({ 400, 5, 10 }, { 10, 5, 10 }) and not BridgeLink.homeSavedFar({ 13, 5, 10 }, { 10, 5, 10 }))

-- a fall is free: a piece dropped from a height is not slowed to a feather
vel, ang = { 0, -30, 0 }, { 0, 0, 0 }
local ffall = BridgeLink.guardOne(piece, 30000)
check("a piece falling at 30 m/s is left alone (gravity), a fall of 90 m/s is clamped to 60", ffall == 1 and vel[2] == -30 and (function() vel = { 0, -90, 0 }; BridgeLink.guardOne(piece, 60000); return vel[2] == -60 end)())
vel, ang = { 5, 40, 0 }, { 0, 0, 0 }
BridgeLink.guardOne(piece, 90000)
check("upward speed is clamped (a thrown piece goes up), sideways with it", vel[2] <= BridgeLink.GUARD_MAX_MS + 1e-9 and vel[2] > 0)

-- re-seat: the move that brings the eye to a taut link's span from the bar
local rx, ry, rz = BridgeLink.reseatShift({ 0, 0, 0 }, { 4.68, 0, 0 }, 0.06)
check("re-seat: an eye 4.68 m from the bar moves 4.62 m towards it (6 cm left)", near(rx, 4.62) and near(ry, 0) and near(rz, 0))
local qx, qy, qz = BridgeLink.reseatShift({ 1, 2, 3 }, { 1.03, 2, 3 }, 0.06)
check("re-seat: an eye already inside the span does not move", qx == 0 and qy == 0 and qz == 0)
local ux, uy, uz = BridgeLink.reseatShift({ 0, 0, 0 }, { 0, 3, 4 }, 0.06)
check("re-seat: the move is along the line to the bar", near(math.sqrt(ux * ux + uy * uy + uz * uz), 4.94) and near(uy / uz, 0.75))
-- the lock: where a grate lies against the line between the pinned pieces
local lf, llat, ldy = BridgeLink.lockPose({ x = 0, y = 10, z = 0 }, { x = 40, y = 6, z = 0 }, 20, 7.95, 0.1)
check("lock pose: halfway along a falling line, 0.1 m to the side, 0.05 m above the line (line 8.0 there, grate at 7.95: below by 0.05)", near(lf, 0.5) and near(math.abs(llat), 0.1) and near(ldy, 0.05))
check("lock pose: two pieces closer than 3 m have no line", BridgeLink.lockPose({ x = 0, y = 0, z = 0 }, { x = 2, y = 0, z = 0 }, 1, 0, 0) == nil)
local lf2, _, ldy2 = BridgeLink.lockPose({ x = 0, y = 10, z = 0 }, { x = 40, y = 10, z = 0 }, 20, 9.6, 0)
check("lock pose: a grate 0.4 m under the line is 0.4 m too low (not locked: it has sunk through the bars)", near(lf2, 0.5) and near(ldy2, 0.4))

print(string.format("bridgelink_test: %d/%d passed", pass, pass + fail))
os.exit(fail == 0 and 0 or 1)
