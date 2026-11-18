HandToolBinoculars = {}
HandToolBinoculars.SPEC_TABLE_NAME = "spec_" .. g_currentModName .. ".binoculars"
HandToolBinoculars.activeOverlayTool = nil

addModEventListener(HandToolBinoculars)

function HandToolBinoculars.registerXMLPaths(xmlSchema)
    xmlSchema:setXMLSpecializationType("HandToolBinoculars")
    xmlSchema:register(XMLValueType.ANGLE, "handTool.binoculars#zoomFov", "Camera field of view while looking through binoculars", math.rad(12), false)
    xmlSchema:register(XMLValueType.FLOAT, "handTool.binoculars#transitionSpeed", "Zoom transition speed", 10, false)
    xmlSchema:register(XMLValueType.FILENAME, "handTool.binoculars.overlay#filename", "Full screen binoculars HUD overlay", nil, false)
    xmlSchema:register(XMLValueType.ANGLE, "handTool.binoculars.variableZoom#minFov", "Strongest wheel zoom field of view", nil, false)
    xmlSchema:register(XMLValueType.ANGLE, "handTool.binoculars.variableZoom#maxFov", "Weakest wheel zoom field of view", nil, false)
    xmlSchema:register(XMLValueType.ANGLE, "handTool.binoculars.variableZoom#step", "Field of view change per wheel input", math.rad(1), false)
    xmlSchema:register(XMLValueType.STRING, "handTool.binoculars.variableZoom#direction", "Allowed wheel zoom direction: in, out or both", "both", false)
    xmlSchema:setXMLSpecializationType()
end

function HandToolBinoculars.registerFunctions(handToolType)
    SpecializationUtil.registerFunction(handToolType, "getBinocularsCameraNode", HandToolBinoculars.getBinocularsCameraNode)
    SpecializationUtil.registerFunction(handToolType, "restoreBinocularsZoom", HandToolBinoculars.restoreBinocularsZoom)
    SpecializationUtil.registerFunction(handToolType, "setBinocularsZoomActive", HandToolBinoculars.setBinocularsZoomActive)
    SpecializationUtil.registerFunction(handToolType, "setBinocularsHudHidden", HandToolBinoculars.setBinocularsHudHidden)
    SpecializationUtil.registerFunction(handToolType, "updateBinocularsZoom", HandToolBinoculars.updateBinocularsZoom)
    SpecializationUtil.registerFunction(handToolType, "updateBinocularsActionEvent", HandToolBinoculars.updateBinocularsActionEvent)
    SpecializationUtil.registerFunction(handToolType, "adjustBinocularsZoom", HandToolBinoculars.adjustBinocularsZoom)
end

function HandToolBinoculars.registerEventListeners(handToolType)
    SpecializationUtil.registerEventListener(handToolType, "onLoad", HandToolBinoculars)
    SpecializationUtil.registerEventListener(handToolType, "onDelete", HandToolBinoculars)
    SpecializationUtil.registerEventListener(handToolType, "onUpdate", HandToolBinoculars)
    SpecializationUtil.registerEventListener(handToolType, "onHeldStart", HandToolBinoculars)
    SpecializationUtil.registerEventListener(handToolType, "onHeldEnd", HandToolBinoculars)
    SpecializationUtil.registerEventListener(handToolType, "onRegisterActionEvents", HandToolBinoculars)
end

function HandToolBinoculars.prerequisitesPresent(_)
    return true
end

