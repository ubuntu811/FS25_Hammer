--[[
    BridgeBake.lua -- a bridge piece (grate, start piece, end piece) that is pinned is a vehicle held by joints; baked, it is a static placeable twin of the same look (vehicles/<name>/<name>_static.i3d and
    <name>_placeable.xml, made by tools/make_selling_plate.py): no body, no joint, no keeper, no pin helper, loaded by the game with the savegame BEFORE the physics run. Un-baking spawns the vehicle again at the
    placeable's pose, lifted clear of the ground (the unbury's five-point terrain check), and deletes the placeable. The link rings and the clips are looks on the twin (aligned, they do nothing).
    Console (a prototype: nothing calls it by itself yet):  sbBridgeBake [all]   bakes the piece nearest to you (all: every pinned piece),   sbBridgeUnbake [all]   the baked piece nearest to you (all: every baked piece).
    The hitches are NOT remembered yet: an un-baked piece is loose, hitch it again. sbBridgeRings ghost|solid: the link rings collide with nothing (a test: do overlapping rings make things fly?).
    Nothing here touches the Hammer's frozen objects and assemblies (the logs).
]]
BridgeBake = {}
BridgeBake.modDir = g_currentModDirectory
BridgeBake.modName = g_currentModName
BridgeBake.REACH_M = 8
BridgeBake.NAMES = { "bridgeGrate", "bridgeStart", "bridgeEnd" }
BridgeBake.pending = {}

local function say(text)
    print("[BridgeBake] " .. text)
    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil and FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_INFO ~= nil then
        pcall(g_currentMission.addIngameNotification, g_currentMission, FSBaseMission.INGAME_NOTIFICATION_INFO, text)
    end
end

function BridgeBake.nameOfVehicle(vehicle)
    local t = vehicle ~= nil and vehicle.typeName or nil
    for _, n in ipairs(BridgeBake.NAMES) do
        if t ~= nil and string.find(t, n, 1, true) ~= nil then
            return n
        end
    end
    return nil
end

function BridgeBake.nameOfPlaceable(placeable)
    local f = placeable ~= nil and placeable.configFileName or nil
    if f == nil or string.find(f, BridgeBake.modName, 1, true) == nil then
        return nil
    end
    for _, n in ipairs(BridgeBake.NAMES) do
        if string.find(f, n .. "_placeable.xml", 1, true) ~= nil then
            return n
        end
    end
    return nil
end

function BridgeBake.pathOf(name, suffix)
    return BridgeBake.modDir .. "vehicles/" .. name .. "/" .. name .. suffix
end

local function playerXZ()
    if g_localPlayer == nil then
        return nil
    end
    local x, _, z = g_localPlayer:getPosition()
    return x, z
end

-- the piece nearest to the player within REACH_M, from a list of { node, object }
local function nearest(list)
    local px, pz = playerXZ()
    if px == nil then
        return nil
    end
    local best, bestD
    for _, e in ipairs(list) do
        local x, _, z = getWorldTranslation(e.node)
        local d = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
        if d <= BridgeBake.REACH_M and (bestD == nil or d < bestD) then
            best, bestD = e.object, d
        end
    end
    return best
end

