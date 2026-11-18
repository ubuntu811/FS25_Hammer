-- SellingPlate (FS25_Hammer): a vehicle that is a selling station while the Sandbox Hammer holds it frozen (components[1].isStatic). Built like PlaceableSellingStation, from the vehicle's own xml.
SellingPlate = {}
SellingPlate.SPEC_TABLE_NAME = "spec_" .. g_currentModName .. ".sellingPlate"       -- a mod's specialization table lives under its mod name
SellingPlate.CHECK_MS = 500
SellingPlate.SWEEP_MS = 1000               -- an open plate looks for empty pallets on it once a second ...
SellingPlate.EMPTY_DELAY_MS = 4000         -- ... and removes one that has been empty there this long (the base game's trigger only takes pallets that hold something)
SellingPlate.SWEEP_HALF = { 1.45, 1.4, 1.95 }      -- half extents of the sweep box over the grid
SellingPlate.GRID_TOP = 0.12

function SellingPlate.prerequisitesPresent(specializations)
    return true
end

function SellingPlate.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType("SellingPlate")
    SellingStation.registerXMLPaths(schema, "vehicle.sellingPlate.sellingStation")
    schema:setXMLSpecializationType()
end

function SellingPlate.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "getSellingStation", SellingPlate.getSellingStation)
    SpecializationUtil.registerFunction(vehicleType, "getIsSellingPlateFixed", SellingPlate.getIsSellingPlateFixed)
end

function SellingPlate.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoadFinished", SellingPlate)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", SellingPlate)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdateTick", SellingPlate)
end

function SellingPlate:getSellingStation()
    return self[SellingPlate.SPEC_TABLE_NAME].sellingStation
end

-- fixed = the Hammer pinned the plate (a locked joint to a kinematic helper: the body stays dynamic and keeps its collision) or froze it
function SellingPlate:getIsSellingPlateFixed()
    local component = self.components ~= nil and self.components[1] or nil
    return self.hdPinned == true or (component ~= nil and component.isStatic == true)
end


local function isEmptyPallet(object)
    if object.isPallet ~= true or object.getFillUnits == nil or object.isDeleted then
        return false
    end
    if object.dynamicMountType ~= nil and MountableObject ~= nil and object.dynamicMountType ~= MountableObject.MOUNT_TYPE_NONE then
        return false                                                   -- strapped or mounted somewhere: not ours to remove
    end
    local any = false
    for index in pairs(object:getFillUnits()) do
        any = true
        if object:getFillUnitFillLevel(index) > 0.001 then
            return false
        end
    end
    return any
end

-- overlapBox callback target: collects the empty pallets inside the sweep box
local sweeper = { seen = {}, full = {}, plate = nil }
function sweeper.onSweepNode(_, nodeId)
    local object = g_currentMission ~= nil and g_currentMission:getNodeObject(nodeId) or nil
    if object ~= nil and object ~= sweeper.plate then
        if isEmptyPallet(object) then
            sweeper.seen[object] = true
        elseif object.isPallet == true and object.rootNode ~= nil and not object.isDeleted then
            sweeper.full[object] = true
        end
    end
    return true
end

local function sweepEmptyPallets(self, spec)
    local root = self.components[1].node
    local half = SellingPlate.SWEEP_HALF
    sweeper.seen, sweeper.full, sweeper.plate = {}, {}, self
    local x, y, z = localToWorld(root, 0, SellingPlate.GRID_TOP + half[2], 0)
    local rx, ry, rz = getWorldRotation(root)
    overlapBox(x, y, z, rx, ry, rz, half[1], half[2], half[3], "onSweepNode", sweeper, CollisionFlag.VEHICLE + CollisionFlag.DYNAMIC_OBJECT, true, true, false, true)
    local timers, nextTimers = spec.emptyTimers or {}, {}
    for object in pairs(sweeper.seen) do
        local waited = (timers[object] or 0) + SellingPlate.SWEEP_MS
        if waited >= SellingPlate.EMPTY_DELAY_MS then
            object:delete()
        else
            nextTimers[object] = waited
        end
    end
    spec.emptyTimers = nextTimers
    -- the game's pallet trigger decides about a pallet once, when it enters (and asks the station then): a pallet that was on the plate before it was fixed is never counted. Told again every sweep that it entered.
    local station = spec.sellingStation
    for _, trigger in ipairs(station ~= nil and station.unloadTriggers or {}) do
        if trigger.palletsInRange ~= nil and trigger.palletTriggerCallback ~= nil then
            for object in pairs(sweeper.full) do
                local known = false
                for _, inRange in ipairs(trigger.palletsInRange) do
                    if inRange == object then
                        known = true
                        break
                    end
                end
                if not known then
                    trigger:palletTriggerCallback(trigger.triggerNode, object.rootNode, true, false, false, 0)
                end
            end
        end
    end
    sweeper.seen, sweeper.full = {}, {}
