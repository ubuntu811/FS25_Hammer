--[[
    HandToolSandboxLeash.lua -- the Hammer's own leash: a rope in the hand that is the winch of FS25_WinchTow (published on g_currentMission.winchTow: mod globals are invisible between mods).
    A click hooks the joint or the log you look at, the next click lets it go; with wires laid between bridge pieces and nothing hooked, the button HELD reels them in (a short press is the usual click);
    Q (the attach key) unhitches everything. No horse code: the horse mod has a leash of its own for horses (a clone of this part, kept apart on purpose: owned items are saved by their xml path).
]]
HandToolSandboxLeash = {}
HandToolSandboxLeash.SPEC_TABLE_NAME = "spec_" .. g_currentModName .. ".sandboxLeash"

function HandToolSandboxLeash.prerequisitesPresent(_)
    return true
end

function HandToolSandboxLeash.registerEventListeners(handToolType)
    SpecializationUtil.registerEventListener(handToolType, "onLoad", HandToolSandboxLeash)
    SpecializationUtil.registerEventListener(handToolType, "onRegisterActionEvents", HandToolSandboxLeash)
    SpecializationUtil.registerEventListener(handToolType, "onHeldStart", HandToolSandboxLeash)
    SpecializationUtil.registerEventListener(handToolType, "onHeldEnd", HandToolSandboxLeash)
end

local function winchOf()
    return g_currentMission ~= nil and g_currentMission.winchTow or nil
end

local function notify(text)
    print("[SandboxHammer] " .. text)
    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil and FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_INFO ~= nil then
        pcall(g_currentMission.addIngameNotification, g_currentMission, FSBaseMission.INGAME_NOTIFICATION_INFO, text)
    end
end

function HandToolSandboxLeash:onLoad(_)
    self[HandToolSandboxLeash.SPEC_TABLE_NAME] = { actionEventId = nil, unhitchEventId = nil }
end

function HandToolSandboxLeash:onRegisterActionEvents()
    local spec = self[HandToolSandboxLeash.SPEC_TABLE_NAME]
    if self:getIsActiveForInput(true) then
        local _, actionEventId = self:addActionEvent(InputAction.ACTIVATE_HANDTOOL, self, HandToolSandboxLeash.onAction, true, true, false, true, nil)
        spec.actionEventId = actionEventId
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventText(actionEventId, "Hook / let go (hold: reel in wires)")
        g_inputBinding:setActionEventActive(actionEventId, self:getIsHeld())
        local _, qId = self:addActionEvent(InputAction.ATTACH, self, HandToolSandboxLeash.onUnhitch, false, true, false, true, nil)
        spec.unhitchEventId = qId
        if qId ~= nil and qId ~= "" then
            g_inputBinding:setActionEventTextPriority(qId, GS_PRIO_HIGH)
            g_inputBinding:setActionEventText(qId, "Unhitch everything")
            g_inputBinding:setActionEventActive(qId, self:getIsHeld())
        end
    end
end

function HandToolSandboxLeash:onUnhitch(_, inputValue)
    local winch = winchOf()
    if inputValue > 0.5 and winch ~= nil and winch.unhitchAll ~= nil then
        notify(winch.unhitchAll())
    end
end

function HandToolSandboxLeash:onHeldStart()
    local spec = self[HandToolSandboxLeash.SPEC_TABLE_NAME]
    if spec.actionEventId ~= nil then
        g_inputBinding:setActionEventActive(spec.actionEventId, true)
    end
    if spec.unhitchEventId ~= nil and spec.unhitchEventId ~= "" then
        g_inputBinding:setActionEventActive(spec.unhitchEventId, true)
    end
    local winch = winchOf()
    if winch ~= nil then
        winch.hold(self.rootNode)                             -- (its rope starts at the leash in the hand)
        winch.hint, winch.gate = nil, nil                     -- (no horse here: the horse leash's hint and gate belong to it)
    end
end

function HandToolSandboxLeash:onHeldEnd()
    local spec = self[HandToolSandboxLeash.SPEC_TABLE_NAME]
    if spec.actionEventId ~= nil then
        g_inputBinding:setActionEventActive(spec.actionEventId, false)
    end
    if spec.unhitchEventId ~= nil and spec.unhitchEventId ~= "" then
        g_inputBinding:setActionEventActive(spec.unhitchEventId, false)
    end
    local winch = winchOf()
    if winch ~= nil then
        winch.putAway(self.rootNode)                          -- (a vehicle on the winch is let go when the tool is put away)
    end
end

-- A click: let go what is hooked, else hook the joint or the log in view. Returns the message.
function HandToolSandboxLeash.click(winch)
    if winch.target ~= nil then
        return winch.toggle()
    end
    local joint = winch.pick ~= nil and winch.pick(true) or nil
    local log, why = nil, nil
    if joint == nil and winch.pickLog ~= nil then
        log, why = winch.pickLog()
    end
    if joint ~= nil or log ~= nil then
        return winch.toggle()
    end
    return why or "look at a joint or a log, close enough, and click"
end

function HandToolSandboxLeash:onAction(_, inputValue)
    local winch = winchOf()
    if winch == nil then
        if inputValue > 0.5 then
            notify("the leash needs FS25_WinchTow (the winch): it is not loaded")
        end
        return
    end
    if inputValue > 0.5 then
        if winch.wiresWantPress ~= nil and winch.wiresWantPress(winch.target ~= nil) then
            winch.wirePress()
        else
            notify(HandToolSandboxLeash.click(winch))
        end
    elseif winch.wirePressed ~= nil and winch.wirePressed() then
        if not winch.wireRelease() then
            notify(HandToolSandboxLeash.click(winch))
        end
    end
end