function HandToolBinoculars:onLoad(xmlFile)
    local spec = self[HandToolBinoculars.SPEC_TABLE_NAME]
    if spec == nil then
        spec = {}
        self[HandToolBinoculars.SPEC_TABLE_NAME] = spec
    end

    spec.zoomFovY = xmlFile:getValue("handTool.binoculars#zoomFov", math.rad(12))
    spec.currentZoomFovY = spec.zoomFovY
    spec.transitionSpeed = math.max(xmlFile:getValue("handTool.binoculars#transitionSpeed", 10), 0.1)
    spec.zoomRequested = false
    spec.cameraNode = nil
    spec.originalFovY = nil
    spec.actionEventId = nil
    spec.wheelActionEventId = nil
    spec.hudHiddenByBinoculars = false
    spec.previousHudVisible = nil
    spec.previousNoHudModeEnabled = nil
    spec.variableZoomEnabled = xmlFile:hasProperty("handTool.binoculars.variableZoom")

    if spec.variableZoomEnabled then
        spec.minZoomFovY = xmlFile:getValue("handTool.binoculars.variableZoom#minFov", spec.zoomFovY)
        spec.maxZoomFovY = xmlFile:getValue("handTool.binoculars.variableZoom#maxFov", spec.zoomFovY)
        spec.zoomStepFovY = math.max(xmlFile:getValue("handTool.binoculars.variableZoom#step", math.rad(1)), math.rad(0.1))
        spec.zoomDirection = string.lower(xmlFile:getValue("handTool.binoculars.variableZoom#direction", "both"))

        if spec.zoomDirection == "in" then
            spec.maxZoomFovY = spec.zoomFovY
        elseif spec.zoomDirection == "out" then
            spec.minZoomFovY = spec.zoomFovY
        elseif spec.zoomDirection ~= "both" then
            Logging.warning("Binoculars: unknown variableZoom direction '%s', using 'both'", tostring(spec.zoomDirection))
            spec.zoomDirection = "both"
        end

        spec.minZoomFovY = math.min(spec.minZoomFovY, spec.zoomFovY)
        spec.maxZoomFovY = math.max(spec.maxZoomFovY, spec.zoomFovY)
        spec.currentZoomFovY = math.clamp(spec.zoomFovY, spec.minZoomFovY, spec.maxZoomFovY)
    end

    if self.isClient then
        local overlayFilename = xmlFile:getValue("handTool.binoculars.overlay#filename")
        if overlayFilename ~= nil then
            spec.hudOverlay = Overlay.new(Utils.getFilename(overlayFilename, self.baseDirectory), 0, 0, 1, 1)
        end
    end
end

function HandToolBinoculars:getBinocularsCameraNode()
    local player = self:getCarryingPlayer()
    if player == nil or not player.isOwner or player.camera == nil then
        return nil
    end

    return player.camera:getCurrentCameraNode()
end

function HandToolBinoculars:restoreBinocularsZoom()
    local spec = self[HandToolBinoculars.SPEC_TABLE_NAME]
    if spec.cameraNode ~= nil and spec.originalFovY ~= nil and entityExists(spec.cameraNode) then
        setFovY(spec.cameraNode, spec.originalFovY)
    end

    spec.cameraNode = nil
    spec.originalFovY = nil
end

function HandToolBinoculars:setBinocularsZoomActive(isActive)
    local spec = self[HandToolBinoculars.SPEC_TABLE_NAME]
    spec.zoomRequested = isActive == true and self:getIsHeld()
    self:setBinocularsHudHidden(spec.zoomRequested)
    self:raiseActive()
end

function HandToolBinoculars:adjustBinocularsZoom(inputValue)
    local spec = self[HandToolBinoculars.SPEC_TABLE_NAME]
    if not spec.zoomRequested or not spec.variableZoomEnabled or inputValue == 0 then
        return
    end

    local direction = inputValue > 0 and 1 or -1
    spec.currentZoomFovY = math.clamp(spec.currentZoomFovY - spec.zoomStepFovY * direction, spec.minZoomFovY, spec.maxZoomFovY)
    self:raiseActive()
end

function HandToolBinoculars:setBinocularsHudHidden(isHidden)
    local spec = self[HandToolBinoculars.SPEC_TABLE_NAME]
    local hud = g_currentMission ~= nil and g_currentMission.hud or nil

    if isHidden and not spec.hudHiddenByBinoculars then
        spec.previousNoHudModeEnabled = g_noHudModeEnabled == true
        spec.previousHudVisible = hud == nil or hud.getIsVisible == nil or hud:getIsVisible()

        if hud ~= nil and hud.setIsVisible ~= nil then
            hud:setIsVisible(false)
        end
        g_noHudModeEnabled = true

        spec.hudHiddenByBinoculars = true
        HandToolBinoculars.activeOverlayTool = self
    elseif not isHidden and spec.hudHiddenByBinoculars then
        if hud ~= nil and hud.setIsVisible ~= nil and spec.previousHudVisible ~= nil then
            hud:setIsVisible(spec.previousHudVisible)
        end
        g_noHudModeEnabled = spec.previousNoHudModeEnabled == true

        spec.hudHiddenByBinoculars = false
        spec.previousHudVisible = nil
        spec.previousNoHudModeEnabled = nil
        if HandToolBinoculars.activeOverlayTool == self then
            HandToolBinoculars.activeOverlayTool = nil
        end
    end
end

