--[[
    ToolSlots.lua -- number keys for the hand tools: slot N is the Nth tool the player carries, in the order the game's own cycle key walks them (slot 1 is the empty hands). Alt+1 ... Alt+8 and Alt+0 (slot 10)
    by default (the plain digits are taken: 1 and 2 cycle, 3 toggles, 9 is the map, 0 the horn; Alt+9 is taken by the minimap mod, so slot 9 has no key until you set one in the controls menu).
    The same key again puts the tool away (back to the hands). A slot with no tool, or a tool that cannot be selected, says so. The events are made for the player's input component (target = the component:
    the game removes them with it), invisible in the key help (ten lines would fill the screen).
]]
ToolSlots = {}
ToolSlots.COUNT = 10

local function notify(text)
    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil and FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_INFO ~= nil then
        pcall(g_currentMission.addIngameNotification, g_currentMission, FSBaseMission.INGAME_NOTIFICATION_INFO, text)
    end
end

local function nameOf(tool, hands)
    if tool == hands then
        return "hands"
    end
    local ok, name = pcall(function()
        if tool.storeItem ~= nil and tool.storeItem.name ~= nil then
            return tool.storeItem.name
        end
        return tool.configFileName ~= nil and (tool.configFileName:match("([^/\\]+)%.xml$") or tool.configFileName) or "tool"
    end)
    return ok and tostring(name) or "tool"
end

function ToolSlots.onSlot(component, _, _, slot)
    print(string.format("[ToolSlots] key for slot %d pressed", slot))
    if component == nil or component.locked or component.player == nil then
        return
    end
    local player = component.player
    if player:getCurrentVehicle() ~= nil or (player.mover ~= nil and player.mover.isSwimming) then
        return
    end
    local tools = player.carriedHandTools
    local tool = tools ~= nil and tools[slot] or nil
    if tool == nil then
        notify(string.format("Tool slot %d is empty (you carry %d)", slot, tools ~= nil and #tools or 0))
        return
    end
    if tool.isSelectable == false then
        notify(string.format("Slot %d (%s) cannot be taken in the hand now", slot, nameOf(tool, player.hands)))
        return
    end
    if player.currentHandToolIndex == slot and slot ~= 1 and player.hands ~= nil then
        player:switchToHandToolIndex(1)                                   -- (the same key again: put it away)
        notify("Slot 1: hands")
        return
    end
    player:switchToHandToolIndex(slot)
    notify(string.format("Slot %d: %s", slot, nameOf(tool, player.hands)))
end

if PlayerInputComponent ~= nil and Utils ~= nil and not ToolSlots.hooked then
    ToolSlots.hooked = true
    PlayerInputComponent.registerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerActionEvents, function(self)
        if self.player == nil or not self.player.isOwner then
            return
        end
        g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)
        for slot = 1, ToolSlots.COUNT do
            local _, eventId = g_inputBinding:registerActionEvent("SANDBOX_TOOL_SLOT_" .. slot, self, ToolSlots.onSlot, false, true, false, true, slot)
            if eventId ~= nil then
                g_inputBinding:setActionEventTextVisibility(eventId, false)
            end
        end
        g_inputBinding:endActionEventsModification()
        print(string.format("[ToolSlots] %d slot keys registered (Alt+1..8 and Alt+0 by default)", ToolSlots.COUNT))
    end)
end

-- sbSlot [N]: with N takes the Nth carried tool (what Alt+N does), without it lists what you carry: tells a key problem from a code problem.
function ToolSlots.consoleSlot(_, arg)
    local player = g_localPlayer
    local component = player ~= nil and (player.inputComponent or player.playerInputComponent) or nil
    local tools = player ~= nil and player.carriedHandTools or nil
    if tools == nil then
        return "no player"
    end
    local n = tonumber(arg)
    if n ~= nil then
        ToolSlots.onSlot(component or { player = player }, nil, nil, n)
        return string.format("slot %d asked for (current index %s)", n, tostring(player.currentHandToolIndex))
    end
    local lines = {}
    for i, t in ipairs(tools) do
        lines[#lines + 1] = string.format("%d: %s%s", i, nameOf(t, player.hands), i == player.currentHandToolIndex and " (in hand)" or "")
    end
    return "carried tools: " .. table.concat(lines, ", ")
end
if addConsoleCommand ~= nil and not ToolSlots.consoleAdded then
    ToolSlots.consoleAdded = true
    addConsoleCommand("sbSlot", "SandboxHammer: sbSlot [N] takes the Nth carried hand tool, without N lists them", "consoleSlot", ToolSlots)
end
