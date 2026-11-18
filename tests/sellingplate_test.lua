-- run: lua tests/sellingplate_test.lua   (mocks the engine: checks that the station only opens while the plate is frozen)
g_currentModName = "FS25_Hammer"
CollisionFlag = { FILLABLE = 0x40000000 }
Vehicle = { xmlSchema = { setXMLSpecializationType = function() end } }
SpecializationUtil = { registerFunction = function(t, n, f) t[n] = f end, registerEventListener = function() end }
SellingStation = { registerXMLPaths = function() end }
local groups = {}
function setCollisionFilterGroup(node, g) groups[node] = g end
-- the spawn test hook: a fixed plate is free ground, anything else keeps the game's answer
local fixedPlate = { getIsSellingPlateFixed = function() return true end }
local loosePlate = { getIsSellingPlateFixed = function() return false end }
g_currentMission = { getNodeObject = function(_, id) return ({ [1] = fixedPlate, [2] = loosePlate })[id] end }
Utils = { overwrittenFunction = function(old, new) return function(...) return new(nil, old, ...) end end }
PlacementUtil = { collisionTestCallback = function(_, id) return "game:" .. tostring(id) end }
dofile("scripts/vehicles/SellingPlate.lua")

local pass, fail = 0, 0
local function check(name, cond) if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name) end end

local trigger = { isEnabled = true, exactFillRootNode = 7 }
local station = { unloadTriggers = { trigger, { isEnabled = true } } }
local v = { components = { { isStatic = false } }, ["spec_FS25_Hammer.sellingPlate"] = { sellingStation = station, fillableGroup = CollisionFlag.FILLABLE, nextCheck = 0 } }
v.getIsSellingPlateFixed = SellingPlate.getIsSellingPlateFixed
v.raiseActive = function() end
check("loose is not fixed", v:getIsSellingPlateFixed() == false)
SellingPlate.onUpdateTick(v, 16)
check("loose: triggers off", trigger.isEnabled == false and station.unloadTriggers[2].isEnabled == false)
check("loose: exact fill node hidden", groups[7] == 0)
v.components[1].isStatic = true
SellingPlate.onUpdateTick(v, 16)
check("still loose within the check interval", trigger.isEnabled == false)
SellingPlate.onUpdateTick(v, 600)
check("frozen: triggers on", trigger.isEnabled == true and station.unloadTriggers[2].isEnabled == true)
check("frozen: exact fill node back", groups[7] == CollisionFlag.FILLABLE)
v.components[1].isStatic = false
SellingPlate.onUpdateTick(v, 600)
check("thawed: closed again", trigger.isEnabled == false and groups[7] == 0)
v.hdPinned = true
SellingPlate.onUpdateTick(v, 600)
check("pinned: open", trigger.isEnabled == true)
v.hdPinned = false
SellingPlate.onUpdateTick(v, 600)
check("unpinned: closed", trigger.isEnabled == false)
check("spawn test: a fixed plate is free ground", PlacementUtil.collisionTestCallback(nil, 1) == true)
check("spawn test: a loose plate still blocks", PlacementUtil.collisionTestCallback(nil, 2) == "game:2")
check("spawn test: anything else is the game's answer", PlacementUtil.collisionTestCallback(nil, 3) == "game:3")
-- empty pallets on an open plate are removed after a few seconds; full, mounted and loose-plate ones stay
local deleted = {}
local function pallet(levels, mounted) return { isPallet = true, isDeleted = false, dynamicMountType = mounted and 2 or nil, getFillUnits = function() local u = {} for i = 1, #levels do u[i] = true end return u end, getFillUnitFillLevel = function(_, i) return levels[i] end, delete = function(p) deleted[p] = true end } end
MountableObject = { MOUNT_TYPE_NONE = 0 }
local empty, full, strapped = pallet({ 0 }), pallet({ 500 }), pallet({ 0 }, true)
local nodes = { [11] = empty, [12] = full, [13] = strapped, [14] = v }
g_currentMission.getNodeObject = function(_, id) return nodes[id] or ({ [1] = fixedPlate, [2] = loosePlate })[id] end
localToWorld = function() return 0, 1.5, 0 end
getWorldRotation = function() return 0, 0, 0 end
overlapBox = function(_, _, _, _, _, _, _, _, _, cbName, target) for _, id in ipairs({ 11, 12, 13, 14 }) do target[cbName](target, id) end end
CollisionFlag.VEHICLE, CollisionFlag.DYNAMIC_OBJECT = 0x10000, 0x40000
v.isServer = true; v.hdPinned = true; v.components[1].node = 99
v["spec_FS25_Hammer.sellingPlate"].open = true
for i = 1, 3 do SellingPlate.onUpdateTick(v, 1000) end
check("empty pallet waits first", next(deleted) == nil)
SellingPlate.onUpdateTick(v, 1000)
check("empty pallet removed after the delay", deleted[empty] == true)
check("a full pallet stays", deleted[full] == nil)
check("a strapped empty pallet stays", deleted[strapped] == nil)
-- a full pallet the trigger never counted is announced again; one it already has is not
local entered = {}
local fullA, fullB = pallet({ 500 }), pallet({ 500 })
fullA.rootNode, fullB.rootNode = 21, 22
nodes[21], nodes[22] = fullA, fullB
overlapBox = function(_, _, _, _, _, _, _, _, _, cbName, target) for _, id in ipairs({ 21, 22 }) do target[cbName](target, id) end end
local palletTrigger = { triggerNode = 5, palletsInRange = { fullB }, palletTriggerCallback = function(_, _, id, enter) entered[id] = enter end }
local stationRef = v["spec_FS25_Hammer.sellingPlate"].sellingStation
stationRef.unloadTriggers = { palletTrigger }
SellingPlate.onUpdateTick(v, 1000)
check("a pallet the trigger missed is announced", entered[21] == true)
check("a pallet already in range is left alone", entered[22] == nil)
print(string.format("sellingplate_test: %d/%d passed", pass, pass + fail))
os.exit(fail == 0 and 0 or 1)