function HandToolBinoculars:updateBinocularsZoom(dt)
    local spec = self[HandToolBinoculars.SPEC_TABLE_NAME]
    local cameraNode = self:getBinocularsCameraNode()

    if cameraNode ~= spec.cameraNode then
        self:restoreBinocularsZoom()
        if spec.zoomRequested and cameraNode ~= nil then
            spec.cameraNode = cameraNode
            spec.originalFovY = getFovY(cameraNode)
        end
    elseif spec.cameraNode == nil and spec.zoomRequested and cameraNode ~= nil then
        spec.cameraNode = cameraNode
        spec.originalFovY = getFovY(cameraNode)
    end

    if spec.cameraNode == nil or spec.originalFovY == nil then
        return
    end

    local targetFovY = spec.originalFovY
    if spec.zoomRequested then
        targetFovY = math.min(spec.currentZoomFovY, spec.originalFovY)
    end

    local currentFovY = getFovY(spec.cameraNode)
    local blend = math.min((dt or 0) * 0.001 * spec.transitionSpeed, 1)
    local nextFovY = MathUtil.lerp(currentFovY, targetFovY, blend)
    if math.abs(nextFovY - targetFovY) < math.rad(0.02) then
        nextFovY = targetFovY
    end

    setFovY(spec.cameraNode, nextFovY)

    if not spec.zoomRequested and nextFovY == spec.originalFovY then
        spec.cameraNode = nil
        spec.originalFovY = nil
    end
end

function HandToolBinoculars:updateBinocularsActionEvent()
    local spec = self[HandToolBinoculars.SPEC_TABLE_NAME]
    if spec.actionEventId ~= nil then
        g_inputBinding:setActionEventActive(spec.actionEventId, self:getIsHeld())
    end
    if spec.wheelActionEventId ~= nil then
        g_inputBinding:setActionEventActive(spec.wheelActionEventId, self:getIsHeld())
    end
end

function HandToolBinoculars:onUpdate(dt)
    if self:getIsHeld() then
        self:updateBinocularsZoom(dt)
        self:updateBinocularsActionEvent()
        self:raiseActive()
    end
end

function HandToolBinoculars:onHeldStart()
    local spec = self[HandToolBinoculars.SPEC_TABLE_NAME]
    spec.zoomRequested = false
    spec.currentZoomFovY = spec.zoomFovY
    self:updateBinocularsActionEvent()
    self:raiseActive()
end

function HandToolBinoculars:draw()
    local handTool = HandToolBinoculars.activeOverlayTool
    local spec = handTool ~= nil and handTool[HandToolBinoculars.SPEC_TABLE_NAME] or nil
    if spec ~= nil and spec.zoomRequested and handTool:getIsHeld() and spec.hudOverlay ~= nil then
        spec.hudOverlay:render()
    end
end

function HandToolBinoculars:onHeldEnd()
    local spec = self[HandToolBinoculars.SPEC_TABLE_NAME]
    spec.zoomRequested = false
    self:setBinocularsHudHidden(false)
    self:restoreBinocularsZoom()
    self:updateBinocularsActionEvent()
end

function HandToolBinoculars:onDelete()
    local spec = self[HandToolBinoculars.SPEC_TABLE_NAME]
    self:setBinocularsHudHidden(false)
    self:restoreBinocularsZoom()
    if spec.hudOverlay ~= nil then
        spec.hudOverlay:delete()
        spec.hudOverlay = nil
    end
end

function HandToolBinoculars:onRegisterActionEvents()
    local spec = self[HandToolBinoculars.SPEC_TABLE_NAME]
    if self:getIsActiveForInput(true) then
        local _, actionEventId = self:addActionEvent(InputAction.ACTIVATE_HANDTOOL, self, HandToolBinoculars.onZoomAction, true, true, false, true, nil)
        spec.actionEventId = actionEventId
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventText(actionEventId, g_i18n:getText("action_useBinoculars"))
        g_inputBinding:setActionEventActive(actionEventId, false)

        if spec.variableZoomEnabled then
            local _, wheelActionEventId = self:addActionEvent("BINOCULARS_ZOOM_ALT_WHEEL", self, HandToolBinoculars.onWheelZoomAction, false, true, false, true, nil)
            spec.wheelActionEventId = wheelActionEventId
            g_inputBinding:setActionEventTextVisibility(wheelActionEventId, false)
            g_inputBinding:setActionEventActive(wheelActionEventId, false)
        end
    end
end

function HandToolBinoculars:onZoomAction(_, inputValue)
    self:setBinocularsZoomActive(inputValue > 0.5)
end

function HandToolBinoculars:onWheelZoomAction(_, inputValue)
    self:adjustBinocularsZoom(inputValue)
end
