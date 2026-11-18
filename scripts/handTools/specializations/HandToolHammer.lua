HandToolHammer = {}
HandToolHammer.SPEC_TABLE_NAME = "spec_" .. g_currentModName .. ".hammer"
HandToolHammer.RAYCAST_DISTANCE = 4.0
HandToolHammer.REDISCOVER_RAYCAST_DISTANCE = 3.0
HandToolHammer.REDISCOVER_RAYCAST_START_HEIGHT = 2.0
HandToolHammer.SAVEGAME_FILENAME = "sandboxtools.xml"
HandToolHammer.MOD_DIRECTORY = g_currentModDirectory

-- World-state registry, not per-hammer-instance: a frozen object must stay
-- frozen even if this exact hammer is dropped/never picked up again, and
-- must be findable again after a save/reload where node ids are not
-- stable. Keyed by the current session's node id; also carries whatever
-- stable identity we could get (object:getUniqueId(), when the hit node
-- belongs to a real Object like a Vehicle/Placeable/ForestryLog) plus the
-- world position, since raw un-itemized geometry has no engine-provided
-- id at all - position is the only thing that survives to re-find it.
HandToolHammer.frozenObjects = {}

-- #nukefromorbit, 2026-08-13: the entire JointConstructor/anchorNode
-- bind system is GONE. Three straight anchor theories (reassert every
-- frame; reorder position-before-addToPhysics; link as a terrain child)
-- all failed the same real convergence-to-zero test - and checking the
-- actual Lua scripting reference (Book_ScriptingFarmingSimulatorWithLua)
-- confirmed RigidBodyType only has NONE/STATIC/DYNAMIC/KINEMATIC, no
-- compound/merge type, so there was never going to be an engine feature
-- that made a bare synthesized TransformGroup a legitimate joint actor
-- no matter how it was registered. Replaced entirely with reparenting -
-- see bindChildToParent below. Each entry:
-- { parent, child, localX/Y/Z, localFwdX/Y/Z, localUpX/Y/Z } - the
-- child's fixed position/orientation relative to its parent, captured
-- once at bind time and reapplied every frame (see onUpdate and
-- applyAssemblyMemberTransform) via localToWorld/localDirectionToWorld -
-- the same "reassert every frame" shape HandToolHands.lua's own real
-- kinematic node uses, just applied to two genuinely real objects
-- instead of a synthesized anchor.
HandToolHammer.assemblyMembers = {}

-- Bind target 1: the first real object picked with B. B binds it to
-- whatever's picked next - both sides are always real, already-
-- physics-backed objects (can be another log, or a vehicle component -
-- "bind log to tractor" works the same way, whatever node the raycast
-- actually hit becomes the parent).
HandToolHammer.bindTarget1Node = nil

function HandToolHammer.prerequisitesPresent(_)
    return true
end

function HandToolHammer.registerEventListeners(handToolType)
    SpecializationUtil.registerEventListener(handToolType, "onLoad", HandToolHammer)
    SpecializationUtil.registerEventListener(handToolType, "onRegisterActionEvents", HandToolHammer)
    SpecializationUtil.registerEventListener(handToolType, "onHeldStart", HandToolHammer)
    SpecializationUtil.registerEventListener(handToolType, "onHeldEnd", HandToolHammer)
    SpecializationUtil.registerEventListener(handToolType, "onUpdate", HandToolHammer)
end

-- Root cause found: loadState() calls raycastClosest (a physics query)
-- directly inside BaseMission.loadMap, which fires before physics/terrain
-- is necessarily ready to answer queries - unlike every reference mod
-- checked (MapObjectsHider, TerraFarm: pure XML, no physics; AISystem:
-- explicitly waits for its own later onTerrainLoad callback before doing
-- anything physics-related). A raycast against a not-yet-ready physics
-- world plausibly hangs rather than errors, matching the observed "stuck
-- loading, log goes silent" symptom exactly - confirmed by disabling
-- these hooks wholesale and both previously-hanging maps loading fine.
--
-- Fix: keep the save-side hook here (pure XML, no physics, safe at this
-- point - matches every working reference mod). Defer the raycast-heavy
-- loadState() to MessageType.CURRENT_MISSION_START instead of calling it
-- directly - the same real, confirmed message AISystem itself waits for
-- before touching physics/terrain.
BaseMission.loadMap = Utils.overwrittenFunction(
    BaseMission.loadMap,
    function(mission, superFunc, filename, ...)
        local success = superFunc(mission, filename, ...)

        g_messageCenter:subscribeOneshot(MessageType.CURRENT_MISSION_START, HandToolHammer.loadState, HandToolHammer)
        -- the pinned vehicles are restored EARLIER: SAVEGAME_LOADED comes before the game's pre-simulation (4 s of physics, BaseMission.preSimulateTime, run by MPLoadingScreen right after this message), CURRENT_MISSION_START after it: a bridge
        -- hanging off an end piece sagged and shifted for those 4 s before its pin existed. A pin needs no raycast, only the vehicle (by its unique id).
        g_messageCenter:subscribeOneshot(MessageType.SAVEGAME_LOADED, HandToolHammer.restorePinsEarly, HandToolHammer)

        -- FSCareerMissionInfo.saveToXMLFile hook (confirmed real via
        -- FS25_MapObjectsHider, an installed, working mod) is
        -- deliberately wired up HERE, inside loadMap, not at file-scope.
        -- MapObjectsHider does the same, and for good reason found the
        -- hard way: FSCareerMissionInfo is a career/mission-specific
        -- class, not a boot-time global like BaseMission - indexing it
        -- at file-scope risks a Lua error the instant this file is
        -- parsed, before any career is even loaded. Guarded so a second
        -- loadMap (e.g. loading a different save without restarting)
        -- doesn't stack duplicate wrappers.
        if not HandToolHammer.saveHookInstalled then
            FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, HandToolHammer.saveState)
            HandToolHammer.saveHookInstalled = true
        end

        return success
    end
)

function HandToolHammer:onLoad(_)
    self[HandToolHammer.SPEC_TABLE_NAME] = {
        actionEventId = nil,
        bindActionEventId = nil,
        rotateActionEventId = nil,
        hitNode = nil,
        hitX = nil,
        hitY = nil,
        hitZ = nil
    }

    self.hammerRaycastCallback = HandToolHammer.hammerRaycastCallback
end