end

local function setOpen(self, open)
    local spec = self[SellingPlate.SPEC_TABLE_NAME]
    local station = spec.sellingStation
    if station == nil or spec.open == open then
        return
    end
    spec.open = open
    for _, trigger in ipairs(station.unloadTriggers) do
        trigger.isEnabled = open
        if trigger.isManualSellingActive ~= nil then
            trigger.isManualSellingActive = open                       -- a wood trigger: the player's sell key only while the plate is fixed
        end
        if trigger.exactFillRootNode ~= nil and trigger.exactFillRootNode ~= 0 then
            setCollisionFilterGroup(trigger.exactFillRootNode, open and spec.fillableGroup or 0)
        end
    end
end

function SellingPlate:onLoadFinished(savegame)
    local spec = self[SellingPlate.SPEC_TABLE_NAME]
    spec.open = nil
    if self:getIsInShowroom() then
        return
    end
    local station = SellingStation.new(self.isServer, self.isClient)
    if not station:load(self.components, self.xmlFile, "vehicle.sellingPlate.sellingStation", self.customEnvironment, self.i3dMappings, self.components[1].node) then
        station:delete()
        return
    end
    station.owningPlaceable = self
    -- loose: sells nothing (the station refuses everything until the plate is frozen)
    local base = {
        allowed = station.getIsFillTypeAllowed,
        farm = station.getIsFillAllowedFromFarm,
    }
    station.getIsFillTypeAllowed = function(s, ...)
        return self:getIsSellingPlateFixed() and base.allowed(s, ...)
    end
    station.getIsFillAllowedFromFarm = function(s, ...)
        return self:getIsSellingPlateFixed() and base.farm(s, ...)
    end
    station:register(true)
    spec.sellingStation = station
    spec.fillableGroup = CollisionFlag.FILLABLE
    spec.nextCheck = 0
    setOpen(self, false)
    self:raiseActive()
end

function SellingPlate:onDelete()
    local spec = self[SellingPlate.SPEC_TABLE_NAME]
    if spec.sellingStation ~= nil then
        g_currentMission.economyManager:removeSellingStation(spec.sellingStation)
        spec.sellingStation:delete()
        spec.sellingStation = nil
    end
end

function SellingPlate:onUpdateTick(dt)
    local spec = self[SellingPlate.SPEC_TABLE_NAME]
    if spec.sellingStation == nil then
        return
    end
    spec.nextCheck = (spec.nextCheck or 0) - dt
    if spec.nextCheck <= 0 then
        spec.nextCheck = SellingPlate.CHECK_MS
        setOpen(self, self:getIsSellingPlateFixed())
    end
    if spec.open and self.isServer then
        spec.sweepIn = (spec.sweepIn or SellingPlate.SWEEP_MS) - dt
        if spec.sweepIn <= 0 then
            spec.sweepIn = SellingPlate.SWEEP_MS
            sweepEmptyPallets(self, spec)
        end
    elseif spec.emptyTimers ~= nil then
        spec.emptyTimers = nil
    end
    self:raiseActive()
end

-- A factory's pallet spawn area is only free when no vehicle stands on it: a fixed plate counts as free ground, so the pallets land on it (and sell by themselves).
if PlacementUtil ~= nil and not PlacementUtil.hdSellingPlateHook then
    PlacementUtil.hdSellingPlateHook = true
    PlacementUtil.collisionTestCallback = Utils.overwrittenFunction(PlacementUtil.collisionTestCallback, function(_, superFunc, target, transformId)         -- (the game calls it with the callback target first, then the node)
        local object = g_currentMission ~= nil and g_currentMission:getNodeObject(transformId) or nil
        if object ~= nil and object.getIsSellingPlateFixed ~= nil and object:getIsSellingPlateFixed() then
            return true
        end
        return superFunc(target, transformId)
    end)
end