function BridgeBake.vehicles(onlyPinned)
    local out = {}
    for _, v in ipairs(g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}) do
        if not v.isDeleted and BridgeBake.nameOfVehicle(v) ~= nil and v.components ~= nil and v.components[1] ~= nil and entityExists(v.components[1].node) and (not onlyPinned or v.hdPinned == true) then
            out[#out + 1] = { node = v.components[1].node, object = v }
        end
    end
    return out
end

function BridgeBake.placeables()
    local out = {}
    local system = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    for _, p in ipairs(system ~= nil and system.placeables or {}) do
        if not p.isDeleted and not p.markedForDeletion and BridgeBake.nameOfPlaceable(p) ~= nil and p.rootNode ~= nil and entityExists(p.rootNode) then
            out[#out + 1] = { node = p.rootNode, object = p }
        end
    end
    return out
end

-- the vehicle as a baked placeable: the twin is made first, the vehicle goes only when the twin has loaded (a failure leaves the vehicle where it is)
function BridgeBake.bake(vehicle)
    local name = BridgeBake.nameOfVehicle(vehicle)
    if name == nil or BridgeBake.pending[vehicle] then
        return false
    end
    local node = vehicle.components[1].node
    local x, y, z = getWorldTranslation(node)
    local rx, ry, rz = getWorldRotation(node)
    local data = PlaceableLoadingData.new()
    data:setFilename(BridgeBake.pathOf(name, "_placeable.xml"))
    if not data.isValid then
        say(name .. ": the placeable twin is not in the store list (modDesc storeItems)")
        return false
    end
    data:setPosition(x, y, z)
    data:setRotation(rx, ry, rz)
    data:setOwnerFarmId(vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or AccessHandler.EVERYONE)
    BridgeBake.pending[vehicle] = true
    data:load(BridgeBake.onBaked, BridgeBake, { vehicle = vehicle, name = name, x = x, y = y, z = z })
    return true
end

function BridgeBake:onBaked(placeable, state, args)
    local vehicle = args.vehicle
    BridgeBake.pending[vehicle] = nil
    if placeable == nil or state ~= PlaceableLoadingState.OK then
        say(string.format("%s: the twin could not be loaded (state %s): the piece stays a vehicle", args.name, tostring(state)))
        return
    end
    -- a loaded placeable is only a preview until it is finalized: that is the step that adds it to the physics, to the placeable system (the unique id, the save) and to the owned items; the savegame loader and the
    -- construction screen both call it (2026-11-18: without it the twin had no collision, no unique id and could not be found again)
    local okF, errF = pcall(placeable.finalizePlacement, placeable)
    if not okF then
        say(string.format("%s: the twin could not be finalized (%s): the piece stays a vehicle", args.name, tostring(errF)))
        placeable:delete()
        return
    end
    if vehicle == nil or vehicle.isDeleted then
        return
    end
    if HandToolHammer ~= nil and HandToolHammer.pinned ~= nil and HandToolHammer.pinned[vehicle] ~= nil then
        HandToolHammer.unpinVehicle(vehicle)
    end
    vehicle:delete()
    Logging.info("[BridgeBake] baked a %s at %.2f %.2f %.2f (placeable %s)", args.name, args.x, args.y, args.z, tostring(placeable:getUniqueId()))
end

-- how far to lift the piece so it lies above the ground: the unbury's five points of its footprint against the terrain
function BridgeBake.liftFor(node, name)
    local half = HandToolHammer ~= nil and HandToolHammer.UNBURY_HALF ~= nil and HandToolHammer.UNBURY_HALF[name] or { 1.5, 2.0 }
    local hx, hz = half[1], half[2]
    local burials = {}
    for _, p in ipairs({ { 0, 0 }, { -hx, -hz }, { hx, -hz }, { -hx, hz }, { hx, hz } }) do
        local wx, wy, wz = localToWorld(node, p[1], 0, p[2])
        burials[#burials + 1] = getTerrainHeightAtWorldPos(g_terrainNode, wx, 0, wz) - wy
    end
    if HandToolHammer ~= nil and HandToolHammer.unburyLift ~= nil then
        return HandToolHammer.unburyLift(burials)
    end
    local worst = -math.huge
    for _, b in ipairs(burials) do worst = math.max(worst, b) end
    return worst > 0.02 and worst + 0.03 or 0
end

function BridgeBake.unbake(placeable)
    local name = BridgeBake.nameOfPlaceable(placeable)
    if name == nil or BridgeBake.pending[placeable] then
        return false
    end
    local node = placeable.rootNode
    local x, y, z = getWorldTranslation(node)
    local rx, ry, rz = getWorldRotation(node)
    local lift = BridgeBake.liftFor(node, name)
    local data = VehicleLoadingData.new()
    data:setFilename(BridgeBake.pathOf(name, ".xml"))
    if not data.isValid then
        say(name .. ": the vehicle is not in the store list")
        return false
    end
    data:setPosition(x, y + lift + 0.02, z)
    data:setRotation(rx, ry, rz)
    data:setPropertyState(VehiclePropertyState.OWNED)
    data:setOwnerFarmId(placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or AccessHandler.EVERYONE)
    BridgeBake.pending[placeable] = true
    data:load(BridgeBake.onUnbaked, BridgeBake, { placeable = placeable, name = name, lift = lift })
    return true
end

function BridgeBake:onUnbaked(vehicles, state, args)
    local placeable = args.placeable
    BridgeBake.pending[placeable] = nil
    if vehicles == nil or vehicles[1] == nil or state ~= VehicleLoadingState.OK then
        say(string.format("%s: the vehicle could not be loaded (state %s): the piece stays baked", args.name, tostring(state)))
        return
    end
    if placeable ~= nil and not placeable.isDeleted then
        placeable:delete()
    end
    Logging.info("[BridgeBake] un-baked a %s (lifted %.2f m): a loose vehicle again, hitch it again", args.name, args.lift)
end

function BridgeBake.consoleBake(_, arg)
    local list = BridgeBake.vehicles(arg == "all")
    local n = 0
    if arg == "all" then
        for _, e in ipairs(list) do
            if BridgeBake.bake(e.object) then n = n + 1 end
        end
        return string.format("%d pinned bridge piece(s) are being baked", n)
    end
    local v = nearest(list)
    if v == nil then
        return string.format("no bridge piece within %d m", BridgeBake.REACH_M)
    end
    return BridgeBake.bake(v) and ("baking the " .. BridgeBake.nameOfVehicle(v)) or "could not bake it (see the log)"
end

function BridgeBake.consoleUnbake(_, arg)
    local list = BridgeBake.placeables()
    if arg == "all" then
        local n = 0
        for _, e in ipairs(list) do
            if BridgeBake.unbake(e.object) then n = n + 1 end
        end
        return string.format("%d baked piece(s) are being turned back into vehicles", n)
    end
    local p = nearest(list)
    if p == nil then
        return string.format("no baked bridge piece within %d m", BridgeBake.REACH_M)
    end
    return BridgeBake.unbake(p) and ("un-baking the " .. BridgeBake.nameOfPlaceable(p)) or "could not un-bake it (see the log)"
end

-- sbBridgeRings ghost|solid: the link rings (the other components of a bridge piece) collide with nothing / with the game's usual vehicle mask
function BridgeBake.consoleRings(_, arg)
    local ghost = arg == "ghost"
    local mask = ghost and 0 or 0xfe3ffb83
    local n = 0
    if arg == "ghost" or arg == "solid" then
        for _, e in ipairs(BridgeBake.vehicles(false)) do
            local v = e.object
            for i = 2, #v.components do
                local node = v.components[i].node
                if node ~= nil and entityExists(node) then
                    setCollisionFilterMask(node, mask)
                    n = n + 1
                end
            end
        end
    end
    return string.format("%d link ring(s) set to %s (this session only)", n, ghost and "collide with nothing" or "the usual mask")
end

-- sbBridgeProbe: why does a baked piece have (or not have) collision? The tree of the nearest baked piece with the rigid body type, collision group and mask of every node (in the log), and rays shot down through it
-- at five places with the widest mask: what they hit, its group and where.
local BODY_NAMES = {}
if RigidBodyType ~= nil then
    for name, value in pairs(RigidBodyType) do
        if type(value) == "number" then BODY_NAMES[value] = name end
    end
end
local function describeNode(node, depth, lines)
    local ok, line = pcall(function()
        return string.format("%s%s  body=%s group=0x%x mask=0x%x", string.rep("  ", depth), tostring(getName(node)), tostring(BODY_NAMES[getRigidBodyType(node)] or getRigidBodyType(node)), getCollisionFilterGroup(node), getCollisionFilterMask(node))
    end)
    lines[#lines + 1] = ok and line or (string.rep("  ", depth) .. tostring(getName(node)))
    for i = 0, getNumOfChildren(node) - 1 do
        describeNode(getChildAt(node, i), depth + 1, lines)
    end
end

BridgeBake.probeHits = {}
function BridgeBake:probeHit(hitNode, x, y, z, distance)
    if hitNode ~= nil and hitNode ~= 0 then
        local ok, group = pcall(getCollisionFilterGroup, hitNode)
        BridgeBake.probeHits[#BridgeBake.probeHits + 1] = string.format("%s (group 0x%x) %.2f m, y %.2f", tostring(getName(hitNode)), ok and group or -1, distance or -1, y or 0)
    end
    return true
end

function BridgeBake.consoleProbe()
    local p = nearest(BridgeBake.placeables())
    if p == nil then
        return string.format("no baked bridge piece within %d m", BridgeBake.REACH_M)
    end
    local lines = {}
    describeNode(p.rootNode, 0, lines)
    for _, l in ipairs(lines) do
        Logging.info("[BridgeBake] probe tree: %s", l)
    end
    local x, y, z = getWorldTranslation(p.rootNode)
    local summary = {}
    for _, o in ipairs({ { 0, 0 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
        BridgeBake.probeHits = {}
        local ok, err = pcall(raycastAll, x + o[1], y + 3, z + o[2], 0, -1, 0, 8, "probeHit", BridgeBake, 0xffffffff)
        local list = table.concat(BridgeBake.probeHits, "; ")
        Logging.info("[BridgeBake] probe ray at %+d %+d: %s%s", o[1], o[2], ok and (list ~= "" and list or "no hit") or ("failed: " .. tostring(err)), "")
        summary[#summary + 1] = #BridgeBake.probeHits
    end
    return string.format("%d node(s) of the twin and 5 rays logged (hits per ray: %s): see the log lines [BridgeBake] probe", #lines, table.concat(summary, ", "))
end

if addConsoleCommand ~= nil and not BridgeBake.consoleAdded then
    BridgeBake.consoleAdded = true
    addConsoleCommand("sbBridgeBake", "SandboxHammer: bake the bridge piece nearest to you into a static placeable [all = every pinned piece]", "consoleBake", BridgeBake)
    addConsoleCommand("sbBridgeUnbake", "SandboxHammer: turn the baked piece nearest to you back into a vehicle [all]", "consoleUnbake", BridgeBake)
    addConsoleCommand("sbBridgeProbe", "SandboxHammer: the collision tree of the nearest baked piece and rays shot through it (in the log)", "consoleProbe", BridgeBake)
    addConsoleCommand("sbBridgeRings", "SandboxHammer: sbBridgeRings ghost|solid: the link rings collide with nothing / as usual", "consoleRings", BridgeBake)
end