-- Runs every frame while held, not just on button press - this is the one
-- and only raycast now, shared between the live target highlight and the
-- actual freeze/unfreeze action, so what you SEE highlighted is always
-- exactly what a swing would act on. Used to be two separate raycasts
-- (one on press, implicitly one more if a highlight were added later) -
-- that's how a highlight and the real action could silently disagree.
function HandToolHammer:onUpdate(_)
    -- TEMPORARY diagnostic - runs regardless of getIsHeld() so it keeps
    -- tracing even if the tool gets switched away right after binding.
    -- Remove once the vanish is understood.
    if HandToolHammer.diagnosticWatchNode ~= nil and HandToolHammer.diagnosticWatchFramesLeft ~= nil and HandToolHammer.diagnosticWatchFramesLeft > 0 then
        if entityExists(HandToolHammer.diagnosticWatchNode) then
            local wx, wy, wz = getWorldTranslation(HandToolHammer.diagnosticWatchNode)
            Logging.info("SandboxHammer DIAGNOSTIC: frame=%d x=%.2f y=%.2f z=%.2f", 60 - HandToolHammer.diagnosticWatchFramesLeft, wx, wy, wz)
        else
            Logging.info("SandboxHammer DIAGNOSTIC: node no longer exists (frame=%d)", 60 - HandToolHammer.diagnosticWatchFramesLeft)
        end
        HandToolHammer.diagnosticWatchFramesLeft = HandToolHammer.diagnosticWatchFramesLeft - 1
    end

    -- Every bound child's world transform is recomputed from its
    -- parent's CURRENT transform every single frame, regardless of
    -- whether the hammer is currently held - a KINEMATIC body's
    -- position is entirely script-driven, it won't track its parent on
    -- its own just because link() put it in the scene graph hierarchy.
    -- Iterated in insertion order, which matches dependency order for a
    -- chain (you can only bind C to B after B already exists as a real
    -- target), so a parent's own sync (if it's itself a bound child)
    -- always runs before its children's this same frame.
    for _, member in ipairs(HandToolHammer.assemblyMembers) do
        HandToolHammer.applyAssemblyMemberTransform(member)
    end

    if not self:getIsHeld() then
        return
    end

    local spec = self[HandToolHammer.SPEC_TABLE_NAME]

    HandToolHammer.hammerRaycast(self)

    -- Pending bind target 1: yellow marker at its live position - shows
    -- exactly which real object is waiting for its second half of the
    -- bind.
    if HandToolHammer.bindTarget1Node ~= nil and entityExists(HandToolHammer.bindTarget1Node) then
        local tx, ty, tz = getWorldTranslation(HandToolHammer.bindTarget1Node)
        DebugUtil.drawSimpleDebugCube(tx, ty, tz, 0.08, 1, 1, 0)
    end

    if spec.hitNode ~= nil then
        -- DebugUtil.drawSimpleDebugCube - confirmed real and NOT
        -- debug-build-gated (WheelDestruction.lua calls
        -- DebugUtil.drawDebugCircle directly in real, shipped gameplay
        -- code, same file, no --#debug prefix) - not a "debug-only"
        -- trick, a genuine world-space marker any mod can draw. Redrawn
        -- every frame on purpose - debug draw calls aren't persistent
        -- scene objects, they only last the frame they're issued in.
        -- Color reflects what a swing would actually do: red = already
        -- frozen, this hit would unfreeze it; green = still dynamic,
        -- this hit would freeze it.
        if HandToolHammer.isIgnoredTarget(spec.hitNode) then
            DebugUtil.drawSimpleDebugCube(spec.hitX, spec.hitY, spec.hitZ, 0.02, 0.6, 0.6, 0.6)               -- grey: the hammer would do nothing here
        elseif HandToolHammer.isStickyTarget(spec.hitNode) then
            DebugUtil.drawSimpleDebugCube(spec.hitX, spec.hitY, spec.hitZ, 0.03, 1, 0, 1)
        elseif HandToolHammer.isFrozenTarget(spec.hitNode) then
            DebugUtil.drawSimpleDebugCube(spec.hitX, spec.hitY, spec.hitZ, 0.03, 1, 0, 0)
        else
            DebugUtil.drawSimpleDebugCube(spec.hitX, spec.hitY, spec.hitZ, 0.03, 0, 1, 0)
        end

        -- The actual answer to "how would I even know if bind did
        -- anything" - look at any bound piece and every direct partner
        -- lights up blue at its own LIVE position (not a saved one), so
        -- this doubles as a live check that the joint is still real,
        -- not just a one-time confirmation. Direct pairs only, not full
        -- transitive chain - looking at B in an A-B-C chain shows A and
        -- C, not "everything eventually connected."
        for _, member in ipairs(HandToolHammer.assemblyMembers) do
            local partner = nil
            if member.child == spec.hitNode then
                partner = member.parent
            elseif member.parent == spec.hitNode then
                partner = member.child
            end

            if partner ~= nil and entityExists(partner) then
                local pxp, pyp, pzp = getWorldTranslation(partner)
                DebugUtil.drawSimpleDebugCube(pxp, pyp, pzp, 0.06, 0, 0.5, 1)
            end
        end
    end
end

function HandToolHammer:onRegisterActionEvents()
    local spec = self[HandToolHammer.SPEC_TABLE_NAME]

    if self:getIsActiveForInput(true) then
        local _, actionEventId = self:addActionEvent(InputAction.ACTIVATE_HANDTOOL, self, HandToolHammer.onHammerAction, true, true, false, true, nil)
        spec.actionEventId = actionEventId

        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventText(actionEventId, "Swing hammer")
        g_inputBinding:setActionEventActive(actionEventId, self:getIsHeld())

        -- SANDBOX_HAMMER_BIND is a custom action (modDesc.xml, bound to
        -- 'B' by default) - unlike ACTIVATE_HANDTOOL_SECONDARY, this one
        -- genuinely doesn't exist as a base-game action, so it needed a
        -- real <action>/<actionBinding> declaration. Referenced by
        -- string name here, not InputAction.X - confirmed real pattern
        -- via HandToolBinoculars.lua's own custom action usage.
        local _, bindActionEventId = self:addActionEvent("SANDBOX_HAMMER_BIND", self, HandToolHammer.onHammerBindAction, true, true, false, true, nil)
        spec.bindActionEventId = bindActionEventId

        g_inputBinding:setActionEventTextPriority(bindActionEventId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventText(bindActionEventId, "Set bind target 1 / bind to it")
        g_inputBinding:setActionEventActive(bindActionEventId, self:getIsHeld())

        -- SANDBOX_HAMMER_ROTATE ('R') - diagnostic exercise: rotate
        -- whatever's under the crosshair 90 degrees around the exact
        -- raycast hit point (not the object's own center). Proves the
        -- hit position is real and precise, since a pivot around the
        -- wrong point is immediately, visibly obvious (the object swings
        -- off to one side instead of spinning in place).
        local _, rotateActionEventId = self:addActionEvent("SANDBOX_HAMMER_ROTATE", self, HandToolHammer.onHammerRotateAction, true, true, false, true, nil)
        spec.rotateActionEventId = rotateActionEventId

        g_inputBinding:setActionEventTextPriority(rotateActionEventId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventText(rotateActionEventId, "Rotate 90 deg around target point")
        g_inputBinding:setActionEventActive(rotateActionEventId, self:getIsHeld())
    end
end

function HandToolHammer:onHeldStart()
    local spec = self[HandToolHammer.SPEC_TABLE_NAME]

    if spec.actionEventId ~= nil then
        g_inputBinding:setActionEventActive(spec.actionEventId, true)
    end
    if spec.bindActionEventId ~= nil then
        g_inputBinding:setActionEventActive(spec.bindActionEventId, true)
    end
    if spec.rotateActionEventId ~= nil then
        g_inputBinding:setActionEventActive(spec.rotateActionEventId, true)
    end
end

function HandToolHammer:onHeldEnd()
    local spec = self[HandToolHammer.SPEC_TABLE_NAME]

    if spec.actionEventId ~= nil then
        g_inputBinding:setActionEventActive(spec.actionEventId, false)
    end
    if spec.bindActionEventId ~= nil then
        g_inputBinding:setActionEventActive(spec.bindActionEventId, false)
    end
    if spec.rotateActionEventId ~= nil then
        g_inputBinding:setActionEventActive(spec.rotateActionEventId, false)
    end
end

-- Acts on whatever onUpdate's continuous raycast already found and is
-- currently highlighting - no separate raycast here anymore. Same
-- guarantee as the highlight comment above: this can never act on
-- something different from what was just shown on screen.
function HandToolHammer:onHammerAction(_, inputValue)
    if inputValue > 0.5 then
        local spec = self[HandToolHammer.SPEC_TABLE_NAME]

        if spec.hitNode ~= nil then
            HandToolHammer.toggleNode(self, spec.hitNode)
        end
    end
end

-- Bind, redesigned via reparenting instead of JointConstructor (see the
-- #nukefromorbit comment on assemblyMembers above for why). Two-step
-- select, same UI shape as before target1 existed: first B press on a
-- real object marks it as the bind target; second B press on a
-- different real object reparents it under that target.
function HandToolHammer:onHammerBindAction(_, inputValue)
    if inputValue > 0.5 then
        local spec = self[HandToolHammer.SPEC_TABLE_NAME]

        -- Same terrain exclusion every other handler has.
        if spec.hitNode == nil or spec.hitNode == g_currentMission.terrainRootNode
            or spec.hitNode == g_terrainNode or getName(spec.hitNode) == "terrain" then
            return
        end

        if HandToolHammer.bindTarget1Node == nil or not entityExists(HandToolHammer.bindTarget1Node) then
            HandToolHammer.bindTarget1Node = spec.hitNode
            Logging.info("SandboxHammer: target 1 = %s name=%s - now hit a second object to bind it, or hit target 1 again to cancel", tostring(spec.hitNode), tostring(getName(spec.hitNode)))
            return
        end

        if spec.hitNode == HandToolHammer.bindTarget1Node then
            HandToolHammer.bindTarget1Node = nil
            Logging.info("SandboxHammer: target 1 cleared")
            return
        end

        local nx, ny, nz = getWorldTranslation(spec.hitNode)
        Logging.info("SandboxHammer DIAGNOSTIC: pre-bind position node=%s x=%.2f y=%.2f z=%.2f", tostring(spec.hitNode), nx, ny, nz)

        -- TEMPORARY diagnostic - real bounding box/size query, confirmed
        -- real via TreePlantManager.lua's own debug tooling
        -- (getSplitShapeOrientedBoundingBox is specifically for
        -- split-shape logs, which is what we're testing with). Wrapped
        -- in pcall since it'll error on anything that isn't actually a
        -- split shape.
        local statsOk, sizeX, sizeY, sizeZ, numConvexes, numAttachments = pcall(getSplitShapeStats, spec.hitNode)
        if statsOk then
            Logging.info("SandboxHammer DIAGNOSTIC: split shape stats sizeX=%.2f sizeY=%.2f sizeZ=%.2f numConvexes=%s numAttachments=%s", sizeX, sizeY, sizeZ, tostring(numConvexes), tostring(numAttachments))
        end

        local boxOk, boundingBox = pcall(getSplitShapeOrientedBoundingBox, spec.hitNode)
        if boxOk and boundingBox ~= nil then
            local dir0X, dir0Y, dir0Z, dir1X, dir1Y, dir1Z, _, _, _, centerX, centerY, centerZ, extent0, extent1, extent2 = unpack(boundingBox)
            Logging.info("SandboxHammer DIAGNOSTIC: oriented bbox localCenter=%.2f %.2f %.2f extents=%.2f %.2f %.2f (full size=%.2f x %.2f x %.2f)", centerX, centerY, centerZ, extent0, extent1, extent2, extent0 * 2, extent1 * 2, extent2 * 2)
        end

        local member = HandToolHammer.bindChildToParent(HandToolHammer.bindTarget1Node, spec.hitNode)
        if member ~= nil then
            table.insert(HandToolHammer.assemblyMembers, member)
            HandToolHammer.saveState()

            -- TEMPORARY diagnostic - traces this node's position every
            -- frame for ~1 second right after binding, to see exactly
            -- where/how it moves instead of just "it's gone". Remove
            -- once the vanish is understood.
            HandToolHammer.diagnosticWatchNode = spec.hitNode
            HandToolHammer.diagnosticWatchFramesLeft = 60
        end
    end
end

-- Exercise: rotate whatever's under the crosshair 90 degrees around the
-- exact raycast hit point, not the object's own pivot/center - proves
-- the hit coordinate is real and precise, since a pivot around the
-- wrong point is immediately, visibly obvious (the object swings off to
-- one side rather than spinning cleanly in place). Rotation is around
-- world Y (vertical) through the hit point - simplest axis to reason
-- about and to visually confirm against a static log lying on the
-- ground.
function HandToolHammer:onHammerRotateAction(_, inputValue)
    if inputValue > 0.5 then
        local spec = self[HandToolHammer.SPEC_TABLE_NAME]

        if spec.hitNode == nil or spec.hitNode == g_currentMission.terrainRootNode
            or spec.hitNode == g_terrainNode or getName(spec.hitNode) == "terrain" then
            return
        end

        HandToolHammer.rotateNodeAroundPoint(spec.hitNode, spec.hitX, spec.hitY, spec.hitZ, math.pi / 2)

        Logging.info("SandboxHammer: rotated node=%s name=%s 90 deg around target point %.2f %.2f %.2f", tostring(spec.hitNode), tostring(getName(spec.hitNode)), spec.hitX, spec.hitY, spec.hitZ)

        -- TEMPORARY diagnostic - reuses the same 60-frame position trace
        -- built for the bind-vanish investigation, to see whether a
        -- "jump" on a later rotate happens instantly (bad math, wrong on
        -- the very first frame) or drifts in over several frames (physics
        -- reacting/correcting something after the fact).
        HandToolHammer.diagnosticWatchNode = spec.hitNode
        HandToolHammer.diagnosticWatchFramesLeft = 60
    end
end

-- getWorldRotation/setWorldRotation confirmed real (Vehicle.lua,
-- VehicleCamera.lua, TensionBelts.lua all use this exact pair on live
-- DYNAMIC nodes, not just static scenery) - safe to use here on a
-- physics-simulated log the same way. Pivoting around an arbitrary
-- world point (rather than the node's own origin) is plain 2D rotation
-- of the position offset in the XZ plane, plus adding the same angle to
-- the node's own world yaw so its facing turns with it instead of just
-- swinging its position around while staying pointed the same way.
function HandToolHammer.rotateNodeAroundPoint(node, pivotX, pivotY, pivotZ, angleRad)
    if node == nil or not entityExists(node) then
        return
    end

    local nx, ny, nz = getWorldTranslation(node)
    local dx, dz = nx - pivotX, nz - pivotZ
    local pivotRadius = math.sqrt(dx * dx + dz * dz)

    local cosA, sinA = math.cos(angleRad), math.sin(angleRad)
    local newDx = dx * cosA - dz * sinA
    local newDz = dx * sinA + dz * cosA

    local rxBefore, ryBefore, rzBefore = getWorldRotation(node)
    local vxBefore, vyBefore, vzBefore = getLinearVelocity(node)
    local rigidBodyType = getRigidBodyType(node)

    setWorldTranslation(node, pivotX + newDx, ny, pivotZ + newDz)
    setWorldRotation(node, rxBefore, ryBefore + angleRad, rzBefore)

    -- Diagnostic, user report: "first rotation always fine, second one
    -- (even after reselecting the log/picking a fresh pivot point)
    -- always jumps" - reliably wrong on click 2 specifically, not just
    -- "wrong when the pivot happens to be far from origin" (pivotRadius
    -- alone doesn't explain a symptom that's consistent regardless of
    -- where you re-aim). Two real, unconfirmed candidates this log is
    -- meant to distinguish between: (a) Euler round-trip corruption -
    -- getWorldRotation/setWorldRotation on rx/ry/rz doesn't necessarily
    -- compose correctly for a second add-to-ry if the first rotation put
    -- non-zero values into rx/rz (a resting log is rarely EXACTLY
    -- axis-aligned) - reading back the rotation actually stored (not
    -- just what we asked for) after the second call would show this; or
    -- (b) the node is a live DYNAMIC rigid body and direct
    -- setWorldTranslation/setWorldRotation teleporting doesn't properly
    -- sync the physics-authoritative pose - if the first rotation left
    -- residual velocity or an interpenetrating pose that physics is
    -- still resolving, the second teleport lands on an already-unstable
    -- body. rigidBodyType/linear velocity right before this rotation is
    -- exactly what would show (b): non-zero velocity or a non-STATIC
    -- body going into rotation 2 that wasn't there going into rotation 1.
    Logging.info("SandboxHammer: rotated node=%s pivotRadius=%.2f rigidBodyType=%s velBefore=%.3f %.3f %.3f rotBefore=%.2f %.2f %.2f originBefore=%.2f %.2f %.2f originAfter=%.2f %.2f %.2f",
        tostring(node), pivotRadius, tostring(rigidBodyType), vxBefore, vyBefore, vzBefore, rxBefore, ryBefore, rzBefore, nx, ny, nz, pivotX + newDx, ny, pivotZ + newDz)
end

-- Updates spec.hitNode/hitX/hitY/hitZ only - no action, no logging. Runs
-- every single frame while held (see onUpdate), so anything that used to
-- log here (Logging.info per miss/hit) would spam log.txt at full
-- framerate instead of once per button press - moved actual event
-- logging to toggleNode, which only fires on a real freeze/unfreeze.
function HandToolHammer.hammerRaycast(self)
    local spec = self[HandToolHammer.SPEC_TABLE_NAME]
    spec.hitNode = nil

    local cameraNode = HandToolHammer.getHammerCameraNode(self)
    if cameraNode == nil then
        return
    end

    local x, y, z = getWorldTranslation(cameraNode)
    local dx, dy, dz = localDirectionToWorld(cameraNode, 0, 0, -1)

    raycastClosest(x, y, z, dx, dy, dz, HandToolHammer.RAYCAST_DISTANCE, "hammerRaycastCallback", self)
end

function HandToolHammer.getHammerCameraNode(self)
    local player = self.getCarryingPlayer ~= nil and self:getCarryingPlayer() or nil

    if player == nil or player.camera == nil or player.camera.getCurrentCameraNode == nil then
        return nil
    end

    return player.camera:getCurrentCameraNode()
end

function HandToolHammer.hammerRaycastCallback(self, hitNode, x, y, z, distance, ...)
    if hitNode == nil or not entityExists(hitNode) then
        return true
    end

    if self.rootNode ~= nil and hitNode == self.rootNode then
        return true
    end

    local spec = self[HandToolHammer.SPEC_TABLE_NAME]
    spec.hitNode = hitNode
    spec.hitX, spec.hitY, spec.hitZ = x, y, z
    local nx, ny, nz = ...                                  -- (the surface normal at the hit: the sticker lies flat on it)
    spec.hitNX, spec.hitNY, spec.hitNZ = nx, ny, nz

    return false
end

-- A vehicle with ONE body (a horse ball, a pallet, a big bag) can be frozen like any loose object; machines with several components and joints still cannot.
function HandToolHammer.isSingleBodyVehicle(object)
    return object ~= nil and object.components ~= nil and #object.components == 1
end

-- A vehicle with several bodies (a wagon: frame, axle, tongue, joined by physics joints) is frozen by its ROOT body only: the others stay dynamic, held by their joints to a static body (a joint between two static bodies is not possible, one to a static one is), and rest there.
-- ===== shift-freeze: a swing with Left Shift held freezes (or pins) ANY object "specially": it stays when the hall is thawed or frozen again, only another shift swing at it lets it go. A plain swing at it does nothing. =====
function HandToolHammer.shiftHeld()
    return Input ~= nil and Input.isKeyPressed ~= nil and Input.KEY_lshift ~= nil and Input.isKeyPressed(Input.KEY_lshift) or false
end

-- What a swing at this node acts on: its vehicle when it is part of one, and the record that says it is frozen (frozenObjects entry, or the pin of a wagon); entry is nil while it is free.
function HandToolHammer.targetOf(node)
    local object = g_currentMission:getNodeObject(node)
    local target = node
    if object == nil then
        local vehicle = HandToolHammer.vehicleOfNode(node)
        if vehicle ~= nil and vehicle.components ~= nil and vehicle.components[1] ~= nil then
            object, target = vehicle, vehicle.components[1].node
        end
    end
    if object ~= nil and object.isa ~= nil and Vehicle ~= nil and object:isa(Vehicle) and not HandToolHammer.isFreezable(object, target) then
        return object, HandToolHammer.pinned[object]
    end
    return object, HandToolHammer.frozenObjects[target]
end

function HandToolHammer.isStickyTarget(node)
    local _, entry = HandToolHammer.targetOf(node)
    return entry ~= nil and entry.sticky == true
end

local function say(text)
    Logging.info("SandboxHammer: " .. text)
    if g_currentMission.addIngameNotification ~= nil and FSBaseMission ~= nil then
        pcall(g_currentMission.addIngameNotification, g_currentMission, FSBaseMission.INGAME_NOTIFICATION_INFO, text)
    end
end

-- What the hammer leaves alone: the terrain and the animals (a horse is a one-body vehicle, it would have been "freezable"). The aiming cube is grey there, and a swing does nothing.
function HandToolHammer.isIgnoredTarget(node)
    if node == nil or not entityExists(node) then
        return false
    end
    if node == g_currentMission.terrainRootNode or node == g_terrainNode or getName(node) == "terrain" then
        return true, "terrain"
    end
    local object = g_currentMission:getNodeObject(node) or HandToolHammer.vehicleOfNode(node)
    if object ~= nil and object.spec_rideable ~= nil then
        return true, "animal"
    end
    return false
end

function HandToolHammer.toggleNode(self, node)
    local ignored, why = HandToolHammer.isIgnoredTarget(node)
    if ignored then
        if why == "animal" then
            say("the hammer leaves animals alone")
        end
        return
    end
    if node == nil or not entityExists(node) or HandToolHammer.placeableOfNode(node) ~= nil then
        return HandToolHammer.toggleNodeCore(self, node)                       -- (a building: the hall swing, a door ...)
    end
    local shift = HandToolHammer.shiftHeld()
    local _, entry = HandToolHammer.targetOf(node)
    if entry ~= nil and entry.sticky and not shift then
        say("this one is shift-frozen: a swing with Left Shift held lets it go")
        return
    end
    if shift and entry ~= nil and not entry.sticky then
        entry.sticky = true                                                    -- (already frozen: it now stays)
        HandToolHammer.saveState()
        say("shift-frozen: it stays when the hall is thawed")
        return
    end
    HandToolHammer.toggleNodeCore(self, node)
    if shift then
        local _, after = HandToolHammer.targetOf(node)
        if after ~= nil then
            after.sticky = true
            HandToolHammer.saveState()
            say("shift-frozen: it stays when the hall is thawed")
        end
    end
end

-- The vehicle a shape belongs to when it is a part INSIDE one (a player trigger, a collision child ...: not a component's own node), else nil. Such a node is not frozen by itself: the vehicle moves it every frame.
function HandToolHammer.vehicleOfNode(node)
    local n, depth = getParent(node), 0
    while n ~= nil and n ~= 0 and depth < 14 do
        local object = g_currentMission:getNodeObject(n)
        if object ~= nil and object.isa ~= nil and Vehicle ~= nil and object:isa(Vehicle) then
            return object
        end
        n = getParent(n)
        depth = depth + 1
    end
    return nil
end

-- Is what a swing at this node would act on frozen? The node itself, its vehicle (a click on a tarp, a trigger, any part takes the whole vehicle: frozen when its root body is), or its building (frozen while it carries the mouse plaque).
function HandToolHammer.isFrozenTarget(node)
    if HandToolHammer.frozenObjects[node] ~= nil then
        return true
    end
    local object = g_currentMission:getNodeObject(node)
    if object == nil or not (object.isa ~= nil and Vehicle ~= nil and object:isa(Vehicle)) then
        object = HandToolHammer.vehicleOfNode(node)
    end
    if object ~= nil and object.components ~= nil and object.components[1] ~= nil and HandToolHammer.frozenObjects[object.components[1].node] ~= nil then
        return true
    end
    if object ~= nil and HandToolHammer.pinned[object] ~= nil then
        return true
    end
    local hall = HandToolHammer.placeableOfNode(node)
    return hall ~= nil and HandToolHammer.hasStickerOf(hall)
end

function HandToolHammer.isFreezable(object, node)
    if object == nil or object.components == nil then
        return true
    end
    -- a vehicle with wheels or several bodies is NOT: changing a body's type destroys its wheel shapes ("Wheel shape not found", the wheels never come back) and its joints (a wagon comes apart at the next pull)
    local wheels = object.spec_wheels ~= nil and object.spec_wheels.wheels or nil
    -- the selling plate is pinned too: a frozen (static) body loses its collision, so wheels and logs sink into the grid
    if object.getIsSellingPlateFixed ~= nil then
        return false
    end
    -- anything hitched to something, or with something hitched to it, and the bridge pieces (made to be hitched): a body-type change would destroy the attach joints, so it is pinned instead
    if object.typeName ~= nil and string.find(object.typeName, "bridge", 1, true) ~= nil then
        return false
    end
    -- the winch pole and anchor are pinned too: a frozen (static) body loses its collision (nothing touches it, the hammer's ray goes through it)
    if object.typeName ~= nil and (string.find(object.typeName, "winchPole", 1, true) ~= nil or string.find(object.typeName, "winchAnchor", 1, true) ~= nil) then
        return false
    end
    if object.getAttacherVehicle ~= nil and object:getAttacherVehicle() ~= nil then
        return false
    end
    if object.getAttachedImplements ~= nil and #object:getAttachedImplements() > 0 then
        return false
    end
    return #object.components == 1 and (wheels == nil or #wheels == 0)
end

-- ===== pinned vehicles: a vehicle with wheels or several bodies is never frozen (changing a body's type destroys its wheel shapes and joints); it is held by an invisible joint to a kinematic helper body in the world instead =====
-- The vehicle stays dynamic and whole (the game's own helper body of the hand tool, dataS/character/shared/kinematicHelper.i3d, and a locked joint like the one that holds a carried object), and rests there: asleep, it costs nothing.
HandToolHammer.pinned = {}                 -- vehicle -> { helper = node, joint = index, uniqueId = ... }
HandToolHammer.HELPER_I3D = "dataS/character/shared/kinematicHelper.i3d"

function HandToolHammer.needsPin(object)
    return object ~= nil and object.components ~= nil and not HandToolHammer.isFreezable(object, nil)
end

function HandToolHammer.loadHelper()
    local root = g_i3DManager:loadSharedI3DFile(HandToolHammer.HELPER_I3D, false, false)
    if root == nil or root == 0 then
        return nil
    end
    local node = getChildAt(root, 0)
    link(getRootNode(), node)
    addToPhysics(node)
    delete(root)
    return node
end

-- The two end pieces of a bridge, the winch poles and the winch anchors are made heavy while they are pinned (the bridge hanging off them cannot pull them off the bank while a savegame loads; start and end piece 30 t, so a chain or a tractor cannot shove them), and as light as a grate when they are free (you cannot drag or lift 3 t by hand).
HandToolHammer.PIN_MASS_T = { bridgeStart = 30.0, bridgeEnd = 30.0, winchPole = 3.0, winchAnchor = 3.0 }
function HandToolHammer.pinMassOf(vehicle)
    if vehicle.typeName == nil then
        return nil
    end
    for name, mass in pairs(HandToolHammer.PIN_MASS_T) do
        if string.find(vehicle.typeName, name, 1, true) ~= nil then
            return mass
        end
    end
    return nil
end

-- The link rings (the other components of a piece) get a mass of their own while it is pinned, when a table entry says so: a heavy piece squeezing a 40 kg ring between two heavy neighbours is the unstable shape (sbBridgePinMass).
HandToolHammer.PIN_RING_T = {}
function HandToolHammer.setPinMass(vehicle, on)
    local component = vehicle.components ~= nil and vehicle.components[1] or nil
    local heavy = HandToolHammer.pinMassOf(vehicle)
    if component == nil or heavy == nil then
        return
    end
    if on then
        if vehicle.hdMassBeforePin == nil then
            vehicle.hdMassBeforePin = component.defaultMass or getMass(component.node)
            component.defaultMass = math.max(vehicle.hdMassBeforePin, heavy)
            if vehicle.maxComponentMass ~= nil and vehicle.maxComponentMass < component.defaultMass + 1 then
                vehicle.hdMaxMassBeforePin = vehicle.maxComponentMass
                vehicle.maxComponentMass = component.defaultMass + 1                      -- (the game clamps a vehicle to the maxMass of its xml: lifted while it is pinned)
            end
        end
        for name, ringMass in pairs(HandToolHammer.PIN_RING_T) do
            if vehicle.hdRingMassBeforePin == nil and vehicle.typeName ~= nil and string.find(vehicle.typeName, name, 1, true) ~= nil then
                vehicle.hdRingMassBeforePin = {}
                for i = 2, #vehicle.components do
                    local c = vehicle.components[i]
                    vehicle.hdRingMassBeforePin[i] = c.defaultMass
                    c.defaultMass = ringMass
                end
            end
        end
    elseif vehicle.hdMassBeforePin ~= nil then
        component.defaultMass = vehicle.hdMassBeforePin
        vehicle.hdMassBeforePin = nil
        if vehicle.hdMaxMassBeforePin ~= nil then
            vehicle.maxComponentMass = vehicle.hdMaxMassBeforePin
            vehicle.hdMaxMassBeforePin = nil
        end
        if vehicle.hdRingMassBeforePin ~= nil then
            for i, m in pairs(vehicle.hdRingMassBeforePin) do
                if vehicle.components[i] ~= nil then vehicle.components[i].defaultMass = m end
            end
            vehicle.hdRingMassBeforePin = nil
        end
    end
    if vehicle.setMassDirty ~= nil then
        vehicle:setMassDirty()
    end
end

-- The winch pole and the winch anchor show their anchor bolts (a node of their own in the i3d, hidden at first) while they are pinned.
function HandToolHammer.setPinVisuals(vehicle, on)
    local component = vehicle.components ~= nil and vehicle.components[1] or nil
    if component == nil or component.node == nil or vehicle.typeName == nil or not entityExists(component.node) then
        return
    end
    for _, name in ipairs({ "winchPole", "winchAnchor", "bridgeGrate" }) do
        if string.find(vehicle.typeName, name, 1, true) ~= nil then
            local bolts = getChild(component.node, name .. (name == "bridgeGrate" and "_lock" or "_bolts"))
            if bolts ~= nil and bolts ~= 0 then
                setVisibility(bolts, on)
                Logging.info("SandboxHammer: the bolts of %s are %s", name, on and "shown (pinned)" or "hidden (free)")
            else
                Logging.info("SandboxHammer: %s has no %s_bolts node (the shapes are an old build: restart the game)", name, name)
            end
        end
    end
end

-- The same for a node the Hammer froze or thawed (a single-body vehicle like the pole is frozen, not pinned).
function HandToolHammer.setNodeBolts(node, on)
    local object = g_currentMission ~= nil and g_currentMission.getNodeObject ~= nil and g_currentMission:getNodeObject(node) or nil
    if object ~= nil and object.components ~= nil then
        HandToolHammer.setPinVisuals(object, on)
    end
end

function HandToolHammer.pinVehicle(vehicle)
    if vehicle == nil or vehicle.isDeleted or HandToolHammer.pinned[vehicle] ~= nil or vehicle.components == nil or vehicle.components[1] == nil then
        return false
    end
    local node = vehicle.components[1].node
    if node == nil or not entityExists(node) then
        return false
    end
    local helper = HandToolHammer.loadHelper()
    if helper == nil then
        Logging.warning("SandboxHammer: the helper body for a pin could not be loaded (%s)", HandToolHammer.HELPER_I3D)
        return false
    end
    local x, y, z = getWorldTranslation(node)
    local rx, ry, rz = getWorldRotation(node)
    setWorldTranslation(helper, x, y, z)
    setWorldRotation(helper, rx, ry, rz)
    setLinearVelocity(node, 0, 0, 0)
    setAngularVelocity(node, 0, 0, 0)
    local joint = JointConstructor.new()
    joint:setActors(helper, node)
    joint:setJointWorldPositions(x, y, z, x, y, z)
    for axis = 0, 2 do
        joint:setTranslationLimit(axis, true, 0, 0)
        joint:setRotationLimit(axis, 0, 0)
    end
    local ax, ay, az = localDirectionToWorld(node, 1, 0, 0)
    joint:setJointWorldAxes(ax, ay, az, ax, ay, az)
    local nx, ny, nz = localDirectionToWorld(node, 0, 1, 0)
    joint:setJointWorldNormals(nx, ny, nz, nx, ny, nz)
    joint:setEnableCollision(false)
    local index = joint:finalize()
    vehicle.hdPinned = true
    HandToolHammer.setPinMass(vehicle, true)
    HandToolHammer.setPinVisuals(vehicle, true)
    HandToolHammer.pinned[vehicle] = { helper = helper, joint = index, uniqueId = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or nil, x = x, y = y, z = z }
    Logging.info("SandboxHammer: pinned %s (joint %s)", tostring(vehicle.getName ~= nil and vehicle:getName() or "vehicle"), tostring(index))
    return true
end

function HandToolHammer.unpinVehicle(vehicle)
    local pin = HandToolHammer.pinned[vehicle]
    if pin == nil then
        return false
    end
    HandToolHammer.pinned[vehicle] = nil
    vehicle.hdPinned = nil
    HandToolHammer.setPinMass(vehicle, false)
    HandToolHammer.setPinVisuals(vehicle, false)
    if pin.joint ~= nil then
        pcall(removeJoint, pin.joint)
    end
    if pin.helper ~= nil and entityExists(pin.helper) then
        delete(pin.helper)
    end
    if not vehicle.isDeleted then
        vehicle:raiseActive()
    end
    return true
end

-- Pins whose vehicle was sold or deleted: the helper goes with it.
function HandToolHammer.cleanPins()
    for vehicle, pin in pairs(HandToolHammer.pinned) do
        if vehicle.isDeleted then
            HandToolHammer.pinned[vehicle] = nil
            if pin.helper ~= nil and entityExists(pin.helper) then
                delete(pin.helper)
            end
        end
    end
end

-- sbFreezeParts: kept for the code below; a vehicle with wheels or several bodies is refused whatever it says (isFreezable).
HandToolHammer.freezeAllParts = false
function HandToolHammer.consoleFreezeParts(_, mode)
    if mode == "on" or mode == "off" then
        HandToolHammer.freezeAllParts = mode == "on"
    end
    return "sbFreezeParts: " .. (HandToolHammer.freezeAllParts and "on (every body of a wagon is frozen)" or "off (a wagon is frozen by its root body: any force on its other bodies tears them off)")
end


function HandToolHammer.toggleNodeCore(self, node)
    if node == nil or not entityExists(node) then
        return
    end
    do                                                                   -- (what the ray hit, so a click that "froze the ground" can be told from one that froze the thing)
        local obj = g_currentMission ~= nil and g_currentMission.getNodeObject ~= nil and g_currentMission:getNodeObject(node) or nil
        Logging.info("SandboxHammer: click on node=%s name=%s, object %s", tostring(node), tostring(getName(node)), obj ~= nil and tostring(obj.configFileName or obj.typeName or "?") or "none (terrain or world shape)")
    end

    -- Terrain is already permanently static - "freezing" it is a no-op
    -- that just wastes a slot in frozenObjects/sandboxtools.xml (it
    -- rediscovers successfully every load since it's always there, but
    -- does nothing). node == g_terrainNode/terrainRootNode (WAILA's own
    -- "kind" check) turned out NOT to match here - a raycast hits a
    -- specific terrain LOD tile/chunk node, not literally the root node
    -- id. getName(node) == "terrain" is what actually produced WAILA's
    -- "name=terrain" display, so check that directly instead.
    if node == g_currentMission.terrainRootNode or node == g_terrainNode or getName(node) == "terrain" then
        Logging.info("SandboxHammer: ignoring terrain; node=%s", tostring(node))
        return
    end

    local hall = HandToolHammer.placeableOfNode(node)
    if hall ~= nil then
        if HandToolHammer.knockOnDoor(hall, node) then
            return                                                    -- (a door: it opens or closes, nothing is frozen and no plaque is put on thin air)
        end
        local spec = self[HandToolHammer.SPEC_TABLE_NAME]
        HandToolHammer.toggleHall(hall, spec ~= nil and { x = spec.hitX, y = spec.hitY, z = spec.hitZ, nx = spec.hitNX, ny = spec.hitNY, nz = spec.hitNZ, node = spec.hitNode } or nil)
        return
    end

    local object = g_currentMission:getNodeObject(node)
    if object == nil then
        local vehicle = HandToolHammer.vehicleOfNode(node)
        if vehicle ~= nil and vehicle.components ~= nil and vehicle.components[1] ~= nil then
            if HandToolHammer.frozenObjects[node] ~= nil then
                Logging.info("SandboxHammer: node=%s name=%s inside a vehicle was frozen by itself earlier: thawed", tostring(node), tostring(getName(node)))
                HandToolHammer.thawNode(node)                            -- (a stray inner shape from before: let it go first)
                HandToolHammer.saveState()
                return
            end
            Logging.info("SandboxHammer: node=%s name=%s is a part inside %s: the vehicle is taken", tostring(node), tostring(getName(node)), tostring(vehicle.getName ~= nil and vehicle:getName() or "a vehicle"))
            node, object = vehicle.components[1].node, vehicle
        end
    end

    if object ~= nil and object.isa ~= nil and object:isa(Vehicle) and not HandToolHammer.isFreezable(object, node) then
        HandToolHammer.cleanPins()
        local was = HandToolHammer.pinned[object] ~= nil
        if was then
            HandToolHammer.unpinVehicle(object)
        else
            HandToolHammer.pinVehicle(object)
        end
        HandToolHammer.saveState()
        local text = string.format("%s %s", was and "released" or "pinned", object.getName ~= nil and object:getName() or "the vehicle")
        Logging.info("SandboxHammer: " .. text)
        if g_currentMission.addIngameNotification ~= nil and FSBaseMission ~= nil then
            pcall(g_currentMission.addIngameNotification, g_currentMission, FSBaseMission.INGAME_NOTIFICATION_INFO, text)
        end
        return
    end

    -- a wagon (several bodies) is frozen or thawed as a whole: a click on any of its parts takes all of them
    if object ~= nil and object.isa ~= nil and object:isa(Vehicle) and HandToolHammer.freezeAllParts and object.components ~= nil and #object.components > 1 then
        HandToolHammer.pendingAll = {}
        for _, component in ipairs(object.components) do
            if component.node ~= nil and entityExists(component.node) then
                HandToolHammer.pendingAll[component.node] = true
            end
        end
        local thaw = false
        for _, component in ipairs(object.components) do
            if HandToolHammer.frozenObjects[component.node] ~= nil then
                thaw = true                                                  -- (any part frozen: the click lets all of them go)
            end
        end
        local count = HandToolHammer.freezeSet(thaw)
        HandToolHammer.pendingAll = nil
        HandToolHammer.saveState()
        local text = string.format("%s %d part(s) of %s", thaw and "thawed" or "froze", count, object.getName ~= nil and object:getName() or "the vehicle")
        Logging.info("SandboxHammer: " .. text)
        if g_currentMission.addIngameNotification ~= nil and FSBaseMission ~= nil then
            pcall(g_currentMission.addIngameNotification, g_currentMission, FSBaseMission.INGAME_NOTIFICATION_INFO, text)
        end
        return
    end

    if HandToolHammer.frozenObjects[node] ~= nil then
        setRigidBodyType(node, HandToolHammer.frozenObjects[node].rigidBodyType)
        HandToolHammer.setVehicleComponentStatic(node, false)
        HandToolHammer.frozenObjects[node] = nil
        Logging.info("SandboxHammer: unfroze node=%s name=%s", tostring(node), tostring(getName(node)))
        HandToolHammer.setNodeBolts(node, false)
        HandToolHammer.saveState()
        return
    end

    local rigidBodyType = getRigidBodyType(node)

    if rigidBodyType == RigidBodyType.NONE then
        Logging.info("SandboxHammer: node has no rigid body; node=%s name=%s", tostring(node), tostring(getName(node)))
        return
    end

    -- uniqueId is only ever present for a real Object (Vehicle, Placeable,
    -- ForestryLog, ...) - raw split/terrain geometry has no engine-side
    -- identity at all, so this is opportunistic, not relied upon; position
    -- is what actually re-finds the thing after reload (see loadState).
    local uniqueId = nil
    if object ~= nil and object.getUniqueId ~= nil then
        uniqueId = object:getUniqueId()
    end
    local x, y, z = getWorldTranslation(node)

    HandToolHammer.frozenObjects[node] = {
        rigidBodyType = rigidBodyType,
        uniqueId = uniqueId,
        x = x, y = y, z = z
    }

    setLinearVelocity(node, 0, 0, 0)
    setAngularVelocity(node, 0, 0, 0)
    HandToolHammer.rememberBody(node)
    setRigidBodyType(node, RigidBodyType.STATIC)
    HandToolHammer.setVehicleComponentStatic(node, true)

    Logging.info("SandboxHammer: froze node=%s name=%s oldRigidBodyType=%s uniqueId=%s", tostring(node), tostring(getName(node)), tostring(rigidBodyType), tostring(uniqueId))
    HandToolHammer.setNodeBolts(node, true)
    HandToolHammer.saveState()
end


-- Rigid attachment via scene-graph reparenting, replacing the old
-- JointConstructor weld entirely. worldToLocal/localToWorld/
-- worldDirectionToLocal/localDirectionToWorld all confirmed real via
-- Book_ScriptingFarmingSimulatorWithLua's own function reference.
-- Checked the same book's RigidBodyType enum before designing this: only
-- NONE/STATIC/DYNAMIC/KINEMATIC exist, no compound/merge type - so
-- there's no free "combine collisions" feature, and the child MUST stay
-- KINEMATIC (not NONE) to keep being a real, solid, collidable body
-- rather than becoming a ghost. What reparenting actually replaces the
-- joint with is the position/orientation tracking - captured once here
-- as a fixed local offset, reapplied every frame by
-- applyAssemblyMemberTransform (see onUpdate) - never a spring, so it
-- can't go unstable under load the way the anchor's joint did.
function HandToolHammer.bindChildToParent(parentNode, childNode)
    if parentNode == nil or childNode == nil or parentNode == childNode then
        return nil
    end
    if not entityExists(parentNode) or not entityExists(childNode) then
        return nil
    end

    local wx, wy, wz = getWorldTranslation(childNode)
    local fwdX, fwdY, fwdZ = localDirectionToWorld(childNode, 0, 0, 1)
    local upX, upY, upZ = localDirectionToWorld(childNode, 0, 1, 0)

    local localX, localY, localZ = worldToLocal(parentNode, wx, wy, wz)
    local localFwdX, localFwdY, localFwdZ = worldDirectionToLocal(parentNode, fwdX, fwdY, fwdZ)
    local localUpX, localUpY, localUpZ = worldDirectionToLocal(parentNode, upX, upY, upZ)

    -- A frozen (STATIC) child is about to become KINEMATIC instead -
    -- the frozenObjects bookkeeping (which rigidBodyType to restore on
    -- unfreeze) no longer applies once it's part of an assembly.
    if HandToolHammer.frozenObjects[childNode] ~= nil then
        HandToolHammer.frozenObjects[childNode] = nil
    end

    setLinearVelocity(childNode, 0, 0, 0)
    setAngularVelocity(childNode, 0, 0, 0)
    setRigidBodyType(childNode, RigidBodyType.KINEMATIC)
    link(parentNode, childNode)

    local member = {
        parent = parentNode,
        child = childNode,
        localX = localX, localY = localY, localZ = localZ,
        localFwdX = localFwdX, localFwdY = localFwdY, localFwdZ = localFwdZ,
        localUpX = localUpX, localUpY = localUpY, localUpZ = localUpZ,
    }

    -- Reapply immediately - link() alone keeps the child's existing
    -- LOCAL transform value, which combined with the NEW parent is a
    -- different world pose unless explicitly re-set, and onUpdate's own
    -- sync wouldn't run until next frame otherwise (a one-frame visual
    -- snap).
    HandToolHammer.applyAssemblyMemberTransform(member)

    Logging.info("SandboxHammer: bound child=%s to parent=%s rigidBodyType=KINEMATIC local=%.2f %.2f %.2f", tostring(childNode), tostring(parentNode), localX, localY, localZ)

    return member
end

-- Shared by bindChildToParent's own immediate reapply and onUpdate's
-- every-frame sync - one place computing "where should this child be
-- right now" from its parent's CURRENT transform plus the fixed local
-- offset/orientation captured at bind time.
function HandToolHammer.applyAssemblyMemberTransform(member)
    if not entityExists(member.parent) or not entityExists(member.child) then
        return
    end

    local wx, wy, wz = localToWorld(member.parent, member.localX, member.localY, member.localZ)
    local fwdX, fwdY, fwdZ = localDirectionToWorld(member.parent, member.localFwdX, member.localFwdY, member.localFwdZ)
    local upX, upY, upZ = localDirectionToWorld(member.parent, member.localUpX, member.localUpY, member.localUpZ)

    setWorldTranslation(member.child, wx, wy, wz)
    setWorldDirection(member.child, fwdX, fwdY, fwdZ, upX, upY, upZ)
end

-- Written on every freeze/unfreeze (a rare, deliberate player action, not
-- per-frame) AND on every real Save Game (see the FSCareerMissionInfo
-- hook above) - toggle-time alone turned out not to be enough, a real
-- Save Game pass didn't preserve a file that wasn't re-written during it.
-- Self-contained on purpose: ModUtils (used earlier) turned out to be
-- FS25_TerraFarm's own mod-local global, not a core-engine one -
-- FS25_Hammer never declared a dependency on it, so it was nil at
-- runtime and crashed the whole mission-start transition. Back to
-- building the path directly, same as AISystem:save does it.
function HandToolHammer.saveState()
    if g_currentMission == nil or g_currentMission.missionInfo == nil or g_currentMission.missionInfo.savegameDirectory == nil then
        return
    end

    local path = g_currentMission.missionInfo.savegameDirectory .. "/" .. HandToolHammer.SAVEGAME_FILENAME
    local xmlFile = XMLFile.create("sandboxToolsXML", path, "sandboxTools")
    if xmlFile == nil then
        return
    end

    local i = 0
    for node, data in pairs(HandToolHammer.frozenObjects) do
        local key = string.format("sandboxTools.frozenObject(%d)", i)
        if data.uniqueId ~= nil then
            xmlFile:setString(key .. "#uniqueId", data.uniqueId)
        end
        local splitId = HandToolHammer.saveableSplitId(node)
        if splitId ~= nil then
            xmlFile:setString(key .. "#splitId", splitId)
        end
        xmlFile:setFloat(key .. "#x", data.x)
        xmlFile:setFloat(key .. "#y", data.y)
        xmlFile:setFloat(key .. "#z", data.z)
        xmlFile:setInt(key .. "#rigidBodyType", data.rigidBodyType)
        if data.sticky then
            xmlFile:setBool(key .. "#sticky", true)
        end
        i = i + 1
    end

    -- Assembly members: both parent and child are always real,
    -- rediscoverable world objects now (never our own synthesized node),
    -- so both endpoints' CURRENT world positions get saved - not the
    -- stored local offset, which gets recomputed fresh from wherever the
    -- rediscovered nodes actually end up on load (bindChildToParent
    -- does this itself, same as a fresh in-game bind would).
    local j = 0
    for _, member in ipairs(HandToolHammer.assemblyMembers) do
        if entityExists(member.parent) and entityExists(member.child) then
            local px, py, pz = getWorldTranslation(member.parent)
            local cx, cy, cz = getWorldTranslation(member.child)
            local key = string.format("sandboxTools.assemblyMember(%d)", j)
            xmlFile:setFloat(key .. "#px", px)
            xmlFile:setFloat(key .. "#py", py)
            xmlFile:setFloat(key .. "#pz", pz)
            xmlFile:setFloat(key .. "#cx", cx)
            xmlFile:setFloat(key .. "#cy", cy)
            xmlFile:setFloat(key .. "#cz", cz)
            j = j + 1
        end
    end

    for k, st in ipairs(HandToolHammer.stickers) do
        local key = string.format("sandboxTools.sticker(%d)", k - 1)
        xmlFile:setFloat(key .. "#x", st.x)
        xmlFile:setFloat(key .. "#y", st.y)
        xmlFile:setFloat(key .. "#z", st.z)
        xmlFile:setFloat(key .. "#nx", st.nx)
        xmlFile:setFloat(key .. "#ny", st.ny)
        xmlFile:setFloat(key .. "#nz", st.nz)
        if st.path ~= nil and st.path ~= "" then
            xmlFile:setString(key .. "#path", st.path)
        end
    end

    local pinIndex = 0
    for vehicle, pin in pairs(HandToolHammer.pinned) do
        if not vehicle.isDeleted and pin.uniqueId ~= nil then
            xmlFile:setString(string.format("sandboxTools.pinnedVehicle(%d)#uniqueId", pinIndex), pin.uniqueId)
            if pin.sticky then
                xmlFile:setBool(string.format("sandboxTools.pinnedVehicle(%d)#sticky", pinIndex), true)
            end
            pinIndex = pinIndex + 1
        end
    end

    xmlFile:save()
    xmlFile:delete()

    Logging.info("SandboxHammer: saved %d frozen object(s), %d assembly member(s), %d sticker(s) to %s", i, j, #HandToolHammer.stickers, path)
end

-- Fires once per map load (see BaseMission.loadMap override above). Node
-- ids from the previous session are gone, so each saved entry is
-- re-found by an overlapSphere search at its saved world position (see
-- findNearestValidNode) - same "search near this position" idea as
-- FS25_ForestryHelper/scripts/CutPositionIndicator.lua uses to re-locate
-- a cut log, just re-freezing instead of drawing a ring. uniqueId is
-- carried through for logging/debugging - there is no confirmed
-- find-by-uniqueId lookup API, so it is not (yet) used to match.
-- The pinned vehicles of the savegame, before the pre-simulation: the vehicles are loaded, nothing has moved yet.
-- ===== unbury: the ground came up under something =====
-- The player can raise the terrain under a pinned start piece, a pole or a chain: at the next load the piece lies INSIDE the ground, and the physics push it out on the first step (a loose one is thrown at 100 m/s,
-- a pinned one shakes its whole chain). Before anything is pinned, every bridge piece, pole and anchor is checked: five points of its footprint (the corners and the middle, in its own orientation) against the terrain,
-- and a chain (what hangs on one piece) is lifted TOGETHER by its deepest burial plus 3 cm, so nothing is stretched. A pinned piece takes its pin helper along.
HandToolHammer.UNBURY_HALF = { bridgeGrate = { 1.5, 2.0 }, bridgeStart = { 1.5, 0.8 }, bridgeEnd = { 1.5, 0.8 }, winchPole = { 0.55, 0.55 }, winchAnchor = { 0.35, 0.35 } }
HandToolHammer.UNBURY_MIN_M = 0.02      -- a burial of less than this is left alone
HandToolHammer.UNBURY_CLEAR_M = 0.03
HandToolHammer.UNBURY_MAX_M = 3         -- more than this is not a raised bank but something else: the lift is capped

-- Pure: the lift for a list of burials (metres the terrain stands above the footprint's points, negative = air): 0 when the deepest is under UNBURY_MIN_M.
function HandToolHammer.unburyLift(burials)
    local worst = -math.huge
    for _, b in ipairs(burials) do
        worst = math.max(worst, b)
    end
    if worst < HandToolHammer.UNBURY_MIN_M then
        return 0
    end
    return math.min(worst + HandToolHammer.UNBURY_CLEAR_M, HandToolHammer.UNBURY_MAX_M)
end

local function unburyHalfOf(vehicle)
    for name, half in pairs(HandToolHammer.UNBURY_HALF) do
        if vehicle.typeName ~= nil and string.find(vehicle.typeName, name, 1, true) ~= nil then
            return half
        end
    end
    return nil
end

-- How deep the terrain stands over the footprint of one vehicle (its root component: the origin is the bottom).
local function unburyDepth(vehicle, half)
    local node = vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node or nil
    if node == nil or not entityExists(node) or g_terrainNode == nil then
        return -math.huge
    end
    local worst = -math.huge
    for _, p in ipairs({ { 0, 0 }, { half[1], half[2] }, { -half[1], half[2] }, { half[1], -half[2] }, { -half[1], -half[2] } }) do
        local wx, wy, wz = localToWorld(node, p[1], 0, p[2])
        worst = math.max(worst, getTerrainHeightAtWorldPos(g_terrainNode, wx, 0, wz) - wy)
    end
    return worst
end

-- Lifts what is buried. Returns the number of pieces lifted and the biggest lift.
function HandToolHammer.unburyAll()
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    local groups = {}
    for _, v in ipairs(vehicles) do
        local half = not v.isDeleted and unburyHalfOf(v) or nil
        if half ~= nil and v.components ~= nil and v.components[1] ~= nil then
            local root = v.getRootVehicle ~= nil and v:getRootVehicle() or v
            local g = groups[root]
            if g == nil then g = { members = {}, burials = {} }; groups[root] = g end
            g.members[#g.members + 1] = v
            g.burials[#g.burials + 1] = unburyDepth(v, half)
        end
    end
    local lifted, biggest = 0, 0
    for root, g in pairs(groups) do
        local lift = HandToolHammer.unburyLift(g.burials)
        if lift > 0 then
            -- a root that is no bridge piece (a tractor hitched to the chain) is not touched: the chain would be torn from it
            if unburyHalfOf(root) == nil and root.components ~= nil and #g.members < (root.getChildVehicles ~= nil and #root:getChildVehicles() or 0) then
                Logging.info("SandboxHammer: unbury: a group under %s is buried %.2f m but is hitched to something that is no bridge piece: left alone", tostring(root.configFileName or "?"), lift)
            else
                for _, v in ipairs(g.members) do
                    for _, component in ipairs(v.components) do
                        if component.node ~= nil and entityExists(component.node) then
                            local x, y, z = getWorldTranslation(component.node)
                            setWorldTranslation(component.node, x, y + lift, z)
                        end
                    end
                    local pin = HandToolHammer.pinned[v]
                    if pin ~= nil and pin.helper ~= nil and entityExists(pin.helper) then
                        local x, y, z = getWorldTranslation(pin.helper)
                        setWorldTranslation(pin.helper, x, y + lift, z)
                        pin.y = (pin.y or y) + lift
                    end
                    lifted = lifted + 1
                end
                biggest = math.max(biggest, lift)
            end
        end
    end
    if lifted > 0 then
        Logging.info("SandboxHammer: unbury: %d piece(s) lay inside the ground (it was raised under them) and were lifted clear, by up to %.2f m", lifted, biggest)
    end
    return lifted, biggest
end

function HandToolHammer.consoleUnbury()
    local n, m = HandToolHammer.unburyAll()
    return string.format("sbBridgeUnbury: %d piece(s) lifted out of the ground, by up to %.2f m", n, m)
end

function HandToolHammer.restorePinsEarly()
    if g_currentMission == nil or g_currentMission.missionInfo == nil or g_currentMission.missionInfo.savegameDirectory == nil or g_currentMission.vehicleSystem == nil then
        return
    end
    if HandToolHammer.pinsRestoredFor == g_currentMission then
        return                                                           -- (BridgeLink asks for it first at the same message: once per mission)
    end
    HandToolHammer.pinsRestoredFor = g_currentMission
    pcall(HandToolHammer.unburyAll)                                      -- (first: whatever the ground came up over is lifted before anything is pinned and before the physics run)
    local xmlFile = XMLFile.load("sandboxToolsPinsXML", g_currentMission.missionInfo.savegameDirectory .. "/" .. HandToolHammer.SAVEGAME_FILENAME)
    if xmlFile == nil then
        return
    end
    local pinned, total = 0, 0
    while true do
        local key = string.format("sandboxTools.pinnedVehicle(%d)", total)
        if not xmlFile:hasProperty(key) then
            break
        end
        local uniqueId = xmlFile:getString(key .. "#uniqueId")
        local vehicle = uniqueId ~= nil and g_currentMission.vehicleSystem:getVehicleByUniqueId(uniqueId) or nil
        if vehicle ~= nil and HandToolHammer.pinVehicle(vehicle) then
            pinned = pinned + 1
            HandToolHammer.pinned[vehicle].sticky = xmlFile:getBool(key .. "#sticky") or nil
        end
        total = total + 1
    end
    xmlFile:delete()
    if total > 0 then
        Logging.info("SandboxHammer: pinned %d/%d vehicle(s) BEFORE the game's pre-simulation (SAVEGAME_LOADED)", pinned, total)
    end
end

function HandToolHammer.loadState()
    HandToolHammer.frozenObjects = {}
    HandToolHammer.assemblyMembers = {}
    HandToolHammer.stickers = {}
    HandToolHammer.bindTarget1Node = nil

    if g_currentMission == nil or g_currentMission.missionInfo == nil or g_currentMission.missionInfo.savegameDirectory == nil then
        return
    end

    local path = g_currentMission.missionInfo.savegameDirectory .. "/" .. HandToolHammer.SAVEGAME_FILENAME
    local xmlFile = XMLFile.load("sandboxToolsXML", path)
    if xmlFile == nil then
        Logging.info("SandboxHammer: no saved state found (%s)", HandToolHammer.SAVEGAME_FILENAME)
        return
    end

    local restored = 0
    local i = 0
    while true do
        local key = string.format("sandboxTools.frozenObject(%d)", i)
        if not xmlFile:hasProperty(key) then
            break
        end

        local uniqueId = xmlFile:getString(key .. "#uniqueId")
        local x = xmlFile:getFloat(key .. "#x")
        local y = xmlFile:getFloat(key .. "#y")
        local z = xmlFile:getFloat(key .. "#z")
        local rigidBodyType = xmlFile:getInt(key .. "#rigidBodyType")

        if x ~= nil and y ~= nil and z ~= nil and rigidBodyType ~= nil then
            if HandToolHammer.rediscoverAndFreeze(uniqueId, x, y, z, rigidBodyType, xmlFile:getBool(key .. "#sticky"), xmlFile:getString(key .. "#splitId")) then
                restored = restored + 1
            end
        end

        i = i + 1
    end

    -- Assembly members: rediscover BOTH saved positions independently
    -- (same findNearestValidNode search freeze-restore uses) and
    -- re-bind child to parent if both are found - "trust only what you
    -- can still find" applies here too, same as freeze. bindChildToParent
    -- recomputes the local offset fresh from wherever the rediscovered
    -- nodes actually are, it doesn't need the pre-reload offset at all.
    -- Child's search excludes whatever the parent resolved to, since two
    -- bound objects are very likely to sit within each other's search
    -- radius - without the exclusion both searches could independently
    -- converge on the same physical object.
    local assemblyRestored = 0
    local j = 0
    while true do
        local key = string.format("sandboxTools.assemblyMember(%d)", j)
        if not xmlFile:hasProperty(key) then
            break
        end

        local px = xmlFile:getFloat(key .. "#px")
        local py = xmlFile:getFloat(key .. "#py")
        local pz = xmlFile:getFloat(key .. "#pz")
        local cx = xmlFile:getFloat(key .. "#cx")
        local cy = xmlFile:getFloat(key .. "#cy")
        local cz = xmlFile:getFloat(key .. "#cz")

        if px ~= nil and cx ~= nil then
            local parentNode = HandToolHammer.findNearestValidNode(px, py, pz)
            local childNode = parentNode ~= nil and HandToolHammer.findNearestValidNode(cx, cy, cz, parentNode) or nil

            if parentNode ~= nil and childNode ~= nil then
                local member = HandToolHammer.bindChildToParent(parentNode, childNode)
                if member ~= nil then
                    table.insert(HandToolHammer.assemblyMembers, member)
                    assemblyRestored = assemblyRestored + 1
                end
            else
                Logging.info("SandboxHammer: could not restore assembly member %d - not found", j)
            end
        end

        j = j + 1
    end

    -- the mice on the halls
    HandToolHammer.stickers = {}
    local k = 0
    while true do
        local key = string.format("sandboxTools.sticker(%d)", k)
        if not xmlFile:hasProperty(key) then
            break
        end
        local sx, sy, sz = xmlFile:getFloat(key .. "#x"), xmlFile:getFloat(key .. "#y"), xmlFile:getFloat(key .. "#z")
        if sx ~= nil and sy ~= nil and sz ~= nil then
            HandToolHammer.addSticker(sx, sy, sz, xmlFile:getFloat(key .. "#nx"), xmlFile:getFloat(key .. "#ny"), xmlFile:getFloat(key .. "#nz"), false, nil, xmlFile:getString(key .. "#path"))
        end
        k = k + 1
    end

    -- the pinned vehicles: found by their unique id, pinned where they stand now
    local pinsRestored, pk = 0, 0
    while true do
        local key = string.format("sandboxTools.pinnedVehicle(%d)", pk)
        if not xmlFile:hasProperty(key) then
            break
        end
        local uniqueId = xmlFile:getString(key .. "#uniqueId")
        local vehicle = uniqueId ~= nil and g_currentMission.vehicleSystem:getVehicleByUniqueId(uniqueId) or nil
        if vehicle ~= nil and HandToolHammer.pinned[vehicle] ~= nil then
            pinsRestored = pinsRestored + 1                              -- (already pinned before the pre-simulation: restorePinsEarly)
        elseif vehicle ~= nil and HandToolHammer.pinVehicle(vehicle) then
            pinsRestored = pinsRestored + 1
            HandToolHammer.pinned[vehicle].sticky = xmlFile:getBool(key .. "#sticky") or nil
        end
        pk = pk + 1
    end
    if pk > 0 then
        Logging.info("SandboxHammer: pinned %d/%d vehicle(s) from %s", pinsRestored, pk, HandToolHammer.SAVEGAME_FILENAME)
    end

    xmlFile:delete()

    Logging.info("SandboxHammer: restored %d/%d frozen object(s), %d/%d assembly member(s) from %s", restored, i, assemblyRestored, j, HandToolHammer.SAVEGAME_FILENAME)
end

-- Real bug found (user theory, confirmed plausible): a straight-down
-- raycast only searches the single vertical line directly above/below
-- the exact saved x,z - if a log drifted sideways at all before we got
-- to search for it (convex-hull jitter, or physics ticks passing before
-- CURRENT_MISSION_START fires), no amount of widening the vertical band
-- helps, since sideways drift was never searched at all. overlapSphere
-- (confirmed real, used by TreePlantManager/TensionBelts/YarderTower for
-- exactly this "find physics objects near a point" pattern) searches an
-- actual 3D radius instead of one line. Unlike raycastClosest, it calls
-- the callback once per object found in range rather than "closest hit,
-- keep searching if rejected" - so this tracks the closest VALID
-- candidate across however many callbacks fire, then acts on it once
-- the search is done.
HandToolHammer.REDISCOVER_SEARCH_RADIUS = 3.0

-- Shared rediscovery core, extracted so both freeze-restore and
-- bind-restore can reuse the same "find the nearest valid physics
-- object near this saved point" search instead of duplicating it.
-- excludeNode is optional - used when restoring a bound pair, so the
-- second endpoint's search can't re-resolve to whatever the first
-- endpoint already claimed (a real risk once two saved positions are
-- within each other's search radius, which bound objects usually are).
-- Returns the found node, or nil.
function HandToolHammer.findNearestValidNode(x, y, z, excludeNode)
    HandToolHammer.pendingSearchX = x
    HandToolHammer.pendingSearchY = y
    HandToolHammer.pendingSearchZ = z
    HandToolHammer.pendingExcludeNode = excludeNode
    HandToolHammer.pendingBestNode = nil
    HandToolHammer.pendingBestDistance = math.huge

    -- Mask matches TensionBelts.lua's cargo/log-detection usage
    -- (DYNAMIC_OBJECT + TREE) - closer semantic match to "find my
    -- previously-frozen/bound log" than TreePlantManager's
    -- tree-cutting-only mask. overlapSphere is confirmed synchronous
    -- (same "read the result right after the call, same frame" pattern
    -- already proven for raycastClosest elsewhere in this file).
    overlapSphere(x, y, z, HandToolHammer.REDISCOVER_SEARCH_RADIUS, "rediscoverOverlapCallback", HandToolHammer, CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.TREE + CollisionFlag.VEHICLE, true, true, false, true)

    return HandToolHammer.pendingBestNode
end

-- A log or tree is a split shape: the engine gives it an id that survives a save and a load (the game's own forestry missions and tree markers use it), three numbers.
function HandToolHammer.saveableSplitId(node)
    if getSaveableSplitShapeId == nil or node == nil or node == 0 or not entityExists(node) or not getHasClassId(node, ClassIds.MESH_SPLIT_SHAPE) then
        return nil
    end
    local ok, a, b, c = pcall(getSaveableSplitShapeId, node)
    if ok and a ~= nil and b ~= nil and c ~= nil then
        return string.format("%s %s %s", tostring(a), tostring(b), tostring(c))
    end
    return nil
end

function HandToolHammer.shapeFromSplitId(text)
    if text == nil or getShapeFromSaveableSplitShapeId == nil then
        return nil
    end
    local a, b, c = string.match(text, "^(%S+) (%S+) (%S+)$")
    a, b, c = tonumber(a), tonumber(b), tonumber(c)
    if a == nil or b == nil or c == nil then
        return nil
    end
    local ok, node = pcall(getShapeFromSaveableSplitShapeId, a, b, c)
    if ok and node ~= nil and node ~= 0 and entityExists(node) and getRigidBodyType(node) == RigidBodyType.DYNAMIC then
        return node
    end
    return nil
end

function HandToolHammer.rediscoverAndFreeze(uniqueId, x, y, z, rigidBodyType, sticky, splitId)
    -- a vehicle (a pallet, the plate) is found by its id first: the nearest node to the saved spot can be anything lying on a pile there
    local node = nil
    local vehicleSystem = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    local byId = uniqueId ~= nil and vehicleSystem ~= nil and vehicleSystem.getVehicleByUniqueId ~= nil and vehicleSystem:getVehicleByUniqueId(uniqueId) or nil
    if byId ~= nil and not byId.isDeleted and HandToolHammer.needsPin(byId) and HandToolHammer.pinned[byId] == nil then
        -- frozen in an older save, but a vehicle like this is pinned now: a frozen body has no collision. Pinned here instead (and left out of the frozen list: the next save writes it as pinned)
        if HandToolHammer.pinVehicle(byId) then
            Logging.info("SandboxHammer: %s was saved frozen: pinned instead (a frozen body loses its collision)", tostring(byId.getName ~= nil and byId:getName() or "vehicle"))
            return true
        end
    end
    if byId ~= nil and not byId.isDeleted and byId.components ~= nil and #byId.components == 1 and byId.components[1].node ~= nil then
        node = byId.components[1].node
        local nx, ny, nz = getWorldTranslation(node)
        HandToolHammer.pendingBestDistance = (nx - x) ^ 2 + (ny - y) ^ 2 + (nz - z) ^ 2
    end
    if node == nil and splitId ~= nil then                       -- a log: found by its engine id, not by what lies nearest
        node = HandToolHammer.shapeFromSplitId(splitId)
        if node ~= nil then
            local nx, ny, nz = getWorldTranslation(node)
            HandToolHammer.pendingBestDistance = (nx - x) ^ 2 + (ny - y) ^ 2 + (nz - z) ^ 2
        end
    end
    node = node or HandToolHammer.findNearestValidNode(x, y, z)
    if node == nil then
        return false
    end

    setLinearVelocity(node, 0, 0, 0)
    setAngularVelocity(node, 0, 0, 0)
    HandToolHammer.rememberBody(node)
    setRigidBodyType(node, RigidBodyType.STATIC)
    HandToolHammer.setVehicleComponentStatic(node, true)

    local wx, wy, wz = getWorldTranslation(node)
    HandToolHammer.frozenObjects[node] = {
        rigidBodyType = rigidBodyType,
        uniqueId = uniqueId,
        x = wx, y = wy, z = wz,
        sticky = sticky or nil
    }

    Logging.info("SandboxHammer: re-froze node=%s name=%s uniqueId=%s distanceFromSaved=%.2f", tostring(node), tostring(getName(node)), tostring(uniqueId), math.sqrt(HandToolHammer.pendingBestDistance))
    HandToolHammer.setNodeBolts(node, true)

    return true
end

-- Called once per object overlapSphere finds within the search radius -
-- no return-value continuation semantics here (unlike raycastClosest),
-- just record the closest valid candidate; the caller acts on whichever
-- one that ends up being after the search completes.
function HandToolHammer.rediscoverOverlapCallback(_, objectId, ...)
    if objectId == nil or not entityExists(objectId) then
        return
    end

    if HandToolHammer.pendingExcludeNode ~= nil and objectId == HandToolHammer.pendingExcludeNode then
        return
    end

    -- Same exclusions as toggleNode: terrain (old
    -- sandboxtools.xml files can have stale terrain entries from before
    -- that filter existed), vehicles, AI-navigation/animal proxy nodes
    -- (dogProxy and likely siblings) - a wider search radius makes
    -- catching one of these by accident more likely, not less.
    if objectId == g_currentMission.terrainRootNode or objectId == g_terrainNode or getName(objectId) == "terrain" then
        return
    end

    local object = g_currentMission:getNodeObject(objectId)
    if object ~= nil and object.isa ~= nil and object:isa(Vehicle) and not HandToolHammer.isFreezable(object, objectId) then
        return
    end
    if object == nil and HandToolHammer.vehicleOfNode(objectId) ~= nil then
        return
    end
    if string.find(getName(objectId) or "", "Proxy") ~= nil then
        return
    end

    if getRigidBodyType(objectId) == RigidBodyType.NONE then
        return
    end

    local ox, oy, oz = getWorldTranslation(objectId)
    local dx = ox - HandToolHammer.pendingSearchX
    local dy = oy - HandToolHammer.pendingSearchY
    local dz = oz - HandToolHammer.pendingSearchZ
    local distanceSq = dx * dx + dy * dy + dz * dz

    if distanceSq < HandToolHammer.pendingBestDistance then
        HandToolHammer.pendingBestNode = objectId
        HandToolHammer.pendingBestDistance = distanceSq
    end
end


-- ===== sbFreezeAll [radius] [thaw]: freeze everything loose around you (a hall you build in) =====
-- Every dynamic object within the radius (planks and logs, pallets, bales, balls, ...: a vehicle only when it has ONE body) is switched to STATIC and remembered like a single swing of the hammer (saved with the savegame, found again by position after a
-- reload). "thaw" lets the ones within the radius go again. Machines with several parts are left alone.
HandToolHammer.FREEZE_ALL_RADIUS = 12

function HandToolHammer.freezeAllCallback(_, objectId, ...)
    if objectId == nil or not entityExists(objectId) then
        return
    end
    if objectId == g_currentMission.terrainRootNode or objectId == g_terrainNode or getName(objectId) == "terrain" then
        return
    end
    local object = g_currentMission:getNodeObject(objectId)
    if object ~= nil and object.isa ~= nil and object:isa(Vehicle) and not HandToolHammer.isFreezable(object, objectId) then
        HandToolHammer.pendingPins = HandToolHammer.pendingPins or {}
        HandToolHammer.pendingPins[object] = true                 -- (a wagon is pinned, not frozen)
        return
    end
    if object == nil and HandToolHammer.vehicleOfNode(objectId) ~= nil then
        return
    end
    if string.find(getName(objectId) or "", "Proxy") ~= nil then
        return
    end
    HandToolHammer.pendingAll[objectId] = true
    -- a wagon is frozen as a whole: any force on a loose part tears it off the frozen rest
    if HandToolHammer.freezeAllParts and object ~= nil and object.components ~= nil and #object.components > 1 then
        for _, component in ipairs(object.components) do
            if component.node ~= nil and entityExists(component.node) then
                HandToolHammer.pendingAll[component.node] = true
            end
        end
    end
end

-- A frozen vehicle's component gets the flag the map's decorative static vehicles have from the start (Vehicle.lua: `component.isStatic`): the vehicle code then skips its position sync and speed update. Undone on thaw.
-- A body that goes static and dynamic again is a new physics body: the engine gives it the mass its shapes add up to (a 3 kg ball turned 372 kg and could not be pushed) and forgets the centre of mass. Both are noted at the freeze and put back at the thaw.
HandToolHammer.savedBodies = {}
function HandToolHammer.rememberBody(node)
    if getRigidBodyType(node) ~= RigidBodyType.DYNAMIC or getMass == nil then
        return
    end
    -- a log or tree (split shape) gets its mass and centre of mass from its wood: an explicit centre of mass is passed on to the pieces of the next cut (they stood on end)
    if getHasClassId ~= nil and ClassIds ~= nil and ClassIds.MESH_SPLIT_SHAPE ~= nil and getHasClassId(node, ClassIds.MESH_SPLIT_SHAPE) then
        return
    end
    local cx, cy, cz
    if getCenterOfMass ~= nil then
        cx, cy, cz = getCenterOfMass(node)
    end
    HandToolHammer.savedBodies[node] = { mass = getMass(node), cx = cx, cy = cy, cz = cz }
end

function HandToolHammer.restoreBody(node)
    local saved = HandToolHammer.savedBodies[node]
    HandToolHammer.savedBodies[node] = nil
    if saved == nil or getRigidBodyType(node) ~= RigidBodyType.DYNAMIC then
        return
    end
    if saved.mass ~= nil and saved.mass > 0 then
        setMass(node, saved.mass)
    end
    if saved.cx ~= nil and setCenterOfMass ~= nil then
        setCenterOfMass(node, saved.cx, saved.cy, saved.cz)
    end
end

function HandToolHammer.setVehicleComponentStatic(node, static)
    if not static then
        HandToolHammer.restoreBody(node)
    end
    local object = g_currentMission:getNodeObject(node)
    if object ~= nil and object.isa ~= nil and object:isa(Vehicle) and object.components ~= nil then
        for _, component in ipairs(object.components) do
            if component.node == node then
                if static then
                    component.hdWasStatic = component.isStatic or false
                    component.isStatic = true
                else
                    component.isStatic = component.hdWasStatic or nil
                    component.hdWasStatic = nil
                    -- the body is a new actor after the type change: the wake-up report (what makes the vehicle's scripts run again) is registered anew, the vehicle is made active and the body woken
                    if object.isServer and component == object.components[1] and object.rootNode == node then
                        if removeWakeUpReport ~= nil and addWakeUpReport ~= nil and object.onVehicleWakeUpCallback ~= nil then
                            removeWakeUpReport(node)
                            addWakeUpReport(node, "onVehicleWakeUpCallback", object)
                        end
                        object:raiseActive()
                        setLinearVelocity(node, 0, -0.001, 0)
                    end
                end
            end
        end
    end
end

-- Freezes (or thaws) every node collected in HandToolHammer.pendingAll; returns how many changed.
-- Is this object held by a vehicle's tension belts (a ball strapped on a wagon)? Frozen in place it would stay behind in the air when the wagon is driven away.
function HandToolHammer.isBelted(object)
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    for _, vehicle in ipairs(vehicles) do
        if vehicle ~= object and vehicle.spec_tensionBelts ~= nil and vehicle.spec_tensionBelts.hasTensionBelts and vehicle.getHasObjectMounted ~= nil and vehicle:getHasObjectMounted(object) then
            return true
        end
    end
    return false
end

function HandToolHammer.freezeSet(thaw)
    local count = 0
    HandToolHammer.beltedSkipped = 0
    for objectId in pairs(HandToolHammer.pendingAll) do
        if entityExists(objectId) then
            local frozen = HandToolHammer.frozenObjects[objectId]
            local object = g_currentMission:getNodeObject(objectId)
            if thaw then
                if frozen ~= nil then
                    setRigidBodyType(objectId, frozen.rigidBodyType)
                    HandToolHammer.setVehicleComponentStatic(objectId, false)
                    HandToolHammer.frozenObjects[objectId] = nil
                    count = count + 1
                end
            elseif frozen == nil and getRigidBodyType(objectId) == RigidBodyType.DYNAMIC and object ~= nil and HandToolHammer.isBelted(object) then
                HandToolHammer.beltedSkipped = HandToolHammer.beltedSkipped + 1              -- (strapped to a wagon: left alone)
            elseif frozen == nil and getRigidBodyType(objectId) == RigidBodyType.DYNAMIC then
                local x, y, z = getWorldTranslation(objectId)
                HandToolHammer.frozenObjects[objectId] = {
                    rigidBodyType = RigidBodyType.DYNAMIC,
                    uniqueId = object ~= nil and object.getUniqueId ~= nil and object:getUniqueId() or nil,
                    x = x, y = y, z = z
                }
                setLinearVelocity(objectId, 0, 0, 0)
                setAngularVelocity(objectId, 0, 0, 0)
                HandToolHammer.rememberBody(objectId)
                setRigidBodyType(objectId, RigidBodyType.STATIC)
                HandToolHammer.setVehicleComponentStatic(objectId, true)
                count = count + 1
            end
        end
    end
    return count
end

-- ===== the mouse on a frozen hall: a flat sticker (stickers/hallSticker.i3d) where the hammer hit, lying on the surface (its normal), saved with the savegame =====
HandToolHammer.stickers = {}
HandToolHammer.STICKER_LIFT_M = 0.012

function HandToolHammer.loadStickerTemplate()
    if HandToolHammer.stickerTemplate ~= nil then
        return HandToolHammer.stickerTemplate or nil
    end
    HandToolHammer.stickerTemplate = false
    local path = (HandToolHammer.MOD_DIRECTORY or "") .. "stickers/hallSticker.i3d"
    local root = g_i3DManager:loadSharedI3DFile(path, false, false)
    if root ~= nil and root ~= 0 then
        local shape = getChildAt(root, 0)
        unlink(shape)
        delete(root)
        HandToolHammer.stickerTemplate = shape
    else
        Logging.warning("SandboxHammer: could not load %s", path)
    end
    return HandToolHammer.stickerTemplate or nil
end

-- The child indices from a root down to a node ("3,0,2"), and back: how a plaque finds the part of the building it sits on (a door that slides open takes it along) after a load.
function HandToolHammer.pathOf(root, node)
    local list, n, depth = {}, node, 0
    while n ~= nil and n ~= 0 and n ~= root and depth < 40 do
        local parent = getParent(n)
        if parent == nil or parent == 0 then
            return nil
        end
        for i = 0, getNumOfChildren(parent) - 1 do
            if getChildAt(parent, i) == n then
                table.insert(list, 1, i)
                break
            end
        end
        n = parent
        depth = depth + 1
    end
    if n ~= root then
        return nil
    end
    return table.concat(list, ",")
end

function HandToolHammer.nodeAt(root, path)
    local n = root
    for index in string.gmatch(path or "", "%d+") do
        if n == nil or n == 0 or tonumber(index) >= getNumOfChildren(n) then
            return nil
        end
        n = getChildAt(n, tonumber(index))
    end
    return n
end

-- The building a world point belongs to (the footprint rule, with the wall margin), or nil.
function HandToolHammer.placeableAt(x, y, z)
    local system = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    for _, placeable in ipairs(system ~= nil and system.placeables or {}) do
        if HandToolHammer.insideHall(placeable, x, y, z, HandToolHammer.STICKER_MARGIN_M) then
            return placeable
        end
    end
    return nil
end

function HandToolHammer.addSticker(x, y, z, nx, ny, nz, save, parent, path)
    local template = HandToolHammer.loadStickerTemplate()
    if template == nil then
        return
    end
    for _, st in ipairs(HandToolHammer.stickers) do
        if (st.x - x) ^ 2 + (st.y - y) ^ 2 + (st.z - z) ^ 2 < 1.0 then
            return                                              -- (a plaque is already there: no second one on top of it)
        end
    end
    nx, ny, nz = nx or 0, ny or 0, nz or 0
    local len = math.sqrt(nx * nx + ny * ny + nz * nz)
    if len < 1e-4 then
        nx, ny, nz, len = 0, 0, 1, 1                                  -- (no normal known: facing +z)
    end
    nx, ny, nz = nx / len, ny / len, nz / len
    local node = clone(template, false, false, false)
    if parent == nil and path ~= nil and path ~= "" then
        local placeable = HandToolHammer.placeableAt(x, y, z)
        parent = placeable ~= nil and HandToolHammer.nodeAt(placeable.rootNode, path) or nil
    end
    if parent ~= nil and entityExists(parent) then
        link(parent, node)                                            -- (on the part it was hit on: a door that opens takes the plaque with it)
    else
        parent, path = nil, nil
        link(getRootNode(), node)
    end
    setWorldTranslation(node, x + nx * HandToolHammer.STICKER_LIFT_M, y + ny * HandToolHammer.STICKER_LIFT_M, z + nz * HandToolHammer.STICKER_LIFT_M)
    if math.abs(ny) > 0.95 then
        setWorldDirection(node, nx, ny, nz, 0, 0, 1)                  -- (on a floor or a roof: "up" is the way the player looks)
    else
        setWorldDirection(node, nx, ny, nz, 0, 1, 0)                  -- (on a wall: the mouse stands upright)
    end
    HandToolHammer.stickers[#HandToolHammer.stickers + 1] = { node = node, x = x, y = y, z = z, nx = nx, ny = ny, nz = nz, path = path }
    Logging.info("SandboxHammer: a mouse sticker at %.1f %.1f %.1f", x, y, z)
end

-- A plaque belongs to a hall by the same rule as everything else in it: inside the hall's footprint boxes (plus a margin for the wall's surface: the hit point is on the wall, the footprint is the foundation).
HandToolHammer.STICKER_MARGIN_M = 2.0

function HandToolHammer.stickersOf(placeable)
    local list = {}
    for i, st in ipairs(HandToolHammer.stickers) do
        if HandToolHammer.insideHall(placeable, st.x, st.y, st.z, HandToolHammer.STICKER_MARGIN_M) then
            list[#list + 1] = i
        end
    end
    return list
end

function HandToolHammer.hasStickerOf(placeable)
    return #HandToolHammer.stickersOf(placeable) > 0
end

function HandToolHammer.removeStickersOf(placeable)
    local list = HandToolHammer.stickersOf(placeable)
    for k = #list, 1, -1 do
        local st = table.remove(HandToolHammer.stickers, list[k])
        if st.node ~= nil and entityExists(st.node) then
            delete(st.node)
        end
    end
end

-- The placeable (a hall, a shed) a node belongs to: the node's own object or one of its parents' (nil when there is none).
function HandToolHammer.placeableOfNode(node)
    local n, depth = node, 0
    while n ~= nil and n ~= 0 and depth < 14 do
        local object = g_currentMission:getNodeObject(n)
        if object ~= nil and object.isa ~= nil and Placeable ~= nil and object:isa(Placeable) then
            return object
        end
        n = getParent(n)
        depth = depth + 1
    end
    return nil
end

-- Collects every loose object inside a placeable's footprint (the game's own placement test areas: boxes in the placeable's space) into HandToolHammer.pendingAll. Returns the number of boxes used.
function HandToolHammer.collectInPlaceable(placeable)
    HandToolHammer.pendingAll = {}
    HandToolHammer.pendingPins = {}
    local spec = placeable.spec_placement
    local boxes = 0
    if spec ~= nil and spec.testAreas ~= nil then
        for _, area in ipairs(spec.testAreas) do
            if area.startNode ~= nil and entityExists(area.startNode) then
                local cx, cy, cz = localToWorld(placeable.rootNode, area.center.x, area.center.y, area.center.z)
                local rx, ry, rz = getWorldRotation(area.startNode)
                local height = math.max(area.size.y, 6)                                        -- (a hall is taller than the box the placement test uses)
                overlapBox(cx, cy + height * 0.5 - area.size.y * 0.5, cz, rx, ry, rz, area.size.x * 0.5, height * 0.5, area.size.z * 0.5, "freezeAllCallback", HandToolHammer, CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.TREE + CollisionFlag.VEHICLE, true, true, true, true)
                boxes = boxes + 1
            end
        end
    end
    return boxes
end

-- A swing at a placeable: everything loose inside it is frozen; when something inside is already frozen it is thawed instead.
-- The hammer on a door (an animated part of the building: its node is under one of the animated objects' parts) opens or closes it, the way the door's own key does.
function HandToolHammer.knockOnDoor(placeable, node)
    local spec = placeable.spec_animatedObjects
    for _, animated in ipairs(spec ~= nil and spec.animatedObjects or {}) do
        for _, part in ipairs(animated.animation ~= nil and animated.animation.parts or {}) do
            local n, depth = node, 0
            while n ~= nil and n ~= 0 and depth < 40 do
                if n == part.node then
                    local ok = animated.getCanBeTriggered == nil or animated:getCanBeTriggered()
                    if ok and animated.setDirection ~= nil then
                        animated:setDirection(animated.animation.direction * -1)
                        Logging.info("SandboxHammer: a knock on the door %s: it is moving (direction %s)", tostring(getName(part.node)), tostring(animated.animation.direction))
                    else
                        Logging.info("SandboxHammer: a knock on the door %s: it cannot be triggered now", tostring(getName(part.node)))
                    end
                    return true
                end
                n = getParent(n)
                depth = depth + 1
            end
        end
    end
    return false
end

-- A door is no place for a plaque: it slides away. Its name (or a parent's, up to the building) says door / gate, or its body is not a static one (animated parts are kinematic).
HandToolHammer.PLAQUE_BLACKLIST = { "door", "gate", "tuer", "tür", "rolltor", "shutter" }
function HandToolHammer.isPlaqueBlacklisted(placeable, node)
    local n, depth = node, 0
    while n ~= nil and n ~= 0 and n ~= placeable.rootNode and depth < 40 do
        local name = string.lower(getName(n) or "")
        for _, word in ipairs(HandToolHammer.PLAQUE_BLACKLIST) do
            if string.find(name, word, 1, true) ~= nil then
                return true, name
            end
        end
        n = getParent(n)
        depth = depth + 1
    end
    if node ~= nil and entityExists(node) and getRigidBodyType(node) == RigidBodyType.KINEMATIC then
        return true, string.lower(getName(node) or "")
    end
    return false
end

function HandToolHammer.toggleHall(placeable, hit)
    local boxes = HandToolHammer.collectInPlaceable(placeable)
    if boxes == 0 then
        HandToolHammer.pendingAll = nil
        Logging.info("SandboxHammer: this placeable has no placement area to take the footprint from")
        return
    end
    -- what the hammer froze in this hall earlier: a frozen body is static and the search for loose objects does not find it again, so the list of frozen objects is asked (their positions against the footprint)
    local frozenInside = {}
    for objectId in pairs(HandToolHammer.frozenObjects) do
        if entityExists(objectId) then
            local x, y, z = getWorldTranslation(objectId)
            if HandToolHammer.insideHall(placeable, x, y, z) and not HandToolHammer.frozenObjects[objectId].sticky then
                frozenInside[#frozenInside + 1] = objectId
            end
        end
    end
    local plaque = HandToolHammer.hasStickerOf(placeable)
    HandToolHammer.cleanPins()
    local pins, anyPinned = HandToolHammer.pendingPins or {}, false
    for vehicle in pairs(HandToolHammer.pinned) do
        if vehicle.rootNode ~= nil and entityExists(vehicle.rootNode) then
            local x, y, z = getWorldTranslation(vehicle.rootNode)
            if HandToolHammer.insideHall(placeable, x, y, z) then
                pins[vehicle] = true
                anyPinned = anyPinned or not HandToolHammer.pinned[vehicle].sticky        -- (a pinned vehicle is still found by the search, this also covers one outside its boxes' height; a shift-pinned one does not count)
            end
        end
    end
    local thaw = #frozenInside > 0 or plaque or anyPinned
    local count = 0
    if thaw then
        for _, objectId in ipairs(frozenInside) do
            HandToolHammer.thawNode(objectId)
            count = count + 1
        end
        for vehicle in pairs(pins) do
            local pin = HandToolHammer.pinned[vehicle]
            if pin ~= nil and not pin.sticky and HandToolHammer.unpinVehicle(vehicle) then
                count = count + 1
            end
        end
        HandToolHammer.removeStickersOf(placeable)
    else
        count = HandToolHammer.freezeSet(false)
        for vehicle in pairs(pins) do
            if HandToolHammer.pinVehicle(vehicle) then
                count = count + 1
            end
        end
        local blocked, why = false, nil
        HandToolHammer.plaqueRefused = false
        if hit ~= nil and hit.node ~= nil then
            blocked, why = HandToolHammer.isPlaqueBlacklisted(placeable, hit.node)
            Logging.info("SandboxHammer: plaque on node=%s name=%s path=%s%s", tostring(hit.node), tostring(getName(hit.node)), tostring(HandToolHammer.pathOf(placeable.rootNode, hit.node)), blocked and (" REFUSED (" .. tostring(why) .. ")") or "")
        end
        HandToolHammer.plaqueRefused = blocked
        if hit ~= nil and hit.x ~= nil and not blocked then
            HandToolHammer.addSticker(hit.x, hit.y, hit.z, hit.nx, hit.ny, hit.nz, true, hit.node, HandToolHammer.pathOf(placeable.rootNode, hit.node))
        end
    end
    HandToolHammer.pendingAll, HandToolHammer.pendingPins = nil, nil
    HandToolHammer.saveState()
    local name = placeable.getName ~= nil and placeable:getName() or "the building"
    local text = thaw and string.format("thawed %d object(s) inside %s", count, name) or string.format("froze %d object(s) inside %s%s", count, name, (count == 0 and " (nothing loose in there)" or "") .. (HandToolHammer.plaqueRefused and " (a door is no place for the mouse: swing at a wall for one)" or "") .. ((not thaw and (HandToolHammer.beltedSkipped or 0) > 0) and string.format(" (%d strapped to a wagon: left alone)", HandToolHammer.beltedSkipped) or ""))
    Logging.info("SandboxHammer: " .. text)
    if g_currentMission.addIngameNotification ~= nil and FSBaseMission ~= nil then
        pcall(g_currentMission.addIngameNotification, g_currentMission, FSBaseMission.INGAME_NOTIFICATION_INFO, text)
    end
end

-- Is a world point inside one of the placeable's footprint boxes (stretched upwards like the search is)?
function HandToolHammer.insideHall(placeable, x, y, z, margin)
    local spec = placeable.spec_placement
    if spec == nil or spec.testAreas == nil then
        return false
    end
    for _, area in ipairs(spec.testAreas) do
        if area.startNode ~= nil and area.endNode ~= nil and entityExists(area.startNode) and entityExists(area.endNode) then
            local ex, ey, ez = localToLocal(area.endNode, area.startNode, 0, 0, 0)
            local lx, ly, lz = worldToLocal(area.startNode, x, y, z)
            local m = margin or 0
            local x0, x1 = math.min(0, ex) - m, math.max(0, ex) + m
            local z0, z1 = math.min(0, ez) - m, math.max(0, ez) + m
            local y0, y1 = math.min(0, ey) - 1.0, math.max(ey, 6) + 12.0
            if lx >= x0 and lx <= x1 and lz >= z0 and lz <= z1 and ly >= y0 and ly <= y1 then
                return true
            end
        end
    end
    return false
end

-- Lets one frozen object go (the thaw half of freezeSet).
function HandToolHammer.thawNode(objectId)
    local frozen = HandToolHammer.frozenObjects[objectId]
    if frozen == nil then
        return
    end
    setRigidBodyType(objectId, frozen.rigidBodyType)
    HandToolHammer.setVehicleComponentStatic(objectId, false)
    HandToolHammer.frozenObjects[objectId] = nil
end

function HandToolHammer.freezeAllAround(radius, thaw)
    local player = g_localPlayer
    local node = player ~= nil and player.rootNode or nil
    if node == nil then
        return "no player to stand next to"
    end
    local px, py, pz = getWorldTranslation(node)
    HandToolHammer.pendingAll = {}
    HandToolHammer.pendingPins = {}
    overlapSphere(px, py, pz, radius, "freezeAllCallback", HandToolHammer, CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.TREE + CollisionFlag.VEHICLE, true, true, false, true)
    local count = 0
    if thaw then
        -- (frozen bodies are static: the search above does not find them, so the list of what was frozen is asked)
        local near = {}
        for objectId in pairs(HandToolHammer.frozenObjects) do
            if entityExists(objectId) and not HandToolHammer.frozenObjects[objectId].sticky then
                local x, y, z = getWorldTranslation(objectId)
                if (x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2 <= radius * radius then
                    near[#near + 1] = objectId
                end
            end
        end
        for _, objectId in ipairs(near) do
            HandToolHammer.thawNode(objectId)
            count = count + 1
        end
    else
        count = HandToolHammer.freezeSet(false)
    end
    HandToolHammer.cleanPins()
    for vehicle in pairs(HandToolHammer.pendingPins or {}) do
        if thaw then
            local pin = HandToolHammer.pinned[vehicle]
            if pin ~= nil and not pin.sticky and HandToolHammer.unpinVehicle(vehicle) then count = count + 1 end
        elseif HandToolHammer.pinVehicle(vehicle) then
            count = count + 1
        end
    end
    HandToolHammer.pendingAll, HandToolHammer.pendingPins = nil, nil
    if count > 0 then
        HandToolHammer.saveState()
    end
    Logging.info("SandboxHammer: %s %d object(s) within %.1f m", thaw and "thawed" or "froze", count, radius)
    return string.format("%s %d object(s) within %.0f m of you%s", thaw and "thawed" or "froze", count, radius, thaw and "" or " (sbFreezeAll <radius> thaw lets them go again)")
end

function HandToolHammer.consoleFreezeAll(_, radius, mode)
    local r = tonumber(radius) or HandToolHammer.FREEZE_ALL_RADIUS
    return HandToolHammer.freezeAllAround(r, mode == "thaw" or radius == "thaw")
end

-- ===== sbMend [radius]: put a wagon that came apart (its parts drifted, its wheels sank, joints lost after a body-type change) back together =====
-- The game's own teleport (FSBaseMission teleport): the vehicle leaves the physics world, every component is set back to its original place relative to the root body (setAbsolutePosition), and it enters again: the joints and the wheel shapes
-- are made anew. The root body stays where it is (0.3 m higher, it falls to the ground).
HandToolHammer.MEND_RADIUS_M = 12
function HandToolHammer.mendVehicle(vehicle)
    local root = vehicle.components[1]
    if root == nil or not entityExists(root.node) then
        return false
    end
    local x, y, z = getWorldTranslation(root.node)
    local rx, ry, rz = getWorldRotation(root.node)
    vehicle:removeFromPhysics()
    vehicle:setAbsolutePosition(x, y + 0.3, z, rx, ry, rz)
    vehicle:addToPhysics()
    for _, component in ipairs(vehicle.components) do
        if component.node ~= nil and entityExists(component.node) and getRigidBodyType(component.node) == RigidBodyType.DYNAMIC then
            setLinearVelocity(component.node, 0, 0, 0)
            setAngularVelocity(component.node, 0, 0, 0)
        end
    end
    vehicle:raiseActive()
    return true
end

function HandToolHammer.consoleMend(_, radius)
    local player = g_localPlayer
    local node = player ~= nil and player.rootNode or nil
    if node == nil then
        return "no player to stand next to"
    end
    local px, _, pz = getWorldTranslation(node)
    local r = tonumber(radius) or HandToolHammer.MEND_RADIUS_M
    local mended, names = 0, {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.components ~= nil and #vehicle.components > 1 and vehicle.rootNode ~= nil and entityExists(vehicle.rootNode) and not vehicle.isDeleted then
            local x, _, z = getWorldTranslation(vehicle.rootNode)
            if (x - px) ^ 2 + (z - pz) ^ 2 <= r * r and vehicle:getAttacherVehicle() == nil and HandToolHammer.mendVehicle(vehicle) then
                mended = mended + 1
                names[#names + 1] = vehicle.getName ~= nil and vehicle:getName() or "vehicle"
            end
        end
    end
    return string.format("%d vehicle(s) put back together within %.0f m%s", mended, r, mended > 0 and (": " .. table.concat(names, ", ")) or " (none with several bodies, not hitched)")
end

-- unpinned and unhitched from everything (the second joints go with the unhitching)
function HandToolHammer.releaseBridgePiece(v)
    HandToolHammer.unpinVehicle(v)
    local parent = v.getAttacherVehicle ~= nil and v:getAttacherVehicle() or nil
    if parent ~= nil then
        pcall(parent.detachImplementByObject, parent, v)
    end
    local implements = v.getAttachedImplements ~= nil and v:getAttachedImplements() or {}
    for i = #implements, 1, -1 do
        if implements[i].object ~= nil then
            pcall(v.detachImplementByObject, v, implements[i].object)
        end
    end
end

-- sbBridgeReset [radius] [delete]: the bridge pieces around you (default 60 m) are unpinned and unhitched from everything (the second joints go with the unhitching), left where they lie; "delete" removes them (sell them back, the money is not refunded)
function HandToolHammer.consoleBridgeReset(_, radius, mode)
    local player = g_localPlayer
    if player == nil then
        return "no player"
    end
    local px, _, pz = getWorldTranslation(player.rootNode)
    local r = tonumber(radius) or 60
    local deleteThem = radius == "delete" or mode == "delete"
    if radius == "delete" then
        r = 60
    end
    local pieces, n = {}, 0
    for _, v in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if not v.isDeleted and v.typeName ~= nil and string.find(v.typeName, "bridge", 1, true) ~= nil and v.components ~= nil and v.components[1] ~= nil then
            local x, _, z = getWorldTranslation(v.components[1].node)
            if math.sqrt((x - px) ^ 2 + (z - pz) ^ 2) <= r then
                pieces[#pieces + 1] = v
            end
        end
    end
    for _, v in ipairs(pieces) do
        HandToolHammer.releaseBridgePiece(v)
        n = n + 1
    end
    if deleteThem then
        for _, v in ipairs(pieces) do
            pcall(v.delete, v)
        end
    end
    HandToolHammer.saveState()
    return string.format("sbBridgeReset: %d bridge piece(s) within %.0f m %s (sbBridgeReset [radius] [delete])", n, r, deleteThem and "unhitched and removed" or "unpinned and unhitched")
end

-- sbBridgeGather: EVERY bridge piece of the map (flung ones too) is released and put down in a neat grid in front of you, 3 m apart, 3 per row, all facing the same way
function HandToolHammer.consoleBridgeGather(_)
    local player = g_localPlayer
    if player == nil then
        return "no player"
    end
    local px, _, pz = getWorldTranslation(player.rootNode)
    local _, ry0 = getWorldRotation(player.rootNode)
    local fx, fz = math.sin(ry0), math.cos(ry0)
    local sx, sz = fz, -fx
    local pieces, kept = {}, 0
    for _, v in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if not v.isDeleted and v.typeName ~= nil and string.find(v.typeName, "bridge", 1, true) ~= nil and v.components ~= nil and v.components[1] ~= nil and entityExists(v.components[1].node) then
            -- a start or end piece that is pinned is fixed in its place on a bank: it stays (the poles are no bridge pieces and are never touched)
            local fixedEnd = v.hdPinned == true and (string.find(v.typeName, "bridgeStart", 1, true) ~= nil or string.find(v.typeName, "bridgeEnd", 1, true) ~= nil)
            if fixedEnd then
                kept = kept + 1
            else
                pieces[#pieces + 1] = v
            end
        end
    end
    for _, v in ipairs(pieces) do
        HandToolHammer.releaseBridgePiece(v)
    end
    for i, v in ipairs(pieces) do
        local row, col = math.floor((i - 1) / 3), (i - 1) % 3
        local x = px + fx * (4 + row * 3) + sx * (col - 1) * 3
        local z = pz + fz * (4 + row * 3) + sz * (col - 1) * 3
        local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.4
        v:removeFromPhysics()
        v:setAbsolutePosition(x, y, z, 0, ry0, 0)
        v:addToPhysics()
        for _, component in ipairs(v.components) do
            if component.node ~= nil and entityExists(component.node) and getRigidBodyType(component.node) == RigidBodyType.DYNAMIC then
                setLinearVelocity(component.node, 0, 0, 0)
                setAngularVelocity(component.node, 0, 0, 0)
            end
        end
        v:raiseActive()
    end
    HandToolHammer.saveState()
    return string.format("sbBridgeGather: %d bridge piece(s) from the whole map put down in front of you (%d pinned start/end piece(s) left where they are; poles and anchors are never touched)", #pieces, kept)
end

if addConsoleCommand ~= nil and not HandToolHammer.freezeAllRegistered then
    addConsoleCommand("sbBridgeReset", "SandboxHammer: unpin and unhitch the bridge pieces around you [radius, default 60 m] [delete]", "consoleBridgeReset", HandToolHammer)
    HandToolHammer.freezeAllRegistered = true
    addConsoleCommand("sbBridgeUnbury", "SandboxHammer: lift every bridge piece, pole and anchor that lies inside the ground (the terrain was raised under it) clear of it, a chain together", "consoleUnbury", HandToolHammer)
    addConsoleCommand("sbBridgeGather", "SandboxHammer: release every bridge piece of the map and put them in a grid in front of you (pinned start and end pieces stay, poles and anchors are not touched)", "consoleBridgeGather", HandToolHammer)
    addConsoleCommand("sbMend", "SandboxHammer: put a vehicle with several bodies that came apart back together [radius, default 12 m]", "consoleMend", HandToolHammer)
    addConsoleCommand("sbFreezeParts", "SandboxHammer: freeze every body of a multi-body vehicle, not only its root [on|off]", "consoleFreezeParts", HandToolHammer)
    addConsoleCommand("sbFreezeAll", "SandboxHammer: freeze everything loose around you [radius, default 12 m] [thaw]", "consoleFreezeAll", HandToolHammer)
end

-- Vehicles the Hammer holds (pinned or frozen) are blue on the map and the minimap: the hotspot is drawn with its colour swapped for the frame, nothing to keep in sync.
HandToolHammer.MAP_COLOR = { 0.25, 0.55, 1.0 }
if VehicleHotspot ~= nil and VehicleHotspot.render ~= nil and not VehicleHotspot.hdHammerBlue then
    VehicleHotspot.hdHammerBlue = true
    VehicleHotspot.render = Utils.overwrittenFunction(VehicleHotspot.render, function(self, superFunc, ...)
        local vehicle = self.vehicle
        local held = vehicle ~= nil and (vehicle.hdPinned == true or (vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].isStatic == true))
        if not held or self.color == nil then
            return superFunc(self, ...)
        end
        local c, blue = self.color, HandToolHammer.MAP_COLOR
        local r, g, b = c[1], c[2], c[3]
        c[1], c[2], c[3] = blue[1], blue[2], blue[3]
        superFunc(self, ...)
        c[1], c[2], c[3] = r, g, b
    end)
end
