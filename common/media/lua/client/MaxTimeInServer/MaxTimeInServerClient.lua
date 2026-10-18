--[[
The client half of the join check.

A dedicated server loads and runs client Lua as well (GameServer.doMinimumInit
walks shared, client and server), so everything here is behind isClient() and
the module does nothing at all on a server.

On arrival it greets the server. If the server answers that the weekly budget
is spent, it shows the numbers and drops the connection - immediately if the
player dismisses the notice, and in any case once the grace period is up.
]]

MaxTimeInServerClient = MaxTimeInServerClient or {}

--- True only on a machine with a local player, i.e. not a dedicated server.
-- Checked when an event fires rather than when this file loads, because the
-- engine sets GameClient.client around the Lua load.
local function actingAsClient()
    return isClient ~= nil and isClient()
end

local disconnectAtMs = nil
local greeted = false

-- The operator's wording comes first, on its own. The numbers are the mod's
-- and always follow in the same shape, so an operator rewriting the message
-- cannot accidentally hide what the player needs to know.
local function noticeText(message, minutes, cap, resetsAt, graceSeconds)
    local blocks = {}

    local wording = tostring(message or "")
    wording = (wording:gsub("^%s+", ""):gsub("%s+$", ""))
    if wording ~= "" then table.insert(blocks, wording) end

    if cap and cap > 0 then
        table.insert(blocks,
            "You have used " .. tostring(math.floor(minutes or 0)) ..
            " of your " .. tostring(math.floor(cap)) .. " minutes this week.\n" ..
            "Your allowance resets on " .. tostring(resetsAt or "the next Monday") .. ".")
    end

    table.insert(blocks, "Disconnecting in " ..
        tostring(math.floor(graceSeconds or 0)) .. " seconds.")

    return table.concat(blocks, "\n\n")
end

local function defaultShowNotice(text)
    local width, height = 440, 240
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local modal = ISModalDialog:new(x, y, width, height, text, false, nil,
        MaxTimeInServerClient.onNoticeDismissed)
    modal:initialise()
    modal:addToUIManager()
    if modal.setAlwaysOnTop ~= nil then modal:setAlwaysOnTop(true) end
end

MaxTimeInServerClient.hooks = {
    sendHello = function()
        sendClientCommand(MaxTimeInServerConfig.netModule, MaxTimeInServerConfig.netHello, {})
    end,
    showNotice = defaultShowNotice,
    disconnect = function() forceDisconnect() end,
    nowMs = function() return getTimestampMs() end,
}

--- Forgets any pending disconnect. Used by the tests and on a fresh session.
function MaxTimeInServerClient.reset()
    disconnectAtMs = nil
    greeted = false
end

local function dropNow()
    disconnectAtMs = nil
    pcall(MaxTimeInServerClient.hooks.disconnect)
end

--- OK on the notice: go straight away rather than waiting out the grace.
function MaxTimeInServerClient.onNoticeDismissed()
    dropNow()
end

function MaxTimeInServerClient.onCreatePlayer(playerIndex)
    if not actingAsClient() then return end
    -- Only the first local player greets; a split-screen second player is the
    -- same account as far as the quota is concerned.
    if playerIndex ~= 0 then return end
    if greeted then return end
    greeted = true
    pcall(MaxTimeInServerClient.hooks.sendHello)
end

function MaxTimeInServerClient.onServerCommand(module, command, args)
    if not actingAsClient() then return end
    if module ~= MaxTimeInServerConfig.netModule then return end
    if command ~= MaxTimeInServerConfig.netBlocked then return end

    args = args or {}
    local minutes = tonumber(args.minutes) or 0
    local cap = tonumber(args.cap) or 0
    local graceSeconds = tonumber(args.graceSeconds) or MaxTimeInServerConfig.graceSeconds or 10

    -- The disconnect is armed before the notice: a UI that refuses to open
    -- must not leave the player in a world they are not allowed to be in.
    local clockOk, now = pcall(MaxTimeInServerClient.hooks.nowMs)
    now = clockOk and now or 0
    disconnectAtMs = now + graceSeconds * 1000

    local shown = pcall(MaxTimeInServerClient.hooks.showNotice,
        noticeText(args.message, minutes, cap, args.resetsAt, graceSeconds))
    if not shown then
        -- Nothing was put on screen, so the grace period buys the player
        -- nothing but confusion. Go almost immediately instead.
        disconnectAtMs = now + 2000
    end

    print("[MaxTimeInServer] refused by the server: " .. tostring(minutes) ..
        "/" .. tostring(cap) .. " minutes this week")
end

function MaxTimeInServerClient.update()
    if disconnectAtMs == nil then return end
    local ok, now = pcall(MaxTimeInServerClient.hooks.nowMs)
    if not ok or now == nil then return end
    if now >= disconnectAtMs then dropNow() end
end

function MaxTimeInServerClient.registerEvents()
    -- Keyed to the event object so a Lua reload re-attaches us, instead of a
    -- boolean that would survive the reload and skip it.
    if MaxTimeInServerClient.registeredOn == Events.OnServerCommand then return end
    MaxTimeInServerClient.registeredOn = Events.OnServerCommand
    Events.OnCreatePlayer.Add(MaxTimeInServerClient.onCreatePlayer)
    Events.OnServerCommand.Add(MaxTimeInServerClient.onServerCommand)
    Events.OnTick.Add(MaxTimeInServerClient.update)
end

-- Registered whatever side we are on; every handler checks for itself. A
-- dedicated server runs this file too and stays silent because isClient() is
-- false there when the events fire.
MaxTimeInServerClient.registerEvents()
