-- BridgeLink (FS25_Hammer): the game joins two vehicles with ONE attacher joint at most (AttacherJoints:attachImplement refuses a second: "Joint already in use"). Two bridge pieces are hitched with one hitch and one eye; this adds a plain physics joint
-- between the other hitch (on the other link ring of the piece) and the other eye, once the attach has pulled the pieces together. The ring hangs on a lug bar like a chain link: it swings freely about the bar and has a little leeway (the same limits as the
-- game's own joint of the pair, in the xml), so two joints hold a piece on uneven ground without fighting it. Taken away again when they are unhitched; rebuilt after every load from the game's own saved first joint.
BridgeLink = {}
BridgeLink.modDir = g_currentModDirectory
BridgeLink.SPEC_TABLE_NAME = "spec_" .. g_currentModName .. ".bridgeLink"
BridgeLink.SETTLED_M = 0.05        -- the second pair is joined when its two points are this close (the attach pulls the piece in smoothly first)
BridgeLink.GIVE_UP_MS = 20000
BridgeLink.PULL_RAD_S = 0.3         -- the swing that closes the second pair (rad/s at most)
BridgeLink.PULL_GIVE_UP_MS = 25000           -- a swing that got nowhere goes back to watching the distance (see RESCAN_MS)
BridgeLink.RESCAN_MS = 200                   -- a hitched pair whose other pair is far apart is looked at this often, for as long as it is hitched: whoever brings the loose piece near (by hand, by winch) gets the swing and the joint
BridgeLink.BOOST_MAX = 12                     -- a swing that is not getting anywhere (friction, a tilted piece) keeps pushing harder: up to this many times the asked turn ...
BridgeLink.BOOST_RAMP_MS = 4000               -- ... reached after this long without 5 mm of progress
BridgeLink.BOOST_LIFT_MS = 0.12               -- ... and the loose side is lifted a little (m/s at full boost) so the ground lets go of it
BridgeLink.ROT_DEG = { 80, 25, 25 }          -- the ring swings about the bar (x) and tilts a little (the game's own joint of the pair has the same: lowerRotLimit in the xml)
BridgeLink.TRANS_M = { 0.02, 0.025, 0.025 }  -- ... and slides a little on it: the leeway (lowerTransLimit in the xml)
BridgeLink.AUTO_PULL_M = 2.0                 -- hitched with ONE pair and the other pair is this close: the loose piece swings closed by itself (as the winch's second pair does)
BridgeLink.RING_SETTLED_M = 0.02              -- with rings the second joint is made when the eye is this close to a taut link's span from the bar (the ring then reaches it without a fight)
BridgeLink.RING_SPAN_M = 0.06                -- a taut link: the two lug bars are this far apart (twice the ring's reach, tools/make_selling_plate.py RING_REACH)
BridgeLink.STALL_MS = 9000                   -- the swing has not brought the points closer by 5 mm in this long: both ends of the loose piece are held (the last gap between two anchored halves) ...
BridgeLink.LOOSE_MAX_M = 0.35                -- ... and when they are this close the second joint is made all the same, loose: its slack is the gap plus a little, so it holds without pulling
BridgeLink.LOOSE_EXTRA_M = 0.03
BridgeLink.LOAD_UPGRADE = false               -- off: closing the loose joints of a loaded bridge by the swing, all at once, flung a settled chain (2026-11-16); they stay loose at their offset
BridgeLink.LOAD_UPGRADE_MS = 6000             -- a joint rebuilt on a load is LOOSE at the offset it finds (a tight one with the nodes 10 cm apart threw whole chains off the slope): this long after the world runs, the swing closes it for real
BridgeLink.LOAD_MAX_M = 0.3                  -- a pair re-attached from a savegame is joined at once when its points are within this

function BridgeLink.prerequisitesPresent(specializations)
    return true
end

function BridgeLink.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "bridgeLinkPair", BridgeLink.bridgeLinkPair)
end

function BridgeLink.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", BridgeLink)
    SpecializationUtil.registerEventListener(vehicleType, "onPostAttachImplement", BridgeLink)
    SpecializationUtil.registerEventListener(vehicleType, "onPreDetachImplement", BridgeLink)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", BridgeLink)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", BridgeLink)
end

function BridgeLink:onLoad(savegame)
    local spec = self[BridgeLink.SPEC_TABLE_NAME]
    spec.pending, spec.links, spec.pulls, spec.upgrade = {}, {}, {}, {}
end

function BridgeLink:onPostAttachImplement(object, inputJointDescIndex, jointDescIndex, loadFromSavegame)
    local spec = self[BridgeLink.SPEC_TABLE_NAME]
    if not self.isServer or object == nil or object[BridgeLink.SPEC_TABLE_NAME] == nil then
        return
    end
    spec.pending[object] = { hitch = jointDescIndex, eye = inputJointDescIndex, ms = 0, fromSave = loadFromSavegame == true }
    if loadFromSavegame then
        Logging.info("[BridgeLink] hitched again from the savegame: the second joint is rebuilt")
    end
    self:raiseActive()
end

local function removeLink(spec, object)
    local index = spec.links[object]
    spec.links[object] = nil
    if index ~= nil then
        pcall(removeJoint, index)
    end
end

function BridgeLink:onPreDetachImplement(implement)
    local spec = self[BridgeLink.SPEC_TABLE_NAME]
    if implement ~= nil and implement.object ~= nil and self.isServer then
        -- a connection that vanishes: who did it (the game has no break force on an attach joint; a detach comes from a click, a reset/delete or a script)
        local why = ""
        if debug ~= nil and debug.traceback ~= nil then
            local tb = debug.traceback("", 3) or ""
            local frames = {}
            for line in tb:gmatch("[^\n]+") do
                if #frames < 4 and not line:find("stack traceback", 1, true) then
                    frames[#frames + 1] = (line:gsub("^%s+", ""):gsub("C:/Users/[^/]+/Documents/My Games/FarmingSimulator2025/mods/", ""):gsub("dataS/scripts/", ""))
                end
            end
            why = " | " .. table.concat(frames, " < ")
        end
        Logging.info("[BridgeLink] %s detached from %s%s", tostring(implement.object.configFileName or "?"):match("([^/]+)%.xml$") or "?", tostring(self.configFileName or "?"):match("([^/]+)%.xml$") or "?", why)
    end
    if implement ~= nil and implement.object ~= nil then
        spec.pending[implement.object] = nil
        spec.pulls[implement.object] = nil
        if spec.upgrade ~= nil then
            spec.upgrade[implement.object] = nil
        end
        removeLink(spec, implement.object)
    end
end

function BridgeLink:onDelete()
    local spec = self[BridgeLink.SPEC_TABLE_NAME]
    for object in pairs(spec.links or {}) do
        removeLink(spec, object)
    end
end

-- the other hitch and the other eye (not the pair the game joined) that lie closest together; nil when there is none
function BridgeLink.otherPair(self, object, p)
    local hitches = self.spec_attacherJoints ~= nil and self.spec_attacherJoints.attacherJoints or {}
    local eyes = object.spec_attachable ~= nil and object.spec_attachable.inputAttacherJoints or {}
    local best, bestD
    local latch = AttacherJoints ~= nil and AttacherJoints.jointTypeNameToInt ~= nil and AttacherJoints.jointTypeNameToInt["winchLatch"] or nil
    local trailer = AttacherJoints ~= nil and AttacherJoints.jointTypeNameToInt ~= nil and AttacherJoints.jointTypeNameToInt["trailer"] or nil      -- (the bridge's own eyes: the lifting joints of wheelLoader, telehandler and bigBag type are no eyes)
    for i, h in ipairs(hitches) do
        if i ~= p.hitch and h.jointTransform ~= nil and entityExists(h.jointTransform) and (latch == nil or h.jointType ~= latch) then
            for j, e in ipairs(eyes) do
                if j ~= p.eye and e.node ~= nil and entityExists(e.node) and (trailer == nil or e.jointType == trailer) then
                    local cand = { a = h.jointTransform, b = e.node, bar = BridgeLink.barOf(self, h.jointTransform) }
                    local d = BridgeLink.gapOf(cand)
                    if bestD == nil or d < bestD then
                        best, bestD = cand, d
                    end
                end
            end
        end
    end
    return best, bestD
end

function BridgeLink.createJoint(self, object, pair, gap)
    local nodeA = self.getParentComponent ~= nil and self:getParentComponent(pair.a) or self.components[1].node       -- (the ring the hitch sits on)
    local nodeB = object.getParentComponent ~= nil and object:getParentComponent(pair.b) or object.components[1].node
    local ax, ay, az = getWorldTranslation(pair.a)
    local bx, by, bz = getWorldTranslation(pair.b)
    local joint = JointConstructor.new()
    joint:setActors(nodeA, nodeB)
    joint:setJointWorldPositions(ax, ay, az, bx, by, bz)
    for axis = 0, 2 do
        local t = BridgeLink.TRANS_M[axis + 1]
        if gap ~= nil then
            t = math.max(t, gap + BridgeLink.LOOSE_EXTRA_M)               -- (the points are not together and cannot be brought together: the joint holds at that offset)
        end
        joint:setTranslationLimit(axis, true, -t, t)
        local r = math.rad(BridgeLink.ROT_DEG[axis + 1])
        joint:setRotationLimit(axis, -r, r)
    end
    local xx, xy, xz = localDirectionToWorld(pair.a, 1, 0, 0)
    local yx, yy, yz = localDirectionToWorld(pair.a, 0, 1, 0)
    joint:setJointWorldAxes(xx, xy, xz, xx, xy, xz)
    joint:setJointWorldNormals(yx, yy, yz, yx, yy, yz)
    joint:setEnableCollision(false)
    return joint:finalize()
end

local function distance(n1, n2)
    local x1, y1, z1 = getWorldTranslation(n1)
    local x2, y2, z2 = getWorldTranslation(n2)
    return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2 + (z1 - z2) ^ 2)
end

-- The lug bar the ring of a hitch hangs on (the joint node of the component joint that carries that ring): the ring itself hangs loose from it, so the hitch node on the ring is NOT where the other piece's eye has to go;
-- the eye has to come within a taut link's span of the bar. nil when the hitch is not on a ring (the plain one-body models).
function BridgeLink.barOf(self, hitchNode)
    local ringNode = self.getParentComponent ~= nil and hitchNode ~= nil and self:getParentComponent(hitchNode) or nil
    if ringNode == nil then
        return nil
    end
    for _, jointDesc in ipairs(self.componentJoints or {}) do
        local component = self.components[jointDesc.componentIndices[2]]
        if component ~= nil and component.node == ringNode then
            return jointDesc.jointNode
        end
    end
    return nil
end

function BridgeLink.settledFor(p)
    return p.bar ~= nil and BridgeLink.RING_SETTLED_M or BridgeLink.SETTLED_M
end

-- How far the second pair is from joined: the eye's distance from the bar beyond a taut link's span (a ring: nothing to close inside the span), else the plain distance of the two nodes.
function BridgeLink.gapOf(p)
    if p.bar ~= nil and entityExists(p.bar) and entityExists(p.b) then
        return math.max(0, distance(p.b, p.bar) - BridgeLink.RING_SPAN_M)
    end
    return distance(p.a, p.b)
end

local function isHeld(vehicle)
    local frame = vehicle.components ~= nil and vehicle.components[1] or nil
    return vehicle.hdPinned == true or (frame ~= nil and frame.isStatic == true)
end

-- The winch asks for the second pair of two hitched pieces: nodeSelf (of this piece) and nodeOther (of the other) are to be joined. The loose piece (not pinned or frozen) is swung about the
-- hitched pair until the two points meet, then the locked joint is made. Returns ok, message.
function BridgeLink.bridgeLinkPair(self, other, nodeSelf, nodeOther)
    if other == nil or other[BridgeLink.SPEC_TABLE_NAME] == nil then
        return false, "that is not a bridge piece"
    end
    local attacher, object, a, b
    if self.getAttacherVehicle ~= nil and self:getAttacherVehicle() == other then
        attacher, object, a, b = other, self, nodeOther, nodeSelf
    elseif other.getAttacherVehicle ~= nil and other:getAttacherVehicle() == self then
        attacher, object, a, b = self, other, nodeSelf, nodeOther
    else
        return false, "the two pieces are not hitched together yet"
    end
    if not attacher.isServer then
        return true
    end
    if isHeld(attacher) and isHeld(object) then
        return false, "both pieces are pinned: let one go first (the hammer), or they cannot be pulled together"
    end
    local spec = attacher[BridgeLink.SPEC_TABLE_NAME]
    spec.pending[object] = nil
    spec.pulls[object] = { a = a, b = b, bar = BridgeLink.barOf(attacher, a), ms = 0 }
    Logging.info("[BridgeLink] second joint requested: gap %.3f m", BridgeLink.gapOf(spec.pulls[object]))
    attacher:raiseActive()
    return true
end

-- The bridge pieces connected to `vehicle` without going through `exclude` (the other side of the new joint), and whether the group is held: a piece that is pinned or frozen, or anything that is not a bridge piece (a tractor): held.
function BridgeLink.sideOf(vehicle, exclude)
    local list, held, seen, queue = {}, false, { [exclude] = true, [vehicle] = true }, { vehicle }
    local i = 1
    while queue[i] ~= nil do
        local v = queue[i]
        i = i + 1
        if v[BridgeLink.SPEC_TABLE_NAME] == nil or isHeld(v) then
            held = true
        else
            list[#list + 1] = v
        end
        local parent = v.getAttacherVehicle ~= nil and v:getAttacherVehicle() or nil
        if parent ~= nil and not seen[parent] then
            seen[parent] = true
            queue[#queue + 1] = parent
        end
        for _, implement in ipairs(v.getAttachedImplements ~= nil and v:getAttachedImplements() or {}) do
            if implement.object ~= nil and not seen[implement.object] then
                seen[implement.object] = true
                queue[#queue + 1] = implement.object
            end
        end
    end
    return list, held
end

-- How hard the swing pushes: 1 while the gap shrinks, up to BOOST_MAX times that the longer it has not shrunk by 5 mm (the gap closes whatever holds the piece back, as the winch would keep pulling).
function BridgeLink.boostOf(p)
    local stuck = p.bestMs ~= nil and (p.ms - p.bestMs) or 0
    return 1 + (BridgeLink.BOOST_MAX - 1) * math.min(1, stuck / BridgeLink.BOOST_RAMP_MS)
end

-- One step of the swing: the loose SIDE (the pieces beyond the new joint: whatever hangs on the loose piece moves with it, a chain is turned as a whole) turns about the hitched pair (every axis: the second piece usually lies on the ground, a little lower or
-- tilted) so that its eye comes to the bar of the other piece's ring (to a taut link's span from it: the ring itself hangs loose, it follows the eye). The turn that carries a point at r from the pivot by e is (r x e) / |r|^2; every body of the side moves like
-- a rigid turn about the pivot (v = w x (centre - pivot)). A side with a pinned piece (or a tractor) cannot move: the other side does; when both are held there is nothing to swing (the stall rule makes the joint loose).
function BridgeLink.pullStep(attacher, object, p)
    local objectSide, objectHeld = BridgeLink.sideOf(object, attacher)
    local attacherSide, attacherHeld = BridgeLink.sideOf(attacher, object)
    local objectMoves = not objectHeld
    if objectHeld and attacherHeld then
        return
    end
    local side = objectMoves and objectSide or attacherSide
    local movedNode = objectMoves and p.b or p.a
    local implement = attacher.getImplementByObject ~= nil and attacher:getImplementByObject(object) or nil
    local desc = implement ~= nil and attacher.getAttacherJointByJointDescIndex ~= nil and attacher:getAttacherJointByJointDescIndex(implement.jointDescIndex) or nil
    if desc == nil or desc.jointTransform == nil or not entityExists(desc.jointTransform) then
        return
    end
    local px, py, pz = getWorldTranslation(desc.jointTransform)
    local mx, my, mz = getWorldTranslation(movedNode)
    local tx, ty, tz
    if p.bar ~= nil and entityExists(p.bar) then
        -- the point a taut link away from the bar, on the line from the bar to the eye (the eye comes to it when the object moves; when the attacher side moves, the bar comes to the eye the same distance)
        local bx, by, bz = getWorldTranslation(p.bar)
        local ex, ey, ez = getWorldTranslation(p.b)
        local dx, dy, dz = ex - bx, ey - by, ez - bz
        local len = math.sqrt(dx * dx + dy * dy + dz * dz)
        if len > BridgeLink.RING_SPAN_M and len > 1e-6 then
            local k = BridgeLink.RING_SPAN_M / len
            if objectMoves then
                tx, ty, tz = bx + dx * k, by + dy * k, bz + dz * k           -- (the eye goes to the span)
            else
                tx, ty, tz = ex - dx * k, ey - dy * k, ez - dz * k           -- (the bar goes to the eye, a span short of it)
                mx, my, mz = bx, by, bz
            end
        else
            tx, ty, tz = mx, my, mz
        end
    else
        tx, ty, tz = getWorldTranslation(objectMoves and p.a or p.b)
    end
    local rx, ry, rz = mx - px, my - py, mz - pz
    local ex, ey, ez = tx - mx, ty - my, tz - mz
    local r2 = rx * rx + ry * ry + rz * rz
    if r2 < 1e-4 then
        return
    end
    local wx, wy, wz = (ry * ez - rz * ey) / r2, (rz * ex - rx * ez) / r2, (rx * ey - ry * ex) / r2
    local boost = BridgeLink.boostOf(p)
    wx, wy, wz = wx * 2 * boost, wy * 2 * boost, wz * 2 * boost
    local w = math.sqrt(wx * wx + wy * wy + wz * wz)
    local cap = BridgeLink.PULL_RAD_S * boost
    if w > cap then
        local sc = cap / w
        wx, wy, wz = wx * sc, wy * sc, wz * sc
    end
    local lift = BridgeLink.BOOST_LIFT_MS * (boost - 1) / (BridgeLink.BOOST_MAX - 1)
    local first = nil
    for _, piece in ipairs(side) do
        local node = piece.components[1].node
        first = first or node
        local cx, cy, cz = getWorldTranslation(node)
        local ox, oy, oz = cx - px, cy - py, cz - pz
        setAngularVelocity(node, wx, wy, wz)
        setLinearVelocity(node, wy * oz - wz * oy, wz * ox - wx * oz + lift, wx * oy - wy * ox)
    end
    if (p.ms - (p.loggedAt or -1000)) >= 1000 then                 -- (once a second: what the swing asks for and what the body does, for the log)
        p.loggedAt = p.ms
        local avx, avy, avz = 0, 0, 0
        if getAngularVelocity ~= nil and first ~= nil then
            avx, avy, avz = getAngularVelocity(first)
        end
        local limit = implement.jointRotLimit
        Logging.info("[BridgeLink] swing %s (%d piece(s)): gap %.3f m, push x%.1f, asks w=(%.2f %.2f %.2f), body w=(%.2f %.2f %.2f), joint rot limit (deg) %s, attaching %s, held(object side %s, attacher side %s)", objectMoves and "object" or "attacher", #side,
            BridgeLink.gapOf(p), boost, wx, wy, wz, avx, avy, avz,
            limit ~= nil and string.format("%.0f %.0f %.0f", math.deg(limit[1] or 0), math.deg(limit[2] or 0), math.deg(limit[3] or 0)) or "?", tostring(implement.attachingIsInProgress), tostring(objectHeld), tostring(attacherHeld))
    end
end

-- Has the swing stopped getting anywhere (the gap has not shrunk by 5 mm for STALL_MS) at a gap a loose joint can take? Keeps the best gap and when it was reached in p.
function BridgeLink.stalled(p)
    local d = BridgeLink.gapOf(p)
    if p.bestGap == nil or d < p.bestGap - 0.005 then
        p.bestGap, p.bestMs = d, p.ms
        return false
    end
    return p.ms - p.bestMs >= BridgeLink.STALL_MS and d <= BridgeLink.LOOSE_MAX_M and distance(p.a, p.b) <= BridgeLink.LOOSE_MAX_M
end

function BridgeLink.updatePulls(self, spec, dt)
    for object, p in pairs(spec.pulls) do
        p.ms = p.ms + dt
        if object.isDeleted or p.ms > BridgeLink.PULL_GIVE_UP_MS or not entityExists(p.a) or not entityExists(p.b) then
            spec.pulls[object] = nil
            if not object.isDeleted and p.pend ~= nil then
                p.pend.ms = 0
                spec.pending[object] = p.pend                 -- (back to watching: the pieces are still hitched)
            end
            Logging.info("[BridgeLink] the swing got nowhere in %.1f s (gap %.3f m): back to watching the distance", p.ms / 1000, (entityExists(p.a) and entityExists(p.b)) and BridgeLink.gapOf(p) or -1)
        elseif BridgeLink.stalled(p) then
            local d = distance(p.a, p.b)                          -- (the real offset of the two nodes: the slack of the loose joint)
            spec.pulls[object] = nil
            removeLink(spec, object)
            spec.links[object] = BridgeLink.createJoint(self, object, { a = p.a, b = p.b }, d)
            Logging.info("[BridgeLink] the swing stalled at %.3f m (both ends of the loose piece are held): second joint made loose, %.0f cm of slack", d, 100 * (d + BridgeLink.LOOSE_EXTRA_M))
        elseif BridgeLink.gapOf(p) <= BridgeLink.settledFor(p) then
            spec.pulls[object] = nil
            removeLink(spec, object)
            spec.links[object] = BridgeLink.createJoint(self, object, { a = p.a, b = p.b })
            Logging.info("[BridgeLink] second joint made after %.1f s", p.ms / 1000)
        else
            BridgeLink.pullStep(self, object, p)
        end
    end
end

-- One pending second pair: given up, joined, or put into a swing (see the cases).
function BridgeLink.processPending(self, spec, object, p)
    if object.isDeleted then
        spec.pending[object] = nil
        return
    end
    if p.fromSave and p.ms > BridgeLink.GIVE_UP_MS then
        p.fromSave = false                                       -- (the load is long over: a piece moved later is an ordinary one)
    end
    if (p.ms - (p.checkedAt or -BridgeLink.RESCAN_MS)) < BridgeLink.RESCAN_MS and p.ms > 1000 then
        return
    end
    p.checkedAt = p.ms
    local implement = self.getImplementByObject ~= nil and self:getImplementByObject(object) or nil
    if implement == nil then
        spec.pending[object] = nil                               -- (not hitched any more)
    elseif not implement.attachingIsInProgress then
        local pair, d = BridgeLink.otherPair(self, object, p)
        if pair == nil then
            spec.pending[object] = nil                           -- (no second pair on these pieces: the one joint is all there is)
        elseif d > BridgeLink.settledFor(pair) and d <= BridgeLink.AUTO_PULL_M and not p.fromSave and not (isHeld(self) and isHeld(object)) then
            spec.pending[object] = nil                           -- (one pair joined, the other one close: swing it closed, the second joint is made when the points meet)
            spec.pulls[object] = { a = pair.a, b = pair.b, bar = pair.bar, ms = 0, pend = p }
            Logging.info("[BridgeLink] the other pair is %.2f m apart: the loose piece swings it closed", d)
        elseif d <= BridgeLink.settledFor(pair) or (p.fromSave and d <= BridgeLink.LOAD_MAX_M) then
            spec.pending[object] = nil
            removeLink(spec, object)
            if p.fromSave then
                local off = distance(pair.a, pair.b)                       -- (loose at the real offset: nothing for the solver to snap)
                spec.links[object] = BridgeLink.createJoint(self, object, pair, off)
                spec.upgrade = spec.upgrade or {}
                spec.upgrade[object] = { a = pair.a, b = pair.b, bar = pair.bar, hitch = p.hitch, eye = p.eye, ms = 0 }
            else
                spec.links[object] = BridgeLink.createJoint(self, object, pair)
            end
            Logging.info("[BridgeLink] second joint made (%s, gap %.3f m)", p.fromSave and "after a load, loose at its offset" or "after the attach", d)
        end
    end
end

-- ===== re-seat: a stretched link is pulled closed BEFORE the physics run =====
-- A chain that hangs over a canyon sags and stretches, and the savegame keeps the stretched poses. At a load the game makes its tight attach joints at those poses, and the solver closes every gap in ONE step: the speed is
-- about gap / step (4.7 m / 0.0167 s = 280 m/s: the throws in the log). So before the first physics step each hitched pair is looked at, from the roots of the chains outward: the child (and everything hanging on it) is moved by the
-- vector that brings its eye to a taut link's span from the ring's bar. Only the translation: the rings have leeway for the rest.
BridgeLink.RESEAT_MIN_M = 0.02
BridgeLink.RESEAT_MAX_M = 25

-- Pure: the vector to move the eye by, so that it lies RING_SPAN from the bar on the line towards it. eye, bar = { x, y, z }.
function BridgeLink.reseatShift(eye, bar, span)
    local dx, dy, dz = bar[1] - eye[1], bar[2] - eye[2], bar[3] - eye[3]
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d <= span + 1e-9 then
        return 0, 0, 0
    end
    local f = 1 - span / d
    return dx * f, dy * f, dz * f
end

local function shiftVehicle(vehicle, sx, sy, sz)
    for _, c in ipairs(vehicle.components or {}) do
        if c.node ~= nil and entityExists(c.node) then
            local x, y, z = getWorldTranslation(c.node)
            setWorldTranslation(c.node, x + sx, y + sy, z + sz)
        end
    end
    local pin = HandToolHammer ~= nil and HandToolHammer.pinned ~= nil and HandToolHammer.pinned[vehicle] or nil
    if pin ~= nil and pin.helper ~= nil and entityExists(pin.helper) then
        local x, y, z = getWorldTranslation(pin.helper)
        setWorldTranslation(pin.helper, x + sx, y + sy, z + sz)
    end
end

function BridgeLink.reseatChains()
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    local children, isChild, pieces = {}, {}, {}
    for _, v in ipairs(vehicles) do
        if not v.isDeleted and v[BridgeLink.SPEC_TABLE_NAME] ~= nil and v.isServer and v.spec_attacherJoints ~= nil then
            pieces[#pieces + 1] = v
            for _, implement in ipairs(v.spec_attacherJoints.attachedImplements or {}) do
                local obj = implement.object
                if obj ~= nil and obj[BridgeLink.SPEC_TABLE_NAME] ~= nil and obj.spec_attachable ~= nil then
                    children[v] = children[v] or {}
                    children[v][#children[v] + 1] = { object = obj, hitch = implement.jointDescIndex, eye = obj.spec_attachable.inputAttacherJointDescIndex }
                    isChild[obj] = true
                end
            end
        end
    end
    local moved, biggest, skipped, pinnedLinks = 0, 0, 0, 0
    local function subtree(v, out)
        out[#out + 1] = v
        for _, ch in ipairs(children[v] or {}) do subtree(ch.object, out) end
        return out
    end
    local function walk(v)
        for _, ch in ipairs(children[v] or {}) do
            local aj = v.spec_attacherJoints.attacherJoints
            local hitch = aj ~= nil and aj[ch.hitch] or nil
            local inputs = ch.object.spec_attachable.inputAttacherJoints
            local eye = inputs ~= nil and inputs[ch.eye or 0] or nil
            if hitch ~= nil and eye ~= nil and hitch.jointTransform ~= nil and eye.node ~= nil and entityExists(hitch.jointTransform) and entityExists(eye.node) then
                local ex, ey, ez = getWorldTranslation(eye.node)
                local bar = BridgeLink.barOf(v, hitch.jointTransform)
                local sx, sy, sz
                if bar ~= nil and entityExists(bar) then
                    local bx, by, bz = getWorldTranslation(bar)
                    sx, sy, sz = BridgeLink.reseatShift({ ex, ey, ez }, { bx, by, bz }, BridgeLink.RING_SPAN_M)
                else
                    local hx, hy, hz = getWorldTranslation(hitch.jointTransform)
                    sx, sy, sz = hx - ex, hy - ey, hz - ez
                end
                local len = math.sqrt(sx * sx + sy * sy + sz * sz)
                local members = subtree(ch.object, {})
                local held = false
                for _, member in ipairs(members) do
                    if member.hdPinned == true then held = true end
                end
                if held then
                    pinnedLinks = pinnedLinks + 1                                           -- (a pinned piece stays where it is saved: moving the subtree dragged the pinned end piece (and its pin) towards the start piece at every load, 0.27 m shorter each time)
                elseif len > BridgeLink.RESEAT_MIN_M and len <= BridgeLink.RESEAT_MAX_M then
                    for _, member in ipairs(members) do
                        shiftVehicle(member, sx, sy, sz)
                    end
                    moved = moved + 1
                    biggest = math.max(biggest, len)
                elseif len > BridgeLink.RESEAT_MAX_M then
                    skipped = skipped + 1
                end
            end
            walk(ch.object)
        end
    end
    for _, v in ipairs(pieces) do
        if not isChild[v] then
            walk(v)
        end
    end
    if pinnedLinks > 0 then
        Logging.info("[BridgeLink] reseat: %d link(s) with a pinned piece behind them left as saved", pinnedLinks)
    end
    if moved > 0 or skipped > 0 then
        Logging.info("[BridgeLink] reseat: %d stretched link(s) pulled closed before the physics (up to %.2f m)%s", moved, biggest, skipped > 0 and string.format("; %d link(s) more than %d m apart left to the home step", skipped, BridgeLink.RESEAT_MAX_M) or "")
    end
    return moved, biggest
end

-- SAVEGAME_LOADED comes before the game's pre-simulation (4 s of physics before the first frame): the second joints of the saved attaches are made now, not on the first update, so a bridge hangs on both its joints from the first physics step.
function BridgeLink.onSavegameLoaded()
    if HandToolHammer ~= nil and HandToolHammer.restorePinsEarly ~= nil then
        pcall(HandToolHammer.restorePinsEarly)                          -- (the unbury first, then the pins: the place a piece remembers must not be inside the ground, and the grates' pins hold them where they were saved)
    elseif HandToolHammer ~= nil and HandToolHammer.unburyAll ~= nil then
        pcall(HandToolHammer.unburyAll)
    end
    local starts, ends = BridgeLink.pairsNow()
    local okL, errL = pcall(BridgeLink.levelChains, starts, ends)       -- (a saved chain that sagged into the bars or drifted sideways goes back on the line)
    if not okL then
        Logging.warning("[BridgeLink] the level failed: %s", tostring(errL))
    end
    local okR, errR = pcall(BridgeLink.reseatChains)                    -- (then every stretched link is pulled closed: the solver would close it at 280 m/s)
    if not okR then
        Logging.warning("[BridgeLink] the re-seat failed: %s", tostring(errR))
    end
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    local made = 0
    for _, vehicle in ipairs(vehicles) do
        local spec = vehicle[BridgeLink.SPEC_TABLE_NAME]
        if spec ~= nil and vehicle.isServer and not vehicle.isDeleted and next(spec.pending or {}) ~= nil then
            for object, p in pairs(spec.pending) do
                if p.fromSave then
                    BridgeLink.processPending(vehicle, spec, object, p)
                    if spec.pending[object] == nil and spec.links[object] ~= nil then
                        made = made + 1
                    end
                end
            end
        end
    end
    if made > 0 then
        Logging.info("[BridgeLink] %d second joint(s) rebuilt BEFORE the game's pre-simulation (SAVEGAME_LOADED)", made)
    end
    if BridgeLink.BEAMS_ON then                                         -- (the steel profiles stand before the first physics step: the chain rests on them from the start)
        local okB, errB = pcall(BridgeLink.beamRun, starts, ends)
        if not okB then
            Logging.warning("[BridgeLink] the profiles could not be built at the load: %s", tostring(errB))
        end
    end
    BridgeLink.homeAll()
end

if g_messageCenter ~= nil and MessageType ~= nil and MessageType.SAVEGAME_LOADED ~= nil and not BridgeLink.loadedHooked then
    BridgeLink.loadedHooked = true
    g_messageCenter:subscribe(MessageType.SAVEGAME_LOADED, BridgeLink.onSavegameLoaded, BridgeLink)
end

-- ===== the connection indicator =====
-- Every hitched pair of bridge pieces has two joints: the game's attach (one hitch and its eye) and our second joint (the other hitch and eye). A flag over each: green = joined and the points together, yellow = the second joint is being closed,
-- orange = joined but the points have been pulled apart, red = no joint there. A line in the log says when a pair changes state (what the tractor did to it).
BridgeLink.STATUS_ON = true
BridgeLink.STATUS_RANGE_M = 30
BridgeLink.OK_GAP_M = 0.20               -- the points of a joined pair are this close (the ring's leeway, a loose joint's slack and a chain's wobble included: 1 to 15 cm was seen on a settled pair) or it counts as pulled apart
BridgeLink.STATUS_SCAN_MS = 500
BridgeLink.statusList, BridgeLink.statusMs, BridgeLink.statusLast = {}, 0, setmetatable({}, { __mode = "k" })

-- { pair1 = { x, y, z, gap }, pair2 = { x, y, z, gap, state } or nil, key } for the pieces `attacher` and `object` that are hitched together.
function BridgeLink.statusOf(attacher, object)
    local spec = attacher[BridgeLink.SPEC_TABLE_NAME]
    local aj = attacher.spec_attacherJoints
    if spec == nil or aj == nil then
        return nil
    end
    local first
    for _, implement in ipairs(aj.attachedImplements or {}) do
        if implement.object == object then
            first = implement
        end
    end
    if first == nil then
        return nil
    end
    local hitch = aj.attacherJoints[first.jointDescIndex]
    local inputs = object.spec_attachable ~= nil and object.spec_attachable.inputAttacherJoints or {}
    local eye = inputs[object.spec_attachable.inputAttacherJointDescIndex or 0]
    if hitch == nil or eye == nil or hitch.jointTransform == nil or eye.node == nil or not entityExists(hitch.jointTransform) or not entityExists(eye.node) then
        return nil
    end
    local st = { key = object }
    local x, y, z = getWorldTranslation(eye.node)
    st.pair1 = { x = x, y = y, z = z, gap = BridgeLink.gapOf({ a = hitch.jointTransform, b = eye.node, bar = BridgeLink.barOf(attacher, hitch.jointTransform) }) }
    local other, gap = BridgeLink.otherPair(attacher, object, { hitch = first.jointDescIndex, eye = object.spec_attachable.inputAttacherJointDescIndex })
    if other ~= nil then
        local ox, oy, oz = getWorldTranslation(other.b)
        local linked = spec.links[object] ~= nil
        local state = "none"
        if linked then
            state = gap <= BridgeLink.OK_GAP_M and "ok" or "apart"
        elseif spec.pulls[object] ~= nil or spec.pending[object] ~= nil then
            state = "closing"
        end
        st.pair2 = { x = ox, y = oy, z = oz, gap = gap, state = state }
    end
    return st
end

function BridgeLink.statusColor(pair, isFirst)
    if isFirst then
        return pair.gap <= BridgeLink.OK_GAP_M and { 0, 1, 0 } or { 1, 0.3, 0 }
    end
    local c = { ok = { 0, 1, 0 }, closing = { 1, 1, 0 }, apart = { 1, 0.3, 0 }, none = { 1, 0, 0 } }
    return c[pair.state]
end

-- joined and together: 5 cubes; being closed: 3; pulled apart: 2; no joint: 1
function BridgeLink.statusHeight(pair, isFirst)
    if isFirst then
        return pair.gap <= BridgeLink.OK_GAP_M and 5 or 2
    end
    return ({ ok = 5, closing = 3, apart = 2, none = 1 })[pair.state] or 1
end

-- ===== the real gap at a joint =====
-- The guide assumes 0.17 m between the frames of two hitched pieces (GUIDE_JOINT_GAP_M); the chain has the real figure: every hitched pair is measured (centre to centre minus both halves) and the guide takes the MEDIAN
-- once there are three samples. The ring has leeway (a few cm), so over 17 joints the span of a chain varies by tens of cm: sbBridgeMeasure shows min / median / max.
BridgeLink.GUIDE_JOINT_GAP_DEFAULT = 0.17
BridgeLink.gapSamples = setmetatable({}, { __mode = "k" })           -- hitched piece -> its last measured gap

function BridgeLink.pieceHalf(vehicle)
    local t = vehicle.typeName or ""
    if string.find(t, "bridgeGrate", 1, true) ~= nil then return 2.0 end
    if string.find(t, "bridgeStart", 1, true) ~= nil or string.find(t, "bridgeEnd", 1, true) ~= nil then return 0.8 end
    return nil
end

-- Pure: min, median, max of a list of numbers.
function BridgeLink.gapStats(list)
    if #list == 0 then
        return nil
    end
    local sorted = {}
    for i, v in ipairs(list) do sorted[i] = v end
    table.sort(sorted)
    local mid = #sorted % 2 == 1 and sorted[(#sorted + 1) / 2] or (sorted[#sorted / 2] + sorted[#sorted / 2 + 1]) / 2
    return sorted[1], mid, sorted[#sorted]
end

function BridgeLink.gapList()
    local list = {}
    for _, g in pairs(BridgeLink.gapSamples) do
        list[#list + 1] = g
    end
    return list
end

BridgeLink.GAP_CALIBRATE_MS = 30000
BridgeLink.gapCalibratedAt = nil
function BridgeLink.gapCalibrate()
    local list = BridgeLink.gapList()
    if #list < 3 then
        return
    end
    local now = g_time or 0
    if BridgeLink.gapCalibratedAt ~= nil and now >= BridgeLink.gapCalibratedAt and now - BridgeLink.gapCalibratedAt < BridgeLink.GAP_CALIBRATE_MS then
        return                                                          -- (the samples wobble with the ring leeway: a new median every half second would only make noise)
    end
    local _, med = BridgeLink.gapStats(list)
    BridgeLink.gapCalibratedAt = now
    if math.abs(med - BridgeLink.GUIDE_JOINT_GAP_M) > 0.03 then
        Logging.info("[BridgeLink] the joint gap measured on %d hitched pair(s): %.3f m (the guide assumed %.3f m): the spans follow it", #list, med, BridgeLink.GUIDE_JOINT_GAP_M)
        BridgeLink.GUIDE_JOINT_GAP_M = med
    end
end

function BridgeLink.consoleMeasure()
    local list = BridgeLink.gapList()
    local lo, med, hi = BridgeLink.gapStats(list)
    if lo == nil then
        return "no hitched bridge pieces measured yet"
    end
    local n = 16
    local text = string.format("%d hitched pair(s): the gap at a joint is min %.3f, median %.3f, max %.3f m (assumed %.3f); 16 grates between a start and an end piece then span %.2f m (min) .. %.2f m (max), the guide's %.2f m",
        #list, lo, med, hi, BridgeLink.GUIDE_JOINT_GAP_M, 1.6 + 4.0 * n + (n + 1) * lo, 1.6 + 4.0 * n + (n + 1) * hi, BridgeLink.guideSpan(n))
    Logging.info("[BridgeLink] measure: %s", text)
    return text
end
if addConsoleCommand ~= nil and not BridgeLink.measureConsole then
    BridgeLink.measureConsole = true
    addConsoleCommand("sbBridgeMeasure", "SandboxHammer: the measured gap at the joints of the hitched bridge pieces (min / median / max) and what it means for the span of a chain", "consoleMeasure", BridgeLink)
end

function BridgeLink.statusScan()
    local list, vehicles = {}, g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    for _, vehicle in ipairs(vehicles) do
        local spec = vehicle[BridgeLink.SPEC_TABLE_NAME]
        if spec ~= nil and vehicle.isServer and not vehicle.isDeleted and vehicle.spec_attacherJoints ~= nil then
            for _, implement in ipairs(vehicle.spec_attacherJoints.attachedImplements or {}) do
                local object = implement.object
                if object ~= nil and object[BridgeLink.SPEC_TABLE_NAME] ~= nil then
                    local ok, st = pcall(BridgeLink.statusOf, vehicle, object)
                    if ok and st ~= nil then
                        st.vehicleA, st.vehicleB = vehicle, object
                        list[#list + 1] = st
                        local hA, hB = BridgeLink.pieceHalf(vehicle), BridgeLink.pieceHalf(object)
                        if hA ~= nil and hB ~= nil and vehicle.components ~= nil and object.components ~= nil and st.pair1.gap <= BridgeLink.OK_GAP_M then
                            local ax, ay, az = getWorldTranslation(vehicle.components[1].node)
                            local bx, by, bz = getWorldTranslation(object.components[1].node)
                            local gap = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2) - hA - hB
                            if gap > -0.2 and gap < 0.8 then
                                BridgeLink.gapSamples[object] = gap
                            end
                        end
                        local now = string.format("%s/%s", st.pair1.gap <= BridgeLink.OK_GAP_M and "ok" or "apart", st.pair2 ~= nil and st.pair2.state or "single")
                        BridgeLink.statusSeen = BridgeLink.statusSeen or setmetatable({}, { __mode = "k" })
                        local seen = BridgeLink.statusSeen[object]
                        if seen == nil or seen.state ~= now then
                            BridgeLink.statusSeen[object] = { state = now, n = 1 }
                        else
                            seen.n = seen.n + 1
                        end
                        local stable = BridgeLink.statusSeen[object].n >= 2                  -- (a state is reported when it has been seen on two scans running: a wobble is no news)
                        if stable and BridgeLink.statusLast[object] ~= now then
                            if BridgeLink.statusLast[object] ~= nil then
                                Logging.info("[BridgeLink] %s -> %s: hitch %s (%.0f cm), second joint %s%s", tostring(vehicle.configFileName or "?"):match("([^/]+)%.xml$") or "?", tostring(object.configFileName or "?"):match("([^/]+)%.xml$") or "?",
                                    st.pair1.gap <= BridgeLink.OK_GAP_M and "ok" or "PULLED APART", 100 * st.pair1.gap, st.pair2 ~= nil and st.pair2.state or "none (no second pair)", st.pair2 ~= nil and string.format(" (%.0f cm)", 100 * st.pair2.gap) or "")
                            end
                            BridgeLink.statusLast[object] = now
                        end
                    end
                end
            end
        end
    end
    if BridgeLink.statusCount ~= #list then
        BridgeLink.statusCount = #list
        Logging.info("[BridgeLink] connection flags: %d hitched pair(s) of bridge pieces in the world", #list)
    end
    BridgeLink.statusList = list
    BridgeLink.gapCalibrate()
end

-- ===== the placement guide: where the end piece and the poles go =====
-- A pinned start piece gives the direction (the bridge goes on from its hitches, local -z). The pieces have fixed lengths, so the span is D(n) = both end pieces' halves + n grates + a small gap at every joint;
-- the guide draws a tick across the axis at every D(n), and for the n nearest to where the player stands the end piece's footprint and the two poles beside it, plus the two poles beside the start piece.
-- The squares follow the terrain. A square turns green when a pinned pole stands in it.
BridgeLink.GUIDE_ON = true
BridgeLink.GUIDE_RANGE_M = 70
BridgeLink.GUIDE_MAX_M = 100               -- no candidates beyond this span
BridgeLink.GUIDE_SCAN_M = 120              -- the far bank is looked for this far along the axis (terrain height every metre)
BridgeLink.GUIDE_DROP_M = 1.5              -- the ground is 'gone' when it lies this far under the start piece's deck ...
BridgeLink.GUIDE_BANK_M = 2.0              -- ... and the far bank is reached when it is back within this of the deck
BridgeLink.GUIDE_HALF_END = 0.8            -- half the end pieces (1.6 m)
BridgeLink.GUIDE_GRATE_M = 4.0
BridgeLink.GUIDE_JOINT_GAP_M = 0.17        -- the frames of two hitched pieces stand this far apart (two lugs and the ring's span)
BridgeLink.GUIDE_DECK_HALF_W = 1.5
BridgeLink.GUIDE_POLE_HALF = 0.55          -- a pole's plate is 1.1 m square
BridgeLink.GUIDE_POLE_SIDE = 1.5 + 0.1 + 0.55     -- a pole's centre: beside the deck with a hand's width between
BridgeLink.GUIDE_FIT_M = 0.7               -- a pole this close to a square's centre fills it
BridgeLink.guideStarts, BridgeLink.guidePoles, BridgeLink.guideEnds = {}, {}, {}
BridgeLink.guideKnown = setmetatable({}, { __mode = "k" })      -- start piece -> its last far-bank suggestion (the terrain is read once in a while, not every scan)

-- Centre-to-centre span of a start and an end piece with n grates between.
function BridgeLink.guideSpan(n)
    return 2 * BridgeLink.GUIDE_HALF_END + n * BridgeLink.GUIDE_GRATE_M + (n + 1) * BridgeLink.GUIDE_JOINT_GAP_M
end

-- The layout from a start piece at (ax, az) facing (fx, fz) (unit, horizontal): the near poles, and per n the end piece's centre and its two poles. Pure numbers.
function BridgeLink.guideLayout(ax, az, fx, fz)
    local rx, rz = -fz, fx
    local side = BridgeLink.GUIDE_POLE_SIDE
    local layout = { near = { { x = ax + rx * side, z = az + rz * side }, { x = ax - rx * side, z = az - rz * side } }, spans = {}, rx = rx, rz = rz }
    local n = 1
    while BridgeLink.guideSpan(n) <= BridgeLink.GUIDE_MAX_M do
        local d = BridgeLink.guideSpan(n)
        local ex, ez = ax + fx * d, az + fz * d
        layout.spans[n] = { n = n, d = d, x = ex, z = ez, poles = { { x = ex + rx * side, z = ez + rz * side }, { x = ex - rx * side, z = ez - rz * side } } }
        n = n + 1
    end
    return layout
end

-- The n whose end piece is nearest to the player's place along the axis (and the player is beside the axis, not far), or nil.
function BridgeLink.guideActive(layout, ax, az, fx, fz, px, pz)
    local t = (px - ax) * fx + (pz - az) * fz
    local lateral = math.abs((px - ax) * layout.rx + (pz - az) * layout.rz)
    if t < 1 or lateral > 14 then
        return nil
    end
    local best, bestD
    for n, sp in ipairs(layout.spans) do
        local d = math.abs(sp.d - t)
        if bestD == nil or d < bestD then
            best, bestD = n, d
        end
    end
    return best
end

-- The far bank along the axis (the "next hill"): from the start piece's height y0, the first place the ground falls away (more than GUIDE_DROP_M under it) and the first place after that where it is back up
-- (within GUIDE_BANK_M of it). heightAt(x, z) is the terrain height. Returns the distance of the bank's edge from the start piece, the n of the first span that reaches it (the end piece's centre 0.8 m past the edge) and the gap's width; or nil when the ground never falls away / never comes back.
function BridgeLink.guideSuggest(heightAt, ax, az, fx, fz, y0)
    local gapAt, farAt
    for d = 2, BridgeLink.GUIDE_SCAN_M do
        local h = heightAt(ax + fx * d, az + fz * d)
        if gapAt == nil then
            if h < y0 - BridgeLink.GUIDE_DROP_M then
                gapAt = d
            end
        elseif h >= y0 - BridgeLink.GUIDE_BANK_M then
            farAt = d
            break
        end
    end
    if gapAt == nil or farAt == nil then
        return nil
    end
    local n = 1
    while BridgeLink.guideSpan(n) < farAt + BridgeLink.GUIDE_HALF_END and BridgeLink.guideSpan(n) <= BridgeLink.GUIDE_MAX_M do
        n = n + 1
    end
    if BridgeLink.guideSpan(n) > BridgeLink.GUIDE_MAX_M then
        return nil
    end
    return farAt, n, farAt - gapAt
end

-- The far bank by rays, as the builder does it by eye: a horizontal ray along the axis at the deck's height runs until it hits the far hill; then the ray goes up in steps until it passes over the top.
-- cast(y) returns the distance of the first hit of a horizontal ray at height y above the deck (nil: nothing within range). Returns the distance of the lip (where the slope ends), its height over the deck, the first hit's distance, and the n of the first span that reaches it.
BridgeLink.GUIDE_RAY_STEP_M = 0.5
BridgeLink.GUIDE_RAY_UP_M = 30
BridgeLink.GUIDE_RAY_NEAR_M = 3          -- a hit this close is the start piece's own ground, not the far hill
function BridgeLink.guideFromRays(cast, from)
    from = from or 0
    local step = BridgeLink.GUIDE_RAY_STEP_M
    local first = cast(step)
    if first == nil or first < BridgeLink.GUIDE_RAY_NEAR_M then
        return nil
    end
    local lip, lipUp = first, step
    local up = step
    while up <= BridgeLink.GUIDE_RAY_UP_M do
        local d = cast(up)
        if d == nil then
            local n = 1
            while BridgeLink.guideSpan(n) < from + lip + BridgeLink.GUIDE_HALF_END and BridgeLink.guideSpan(n) <= BridgeLink.GUIDE_MAX_M do
                n = n + 1
            end
            if BridgeLink.guideSpan(n) > BridgeLink.GUIDE_MAX_M then
                return nil
            end
            return from + lip, lipUp, from + first, n
        end
        lip, lipUp = d, up
        up = up + step
    end
    return nil                                  -- (it never ends: a mountain, not a bank)
end

function BridgeLink.guideRayCallback(self, hitNode, x, y, z, distance)
    if hitNode ~= nil and distance ~= nil then
        BridgeLink.rayHit = distance
        return false
    end
    return true
end

-- Where the ground falls away: the first distance (every metre) where the terrain lies more than GUIDE_DROP_M under the deck height y0, or nil (no canyon in that direction).
function BridgeLink.guideGapStart(heightAt, ax, az, fx, fz, y0)
    for d = 2, BridgeLink.GUIDE_SCAN_M do
        if heightAt(ax + fx * d, az + fz * d) < y0 - BridgeLink.GUIDE_DROP_M then
            return d
        end
    end
    return nil
end

-- The game's version: terrain rays along the axis, starting where the ground has fallen away (a bump near the start piece is no far hill). The distances are from the start piece.
function BridgeLink.guideRaysInGame(ax, y0, az, fx, fz, from)
    if raycastClosest == nil or CollisionFlag == nil then
        return nil
    end
    local mask = CollisionFlag.TERRAIN + (CollisionFlag.TERRAIN_DELTA or 0)
    local ox, oz = ax + fx * (from or 0), az + fz * (from or 0)
    local lip, up, first, n = BridgeLink.guideFromRays(function(upM)
        BridgeLink.rayHit = nil
        raycastClosest(ox, y0 + upM, oz, fx, 0, fz, BridgeLink.GUIDE_SCAN_M, "guideRayCallback", BridgeLink, mask)
        return BridgeLink.rayHit
    end, from or 0)
    return lip, up, first, n
end

local function groundY(x, z)
    if g_terrainNode ~= nil and getTerrainHeightAtWorldPos ~= nil then
        return getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.05
    end
    return 0
end

-- a line along the ground between two points, bent to follow the terrain (a point every half metre)
local function groundLine(x0, z0, x1, z1, r, g, b, dashed)
    local len = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2)
    local steps = math.max(1, math.ceil(len / 0.5))
    local px, pz = x0, z0
    for i = 1, steps do
        local x, z = x0 + (x1 - x0) * i / steps, z0 + (z1 - z0) * i / steps
        if not dashed or i % 2 == 1 then                                          -- (dashed: every other half metre)
            drawDebugLine(px, groundY(px, pz), pz, r, g, b, x, groundY(x, z), z, r, g, b)
        end
        px, pz = x, z
    end
end

-- a rectangle on the ground: centre (cx, cz), half sizes along (ux, uz) and the perpendicular
local function groundRect(cx, cz, ux, uz, hu, hv, r, g, b, dashed)
    local vx, vz = -uz, ux
    local function corner(su, sv) return cx + ux * hu * su + vx * hv * sv, cz + uz * hu * su + vz * hv * sv end
    local x1, z1 = corner(1, 1)
    local x2, z2 = corner(1, -1)
    local x3, z3 = corner(-1, -1)
    local x4, z4 = corner(-1, 1)
    groundLine(x1, z1, x2, z2, r, g, b, dashed)
    groundLine(x2, z2, x3, z3, r, g, b, dashed)
    groundLine(x3, z3, x4, z4, r, g, b, dashed)
    groundLine(x4, z4, x1, z1, r, g, b, dashed)
end

local function poleIn(sq)
    for _, pole in ipairs(BridgeLink.guidePoles) do
        if math.sqrt((pole.x - sq.x) ^ 2 + (pole.z - sq.z) ^ 2) <= BridgeLink.GUIDE_FIT_M then
            return true
        end
    end
    return false
end

local function poleSquare(sq, ux, uz, fx, fz)
    local fit = poleIn(sq)
    if fx ~= nil then                                                          -- an arrow from the middle of the square: the way the pole's lower eye is to point (towards the other end)
        groundLine(sq.x, sq.z, sq.x + fx * 0.5, sq.z + fz * 0.5, 1, 1, 1)
        groundLine(sq.x + fx * 0.5, sq.z + fz * 0.5, sq.x + fx * 0.38 - fz * 0.09, sq.z + fz * 0.38 + fx * 0.09, 1, 1, 1)
        groundLine(sq.x + fx * 0.5, sq.z + fz * 0.5, sq.x + fx * 0.38 + fz * 0.09, sq.z + fz * 0.38 - fx * 0.09, 1, 1, 1)
    end
    groundRect(sq.x, sq.z, ux, uz, BridgeLink.GUIDE_POLE_HALF, BridgeLink.GUIDE_POLE_HALF, fit and 0 or 1, fit and 1 or 0.6, 0, not fit)
    groundLine(sq.x - 0.12, sq.z, sq.x + 0.12, sq.z, 1, 1, 1)               -- a cross where the post stands
    groundLine(sq.x, sq.z - 0.12, sq.x, sq.z + 0.12, 1, 1, 1)
end

-- A pinned pole beside the axis near the start piece or near one of the end piece spots: which zone, which n, and where its partner goes (the same distance along the axis, the other side, the same distance from it).
-- Returns { zone = "near" | "far", n = nil | n, pole = { x, z }, partner = { x, z } } or nil.
BridgeLink.GUIDE_ZONE_M = 3
function BridgeLink.guidePartner(a, layout, pole)
    local dx, dz = pole.x - a.x, pole.z - a.z
    local t = dx * a.fx + dz * a.fz
    local s = dx * layout.rx + dz * layout.rz
    if math.abs(s) < 1.2 or math.abs(s) > 3.6 then
        return nil
    end
    local zone, n = nil, nil
    if math.abs(t) <= BridgeLink.GUIDE_ZONE_M then
        zone = "near"
    else
        local bestD
        for i, sp in ipairs(layout.spans) do
            local d = math.abs(sp.d - t)
            if d <= BridgeLink.GUIDE_ZONE_M and (bestD == nil or d < bestD) then
                n, bestD = i, d
            end
        end
        if n ~= nil then
            zone = "far"
        end
    end
    if zone == nil then
        return nil
    end
    return { zone = zone, n = n, pole = { x = pole.x, z = pole.z }, partner = { x = a.x + a.fx * t - layout.rx * s, z = a.z + a.fz * t - layout.rz * s } }
end

-- A pinned end piece beside the axis at one of the spans: its n, or nil.
BridgeLink.GUIDE_END_ZONE_M = 3.5
function BridgeLink.guideEndAt(a, layout, e)
    local dx, dz = e.x - a.x, e.z - a.z
    local t = dx * a.fx + dz * a.fz
    local s = dx * layout.rx + dz * layout.rz
    if t <= BridgeLink.GUIDE_ZONE_M or math.abs(s) > 3 then
        return nil
    end
    local best, bestD
    for i, sp in ipairs(layout.spans) do
        local d = math.abs(sp.d - t)
        if d <= BridgeLink.GUIDE_END_ZONE_M and (bestD == nil or d < bestD) then
            best, bestD = i, d
        end
    end
    return best
end

local function drawPair(a, sq1, sq2, sign)
    sign = sign or 1                                                             -- (+1 near the start piece: the lower eyes point along the bridge; -1 at the far end: back)
    poleSquare(sq1, a.fx, a.fz, sign * a.fx, sign * a.fz)
    poleSquare(sq2, a.fx, a.fz, sign * a.fx, sign * a.fz)
end

-- ===== the fit: two pieces placed by eye -> the pose of both that closes the gap =====
-- The line between the two centres is the bridge axis (no right angles assumed). The fixed lengths allow the spans guideSpan(n) (measured along the slope); the n nearest to the real distance is taken, and the
-- shortfall or excess is shared: each piece moves half of it along the line, and both are turned to face along it. A piece's yaw (rotation about y) is the one in the game's units: a piece with its local +z towards
-- (sin yaw, cos yaw); the start piece's hitches (its local -z) look at the end piece, the end piece's eyes (its local +z) look at the start piece, so both have the same ideal yaw.
-- s, e = { x, y, z } (the centres). Returns a table or nil (too close, too far).
function BridgeLink.guideFit(s, e, sFixed, eFixed)
    local dx, dz = e.x - s.x, e.z - s.z
    local lh = math.sqrt(dx * dx + dz * dz)
    local dh = e.y - s.y
    local l3 = math.sqrt(lh * lh + dh * dh)
    if lh < 3 or l3 > BridgeLink.GUIDE_MAX_M then
        return nil
    end
    local ux, uz = dx / lh, dz / lh
    local n, bestD = 1, nil
    local k = 1
    while BridgeLink.guideSpan(k) <= BridgeLink.GUIDE_MAX_M + 5 do
        local d = math.abs(BridgeLink.guideSpan(k) - l3)
        if bestD == nil or d < bestD then
            n, bestD = k, d
        end
        k = k + 1
    end
    local span = BridgeLink.guideSpan(n)
    local idealH = math.sqrt(math.max(span * span - dh * dh, 0))                   -- the horizontal distance that makes the span along the slope
    local mx, mz = (s.x + e.x) / 2, (s.z + e.z) / 2
    local fit = {
        n = n, span = span, lh = lh, l3 = l3, dh = dh, ux = ux, uz = uz,
        yaw = math.deg(math.atan2(-ux, -uz)),                                      -- the same for both pieces
        slope = math.deg(math.atan2(dh, lh)),
        sFixed = sFixed == true, eFixed = eFixed == true,
        excess = l3 - span,                                                          -- positive: they stand too far apart
    }
    if sFixed and not eFixed then                                                    -- the pinned one stays, the other goes to its place on the line
        fit.start = { x = s.x, z = s.z }
        fit.stop = { x = s.x + ux * idealH, z = s.z + uz * idealH }
    elseif eFixed and not sFixed then
        fit.stop = { x = e.x, z = e.z }
        fit.start = { x = e.x - ux * idealH, z = e.z - uz * idealH }
    elseif sFixed and eFixed then                                                    -- both pinned: nothing to move, the excess says how far off the whole grates it is
        fit.start, fit.stop = { x = s.x, z = s.z }, { x = e.x, z = e.z }
    else                                                                              -- both loose: the correction is shared
        fit.start = { x = mx - ux * idealH / 2, z = mz - uz * idealH / 2 }
        fit.stop = { x = mx + ux * idealH / 2, z = mz + uz * idealH / 2 }
    end
    fit.startMove = math.sqrt((fit.start.x - s.x) ^ 2 + (fit.start.z - s.z) ^ 2)
    fit.stopMove = math.sqrt((fit.stop.x - e.x) ^ 2 + (fit.stop.z - e.z) ^ 2)
    -- along the line, forward = towards the other piece: the start piece forward is +u, the end piece forward is -u; positive = forward
    fit.startAlong = (fit.start.x - s.x) * ux + (fit.start.z - s.z) * uz
    fit.stopAlong = -((fit.stop.x - e.x) * ux + (fit.stop.z - e.z) * uz)
    fit.startSide = (fit.start.x - s.x) * -uz + (fit.start.z - s.z) * ux              -- sideways off the line (0 when the pieces stand on it: the midpoint is on the line, so this is the piece's own offset)
    fit.stopSide = (fit.stop.x - e.x) * -uz + (fit.stop.z - e.z) * ux
    return fit
end

-- A turn in degrees, to -180..180.
function BridgeLink.guideTurn(from, to)
    local d = (to - from) % 360
    return d > 180 and d - 360 or d
end

-- The nearest end piece in front of a start piece (within GUIDE_FIT_ANGLE degrees of its facing and the span limit), or nil.
BridgeLink.GUIDE_FIT_ANGLE = 35
function BridgeLink.guideEndFor(a, ends)
    local best, bestL
    for _, e in ipairs(ends) do
        local dx, dz = e.x - a.x, e.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 3 and l <= BridgeLink.GUIDE_MAX_M then
            local cos = (dx * a.fx + dz * a.fz) / l
            if math.deg(math.acos(math.max(-1, math.min(1, cos)))) <= BridgeLink.GUIDE_FIT_ANGLE and (bestL == nil or l < bestL) then
                best, bestL = e, l
            end
        end
    end
    return best
end

-- The axis aimed at a placed end piece: a start piece that does not quite face the end piece (a few degrees are 2 m at 60 m) would put every square beside the real poles. The end piece must stand
-- in front (more than 3.5 m, within AIM_LATERAL_M of the facing line) and the new direction must be within AIM_MAX_DEG of the facing. Returns the unit direction (fx, fz).
BridgeLink.GUIDE_AIM_LATERAL_M = 7
BridgeLink.GUIDE_AIM_MAX_DEG = 10
function BridgeLink.guideAimed(a, ends)
    local best, bestT
    for _, e in ipairs(ends) do
        local dx, dz = e.x - a.x, e.z - a.z
        local t = dx * a.fx + dz * a.fz
        local s = math.abs(dx * -a.fz + dz * a.fx)
        if t > 3.5 and s <= BridgeLink.GUIDE_AIM_LATERAL_M and (bestT == nil or t > bestT) then
            best, bestT = e, t
        end
    end
    if best == nil then
        return a.fx, a.fz
    end
    local dx, dz = best.x - a.x, best.z - a.z
    local l = math.sqrt(dx * dx + dz * dz)
    local fx, fz = dx / l, dz / l
    if math.deg(math.acos(math.max(-1, math.min(1, fx * a.fx + fz * a.fz)))) > BridgeLink.GUIDE_AIM_MAX_DEG then
        return a.fx, a.fz
    end
    return fx, fz
end

-- The fit, drawn: the line between the two centres, the ideal footprints of both (green) with their poles' squares, an arrow from each piece to its ideal place, and the numbers.
BridgeLink.GUIDE_OK_M = 0.2          -- a piece this close to its rectangle (centre) ...
BridgeLink.GUIDE_OK_DEG = 1.5        -- ... and this well turned: the rectangle is green, pin it
function BridgeLink.guideFitOk(piece, ideal, yaw)
    local d = math.sqrt((piece.x - ideal.x) ^ 2 + (piece.z - ideal.z) ^ 2)
    return d <= BridgeLink.GUIDE_OK_M and math.abs(BridgeLink.guideTurn(piece.yaw or yaw, yaw)) <= BridgeLink.GUIDE_OK_DEG
end

function BridgeLink.guideFitDraw(a, e, fit)
    local ux, uz = fit.ux, fit.uz
    local rx, rz = -uz, ux
    local sy, ey = a.y + 0.3, e.y + 0.3
    drawDebugLine(a.x, sy, a.z, 1, 1, 1, e.x, ey, e.z, 1, 1, 1)                                     -- the real line between the centres (white)
    local sgy, egy = groundY(fit.start.x, fit.start.z), groundY(fit.stop.x, fit.stop.z)
    local side = BridgeLink.GUIDE_POLE_SIDE
    local okS = fit.sFixed or BridgeLink.guideFitOk(a, fit.start, fit.yaw)
    local okE = fit.eFixed or BridgeLink.guideFitOk(e, fit.stop, fit.yaw)
    -- a piece that is fixed (pinned) has nothing to show; a loose one gets its rectangle: orange while it is off, green when it fits
    if not fit.sFixed then
        local c = okS and { 0, 1, 0 } or { 1, 0.3, 0 }
        groundRect(fit.start.x, fit.start.z, ux, uz, BridgeLink.GUIDE_HALF_END, BridgeLink.GUIDE_DECK_HALF_W, c[1], c[2], c[3], not okS)
        if not okS then
            drawDebugLine(a.x, sy, a.z, 1, 0.3, 0, fit.start.x, sgy + 0.3, fit.start.z, 1, 0.3, 0)
        end
    end
    if not fit.eFixed then
        local c = okE and { 0, 1, 0 } or { 1, 0.3, 0 }
        groundRect(fit.stop.x, fit.stop.z, ux, uz, BridgeLink.GUIDE_HALF_END, BridgeLink.GUIDE_DECK_HALF_W, c[1], c[2], c[3], not okE)
        if not okE then
            drawDebugLine(e.x, ey, e.z, 1, 0.3, 0, fit.stop.x, egy + 0.3, fit.stop.z, 1, 0.3, 0)
        end
    end
    for _, c in ipairs({ { fit.start, 1 }, { fit.stop, -1 } }) do                                   -- the poles' squares at both ends, the arrow towards the other end
        poleSquare({ x = c[1].x + rx * side, z = c[1].z + rz * side }, ux, uz, c[2] * ux, c[2] * uz)
        poleSquare({ x = c[1].x - rx * side, z = c[1].z - rz * side }, ux, uz, c[2] * ux, c[2] * uz)
    end
    if Utils ~= nil and Utils.renderTextAtWorldPosition ~= nil then                                  -- one short label, over the middle
        local label = (fit.sFixed and fit.eFixed) and string.format("both fixed: %.2f m %s than %d grate(s)", math.abs(fit.excess), fit.excess > 0 and "longer" or "shorter", fit.n)
            or ((okS and okE) and string.format("%d grate(s): fits, pin it", fit.n) or string.format("%d grate(s)", fit.n))
        Utils.renderTextAtWorldPosition((a.x + e.x) / 2, (a.y + e.y) / 2 + 0.9, (a.z + e.z) / 2, label, 0.016, 0, 1, 1, 1, 1)
    end
end

function BridgeLink.guideDraw(px, pz)
    if not BridgeLink.GUIDE_ON or drawDebugLine == nil then
        return
    end
    for _, a0 in ipairs(BridgeLink.guideStarts) do
        if BridgeLink.lockedStarts[a0.vehicle] ~= true and math.abs(a0.x - px) < BridgeLink.GUIDE_RANGE_M and math.abs(a0.z - pz) < BridgeLink.GUIDE_RANGE_M then
            local fitEnd = BridgeLink.guideEndFor(a0, BridgeLink.guideEnds)
            local fit = fitEnd ~= nil and BridgeLink.guideFit(a0, { x = fitEnd.x, y = fitEnd.y or a0.y, z = fitEnd.z }, a0.pinned, fitEnd.pinned) or nil
            if fit ~= nil then
                BridgeLink.guideFitDraw(a0, { x = fitEnd.x, y = fitEnd.y or a0.y, z = fitEnd.z, yaw = fitEnd.yaw }, fit)
            end
            if fit == nil and a0.pinned then
            local fx, fz = BridgeLink.guideAimed(a0, BridgeLink.guideEnds)
            if a0.aimX ~= nil and fx == a0.fx and fz == a0.fz then
                fx, fz = a0.aimX, a0.aimZ                                          -- (aimed at the point you marked)
            end
            local a = { x = a0.x, y = a0.y, z = a0.z, fx = fx, fz = fz, suggest = a0.suggest, farAt = a0.farAt, gapW = a0.gapW }
            local layout = BridgeLink.guideLayout(a.x, a.z, a.fx, a.fz)
            local active = BridgeLink.guideActive(layout, a.x, a.z, a.fx, a.fz, px, pz)
            -- the poles that stand there already: a far one picks the span (n) and the partner square; a near one just gets its partner
            local nearFound, farFound
            for _, pole in ipairs(BridgeLink.guidePoles) do
                local m = BridgeLink.guidePartner(a, layout, pole)
                if m ~= nil then
                    if m.zone == "near" and nearFound == nil then nearFound = m end
                    if m.zone == "far" and farFound == nil then farFound = m end
                end
            end
            local endFound
            for _, e in ipairs(BridgeLink.guideEnds) do
                local n = BridgeLink.guideEndAt(a, layout, e)
                if n ~= nil and endFound == nil then
                    endFound = { n = n, x = e.x, z = e.z }
                end
            end
            local suggest = a.suggest
            local shown = (endFound ~= nil and endFound.n) or (farFound ~= nil and farFound.n) or active or suggest
            if nearFound ~= nil then
                drawPair(a, nearFound.pole, nearFound.partner)
            else
                drawPair(a, layout.near[1], layout.near[2])
            end
            for n, sp in ipairs(layout.spans) do
                if shown == nil or math.abs(n - shown) <= 1 then                     -- (a tick for the nearby spans only: the rest is clutter)
                    local on = n == shown
                    local hasEnd = endFound ~= nil and endFound.n == n
                    local c = (hasEnd and { 0.2, 1, 0.3 }) or ((n == active or (farFound ~= nil and n == farFound.n)) and { 0.3, 0.8, 1 }) or (n == suggest and { 1, 0.55, 0.1 } or { 0.6, 0.6, 0.6 })
                    groundLine(sp.x - layout.rx * 2.0, sp.z - layout.rz * 2.0, sp.x + layout.rx * 2.0, sp.z + layout.rz * 2.0, c[1], c[2], c[3])
                    if on then
                        local cx, cz = sp.x, sp.z
                        local sq1, sq2 = sp.poles[1], sp.poles[2]
                        if hasEnd then                                                 -- the end piece that is there is the reference: its poles go beside IT
                            cx, cz = endFound.x, endFound.z
                            local side = BridgeLink.GUIDE_POLE_SIDE
                            sq1, sq2 = { x = cx + layout.rx * side, z = cz + layout.rz * side }, { x = cx - layout.rx * side, z = cz - layout.rz * side }
                        elseif farFound ~= nil and farFound.n == n then
                            sq1, sq2 = farFound.pole, farFound.partner                  -- the pole that is there, and where the other one goes
                        end
                        groundRect(cx, cz, a.fx, a.fz, BridgeLink.GUIDE_HALF_END, BridgeLink.GUIDE_DECK_HALF_W, c[1], c[2], c[3])       -- the end piece's footprint
                        local off = math.sqrt((cx - sp.x) ^ 2 + (cz - sp.z) ^ 2)
                        if hasEnd and off > 0.3 then                                        -- the end piece is not where the chain fits: the spot it would have is drawn too
                            groundRect(sp.x, sp.z, a.fx, a.fz, BridgeLink.GUIDE_HALF_END, BridgeLink.GUIDE_DECK_HALF_W, 0.3, 0.8, 1)
                        end
                        drawPair(a, sq1, sq2, -1)
                        if Utils ~= nil and Utils.renderTextAtWorldPosition ~= nil then
                            local rise = groundY(cx, cz) - a.y
                            local placed = (poleIn(sq1) and 1 or 0) + (poleIn(sq2) and 1 or 0)
                            local what = (n == suggest) and string.format("suggested: the far bank ends %.0f m away, ", a.farAt or 0) or ""
                            if hasEnd or farFound ~= nil then
                                what = string.format("%s, %d of 2 poles. ", hasEnd and (off > 0.3 and string.format("end piece placed %.1f m off its spot (blue)", off) or "end piece placed") or "end piece missing", placed)
                            end
                            Utils.renderTextAtWorldPosition(cx, groundY(cx, cz) + 1.4, cz, string.format("%s%d grate(s): end piece %.1f m from the start piece, ground %+.1f m", what, n, sp.d, rise), 0.016, 0, c[1], c[2], c[3], 1)
                        end
                    end
                end
            end
            end
        end
    end
end

-- Every half second: the pinned start pieces (centre, direction), and the poles and end pieces wherever they stand (loose ones too: the squares turn green as they are dragged into place).
function BridgeLink.guideScan()
    local starts, poles, ends = {}, {}, {}
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    for _, vehicle in ipairs(vehicles) do
        local name = vehicle.typeName
        local node = vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node or nil
        if name ~= nil and node ~= nil and not vehicle.isDeleted and entityExists(node) then
            if string.find(name, "bridgeStart", 1, true) ~= nil then
                do                                                                  -- (a loose start piece counts too: both pieces are placed by eye and the pinned one is the fixed reference)
                local x, y, z = getWorldTranslation(node)
                local dx, _, dz = localDirectionToWorld(node, 0, 0, -1)
                local l = math.sqrt(dx * dx + dz * dz)
                if l > 1e-6 then
                    local entry = { x = x, y = y, z = z, fx = dx / l, fz = dz / l, yaw = math.deg(math.atan2(-dx, -dz)), pinned = vehicle.hdPinned == true, vehicle = vehicle }
                    local old = BridgeLink.guideKnown[vehicle]
                    local now = g_time or 0
                    -- the far bank is looked for again only when the start piece has moved (0.3 m, 2 degrees), the target changed, or a minute has passed: it is dozens of rays
                    if old ~= nil and math.abs(old.x - x) < 0.3 and math.abs(old.z - z) < 0.3 and math.abs(BridgeLink.guideTurn(old.yaw or entry.yaw, entry.yaw)) < 2 and old.target == BridgeLink.guideTargetId and now - old.t < 60000 then
                        entry.farAt, entry.suggest, entry.gapW, entry.aimX, entry.aimZ = old.farAt, old.suggest, old.gapW, old.aimX, old.aimZ
                    else
                        local farAt, n, w
                        local target = BridgeLink.guideTarget
                        if target ~= nil then
                            -- you told it where you want to go (sbBridgeTarget): the direction is towards that point, the far bank ends at it
                            local tx, tz = target.x - x, target.z - z
                            local tl = math.sqrt(tx * tx + tz * tz)
                            if tl > 3 then
                                entry.aimX, entry.aimZ = tx / tl, tz / tl
                                farAt, w = tl, 0
                                n = 1
                                while BridgeLink.guideSpan(n) < tl + BridgeLink.GUIDE_HALF_END and BridgeLink.guideSpan(n) <= BridgeLink.GUIDE_MAX_M do n = n + 1 end
                                if BridgeLink.guideSpan(n) > BridgeLink.GUIDE_MAX_M then farAt, n = nil, nil end
                            end
                        else
                            local height = function(px, pz) return getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz) end
                            local okG, gapAt = pcall(BridgeLink.guideGapStart, height, x, z, entry.fx, entry.fz, y)
                            if okG and gapAt ~= nil then
                                local ok, lip, up, first, nr = pcall(BridgeLink.guideRaysInGame, x, y, z, entry.fx, entry.fz, gapAt)
                                if ok and lip ~= nil then
                                    farAt, n, w = lip, nr, lip - first
                                else
                                    local ok2, f2, n2, w2 = pcall(BridgeLink.guideSuggest, height, x, z, entry.fx, entry.fz, y)
                                    if ok2 and f2 ~= nil then farAt, n, w = f2, n2, w2 end
                                end
                            end
                        end
                        entry.farAt, entry.suggest, entry.gapW = farAt, n, w
                        if old == nil or old.suggest ~= n or math.abs((old.farAt or 0) - (farAt or 0)) > 1 then
                            if farAt ~= nil then
                                Logging.info("[BridgeLink] guide: the far bank ends %.0f m from the start piece (%s): %d grate(s) reach it", farAt, target ~= nil and "the point you marked" or string.format("a gap of %.0f m", w or 0), n)
                            else
                                Logging.info("[BridgeLink] guide: no far bank found in front of the start piece (no canyon, or none within %d m): put an end piece where it goes, or look at the spot and use sbBridgeTarget", BridgeLink.GUIDE_SCAN_M)
                            end
                        end
                        BridgeLink.guideKnown[vehicle] = { x = x, z = z, yaw = entry.yaw, t = now, farAt = farAt, suggest = n, gapW = w, aimX = entry.aimX, aimZ = entry.aimZ, target = BridgeLink.guideTargetId }
                    end
                    starts[#starts + 1] = entry
                end
                end
            elseif string.find(name, "bridgeEnd", 1, true) ~= nil then
                local x, y, z = getWorldTranslation(node)
                local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
                ends[#ends + 1] = { x = x, y = y, z = z, yaw = math.deg(math.atan2(dx, dz)), pinned = vehicle.hdPinned == true, vehicle = vehicle }
            elseif string.find(name, "winchPole", 1, true) ~= nil then
                local x, _, z = getWorldTranslation(node)
                local pdx, _, pdz = localDirectionToWorld(node, 0, 0, 1)
                poles[#poles + 1] = { x = x, z = z, vehicle = vehicle, pinned = vehicle.hdPinned == true, yaw = math.deg(math.atan2(pdx, pdz)) }
            end
        end
    end
    BridgeLink.guideStarts, BridgeLink.guidePoles, BridgeLink.guideEnds = starts, poles, ends
end

-- A bridge is locked when its start piece and end piece are pinned and every hitched grate on the line between them is pinned too: its guide and flags are not drawn any more (what shows is what is NOT pinned yet).
BridgeLink.lockedStarts = setmetatable({}, { __mode = "k" })
function BridgeLink.lockedScan()
    local locked = setmetatable({}, { __mode = "k" })
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    for _, a in ipairs(BridgeLink.guideStarts or {}) do
        local e = a.pinned and BridgeLink.guideEndFor(a, BridgeLink.guideEnds or {}) or nil
        if e ~= nil and e.pinned and a.vehicle ~= nil then
            local all, n = true, 0
            for _, v in ipairs(vehicles) do
                if BridgeLink.isGrate(v) and BridgeLink.isHitched(v) then
                    local x, y, z = getWorldTranslation(v.components[1].node)
                    local f, lat = BridgeLink.lockPose(a, e, x, y, z)
                    if f ~= nil and f > 0 and f < 1 and math.abs(lat) < 1.5 then
                        n = n + 1
                        if v.hdPinned ~= true then all = false end
                    end
                end
            end
            if all and n > 0 then locked[a.vehicle] = true end
        end
    end
    BridgeLink.lockedStarts = locked
end

-- sbBridgeShowCollision [on|off]: the real collision shapes of the bridge pieces as wire boxes within 40 m: the body hull of a grate, start or end piece (white) and the solid plate of every link ring (red).
BridgeLink.SHOW_COLLISION = false
BridgeLink.COLLISION_HULLS = {            -- local centre, half extents of the main hull (tools/make_selling_plate.py: one flat box), by piece
    bridgeGrate = { 0, 0.06, 0, 1.5, 0.06, 2.0 }, bridgeStart = { 0, 0.06, 0, 1.5, 0.06, 0.8 }, bridgeEnd = { 0, 0.06, 0, 1.5, 0.06, 0.8 },
}
BridgeLink.COLLISION_RING = { 0, 0, 0, 0.0125, 0.0675, 0.0675 }       -- the ring's hull_block: a thin solid plate, the ring's hole filled (RING_R + RING_r = 0.0675)
local BOX_EDGES = { { 1, 2 }, { 2, 4 }, { 4, 3 }, { 3, 1 }, { 5, 6 }, { 6, 8 }, { 8, 7 }, { 7, 5 }, { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 } }
local function drawBox(node, c, r, g, b)
    local pts = {}
    for _, sx in ipairs({ -1, 1 }) do
        for _, sy in ipairs({ -1, 1 }) do
            for _, sz in ipairs({ -1, 1 }) do
                local x, y, z = localToWorld(node, c[1] + sx * c[4], c[2] + sy * c[5], c[3] + sz * c[6])
                pts[#pts + 1] = { x, y, z }
            end
        end
    end
    for _, e in ipairs(BOX_EDGES) do
        local a, bb = pts[e[1]], pts[e[2]]
        drawDebugLine(a[1], a[2], a[3], r, g, b, bb[1], bb[2], bb[3], r, g, b)
    end
end
function BridgeLink.collisionDraw()
    if not BridgeLink.SHOW_COLLISION or g_localPlayer == nil or drawDebugLine == nil then
        return
    end
    local px, _, pz = g_localPlayer:getPosition()
    if px == nil then
        return
    end
    for _, v in ipairs(g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}) do
        local name = v.typeName ~= nil and (v.typeName:match("bridgeGrate") or v.typeName:match("bridgeStart") or v.typeName:match("bridgeEnd")) or nil
        local hull = name ~= nil and BridgeLink.COLLISION_HULLS[name] or nil
        if hull ~= nil and not v.isDeleted and v.components ~= nil and v.components[1] ~= nil and entityExists(v.components[1].node) then
            local x, _, z = getWorldTranslation(v.components[1].node)
            if math.abs(x - px) < 40 and math.abs(z - pz) < 40 then
                drawBox(v.components[1].node, hull, 1, 1, 1)
                for i = 2, #v.components do
                    if entityExists(v.components[i].node) then
                        drawBox(v.components[i].node, BridgeLink.COLLISION_RING, 1, 0, 0)
                    end
                end
            end
        end
    end
end
function BridgeLink.consoleShowCollision(_, arg)
    if arg == "on" then BridgeLink.SHOW_COLLISION = true elseif arg == "off" then BridgeLink.SHOW_COLLISION = false else BridgeLink.SHOW_COLLISION = not BridgeLink.SHOW_COLLISION end
    return string.format("collision shapes of the bridge pieces %s (white: the body hull, red: the link rings' solid plates)", BridgeLink.SHOW_COLLISION and "drawn" or "hidden")
end
if addConsoleCommand ~= nil and not BridgeLink.showCollisionConsole then
    BridgeLink.showCollisionConsole = true
    addConsoleCommand("sbBridgeShowCollision", "SandboxHammer: draw the collision shapes of the bridge pieces and their link rings [on|off]", "consoleShowCollision", BridgeLink)
end

function BridgeLink.statusDraw(dt)
    pcall(BridgeLink.collisionDraw)
    if g_currentMission == nil or g_localPlayer == nil or DebugUtil == nil or DebugUtil.drawSimpleDebugCube == nil or not (BridgeLink.STATUS_ON or BridgeLink.GUIDE_ON) then
        return
    end
    BridgeLink.statusMs = BridgeLink.statusMs + (dt or 0)
    if BridgeLink.statusMs >= BridgeLink.STATUS_SCAN_MS then
        BridgeLink.statusMs = 0
        BridgeLink.statusScan()
        BridgeLink.guideScan()
        BridgeLink.lockedScan()
    end
    local px, _, pz = g_localPlayer:getPosition()
    if px == nil then
        return
    end
    BridgeLink.guideDraw(px, pz)
    if not BridgeLink.STATUS_ON then
        return
    end
    for _, st in ipairs(BridgeLink.statusList) do
        local frozen = st.vehicleA ~= nil and st.vehicleB ~= nil and st.vehicleA.hdPinned == true and st.vehicleB.hdPinned == true      -- (a joint of two pinned pieces needs no flag: what is NOT pinned yet is what shows)
        for i, pair in ipairs({ st.pair1, st.pair2 or false }) do
            if pair and not frozen and math.abs(pair.x - px) < BridgeLink.STATUS_RANGE_M and math.abs(pair.z - pz) < BridgeLink.STATUS_RANGE_M then
                local c = BridgeLink.statusColor(pair, i == 1)
                local n = BridgeLink.statusHeight(pair, i == 1)
                for k = 0, n - 1 do                                       -- a flag: a column of cubes standing on the joint, the top one bigger; the HEIGHT says the state as well as the colour
                    DebugUtil.drawSimpleDebugCube(pair.x, pair.y + 0.08 + k * 0.1, pair.z, k == n - 1 and 0.16 or 0.05, c[1], c[2], c[3])
                end
            end
        end
    end
end

-- ===== the speed guard =====
-- A bridge piece that suddenly moves much faster than anything we do to it (a tractor, the hand winch, a swing: a few m/s) was thrown by the physics: overlapping bodies pushed apart, a joint snapping at a load. It is slowed
-- to the limit, and the log says how fast it was and when (so the cause can be found). Cheap: one velocity read per piece per frame; the list of pieces is made once a second.
BridgeLink.GUARD_ON = true
BridgeLink.GUARD_MAX_MS = 12            -- m/s (43 km/h)
BridgeLink.GUARD_MAX_RAD_S = 5          -- rad/s
BridgeLink.GUARD_FALL_MS = 60           -- m/s: a fall is not clamped below this
BridgeLink.guardPieces, BridgeLink.guardMs, BridgeLink.guardLogged = {}, 0, setmetatable({}, { __mode = "k" })

function BridgeLink.guardScan()
    local list, vehicles = {}, g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    for _, vehicle in ipairs(vehicles) do
        local node = vehicle[BridgeLink.SPEC_TABLE_NAME] ~= nil and vehicle.isServer and not vehicle.isDeleted and vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node or nil
        if node ~= nil and entityExists(node) then
            list[#list + 1] = { vehicle = vehicle, node = node }
        end
    end
    BridgeLink.guardPieces = list
end

-- Returns the factor the velocities were scaled by (1 when nothing was done).
function BridgeLink.guardOne(piece, now)
    local node = piece.node
    local vx, vy, vz = getLinearVelocity(node)
    local ax, ay, az = getAngularVelocity(node)
    -- the speed that matters is sideways and UPWARD: a fall is gravity, and a clamped fall looks like a feather (a piece let go in the air sailed down); only a crazy fall (GUARD_FALL_MS) is clamped
    local up = math.max(vy, 0)
    local v = math.sqrt(vx * vx + vz * vz + up * up)
    local w = math.sqrt(ax * ax + ay * ay + az * az)
    if v > BridgeLink.HOME_THROWN_MS then                                  -- (told to the home step: by the time it looks, the speed is clamped)
        BridgeLink.thrownNow = BridgeLink.thrownNow or setmetatable({}, { __mode = "k" })
        BridgeLink.thrownNow[piece.vehicle] = v
    end
    local fv = v > BridgeLink.GUARD_MAX_MS and BridgeLink.GUARD_MAX_MS / v or 1
    local fall = vy < -BridgeLink.GUARD_FALL_MS
    local fw = w > BridgeLink.GUARD_MAX_RAD_S and BridgeLink.GUARD_MAX_RAD_S / w or 1
    if fv < 1 or fall then
        local nvy = vy > 0 and vy * fv or (fall and -BridgeLink.GUARD_FALL_MS or vy)
        setLinearVelocity(node, vx * fv, nvy, vz * fv)
        fv = math.min(fv, fall and 0.99 or 1)
    end
    if fw < 1 then
        setAngularVelocity(node, ax * fw, ay * fw, az * fw)
    end
    if (fv < 1 or fw < 1) and (BridgeLink.guardLogged[piece.vehicle] == nil or now - BridgeLink.guardLogged[piece.vehicle] > 2000) then
        BridgeLink.guardLogged[piece.vehicle] = now
        local x, y, z = getWorldTranslation(node)
        local ground = (g_terrainNode ~= nil and getTerrainHeightAtWorldPos ~= nil) and getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) or nil
        -- what is within 3 m (the pieces, poles, anything): a thrown piece was usually pushed by something it overlapped
        local near = {}
        local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
        for _, other in ipairs(vehicles) do
            local on = other ~= piece.vehicle and not other.isDeleted and other.components ~= nil and other.components[1] ~= nil and other.components[1].node or nil
            if on ~= nil and entityExists(on) then
                local ox, oy, oz = getWorldTranslation(on)
                local d = math.sqrt((ox - x) ^ 2 + (oy - y) ^ 2 + (oz - z) ^ 2)
                if d < 3 and #near < 4 then
                    near[#near + 1] = string.format("%s %.1f m%s", tostring(other.configFileName or "?"):match("([^/]+)%.xml$") or "?", d, other.hdPinned and " pinned" or "")
                end
            end
        end
        Logging.info("[BridgeLink] speed guard: %s moved at %.1f m/s, turning %.1f rad/s: slowed to %d m/s, %d rad/s (at %.1f %.1f %.1f, the ground there is at %s; within 3 m: %s; this piece is %s, hitched to %s)", tostring(piece.vehicle.configFileName or "?"):match("([^/]+)%.xml$") or "?", v, w, BridgeLink.GUARD_MAX_MS, BridgeLink.GUARD_MAX_RAD_S, x, y, z,
            ground ~= nil and string.format("%.2f", ground) or "?", #near > 0 and table.concat(near, ", ") or "nothing", piece.vehicle.hdPinned and "pinned" or "loose",
            piece.vehicle.getAttacherVehicle ~= nil and piece.vehicle:getAttacherVehicle() ~= nil and tostring(piece.vehicle:getAttacherVehicle().configFileName or "?"):match("([^/]+)%.xml$") or "nothing")
    end
    return math.min(fv, fw)
end

function BridgeLink.guard(dt)
    if not BridgeLink.GUARD_ON then
        return
    end
    BridgeLink.guardMs = BridgeLink.guardMs + (dt or 0)
    if BridgeLink.guardMs >= 1000 then
        BridgeLink.guardMs = 0
        BridgeLink.guardScan()
    end
    local now = g_time or 0
    for _, piece in ipairs(BridgeLink.guardPieces) do
        if entityExists(piece.node) then
            BridgeLink.guardOne(piece, now)
        end
    end
end

-- ===== snapping: a loose piece put down close to its place goes the rest of the way =====
-- A start piece, an end piece or a pole that is loose, at rest (a moment), not in the hands, with nothing hitched to it, and within SNAP_M / SNAP_DEG of its place in the fit, is put exactly there (flat, a little above
-- the ground, and the physics let it settle). The target is the place on the line from the other piece (counted as fixed). A hitched piece is never moved: its chain would stay behind.
BridgeLink.SNAP_ON = true
BridgeLink.SNAP_M = 0.05              -- a loose piece this close to its place (5 cm) and this well turned ...
BridgeLink.SNAP_POLE_M = 0.5            -- a pole is optics: put into its square from half a metre, and turned (any angle) so its lower eye faces the other end
BridgeLink.SNAP_DEG = 3               -- ... (3 degrees) is put exactly there
BridgeLink.SNAP_REST_MS = 700
BridgeLink.SNAP_REST_SPEED = 0.15
BridgeLink.snapState = setmetatable({}, { __mode = "k" })

-- A pole's local +x (its lower eye, and the top eye on the same side) points along (dx, dz) when the pole's yaw is atan2(-dz, dx): a pole's local +z is (sin yaw, cos yaw), its +x (cos yaw, -sin yaw).
function BridgeLink.poleYawFor(dx, dz)
    return math.deg(math.atan2(-dz, dx))
end

-- Pure: is the piece close enough to its place (and not already there)?
function BridgeLink.snapWanted(piece, target, yaw, maxM, maxDeg)
    local d = math.sqrt((piece.x - target.x) ^ 2 + (piece.z - target.z) ^ 2)
    local turn = yaw ~= nil and piece.yaw ~= nil and math.abs(BridgeLink.guideTurn(piece.yaw, yaw)) or 0
    return d <= maxM and turn <= maxDeg and (d > 0.005 or turn > 0.3)
end

local function heldByHands(vehicle)
    local hands = g_localPlayer ~= nil and g_localPlayer.hands or nil
    local held = hands ~= nil and hands.spec_hands ~= nil and hands.spec_hands.heldItemNode or nil
    return held ~= nil and vehicle.components ~= nil and vehicle.components[1] ~= nil and held == vehicle.components[1].node
end

local function isFree(vehicle)
    if vehicle == nil or vehicle.isDeleted or vehicle.hdPinned == true or heldByHands(vehicle) then
        return false
    end
    if vehicle.getAttacherVehicle ~= nil and vehicle:getAttacherVehicle() ~= nil then
        return false
    end
    if vehicle.getAttachedImplements ~= nil and #vehicle:getAttachedImplements() > 0 then
        return false
    end
    return true
end

local function isResting(vehicle)
    local node = vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node or nil
    if node == nil or not entityExists(node) then
        return false
    end
    local vx, vy, vz = getLinearVelocity(node)
    local ax, ay, az = getAngularVelocity(node)
    return math.sqrt(vx * vx + vy * vy + vz * vz) < BridgeLink.SNAP_REST_SPEED and math.sqrt(ax * ax + ay * ay + az * az) < 0.3
end

function BridgeLink.snapTo(vehicle, x, z, yawDeg)
    local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.1
    vehicle:removeFromPhysics()
    vehicle:setAbsolutePosition(x, y, z, 0, math.rad(yawDeg), 0)
    vehicle:addToPhysics()
    for _, component in ipairs(vehicle.components) do
        if component.node ~= nil and entityExists(component.node) and getRigidBodyType(component.node) == RigidBodyType.DYNAMIC then
            setLinearVelocity(component.node, 0, 0, 0)
            setAngularVelocity(component.node, 0, 0, 0)
        end
    end
    vehicle:raiseActive()
end

-- Every update: counts how long each candidate has rested close to its place, and snaps it. Cheap: a few pieces, nothing when no start piece has an end piece in front.
function BridgeLink.snapStep(dt)
    if not BridgeLink.SNAP_ON then
        return
    end
    for _, a in ipairs(BridgeLink.guideStarts) do
        local e = BridgeLink.guideEndFor(a, BridgeLink.guideEnds)
        local fit = e ~= nil and BridgeLink.guideFit(a, { x = e.x, y = e.y or a.y, z = e.z }, a.pinned, e.pinned) or nil
        if fit ~= nil then
            local cands = {}
            local ee = { x = e.x, y = e.y or a.y, z = e.z }
            local now = g_time or 0
            -- each loose piece goes to its place on the line from the OTHER one (counted as fixed); only when it is within SNAP_M / SNAP_DEG of it
            if not a.pinned then
                local f = BridgeLink.guideFit(a, ee, false, true)
                if f ~= nil then cands[#cands + 1] = { piece = a, target = f.start, yaw = f.yaw, max = BridgeLink.SNAP_M } end
            end
            if not e.pinned then
                local f = BridgeLink.guideFit(a, ee, true, false)
                if f ~= nil then cands[#cands + 1] = { piece = e, target = f.stop, yaw = f.yaw, max = BridgeLink.SNAP_M } end
            end
            local side = BridgeLink.GUIDE_POLE_SIDE
            local rx, rz = -fit.uz, fit.ux
            local squares = {}
            -- a pole's lower eye (its local +x) points along the bridge towards the OTHER end: near poles along +u, far poles along -u
            for _, c in ipairs({ { fit.start, 1 }, { fit.stop, -1 } }) do
                local yaw = BridgeLink.poleYawFor(c[2] * fit.ux, c[2] * fit.uz)
                squares[#squares + 1] = { x = c[1].x + rx * side, z = c[1].z + rz * side, yaw = yaw }
                squares[#squares + 1] = { x = c[1].x - rx * side, z = c[1].z - rz * side, yaw = yaw }
            end
            local bothPlaced = (a.pinned or BridgeLink.guideFitOk(a, fit.start, fit.yaw)) and (e.pinned or BridgeLink.guideFitOk(e, fit.stop, fit.yaw))
            for _, pole in ipairs(BridgeLink.guidePoles) do
                if bothPlaced and not pole.pinned then                              -- (the poles' squares stand still only when both pieces are in place)
                    local best, bestD
                    for _, sq in ipairs(squares) do
                        local d = math.sqrt((pole.x - sq.x) ^ 2 + (pole.z - sq.z) ^ 2)
                        if bestD == nil or d < bestD then best, bestD = sq, d end
                    end
                    if best ~= nil then
                        cands[#cands + 1] = { piece = pole, target = best, yaw = best.yaw, max = BridgeLink.SNAP_POLE_M, maxDeg = 181 }
                    end
                end
            end
            for _, c in ipairs(cands) do
                local v = c.piece.vehicle
                local st = BridgeLink.snapState[v]
                if st == nil then st = { ms = 0 }; BridgeLink.snapState[v] = st end
                local wanted = v ~= nil and BridgeLink.snapWanted(c.piece, c.target, c.yaw, c.max, c.maxDeg or BridgeLink.SNAP_DEG)
                if wanted and not (isFree(v) and isResting(v)) and (st.said == nil or now - st.said > 15000) then   -- (it would snap: why it does not, said every 15 s)
                    st.said = now
                    local why = v.hdPinned and "it is pinned" or (heldByHands(v) and "it is in your hands" or ((v.getAttacherVehicle ~= nil and v:getAttacherVehicle() ~= nil) and "it hangs on another vehicle" or ((v.getAttachedImplements ~= nil and #v:getAttachedImplements() > 0) and "something is hitched to it (a hitched piece is never moved: its chain would stay behind)" or "it is still moving")))
                    Logging.info("[BridgeLink] snap: %s is %.2f m from its place but not snapped: %s", tostring(v.configFileName or "?"):match("([^/]+)%.xml$") or "?", math.sqrt((c.piece.x - c.target.x) ^ 2 + (c.piece.z - c.target.z) ^ 2), why)
                end
                if wanted and isFree(v) and isResting(v) then
                    st.ms = st.ms + (dt or 0)
                    if st.ms >= BridgeLink.SNAP_REST_MS then
                        st.ms = 0
                        BridgeLink.snapTo(v, c.target.x, c.target.z, c.yaw)
                        Logging.info("[BridgeLink] snapped %s to its place (%.2f m, %.1f deg off)", tostring(v.configFileName or "?"):match("([^/]+)%.xml$") or "?", math.sqrt((c.piece.x - c.target.x) ^ 2 + (c.piece.z - c.target.z) ^ 2), c.yaw ~= nil and math.abs(BridgeLink.guideTurn(c.piece.yaw or c.yaw, c.yaw)) or 0)
                    end
                else
                    st.ms = 0
                end
            end
        end
    end
end

-- ===== the guide wires, pulled by themselves =====
-- When the start piece and the end piece are both pinned and a pinned pole stands in each of their pole squares, the stiff steel cables between the poles are laid at once (left near pole to left far pole, right to
-- right) with FS25_WinchTow's wire (published on g_currentMission.winchTow): they get collision once still. The wires are not saved, but this lays them again after every load.
BridgeLink.AUTOWIRE_ON = true
BridgeLink.AUTOWIRE_MS = 2000
BridgeLink.AUTOWIRE_TOL_M = 1.2           -- a pole this close to a square's centre fills it
BridgeLink.autoWireMs, BridgeLink.autoWireDone = 0, setmetatable({}, { __mode = "k" })

-- Pure: from the fit (both pieces fixed) and the pole entries { x, z, pinned, vehicle }: the sides that have a pinned pole near AND far, { near, far, side }.
function BridgeLink.autoWirePairs(fit, poles)
    local rx, rz = -fit.uz, fit.ux
    local side = BridgeLink.GUIDE_POLE_SIDE
    local function find(c, sgn)
        local best, bestD
        for _, pole in ipairs(poles) do
            if pole.pinned then
                local d = math.sqrt((pole.x - (c.x + rx * side * sgn)) ^ 2 + (pole.z - (c.z + rz * side * sgn)) ^ 2)
                if d <= BridgeLink.AUTOWIRE_TOL_M and (bestD == nil or d < bestD) then
                    best, bestD = pole, d
                end
            end
        end
        return best
    end
    local pairs_ = {}
    for _, sgn in ipairs({ 1, -1 }) do
        local n, f = find(fit.start, sgn), find(fit.stop, sgn)
        if n ~= nil and f ~= nil then
            pairs_[#pairs_ + 1] = { near = n, far = f, side = sgn }
        end
    end
    return pairs_
end

function BridgeLink.autoWireStep(dt)
    if not BridgeLink.AUTOWIRE_ON then
        return
    end
    BridgeLink.autoWireMs = BridgeLink.autoWireMs + (dt or 0)
    if BridgeLink.autoWireMs < BridgeLink.AUTOWIRE_MS then
        return
    end
    BridgeLink.autoWireMs = 0
    local winch = g_currentMission ~= nil and g_currentMission.winchTow or nil
    if winch == nil or winch.layLatchWire == nil or winch.hasWireBetween == nil then
        return
    end
    for _, a in ipairs(BridgeLink.guideStarts) do
        local e = a.pinned and BridgeLink.guideEndFor(a, BridgeLink.guideEnds) or nil
        if e ~= nil and e.pinned then
            local fit = BridgeLink.guideFit(a, { x = e.x, y = e.y or a.y, z = e.z }, true, true)
            if fit ~= nil then
                for _, pr in ipairs(BridgeLink.autoWirePairs(fit, BridgeLink.guidePoles)) do
                    local va, vb = pr.near.vehicle, pr.far.vehicle
                    if va ~= nil and vb ~= nil and not va.isDeleted and not vb.isDeleted and not winch.hasWireBetween(va, vb) then
                        local done = BridgeLink.autoWireDone[va]
                        if done == nil or done.with ~= vb or (g_time or 0) - done.t > 15000 then   -- (a try that failed is repeated every 15 s; one that worked is not laid again unless the wire is gone and the poles moved)
                            BridgeLink.autoWireDone[va] = { with = vb, t = g_time or 0 }
                            local msg, why = winch.layLatchWire(va, vb)
                            Logging.info("[BridgeLink] guide wire between the poles (side %+d): %s", pr.side, msg ~= nil and tostring(msg) or ("not laid: " .. tostring(why)))
                        end
                    end
                end
            end
        end
    end
end

-- ===== the steel profiles under the bridge =====
-- With the start piece and the end piece both pinned, two H profiles (12 cm) run between them under the deck, 0.9 m either side of the centre line, their top 5 mm under the pieces' bottoms: along the real line between
-- the two (so a slope is followed). They are built from models/beamSegment.i3d (tools/make_beam_segment.py): one body of thin collision slabs on the TOP face, 4 m each, and the visual profile scaled along its length
-- to fit. Only the top is solid: the panels of the chain rest on it, whatever else the profile does (in the ground at the banks) touches nothing.
-- Built again after every load (nothing is saved). They stay when a piece is unpinned for a moment; rebuilt when both are pinned again and a piece has moved.
BridgeLink.BEAMS_ON = true
BridgeLink.BEAM_OFFSET_M = 0.9
BridgeLink.BEAM_DROP_M = 0.05             -- the profile's top lies this far under the pieces' bottoms (the rings' leeway is 2.5 cm: a profile closer than that overlaps the pieces and SHOVES them: the rebuild loop of 2026-11-17)
BridgeLink.BEAM_VEHICLES = true           -- the profiles carry vehicles (the chain rests on them); false: only the player, the hands, a horse and the terrain touch them (sbBridgeBeams novehicles)
BridgeLink.BEAM_MASK_NO_VEHICLE = 0xfe3efb83     -- the asset's mask 0xfe3ffb83 without the VEHICLE bit 0x10000
BridgeLink.BEAM_MASK_ALL = 0xfe3ffb83
BridgeLink.BEAM_MOVED_M = 0.15            -- rebuilt only when a piece has moved this far (a pinned piece under a chain's pull gives a few cm)
BridgeLink.BEAM_MS = 2000
BridgeLink.beamTemplate, BridgeLink.beamMs, BridgeLink.beamState = nil, 0, setmetatable({}, { __mode = "k" })
BridgeLink.beamVisualOnly = setmetatable({}, { __mode = "k" })      -- nodes that are a look only (no physics to remove)

local function loadBeamTemplate()
    local t = BridgeLink.beamTemplate
    if t ~= nil and entityExists(t.root) and entityExists(t.child) and entityExists(t.vis) then
        return t
    end
    if g_i3DManager == nil or BridgeLink.modDir == nil then
        return nil
    end
    local ok, node = pcall(g_i3DManager.loadI3DFile, g_i3DManager, BridgeLink.modDir .. "models/beamSegment.i3d", false, false)
    if not ok or node == nil or node == 0 then
        Logging.info("[BridgeLink] the beam model could not be loaded: %s", tostring(node))
        BridgeLink.BEAMS_ON = false
        return nil
    end
    local group = getChildAt(node, 0)
    local root, child, vis = getChild(group, "beamRoot"), getChild(group, "beamChild"), getChild(group, "beamVisual")
    if root == nil or root == 0 or child == nil or child == 0 or vis == nil or vis == 0 then
        Logging.info("[BridgeLink] the beam model has no beamRoot / beamChild / beamVisual")
        BridgeLink.BEAMS_ON = false
        return nil
    end
    BridgeLink.beamTemplate = { node = node, root = root, child = child, vis = vis }
    return BridgeLink.beamTemplate
end

local function placeBeam(node, x, y, z, dx, dy, dz, up)
    local ux, uy, uz = 0, 1, 0
    if up ~= nil then
        ux, uy, uz = up[1], up[2], up[3]                                                  -- (a kerb is turned on its side: its solid face looks to the middle of the deck)
    elseif math.abs(dy) > 0.99 then
        ux, uy, uz = 1, 0, 0
    end
    setWorldTranslation(node, x, y, z)
    setWorldDirection(node, dx, dy, dz, ux, uy, uz)
end

-- One profile between two points: returns a list of root nodes (the engine takes 40 children per compound body at most: one body per BEAM_CHUNK metres, the visuals hang under their body), or nil.
BridgeLink.BEAM_CHUNK = 32
BridgeLink.BEAM_UNIT_M = 4.0              -- the model's length (tools/make_beam_segment.py): the collision cannot be stretched, so a profile is a row of these; the visual is stretched to the spacing
function BridgeLink.beamBuild(ax, ay, az, bx, by, bz, up, visualOnly)
    local t = loadBeamTemplate()
    local dx, dy, dz = bx - ax, by - ay, bz - az
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if t == nil or length < 1 then
        return nil
    end
    dx, dy, dz = dx / length, dy / length, dz / length
    local n = math.max(1, math.ceil(length / BridgeLink.BEAM_UNIT_M))
    local step = length / n
    local roots, cols = {}, {}
    if visualOnly then                                                                    -- (a strut or a post: the look only, no body, nothing to shove)
        local ok, v = pcall(function()
            local node = clone(t.vis, true)
            placeBeam(node, ax + dx * length / 2, ay + dy * length / 2, az + dz * length / 2, dx, dy, dz, up)
            setScale(node, 1, 1, length * 1.002 / BridgeLink.BEAM_UNIT_M)
            link(getRootNode(), node)
            BridgeLink.beamVisualOnly[node] = true
            return node
        end)
        if not ok then
            Logging.info("[BridgeLink] a steel strut could not be built: %s", tostring(v))
            return nil
        end
        return { v }, {}
    end
    local ok, err = pcall(function()
        local first = 1
        while first <= n do
            local last = math.min(n, first + BridgeLink.BEAM_CHUNK - 1)
            local s0 = (first - 0.5) * step
            local r = clone(t.root, true)
            cols[#cols + 1] = r
            placeBeam(r, ax + dx * s0, ay + dy * s0, az + dz * s0, dx, dy, dz, up)
            for i = first + 1, last do                                              -- (the collision is a row of fixed units: the engine cannot stretch it)
                local c = clone(t.child, true)
                cols[#cols + 1] = c
                link(r, c)
                placeBeam(c, ax + dx * (i - 0.5) * step, ay + dy * (i - 0.5) * step, az + dz * (i - 0.5) * step, dx, dy, dz, up)
            end
            -- the look is ONE profile for the whole body, stretched to its length (a visual can be stretched: no need for a piece per unit)
            local mid = ((first - 1) + last) / 2 * step
            local v = clone(t.vis, true)
            link(r, v)
            placeBeam(v, ax + dx * mid, ay + dy * mid, az + dz * mid, dx, dy, dz, up)
            setScale(v, 1, 1, (last - first + 1) * step * 1.002 / BridgeLink.BEAM_UNIT_M)
            link(getRootNode(), r)
            addToPhysics(r)
            roots[#roots + 1] = r
            first = last + 1
        end
        if not BridgeLink.BEAM_VEHICLES then
            for _, node in ipairs(cols) do setCollisionFilterMask(node, BridgeLink.BEAM_MASK_NO_VEHICLE) end
        end
    end)
    if not ok then
        Logging.info("[BridgeLink] a steel profile could not be built: %s", tostring(err))
        for _, r in ipairs(roots) do
            if entityExists(r) then pcall(removeFromPhysics, r); delete(r) end
        end
        return nil
    end
    return roots, cols
end

function BridgeLink.beamDestroy(state)
    for _, r in ipairs(state.roots or {}) do
        if r ~= nil and entityExists(r) then
            if not BridgeLink.beamVisualOnly[r] then
                pcall(removeFromPhysics, r)
            end
            delete(r)
        end
    end
    state.roots, state.cols, state.key = {}, {}, nil
end

-- Pure: the two profiles' end points from the two pieces' bottom centres (x, y, z): { { a = {x,y,z}, b = {x,y,z} }, ... } and a key that changes when any of them moves 2 cm.
BridgeLink.BEAM_POST_M = 0.74             -- a kerb's end post reaches this far under the kerb's middle: into the ground
BridgeLink.KERB_FROM_M = 0.8              -- a kerb starts at an end piece's inner face (its half length)
BridgeLink.KERB_FACE_M = 1.72             -- the kerb's inner (solid) face, from the centre line: the grates' edge is 1.5, their winch latches reach 1.68
BridgeLink.KERB_RISE_M = 0.02             -- the kerb's middle above the pieces' bottoms (12 cm high: from 4 cm under to 8 cm over the grate's bottom)
BridgeLink.BEAM_STUB_M = 2.8             -- at each end the profile goes on this far into the bank (past the piece's outer end) ...
BridgeLink.BEAM_SINK_M = 0.35           -- ... sloping this much down: it looks sunk into the ground
function BridgeLink.beamPlan(s, e)
    local dx, dz = e.x - s.x, e.z - s.z
    local lh = math.sqrt(dx * dx + dz * dz)
    if lh < 3 then
        return nil
    end
    local ux, uz = dx / lh, dz / lh
    local rx, rz = -uz, ux
    local off, drop = BridgeLink.BEAM_OFFSET_M, BridgeLink.BEAM_DROP_M + 0.06
    local ext, sink = BridgeLink.BEAM_STUB_M, BridgeLink.BEAM_SINK_M
    local plan = {}
    for _, sgn in ipairs({ 1, -1 }) do
        local a = { x = s.x + rx * off * sgn, y = s.y - drop, z = s.z + rz * off * sgn }
        local b = { x = e.x + rx * off * sgn, y = e.y - drop, z = e.z + rz * off * sgn }
        plan[#plan + 1] = { a = a, b = b }                                                                  -- the profile between the pieces
        plan[#plan + 1] = { a = { x = a.x - ux * ext, y = a.y - sink, z = a.z - uz * ext }, b = a }          -- the stub into the bank behind the start piece
        plan[#plan + 1] = { a = b, b = { x = b.x + ux * ext, y = b.y - sink, z = b.z + uz * ext } }          -- the stub into the bank behind the end piece
    end
    -- the kerbs: a low steel rail on each side of the deck, its solid face KERB_GAP_M outside the grates' edge, from one end piece's inner face to the other's, so a grate that drifts is stopped
    local half, span = BridgeLink.KERB_FROM_M, lh
    if span > 2 * half + 1 then
        local f0, f1 = half / span, 1 - half / span
        local lat = BridgeLink.KERB_FACE_M + 0.06
        for _, sgn in ipairs({ 1, -1 }) do
            local function at(f, y) return { x = s.x + dx * f + rx * lat * sgn, y = y, z = s.z + dz * f + rz * lat * sgn } end
            local ya, yb = s.y + BridgeLink.KERB_RISE_M, e.y + BridgeLink.KERB_RISE_M
            plan[#plan + 1] = { a = at(f0, ya + (yb - ya) * f0), b = at(f1, ya + (yb - ya) * f1), up = { -sgn * rx, 0, -sgn * rz } }
        end
        -- what holds them (the look only, no collision): a post at each kerb end that goes BEAM_POST_M into the ground, and every 4 m a strut from the profile out to the kerb
        local n = math.max(1, math.ceil((f1 - f0) * span / BridgeLink.BEAM_UNIT_M))
        for _, sgn in ipairs({ 1, -1 }) do
            local function at(f, y, l) return { x = s.x + dx * f + rx * l * sgn, y = y, z = s.z + dz * f + rz * l * sgn } end
            for _, f in ipairs({ f0, f1 }) do
                local ky = s.y + BridgeLink.KERB_RISE_M + (e.y - s.y) * f
                plan[#plan + 1] = { a = at(f, ky - 0.04, lat), b = at(f, ky - BridgeLink.BEAM_POST_M, lat), visual = true }
            end
            for i = 0, n do
                local f = f0 + (f1 - f0) * i / n
                local sy = s.y - BridgeLink.BEAM_DROP_M - 0.06 + (e.y - s.y) * f
                plan[#plan + 1] = { a = at(f, sy, off), b = at(f, sy, lat), visual = true }
            end
        end
    end
    return plan, { s.x, s.y, s.z, e.x, e.y, e.z }
end

-- Pure: did either piece move more than BEAM_MOVED_M since the profiles were built (a pinned piece jitters, and a chain pulls it a few cm: no key that rounds)?
function BridgeLink.beamMoved(old, new)
    if old == nil then
        return true
    end
    for i = 1, 6 do
        if math.abs(old[i] - new[i]) > BridgeLink.BEAM_MOVED_M then
            return true
        end
    end
    return false
end

-- The keeper: a pin is a joint (soft under force), so a pinned start/end piece or pole that lies more than KEEP_M from its pin's helper body is put back on it (pose, no velocity) twice a second.
-- Beyond KEEP_MAX_M something else is wrong (the home step deals with throws). Logged when the drift changes by 5 cm and on every put-back.
BridgeLink.KEEP_M = 0.03
BridgeLink.KEEP_MAX_M = 1.5
BridgeLink.KEEP_TILT_RAD = 0.02          -- about 1 degree
BridgeLink.KEEP_MS = 500
BridgeLink.keepMs, BridgeLink.pinDrift = 0, setmetatable({}, { __mode = "k" })
BridgeLink.KEEP_ON = true
function BridgeLink.consoleKeep(_, arg)
    if arg == "on" then BridgeLink.KEEP_ON = true elseif arg == "off" then BridgeLink.KEEP_ON = false end
    return string.format("pin keeper %s (it only looks and logs when off)", BridgeLink.KEEP_ON and "on" or "off")
end
if addConsoleCommand ~= nil and not BridgeLink.keepConsole then
    BridgeLink.keepConsole = true
    addConsoleCommand("sbBridgeKeep", "SandboxHammer: the pin keeper puts a drifted pinned piece back [on|off]", "consoleKeep", BridgeLink)
end
function BridgeLink.pinDriftStep(dt)
    BridgeLink.keepMs = BridgeLink.keepMs + (dt or 0)
    if BridgeLink.keepMs < BridgeLink.KEEP_MS then
        return
    end
    BridgeLink.keepMs = 0
    local pins = HandToolHammer ~= nil and HandToolHammer.pinned or nil
    if pins == nil then
        return
    end
    for _, list in ipairs({ BridgeLink.guideStarts, BridgeLink.guideEnds, BridgeLink.guidePoles }) do
        for _, a in ipairs(list) do
            local v = a.vehicle
            local pin = v ~= nil and pins[v] or nil
            local node = pin ~= nil and v.components ~= nil and v.components[1] ~= nil and v.components[1].node or nil
            if node ~= nil and pin.helper ~= nil and entityExists(node) and entityExists(pin.helper) then
                local x, y, z = getWorldTranslation(node)
                local hx, hy, hz = getWorldTranslation(pin.helper)
                local d = math.sqrt((x - hx) ^ 2 + (y - hy) ^ 2 + (z - hz) ^ 2)
                local last = BridgeLink.pinDrift[v] or 0
                local nux, nuy, nuz = localDirectionToWorld(node, 0, 1, 0)                   -- (a tall post under a wire's pull tips about its base: its origin does not move, so the tilt is looked at too)
                local pux, puy, puz = localDirectionToWorld(pin.helper, 0, 1, 0)
                local tilt = math.acos(math.max(-1, math.min(1, nux * pux + nuy * puy + nuz * puz)))
                if (d > BridgeLink.KEEP_M and d < BridgeLink.KEEP_MAX_M) or (tilt > BridgeLink.KEEP_TILT_RAD and tilt < 0.9) then
                    d = math.max(d, 0.0001)
                    if (v.hdKeepLogAt or 0) + 5000 < (g_time or 0) then                          -- (a winch pulling on a pole puts it back every half second: one log line per 5 s)
                        v.hdKeepLogAt = g_time or 0
                        local vx, vy, vz = getLinearVelocity(node)
                        Logging.info("[BridgeLink] pinned %s had drifted %.2f m, tilted %.1f deg from its pin (%+.2f %+.2f %+.2f, speed %.2f m/s at %.1f %.1f %.1f)%s", tostring(v.typeName), d, math.deg(tilt), x - hx, y - hy, z - hz, math.sqrt(vx * vx + vy * vy + vz * vz), hx, hy, hz, BridgeLink.KEEP_ON and ": put back" or ": left")
                    end
                    if BridgeLink.KEEP_ON then
                        local rx, ry, rz = getWorldRotation(pin.helper)
                        setWorldRotation(node, rx, ry, rz)
                        setWorldTranslation(node, hx, hy, hz)
                        setLinearVelocity(node, 0, 0, 0)
                        setAngularVelocity(node, 0, 0, 0)
                    end
                    BridgeLink.pinDrift[v] = 0
                elseif math.abs(d - last) >= 0.05 then
                    BridgeLink.pinDrift[v] = d
                    Logging.info("[BridgeLink] pinned %s is %.2f m from its pin (was %.2f)", tostring(v.typeName), d, last)
                end
            end
        end
    end
end

-- One pass over the pinned start pieces and their end pieces: profiles built, or rebuilt when a piece has moved; the lists come from the guide scan (every 0.5 s) or, at a load, from pairsNow.
function BridgeLink.beamRun(starts, ends)
    local seen = {}
    for _, a in ipairs(starts) do
        local e = a.pinned and BridgeLink.guideEndFor(a, ends) or nil
        local v = a.vehicle
        if v ~= nil then
            seen[v] = true
            local st = BridgeLink.beamState[v]
            if st == nil then st = { roots = {} }; BridgeLink.beamState[v] = st end
            if e ~= nil and e.pinned then
                local plan, key = BridgeLink.beamPlan({ x = a.x, y = a.y, z = a.z }, { x = e.x, y = e.y or a.y, z = e.z })
                if plan ~= nil and BridgeLink.beamMoved(st.key, key) then
                    BridgeLink.beamDestroy(st)
                    for _, p in ipairs(plan) do
                        local rs, cs = BridgeLink.beamBuild(p.a.x, p.a.y, p.a.z, p.b.x, p.b.y, p.b.z, p.up, p.visual)
                        for _, r in ipairs(rs or {}) do st.roots[#st.roots + 1] = r end
                        st.cols = st.cols or {}
                        for _, c in ipairs(cs or {}) do st.cols[#st.cols + 1] = c end
                    end
                    st.key = key
                    Logging.info("[BridgeLink] steel profiles built under the bridge: %d body(ies) (two profiles and their stubs into the banks, at most %d boxes each), %.1f m between the end pieces", #st.roots, BridgeLink.BEAM_CHUNK, math.sqrt((e.x - a.x) ^ 2 + (e.z - a.z) ^ 2))
                end
            end                                                                                 -- (a piece unpinned for a moment: the profiles stay; they are rebuilt when both are pinned again somewhere else)
        end
    end
    for v, st in pairs(BridgeLink.beamState) do
        if not seen[v] and st.key ~= nil then
            BridgeLink.beamDestroy(st)
        end
    end
end

function BridgeLink.beamStep(dt)
    BridgeLink.pinDriftStep(dt)
    BridgeLink.lockStep(dt)
    if not BridgeLink.BEAMS_ON then
        return
    end
    BridgeLink.beamMs = BridgeLink.beamMs + (dt or 0)
    if BridgeLink.beamMs < BridgeLink.BEAM_MS then
        return
    end
    BridgeLink.beamMs = 0
    BridgeLink.beamRun(BridgeLink.guideStarts, BridgeLink.guideEnds)
end

-- ===== the bridge is locked to its profiles =====
-- A finished bridge (start piece and end piece pinned, the profiles built) pins every grate that rests on the profiles: a pinned grate stays where it is saved, so nothing sags through the steel bars when a savegame loads, and the clamps
-- (hidden nodes of the grate, shown while it is pinned: HandToolHammer.setPinVisuals) look like what holds it. sbBridgeLock [on|off|now|unlock].
BridgeLink.LOCK_ON = true
BridgeLink.LOCK_MS = 1000
BridgeLink.LOCK_STEPS = 3                 -- a grate must rest (almost no speed) this many looks in a row
BridgeLink.LOCK_REST_MS = 0.15            -- m/s
BridgeLink.LOCK_DY_M = 0.12               -- it rests on the profile when its height is this near the line between the pieces
BridgeLink.LOCK_LAT_M = 0.3
BridgeLink.lockMs = 0

-- Pure: where a piece at (x, y, z) is against the line from piece a to piece e: the fraction along it (0 at a, 1 at e), the sideways offset (right of the line is positive) and how far it lies BELOW the line (height error, up is positive).
function BridgeLink.lockPose(a, e, x, y, z)
    local dx, dz = e.x - a.x, e.z - a.z
    local lh = math.sqrt(dx * dx + dz * dz)
    if lh < 3 then
        return nil
    end
    local ux, uz = dx / lh, dz / lh
    local px, pz = x - a.x, z - a.z
    local f = (px * ux + pz * uz) / lh
    local lat = px * (-uz) + pz * ux
    local line = a.y + ((e.y or a.y) - a.y) * f
    return f, lat, line - y
end

local function isGrate(v)
    return v ~= nil and not v.isDeleted and v.typeName ~= nil and string.find(v.typeName, "bridgeGrate", 1, true) ~= nil and v.components ~= nil and v.components[1] ~= nil and v.components[1].node ~= nil and entityExists(v.components[1].node)
end

local function isHitched(v)
    return (v.getAttacherVehicle ~= nil and v:getAttacherVehicle() ~= nil) or (v.getAttachedImplements ~= nil and #v:getAttachedImplements() > 0)
end

BridgeLink.isGrate, BridgeLink.isHitched = isGrate, isHitched

-- The pinned start pieces, and the end pieces wherever they stand, with no terrain rays (the guide scan does those): for a load.
function BridgeLink.pairsNow()
    local starts, ends = {}, {}
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    for _, vehicle in ipairs(vehicles) do
        local name = vehicle.typeName
        local node = vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node or nil
        if name ~= nil and node ~= nil and not vehicle.isDeleted and entityExists(node) then
            local x, y, z = getWorldTranslation(node)
            if string.find(name, "bridgeStart", 1, true) ~= nil then
                local dx, _, dz = localDirectionToWorld(node, 0, 0, -1)
                local l = math.sqrt(dx * dx + dz * dz)
                if l > 1e-6 then
                    starts[#starts + 1] = { x = x, y = y, z = z, fx = dx / l, fz = dz / l, yaw = math.deg(math.atan2(-dx, -dz)), pinned = vehicle.hdPinned == true, vehicle = vehicle }
                end
            elseif string.find(name, "bridgeEnd", 1, true) ~= nil then
                local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
                ends[#ends + 1] = { x = x, y = y, z = z, yaw = math.deg(math.atan2(dx, dz)), pinned = vehicle.hdPinned == true, vehicle = vehicle }
            end
        end
    end
    return starts, ends
end

-- The complete bridges: { a = start entry, e = end entry } for every pinned start piece with a pinned end piece in front.
function BridgeLink.completePairs(starts, ends)
    local out = {}
    for _, a in ipairs(starts) do
        local e = a.pinned and BridgeLink.guideEndFor(a, ends) or nil
        if e ~= nil and e.pinned then
            out[#out + 1] = { a = a, e = e }
        end
    end
    return out
end

-- At a load: a grate of a saved chain that lies off the line (sagged into the bars, or drifted sideways: the profiles were not there to carry it) is put back on the line, every body of it by the same vector
-- (and its pin helper), before anything moves. Only a hitched grate between two pinned pieces, up to LEVEL_MAX_M off.
BridgeLink.LEVEL_MAX_M = 1.5
function BridgeLink.levelChains(starts, ends)
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    local moved, biggest = 0, 0
    for _, pair in ipairs(BridgeLink.completePairs(starts, ends)) do
        local dx, dz = pair.e.x - pair.a.x, pair.e.z - pair.a.z
        local lh = math.sqrt(dx * dx + dz * dz)
        local rx, rz = -dz / lh, dx / lh
        for _, v in ipairs(vehicles) do
            if isGrate(v) and isHitched(v) then
                local x, y, z = getWorldTranslation(v.components[1].node)
                local f, lat, dy = BridgeLink.lockPose(pair.a, pair.e, x, y, z)
                if f ~= nil and f > 0 and f < 1 and math.abs(lat) < BridgeLink.LEVEL_MAX_M and math.abs(dy) < BridgeLink.LEVEL_MAX_M and (math.abs(lat) > 0.05 or math.abs(dy) > 0.03) then
                    local mx, mz = -lat * rx, -lat * rz
                    for _, c in ipairs(v.components) do
                        if c.node ~= nil and entityExists(c.node) then
                            local cx, cy, cz = getWorldTranslation(c.node)
                            setWorldTranslation(c.node, cx + mx, cy + dy, cz + mz)
                        end
                    end
                    local pin = HandToolHammer ~= nil and HandToolHammer.pinned[v] or nil
                    if pin ~= nil and pin.helper ~= nil and entityExists(pin.helper) then
                        local hx, hy, hz = getWorldTranslation(pin.helper)
                        setWorldTranslation(pin.helper, hx + mx, hy + dy, hz + mz)
                    end
                    moved = moved + 1
                    biggest = math.max(biggest, math.abs(lat), math.abs(dy))
                end
            end
        end
    end
    if moved > 0 then
        Logging.info("[BridgeLink] level: %d grate(s) lay off the line between the pinned pieces and were put back on it (up to %.2f m), before the physics", moved, biggest)
    end
end

function BridgeLink.lockStep(dt)
    if not BridgeLink.LOCK_ON or HandToolHammer == nil or HandToolHammer.pinVehicle == nil then
        return
    end
    BridgeLink.lockMs = BridgeLink.lockMs + (dt or 0)
    if BridgeLink.lockMs < BridgeLink.LOCK_MS then
        return
    end
    BridgeLink.lockMs = 0
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    for _, pair in ipairs(BridgeLink.completePairs(BridgeLink.guideStarts, BridgeLink.guideEnds)) do
        local st = BridgeLink.beamState[pair.a.vehicle]
        if st ~= nil and st.key ~= nil then                                         -- (only once the profiles are there to rest on)
            for _, v in ipairs(vehicles) do
                if isGrate(v) and v.hdPinned ~= true and isHitched(v) then
                    local node = v.components[1].node
                    local x, y, z = getWorldTranslation(node)
                    local f, lat, dy = BridgeLink.lockPose(pair.a, pair.e, x, y, z)
                    if f ~= nil and f > 0 and f < 1 and math.abs(lat) < BridgeLink.LOCK_LAT_M and math.abs(dy) < BridgeLink.LOCK_DY_M then
                        local vx, vy, vz = getLinearVelocity(node)
                        local rest = math.sqrt(vx * vx + vy * vy + vz * vz) < BridgeLink.LOCK_REST_MS
                        v.hdLockRest = rest and (v.hdLockRest or 0) + 1 or 0
                        if v.hdLockRest >= BridgeLink.LOCK_STEPS then
                            v.hdLockRest = nil
                            if HandToolHammer.pinVehicle(v) then
                                Logging.info("[BridgeLink] locked a grate to the profiles (%.0f%% along, %.2f m off the line, %.2f m off the height)", f * 100, lat, dy)
                            end
                        end
                    else
                        v.hdLockRest = nil
                    end
                end
            end
        end
    end
end

-- sbBridgePinMass [grate tons] [ring tons]: the mass of a PINNED grate (and of its link rings), changed live for every pinned grate: a heavy tractor on light jointed bodies jitters (mass ratio); try 20 1. 0 = back to the xml's.
function BridgeLink.consolePinMass(_, grate, ring)
    local g, r = tonumber(grate), tonumber(ring)
    if HandToolHammer == nil or HandToolHammer.PIN_MASS_T == nil then
        return "the Hammer is not there"
    end
    if g ~= nil then HandToolHammer.PIN_MASS_T.bridgeGrate = g > 0 and g or nil end
    if r ~= nil then HandToolHammer.PIN_RING_T.bridgeGrate = r > 0 and r or nil end
    local n = 0
    for _, v in ipairs(g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}) do
        if isGrate(v) and v.hdPinned == true then
            HandToolHammer.setPinMass(v, false)
            HandToolHammer.setPinMass(v, true)
            n = n + 1
        end
    end
    return string.format("pinned grates weigh %s t, their rings %s t (%d pinned grate(s) changed); not saved: set it again after a restart", tostring(HandToolHammer.PIN_MASS_T.bridgeGrate or "the xml's"), tostring(HandToolHammer.PIN_RING_T.bridgeGrate or "the xml's"), n)
end
if addConsoleCommand ~= nil and not BridgeLink.pinMassConsole then
    BridgeLink.pinMassConsole = true
    addConsoleCommand("sbBridgePinMass", "SandboxHammer: mass of the pinned grates and their rings in tons, live [grate t] [ring t] (0 = the xml's)", "consolePinMass", BridgeLink)
end

-- sbBridgeLock [on|off|now|unlock]: "now" locks the resting grates at once, "unlock" lets every grate between the pinned pieces go and switches the automatic lock off.
function BridgeLink.consoleLock(_, arg)
    if arg == "on" then BridgeLink.LOCK_ON = true elseif arg == "off" then BridgeLink.LOCK_ON = false end
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    local n = 0
    if arg == "now" or arg == "unlock" then
        if arg == "unlock" then BridgeLink.LOCK_ON = false end
        for _, v in ipairs(vehicles) do
            if isGrate(v) then
                if arg == "unlock" and v.hdPinned == true and HandToolHammer ~= nil and HandToolHammer.unpinVehicle(v) then
                    n = n + 1
                elseif arg == "now" then
                    v.hdLockRest = BridgeLink.LOCK_STEPS
                    n = n + 1
                end
            end
        end
        if arg == "now" then BridgeLink.lockMs = BridgeLink.LOCK_MS end
    end
    return string.format("lock of the grates %s%s", BridgeLink.LOCK_ON and "on" or "off", arg == "unlock" and string.format(" (%d unpinned)", n) or (arg == "now" and " (looking now)" or ""))
end
if addConsoleCommand ~= nil and not BridgeLink.lockConsole then
    BridgeLink.lockConsole = true
    addConsoleCommand("sbBridgeLock", "SandboxHammer: pin the grates that rest on the steel profiles of a finished bridge [on|off|now|unlock]", "consoleLock", BridgeLink)
end

-- sbBridgeBeams [on|off|vehicles|novehicles]: "novehicles" lets a bridge piece or a vehicle pass through the profiles (at once, on the ones that stand)
function BridgeLink.consoleBeams(_, arg)
    if arg == "on" then BridgeLink.BEAMS_ON = true elseif arg == "off" then
        BridgeLink.BEAMS_ON = false
        for _, st in pairs(BridgeLink.beamState) do BridgeLink.beamDestroy(st) end
    elseif arg == "vehicles" or arg == "novehicles" then
        BridgeLink.BEAM_VEHICLES = arg == "vehicles"
        local mask = BridgeLink.BEAM_VEHICLES and BridgeLink.BEAM_MASK_ALL or BridgeLink.BEAM_MASK_NO_VEHICLE
        for _, st in pairs(BridgeLink.beamState) do
            for _, node in ipairs(st.cols or {}) do
                if entityExists(node) then setCollisionFilterMask(node, mask) end
            end
        end
    end
    return string.format("steel profiles %s, %s (both end pieces pinned)", BridgeLink.BEAMS_ON and "on" or "off", BridgeLink.BEAM_VEHICLES and "carry vehicles" or "vehicles pass through")
end
if addConsoleCommand ~= nil and not BridgeLink.beamsConsole then
    BridgeLink.beamsConsole = true
    addConsoleCommand("sbBridgeBeams", "SandboxHammer: the two steel profiles under the bridge between the pinned start and end piece [on|off|vehicles|novehicles]", "consoleBeams", BridgeLink)
end

-- ===== home: a thrown piece is put back =====
-- At a load (after the unbury, before the physics warm-up) every bridge piece, pole and anchor remembers its pose (all its bodies). It follows legitimate moves (a piece that rests 2 s somewhere else has a new home).
-- A piece that is THROWN goes back, with its velocities zeroed: faster than 40 m/s (nothing we do comes near), a jump of more than 60 m in one step (the game's own "reset to shop"), and, in the first 20 s after a load,
-- more than 5 m from its home. Whatever stood on it stays where it fell: the tractor on a bridge that was thrown ends up in the ditch.
BridgeLink.HOME_ON = true
BridgeLink.HOME_MS = 500
BridgeLink.HOME_THROWN_MS = 40
BridgeLink.HOME_JUMP_M = 60
BridgeLink.HOME_LOAD_WINDOW_MS = 20000
BridgeLink.HOME_LOAD_DRIFT_M = 5
BridgeLink.HOME_REST_MS = 2000
BridgeLink.HOME_MAX_TRIES = 3
BridgeLink.home = setmetatable({}, { __mode = "k" })
BridgeLink.homeMs, BridgeLink.homeSinceLoadMs = 0, 1e9

-- ===== the homes are saved: a piece that was thrown AND saved starts from its last good place =====
-- The homes live in bridgeHome.xml in the savegame folder, written whenever the game saves (FSBaseMission.saveSavegame), keyed by the vehicle's unique id. At a load a piece that lies more than HOME_SAVED_FAR_M from
-- its saved home was saved while thrown: it is put back at once (before the physics warm-up), and the saved home stays its home.
BridgeLink.HOME_FILE = "bridgeHome.xml"
BridgeLink.HOME_SAVED_FAR_M = 20

function BridgeLink.homeSave()
    local dir = g_currentMission ~= nil and g_currentMission.missionInfo ~= nil and g_currentMission.missionInfo.savegameDirectory or nil
    if dir == nil or XMLFile == nil then
        return
    end
    local xml = XMLFile.create("bridgeHomeXML", dir .. "/" .. BridgeLink.HOME_FILE, "bridgeHome")
    if xml == nil then
        return
    end
    local i = 0
    for v, rec in pairs(BridgeLink.home) do
        if not v.isDeleted and v.getUniqueId ~= nil and v:getUniqueId() ~= nil then
            local key = string.format("bridgeHome.piece(%d)", i)
            xml:setString(key .. "#uniqueId", v:getUniqueId())
            for j, c in ipairs(rec.comps) do
                xml:setString(string.format("%s.c(%d)#pose", key, j - 1), string.format("%.4f %.4f %.4f %.5f %.5f %.5f", c[1], c[2], c[3], c[4], c[5], c[6]))
            end
            i = i + 1
        end
    end
    xml:save()
    xml:delete()
end

-- uniqueId -> { comps }, or {} when there is no file
function BridgeLink.homeLoadSaved()
    local out = {}
    local dir = g_currentMission ~= nil and g_currentMission.missionInfo ~= nil and g_currentMission.missionInfo.savegameDirectory or nil
    if dir == nil or XMLFile == nil or fileExists == nil or not fileExists(dir .. "/" .. BridgeLink.HOME_FILE) then
        return out
    end
    local xml = XMLFile.load("bridgeHomeXML", dir .. "/" .. BridgeLink.HOME_FILE)
    if xml == nil then
        return out
    end
    xml:iterate("bridgeHome.piece", function(_, key)
        local id = xml:getString(key .. "#uniqueId")
        if id ~= nil then
            local comps = {}
            xml:iterate(key .. ".c", function(j, ckey)
                local p = {}
                for num in string.gmatch(xml:getString(ckey .. "#pose", ""), "%S+") do p[#p + 1] = tonumber(num) end
                if #p == 6 then comps[j] = p end
            end)
            if comps[1] ~= nil then out[id] = comps end
        end
    end)
    xml:delete()
    return out
end

-- Pure: was the piece saved far from its saved home (thrown and saved)?
function BridgeLink.homeSavedFar(cur, saved)
    return math.sqrt((cur[1] - saved[1]) ^ 2 + (cur[2] - saved[2]) ^ 2 + (cur[3] - saved[3]) ^ 2) > BridgeLink.HOME_SAVED_FAR_M
end

if FSBaseMission ~= nil and FSBaseMission.saveSavegame ~= nil and Utils ~= nil and not BridgeLink.homeSaveHooked then
    BridgeLink.homeSaveHooked = true
    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, function()
        local ok, err = pcall(BridgeLink.homeSave)
        if not ok then
            Logging.warning("[BridgeLink] the homes could not be saved: %s", tostring(err))
        end
    end)
end

local function homeKind(vehicle)
    local t = vehicle.typeName
    return t ~= nil and (string.find(t, "bridge", 1, true) ~= nil or string.find(t, "winchPole", 1, true) ~= nil or string.find(t, "winchAnchor", 1, true) ~= nil)
end

-- Pure: what is to be done with a piece. st = { last = {x,y,z}, restMs, tries, since }, p = its position, home = its home position, speed, held, sinceLoadMs, dtMs.
-- Returns "thrown" (put it back), "rehome" (it has rested somewhere else: that is home now) or nil.
function BridgeLink.homeVerdict(st, p, home, speed, held, sinceLoadMs, dtMs)
    local function dist(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2) end
    local jumped = st.last ~= nil and dist(p, st.last) > BridgeLink.HOME_JUMP_M
    st.last = { p[1], p[2], p[3] }
    local fromHome = dist(p, home)
    if jumped or speed > BridgeLink.HOME_THROWN_MS or (sinceLoadMs < BridgeLink.HOME_LOAD_WINDOW_MS and not held and fromHome > BridgeLink.HOME_LOAD_DRIFT_M) then
        st.restMs = 0
        return "thrown"
    end
    if speed < 0.2 and not held then
        st.restMs = (st.restMs or 0) + dtMs
        if st.restMs >= BridgeLink.HOME_REST_MS and fromHome > 0.05 then
            st.restMs = 0
            return "rehome"
        end
    else
        st.restMs = 0
    end
    return nil
end

function BridgeLink.homeSnapshot(vehicle)
    local comps = {}
    for i, c in ipairs(vehicle.components or {}) do
        if c.node ~= nil and entityExists(c.node) then
            local x, y, z = getWorldTranslation(c.node)
            local rx, ry, rz = getWorldRotation(c.node)
            comps[i] = { x, y, z, rx, ry, rz }
        end
    end
    return comps[1] ~= nil and comps or nil
end

function BridgeLink.homeAll()
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    local saved = BridgeLink.homeLoadSaved()
    local n, back = 0, 0
    for _, v in ipairs(vehicles) do
        if not v.isDeleted and homeKind(v) and v.isServer then
            local snap = BridgeLink.homeSnapshot(v)
            if snap ~= nil then
                local id = v.getUniqueId ~= nil and v:getUniqueId() or nil
                local old = id ~= nil and saved[id] or nil
                if old ~= nil and BridgeLink.homeSavedFar(snap[1], old[1]) then
                    -- saved while thrown: back at its last good place now, before the physics run (and it is its home)
                    Logging.info("[BridgeLink] home: %s was saved %.0f m from its last good place: put back", tostring(v.configFileName or "?"):match("([^/]+)%.xml$") or "?", math.sqrt((snap[1][1] - old[1][1]) ^ 2 + (snap[1][2] - old[1][2]) ^ 2 + (snap[1][3] - old[1][3]) ^ 2))
                    BridgeLink.homeTeleport(v, old)
                    snap = old
                    back = back + 1
                end
                BridgeLink.home[v] = { comps = snap, st = { tries = 0 } }
                n = n + 1
            end
        end
    end
    if back > 0 and HandToolHammer ~= nil and HandToolHammer.unburyAll ~= nil then
        pcall(HandToolHammer.unburyAll)                                         -- (a saved place may lie inside terrain that was raised since)
    end
    BridgeLink.homeSinceLoadMs = 0
    if n > 0 then
        Logging.info("[BridgeLink] home: %d piece(s) remember their place (%d put back from the saved homes; a thrown one is put back)", n, back)
    end
end

function BridgeLink.homeTeleport(vehicle, comps)
    for i, c in ipairs(vehicle.components or {}) do
        local h = comps[i]
        if h ~= nil and c.node ~= nil and entityExists(c.node) then
            setWorldRotation(c.node, h[4], h[5], h[6])
            setWorldTranslation(c.node, h[1], h[2], h[3])
            if getRigidBodyType(c.node) == RigidBodyType.DYNAMIC then
                setLinearVelocity(c.node, 0, 0, 0)
                setAngularVelocity(c.node, 0, 0, 0)
            end
        end
    end
    if vehicle.raiseActive ~= nil then vehicle:raiseActive() end
end

function BridgeLink.homeStep(dt)
    if not BridgeLink.HOME_ON then
        return
    end
    BridgeLink.homeSinceLoadMs = BridgeLink.homeSinceLoadMs + (dt or 0)
    BridgeLink.homeMs = BridgeLink.homeMs + (dt or 0)
    if BridgeLink.homeMs < BridgeLink.HOME_MS then
        return
    end
    local dtMs = BridgeLink.homeMs
    BridgeLink.homeMs = 0
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    for _, v in ipairs(vehicles) do
        if not v.isDeleted and v.isServer and homeKind(v) and v.components ~= nil and v.components[1] ~= nil and entityExists(v.components[1].node) then
            local rec = BridgeLink.home[v]
            if rec == nil then
                local snap = BridgeLink.homeSnapshot(v)
                if snap ~= nil then BridgeLink.home[v] = { comps = snap, st = { tries = 0 } } end          -- (a piece bought or reset later: its place is where it is now)
            else
                local node = v.components[1].node
                local x, y, z = getWorldTranslation(node)
                local vx, vy, vz = getLinearVelocity(node)
                local speed = math.sqrt(vx * vx + vy * vy + vz * vz)
                if BridgeLink.thrownNow ~= nil and BridgeLink.thrownNow[v] ~= nil then
                    speed = math.max(speed, BridgeLink.thrownNow[v])
                    BridgeLink.thrownNow[v] = nil
                end
                local h = rec.comps[1]
                local held = false
                local hands = g_localPlayer ~= nil and g_localPlayer.hands or nil
                if hands ~= nil and hands.spec_hands ~= nil and hands.spec_hands.heldItemNode == node then held = true end
                local verdict = BridgeLink.homeVerdict(rec.st, { x, y, z }, { h[1], h[2], h[3] }, speed, held, BridgeLink.homeSinceLoadMs, dtMs)
                if verdict == "thrown" then
                    rec.st.tries = rec.st.tries + 1
                    if rec.st.tries <= BridgeLink.HOME_MAX_TRIES then
                        Logging.info("[BridgeLink] home: %s was thrown (%.0f m/s, %.0f m from its place at %.0f %.0f %.0f): put back (try %d)", tostring(v.configFileName or "?"):match("([^/]+)%.xml$") or "?", speed, math.sqrt((x - h[1]) ^ 2 + (y - h[2]) ^ 2 + (z - h[3]) ^ 2), x, y, z, rec.st.tries)
                        BridgeLink.homeTeleport(v, rec.comps)
                        rec.st.last = { h[1], h[2], h[3] }
                    elseif rec.st.tries == BridgeLink.HOME_MAX_TRIES + 1 then
                        Logging.info("[BridgeLink] home: %s keeps being thrown: left where it is", tostring(v.configFileName or "?"):match("([^/]+)%.xml$") or "?")
                    end
                elseif verdict == "rehome" then
                    local snap = BridgeLink.homeSnapshot(v)
                    if snap ~= nil then rec.comps = snap; rec.st.tries = 0 end
                end
            end
        end
    end
end

-- sbBridgeHome [on|off|now]: "now" remembers every piece's place as it is now
function BridgeLink.consoleHome(_, arg)
    if arg == "on" then BridgeLink.HOME_ON = true elseif arg == "off" then BridgeLink.HOME_ON = false elseif arg == "now" then BridgeLink.homeAll(); BridgeLink.homeSinceLoadMs = 1e9 end
    local n = 0
    for _ in pairs(BridgeLink.home) do n = n + 1 end
    return string.format("home %s: %d piece(s) remember their place", BridgeLink.HOME_ON and "on" or "off", n)
end
if addConsoleCommand ~= nil and not BridgeLink.homeConsole then
    BridgeLink.homeConsole = true
    addConsoleCommand("sbBridgeHome", "SandboxHammer: a thrown bridge piece, pole or anchor is put back at its place [on|off|now]", "consoleHome", BridgeLink)
end

-- The hands lift the plate and the bridge pieces while they are free: the game's mass check (500 kg with super strength, a grate with its rings is 580 kg, the plate 800) is lifted for them. A pinned piece is left alone.
-- What the hands looked at (one log line per change): the node, its body type, the mass the game compares and its limit, and the answer.
function BridgeLink.handsLog(hands, node, object, limit, result)
    local ok, line = pcall(function()
        local mass = HandToolHands.calculateItemMass(node)
        return string.format("hands look at %s node %s (%s), body type %s, mass %.0f kg, limit %.0f kg, pinned %s: %s", tostring(object.typeName), tostring(getName(node)), tostring(node), tostring(getRigidBodyType(node)), (mass or 0) * 1000, (limit or 0) * 1000, tostring(object.hdPinned == true), result and "can lift" or "CANNOT lift")
    end)
    if ok and line ~= BridgeLink.handsLast then
        BridgeLink.handsLast = line
        Logging.info("[BridgeLink] %s", line)
    end
end
if HandToolHands ~= nil and HandToolHands.getCanPickUpNode ~= nil and Utils ~= nil and not BridgeLink.handsHooked then
    BridgeLink.handsHooked = true
    HandToolHands.getCanPickUpNode = Utils.overwrittenFunction(HandToolHands.getCanPickUpNode, function(self, superFunc, node)
        local spec = self.spec_hands
        local object = node ~= nil and node ~= 0 and entityExists(node) and g_currentMission ~= nil and g_currentMission:getNodeObject(node) or nil
        local name = object ~= nil and object.typeName or nil
        if spec ~= nil and name ~= nil and object.hdPinned ~= true and (string.find(name, "bridge", 1, true) ~= nil or string.find(name, "sellingPlate", 1, true) ~= nil) then
            local old = spec.currentMaximumMass
            spec.currentMaximumMass = math.max(old or 0, 5000)
            local ok, result = pcall(superFunc, self, node)
            spec.currentMaximumMass = old
            BridgeLink.handsLog(self, node, object, old, ok and result)
            return ok and result
        end
        local result = superFunc(self, node)
        if node ~= nil and node ~= 0 and entityExists(node) and g_currentMission ~= nil then
            local object = g_currentMission:getNodeObject(node)
            if object ~= nil and object.typeName ~= nil and (string.find(object.typeName, "bridge", 1, true) ~= nil or string.find(object.typeName, "sellingPlate", 1, true) ~= nil) then
                BridgeLink.handsLog(self, node, object, spec ~= nil and spec.currentMaximumMass or nil, result)
            end
        end
        return result
    end)
end

-- ===== what it costs =====
-- Every step of the per-frame hooks is timed (getTimeSec, as the profiler mod does): ms per second of game time, calls and the worst single call per section, logged once a minute and by sbBridgePerf [reset].
-- A world of many bridges is the target: what grows with the number of bridges or vehicles shows up here first.
BridgeLink.perf, BridgeLink.perfSince, BridgeLink.perfLogMs = {}, nil, 0
local function timed(name, fn, ...)
    local clock = getTimeSec
    local t0 = clock ~= nil and clock() or 0
    local ok, err = pcall(fn, ...)
    local took = (clock ~= nil and clock() or 0) - t0
    local e = BridgeLink.perf[name]
    if e == nil then e = { sec = 0, calls = 0, worst = 0 }; BridgeLink.perf[name] = e end
    e.sec, e.calls = e.sec + took, e.calls + 1
    if took > e.worst then e.worst = took end
    return ok, err
end

function BridgeLink.perfText()
    local now = g_time or 0
    local span = math.max(1, (now - (BridgeLink.perfSince or now)) / 1000)
    local names = {}
    for name in pairs(BridgeLink.perf) do names[#names + 1] = name end
    table.sort(names, function(x, y) return BridgeLink.perf[x].sec > BridgeLink.perf[y].sec end)
    local parts, total = {}, 0
    for _, name in ipairs(names) do
        local e = BridgeLink.perf[name]
        total = total + e.sec
        parts[#parts + 1] = string.format("%s %.2f ms/s (%d calls, worst %.2f ms)", name, e.sec * 1000 / span, e.calls, e.worst * 1000)
    end
    local pairsN, grates = 0, 0
    for _, a in ipairs(BridgeLink.guideStarts or {}) do
        if a.pinned and BridgeLink.guideEndFor(a, BridgeLink.guideEnds or {}) ~= nil then pairsN = pairsN + 1 end
    end
    for _, v in ipairs(g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}) do
        if v.typeName ~= nil and string.find(v.typeName, "bridgeGrate", 1, true) ~= nil then grates = grates + 1 end
    end
    return string.format("%.2f ms/s over %.0f s, %d complete bridge(s), %d grate(s), %d hitched pair(s): %s", total * 1000 / span, span, pairsN, grates, #(BridgeLink.statusList or {}), table.concat(parts, " | "))
end

function BridgeLink.consolePerf(_, arg)
    local text = BridgeLink.perfText()
    if arg == "reset" then
        BridgeLink.perf, BridgeLink.perfSince = {}, g_time
    end
    return text
end
if addConsoleCommand ~= nil and not BridgeLink.perfConsole then
    BridgeLink.perfConsole = true
    addConsoleCommand("sbBridgePerf", "SandboxHammer: what the bridge code costs per second, per step [reset]", "consolePerf", BridgeLink)
end

-- A debug line lives for the frame it is issued in, and the screen renders more often than the game updates: drawn from the update alone the lines flicker (shown on some frames, gone on others). So they are issued
-- from the mission's draw as well (no scan there: dt 0).
if FSBaseMission ~= nil and FSBaseMission.draw ~= nil and Utils ~= nil and not BridgeLink.drawHookedDraw then
    BridgeLink.drawHookedDraw = true
    FSBaseMission.draw = Utils.appendedFunction(FSBaseMission.draw, function(self)
        local ok, err = timed("draw", BridgeLink.statusDraw, 0)
        if not ok and not BridgeLink.drawFailedDraw then
            BridgeLink.drawFailedDraw = true
            Logging.warning("[BridgeLink] the guide and flags failed in the draw phase: %s", tostring(err))
        end
    end)
end

-- the same cube call as the Hammer's aim marker, which is seen: drawn from the mission's update
if FSBaseMission ~= nil and FSBaseMission.update ~= nil and Utils ~= nil and not BridgeLink.drawHooked then
    BridgeLink.drawHooked = true
    FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(self, dt)
        BridgeLink.perfSince = BridgeLink.perfSince or g_time
        local steps = {
            { "status", BridgeLink.statusDraw, "drawFailed", "the connection flags" },
            { "home", BridgeLink.homeStep, "homeFailed", "the home step" },
            { "beams+lock+keeper", BridgeLink.beamStep, "beamFailed", "the steel profiles" },
            { "autoWire", BridgeLink.autoWireStep, "autoWireFailed", "the guide wires" },
            { "snap", BridgeLink.snapStep, "snapFailed", "the snap" },
            { "guard", BridgeLink.guard, "guardFailed", "the speed guard" },
        }
        for _, step in ipairs(steps) do
            local ok, err = timed(step[1], step[2], dt)
            if not ok and not BridgeLink[step[3]] then
                BridgeLink[step[3]] = true
                Logging.warning("[BridgeLink] %s failed: %s", step[4], tostring(err))
            end
        end
        BridgeLink.perfLogMs = BridgeLink.perfLogMs + (dt or 0)
        if BridgeLink.perfLogMs >= 60000 then
            BridgeLink.perfLogMs = 0
            Logging.info("[BridgeLink] cost: %s", BridgeLink.perfText())
            BridgeLink.perf, BridgeLink.perfSince = {}, g_time
        end
    end)
end

-- sbBridgeStatus [on|off]: the flags on or off; and a line per hitched pair in the log
function BridgeLink.consoleStatus(_, arg)
    if arg == "on" then BridgeLink.STATUS_ON = true elseif arg == "off" then BridgeLink.STATUS_ON = false end
    BridgeLink.statusScan()
    for _, st in ipairs(BridgeLink.statusList) do
        Logging.info("[BridgeLink] status: hitch %.0f cm, second joint %s", 100 * st.pair1.gap, st.pair2 ~= nil and string.format("%s (%.0f cm)", st.pair2.state, 100 * st.pair2.gap) or "none (no second pair)")
    end
    return string.format("connection flags %s, %d hitched pair(s) (green joined, yellow closing, orange pulled apart, red no joint; details in the log)", BridgeLink.STATUS_ON and "on" or "off", #BridgeLink.statusList)
end
if addConsoleCommand ~= nil and not BridgeLink.statusConsole then
    BridgeLink.statusConsole = true
    addConsoleCommand("sbBridgeStatus", "SandboxHammer: show or hide the connection flags of the bridge pieces [on|off]", "consoleStatus", BridgeLink)
end

function BridgeLink:onUpdate(dt)
    local spec = self[BridgeLink.SPEC_TABLE_NAME]
    if not self.isServer then
        return
    end
    if next(spec.pulls) ~= nil then
        BridgeLink.updatePulls(self, spec, dt)
        self:raiseActive()
    end
    spec.upgrade = spec.upgrade or {}
    if not BridgeLink.LOAD_UPGRADE then
        spec.upgrade = {}
    elseif next(spec.upgrade) ~= nil then
        for object, u in pairs(spec.upgrade) do
            u.ms = u.ms + dt
            if object.isDeleted or spec.links[object] == nil then
                spec.upgrade[object] = nil
            elseif u.ms >= BridgeLink.LOAD_UPGRADE_MS and entityExists(u.a) and entityExists(u.b) then
                spec.upgrade[object] = nil
                removeLink(spec, object)
                local pend = { hitch = u.hitch, eye = u.eye, ms = 0 }
                local gap = distance(u.a, u.b)
                if gap > BridgeLink.AUTO_PULL_M then
                    spec.pending[object] = pend
                    Logging.info("[BridgeLink] the loose joint from the load is dropped: the pair is %.1f m apart, watching the distance instead", gap)
                else
                    spec.pulls[object] = { a = u.a, b = u.b, bar = u.bar, ms = 0, pend = pend }
                    Logging.info("[BridgeLink] the loose joint from the load is closed by the swing now (gap %.3f m)", gap)
                end
            end
        end
        self:raiseActive()
    end
    if next(spec.pending) == nil then
        return
    end
    for object, p in pairs(spec.pending) do
        p.ms = p.ms + dt
        BridgeLink.processPending(self, spec, object, p)
    end
    if next(spec.pending) ~= nil then
        self:raiseActive()
    end
end

-- sbBridgeGuide [on|off]: the placement guide (ground squares for the poles and the end piece, from a pinned start piece)
function BridgeLink.consoleGuide(_, arg)
    if arg == "on" then BridgeLink.GUIDE_ON = true elseif arg == "off" then BridgeLink.GUIDE_ON = false end
    BridgeLink.guideScan()
    return string.format("placement guide %s, %d pinned start piece(s), %d pinned pole(s)", BridgeLink.GUIDE_ON and "on" or "off", #BridgeLink.guideStarts, #BridgeLink.guidePoles)
end
if addConsoleCommand ~= nil and not BridgeLink.guideConsole then
    BridgeLink.guideConsole = true
    addConsoleCommand("sbBridgeGuide", "SandboxHammer: show or hide the placement guide for the poles and the end piece [on|off]", "consoleGuide", BridgeLink)
end

-- sbBridgeAutoWire [on|off]: the guide wires between the poles laid by themselves
function BridgeLink.consoleAutoWire(_, arg)
    if arg == "on" then BridgeLink.AUTOWIRE_ON = true elseif arg == "off" then BridgeLink.AUTOWIRE_ON = false end
    BridgeLink.autoWireDone = setmetatable({}, { __mode = "k" })
    return string.format("guide wires %s (both end pieces pinned, a pinned pole in each of the four squares)", BridgeLink.AUTOWIRE_ON and "on" or "off")
end
if addConsoleCommand ~= nil and not BridgeLink.autoWireConsole then
    BridgeLink.autoWireConsole = true
    addConsoleCommand("sbBridgeAutoWire", "SandboxHammer: lay the guide wires between the poles by themselves once both end pieces and the poles are pinned [on|off]", "consoleAutoWire", BridgeLink)
end

-- sbBridgeTarget [clear]: the guide cannot know where you want to go: look at the spot where the far end of the bridge should land and use it. The suggestion then aims at that point. "clear" forgets it.
BridgeLink.guideTarget, BridgeLink.guideTargetId = nil, 0
function BridgeLink.consoleTarget(_, arg)
    if arg == "clear" then
        BridgeLink.guideTarget, BridgeLink.guideTargetId = nil, BridgeLink.guideTargetId + 1
        return "sbBridgeTarget: forgotten, the guide looks for the far bank by itself"
    end
    local player = g_localPlayer
    if player == nil or raycastClosest == nil or CollisionFlag == nil then
        return "sbBridgeTarget: no player"
    end
    local camera = player:getCurrentCameraNode()
    local ox, oy, oz = getWorldTranslation(camera)
    local dx, dy, dz = localDirectionToWorld(camera, 0, 0, -1)
    BridgeLink.rayHit, BridgeLink.rayPoint = nil, nil
    raycastClosest(ox, oy, oz, dx, dy, dz, 200, "targetRayCallback", BridgeLink, CollisionFlag.TERRAIN + (CollisionFlag.TERRAIN_DELTA or 0))
    local p = BridgeLink.rayPoint
    if p == nil then
        return "sbBridgeTarget: the ground is not in sight (look at the far bank within 200 m)"
    end
    BridgeLink.guideTarget, BridgeLink.guideTargetId = { x = p[1], z = p[2] }, BridgeLink.guideTargetId + 1
    return string.format("sbBridgeTarget: the bridge is to land at %.1f / %.1f; the guide aims at it", p[1], p[2])
end
function BridgeLink.targetRayCallback(self, hitNode, x, y, z, distance)
    if hitNode ~= nil then
        BridgeLink.rayPoint = { x, z }
        return false
    end
    return true
end
if addConsoleCommand ~= nil and not BridgeLink.targetConsole then
    BridgeLink.targetConsole = true
    addConsoleCommand("sbBridgeTarget", "SandboxHammer: look at the spot where the far end of the bridge should land: the guide aims at it [clear]", "consoleTarget", BridgeLink)
end
