--[[
    ToolPicker.lua -- key 1 opens a picker instead of "yet another toggle": tiles with the shop pictures of the hand tools you carry (tile 1 is the empty hands). Click a tile, or press its number, to take that
    tool; ESC, the same key again, or a click beside the tiles closes it. While it is open the player is locked (the game's own lock of the on-foot input) and the mouse cursor is shown.
    The base game's own key 1 ("switch hand tool", the cycle) is switched off for this session when the picker's key collides with it (the key 2 side of the cycle and the toggle on 3 stay): the engine's
    own disableBinding, not saved, undone by a rebinding in the controls menu. Alt+1..8 / Alt+0 (ToolSlots.lua) keep taking a tool at once.
]]
ToolPicker = {}
ToolPicker.isOpen = false
ToolPicker.tiles = {}
ToolPicker.overlays = {}
ToolPicker.hover = nil
ToolPicker.openedAt = 0
ToolPicker.component = nil
ToolPicker.COLS_MAX = 6
ToolPicker.TILE_W, ToolPicker.TILE_H, ToolPicker.GAP = 0.085, 0.16, 0.012
ToolPicker.SHUT_MS = 250                   -- the key that opens it must not also pick tile 1

local function nameOf(tool, hands)
    if tool == hands then
        return "Hands"
    end
    local ok, name = pcall(function()
        if tool.storeItem ~= nil and tool.storeItem.name ~= nil then
            return tool.storeItem.name
        end
        return tool.configFileName ~= nil and (tool.configFileName:match("([^/\\]+)%.xml$") or tool.configFileName) or "Tool"
    end)
    return ok and tostring(name) or "Tool"
end

local function imageOf(tool, hands)
    if tool == hands or tool.storeItem == nil then
        return nil
    end
    return tool.storeItem.imageFilename
end

function ToolPicker.clearOverlays()
    for _, overlay in pairs(ToolPicker.overlays) do
        if overlay ~= nil and overlay.delete ~= nil then
            pcall(overlay.delete, overlay)
        end
    end
    ToolPicker.overlays = {}
end

function ToolPicker.rects()
    local n = #ToolPicker.tiles
    local cols = math.min(n, ToolPicker.COLS_MAX)
    local rows = math.ceil(n / math.max(cols, 1))
    local w, h, gap = ToolPicker.TILE_W, ToolPicker.TILE_H, ToolPicker.GAP
    local totalW, totalH = cols * w + (cols - 1) * gap, rows * h + (rows - 1) * gap
    local x0, y0 = 0.5 - totalW / 2, 0.5 + totalH / 2
    local out = {}
    for i = 1, n do
        local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
        out[i] = { x = x0 + c * (w + gap), y = y0 - (r + 1) * h - r * gap, w = w, h = h }
    end
    return out, { x = x0 - 0.02, y = y0 - totalH - 0.05, w = totalW + 0.04, h = totalH + 0.11 }
end

function ToolPicker.openPicker(component)
    local player = component ~= nil and component.player or nil
    if player == nil or component.locked or player:getCurrentVehicle() ~= nil or (player.mover ~= nil and player.mover.isSwimming) then
        return
    end
    if g_gui ~= nil and g_gui:getIsGuiVisible() then
        return
    end
    local tools = player.carriedHandTools or {}
    ToolPicker.tiles = {}
    for i, tool in ipairs(tools) do
        ToolPicker.tiles[#ToolPicker.tiles + 1] = { index = i, tool = tool, name = nameOf(tool, player.hands), image = imageOf(tool, player.hands), current = i == player.currentHandToolIndex }
    end
    if #ToolPicker.tiles == 0 then
        return
    end
    ToolPicker.component, ToolPicker.isOpen, ToolPicker.hover, ToolPicker.openedAt = component, true, nil, g_time or 0
    component:lock()
    g_inputBinding:setShowMouseCursor(true)
end

function ToolPicker.closePicker()
    if not ToolPicker.isOpen then
        return
    end
    ToolPicker.isOpen = false
    local component = ToolPicker.component
    ToolPicker.component = nil
    if component ~= nil then
        component:unlock()
    end
    g_inputBinding:setShowMouseCursor(false)
    ToolPicker.clearOverlays()
end

function ToolPicker.select(i)
    local component = ToolPicker.component
    local player = component ~= nil and component.player or nil
    local tile = ToolPicker.tiles[i]
    ToolPicker.closePicker()
    if player == nil or tile == nil then
        return
    end
    if tile.tool.isSelectable == false then
        return
    end
    if player.currentHandToolIndex == i and i ~= 1 and player.hands ~= nil then
        player:switchToHandToolIndex(1)
    else
        player:switchToHandToolIndex(i)
    end
end

function ToolPicker.onAction(component, _, inputValue)
    if inputValue ~= nil and inputValue < 0.5 then
        return
    end
    if ToolPicker.isOpen then
        ToolPicker.closePicker()
    else
        ToolPicker.openPicker(component)
    end
end

function ToolPicker:update(dt)
    if ToolPicker.isOpen then
        local player = ToolPicker.component ~= nil and ToolPicker.component.player or nil
        if player == nil or player:getCurrentVehicle() ~= nil or (g_gui ~= nil and g_gui:getIsGuiVisible()) then
            ToolPicker.closePicker()
        end
    end
end

function ToolPicker:keyEvent(unicode, sym, modifier, isDown)
    if not ToolPicker.isOpen or not isDown then
        return
    end
    if sym == Input.KEY_escape then
        ToolPicker.closePicker()
        return
    end
    if (g_time or 0) - ToolPicker.openedAt < ToolPicker.SHUT_MS then
        return
    end
    for n = 1, 9 do
        if sym == Input["KEY_" .. n] and ToolPicker.tiles[n] ~= nil then
            ToolPicker.select(n)
            return
        end
    end
end

function ToolPicker:mouseEvent(posX, posY, isDown, isUp, button)
    if not ToolPicker.isOpen then
        return
    end
    local rects, panel = ToolPicker.rects()
    ToolPicker.hover = nil
    for i, r in ipairs(rects) do
        if posX >= r.x and posX <= r.x + r.w and posY >= r.y and posY <= r.y + r.h then
            ToolPicker.hover = i
        end
    end
    if isUp and button == Input.MOUSE_BUTTON_LEFT then
        if ToolPicker.hover ~= nil then
            ToolPicker.select(ToolPicker.hover)
        elseif posX < panel.x or posX > panel.x + panel.w or posY < panel.y or posY > panel.y + panel.h then
            ToolPicker.closePicker()
        end
    end
end

function ToolPicker:draw()
    if not ToolPicker.isOpen then
        return
    end
    local rects, panel = ToolPicker.rects()
    drawFilledRect(0, 0, 1, 1, 0, 0, 0, 0.35)
    drawFilledRect(panel.x, panel.y, panel.w, panel.h, 0.12, 0.12, 0.13, 0.92)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextBold(true)
    setTextColor(1, 1, 1, 1)
    renderText(0.5, panel.y + panel.h - 0.032, 0.018, "HAND TOOLS")
    setTextBold(false)
    local aspect = g_screenWidth / g_screenHeight
    for i, r in ipairs(rects) do
        local tile = ToolPicker.tiles[i]
        local hot = ToolPicker.hover == i
        drawFilledRect(r.x, r.y, r.w, r.h, hot and 0.35 or 0.2, hot and 0.55 or 0.2, hot and 0.2 or 0.22, hot and 0.95 or 0.9)
        if tile.current then
            drawFilledRect(r.x, r.y, r.w, 0.004, 0.55, 0.75, 0.2, 1)
        end
        if tile.image ~= nil then
            local overlay = ToolPicker.overlays[i]
            if overlay == nil then
                local ok, created = pcall(Overlay.new, tile.image, 0, 0, 0.07, 0.07 * aspect)
                overlay = ok and created or false
                ToolPicker.overlays[i] = overlay
            end
            if overlay then
                local iw = r.w * 0.86
                overlay:setPosition(r.x + (r.w - iw) / 2, r.y + r.h * 0.34)
                overlay:setDimension(iw, iw * aspect)
                overlay:render()
            end
        end
        setTextColor(0.8, 0.8, 0.8, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        renderText(r.x + 0.006, r.y + r.h - 0.02, 0.014, tostring(i))
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(1, 1, 1, 1)
        local label = #tile.name > 15 and (tile.name:sub(1, 14) .. ".") or tile.name
        renderText(r.x + r.w / 2, r.y + 0.012, 0.012, label)
    end
    setTextColor(0.75, 0.75, 0.75, 1)
    renderText(0.5, panel.y + 0.014, 0.012, "click a tool or press its number   |   ESC closes")
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

-- the registration: after the game's own on-foot events, in the same context
if PlayerInputComponent ~= nil and Utils ~= nil and not ToolPicker.hooked then
    ToolPicker.hooked = true
    PlayerInputComponent.registerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerActionEvents, function(self)
        if self.player == nil or not self.player.isOwner then
            return
        end
        g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)
        local _, eventId = g_inputBinding:registerActionEvent("SANDBOX_TOOL_PICKER", self, ToolPicker.onAction, false, true, false, true)
        if eventId ~= nil then
            g_inputBinding:setActionEventTextVisibility(eventId, false)
        end
        g_inputBinding:endActionEventsModification()
        -- the game's own key 1 (the cycle) is switched off where it collides with the picker's key
        local ok, err = pcall(function()
            local mine = g_inputBinding.nameActions["SANDBOX_TOOL_PICKER"]
            local base = g_inputBinding.nameActions[InputAction.CYCLE_HANDTOOL]
            local off = 0
            if mine ~= nil and base ~= nil then
                for _, theirs in pairs(base:getBindings()) do
                    for _, ours in pairs(mine:getActiveBindings()) do
                        if ours:hasEventCollision(theirs) then
                            base:disableBinding(theirs)
                            off = off + 1
                        end
                    end
                end
            end
            print(string.format("[ToolPicker] registered; %d binding(s) of the game's hand tool cycle switched off", off))
        end)
        if not ok then
            print("[ToolPicker] the collision with the game's cycle key could not be resolved: " .. tostring(err))
        end
    end)
    addModEventListener(ToolPicker)
end
