--[[
The client half of the join check.

A dedicated server loads and runs client Lua as well (GameServer.doMinimumInit
walks shared, client and server), so everything here is behind isClient() and
the module does nothing at all on a server.

On arrival it greets the server. If the server answers that the weekly budget
is spent, it shows the numbers and drops the connection - immediately if the
player dismisses the notice, and in any case once the grace period is up.
]]

PlayerTimerClient = PlayerTimerClient or {}

--- True only on a machine with a local player, i.e. not a dedicated server.
-- Checked when an event fires rather than when this file loads, because the
-- engine sets GameClient.client around the Lua load.
local function actingAsClient()
    return isClient ~= nil and isClient()
end

local disconnectAtMs = nil
local greeted = false

local function noticeText(minutes, cap, resetsAt, graceSeconds)
    if cap and cap > 0 then
        return string.format(
            "Weekly play limit reached.\n\n" ..
            "You have used %d of your %d minutes this week.\n" ..
            "Your allowance resets on %s.\n\n" ..
            "Disconnecting in %d seconds.",
            minutes or 0, cap, tostring(resetsAt or "the next Monday"), graceSeconds or 0)
    end
    return "Weekly play limit reached. Your allowance resets at the start of " ..
           "next week. Disconnecting shortly."
end

local function defaultShowNotice(text)
    local width, height = 440, 240
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local modal = ISModalDialog:new(x, y, width, height, text, false, nil,
        PlayerTimerClient.onNoticeDismissed)
    modal:initialise()
    modal:addToUIManager()
    if modal.setAlwaysOnTop ~= nil then modal:setAlwaysOnTop(true) end
end

PlayerTimerClient.hooks = {
    sendHello = function()
        sendClientCommand(PlayerTimerConfig.netModule, PlayerTimerConfig.netHello, {})
    end,
    showNotice = defaultShowNotice,
    disconnect = function() forceDisconnect() end,
    nowMs = function() return getTimestampMs() end,
}

--- Forgets any pending disconnect. Used by the tests and on a fresh session.
function PlayerTimerClient.reset()
    disconnectAtMs = nil
    greeted = false
end

local function dropNow()
    disconnectAtMs = nil
    pcall(PlayerTimerClient.hooks.disconnect)
end

--- OK on the notice: go straight away rather than waiting out the grace.
function PlayerTimerClient.onNoticeDismissed()
    dropNow()
end

function PlayerTimerClient.onCreatePlayer(playerIndex)
    if not actingAsClient() then return end
    -- Only the first local player greets; a split-screen second player is the
    -- same account as far as the quota is concerned.
    if playerIndex ~= 0 then return end
    if greeted then return end
    greeted = true
    pcall(PlayerTimerClient.hooks.sendHello)
end

function PlayerTimerClient.onServerCommand(module, command, args)
    if not actingAsClient() then return end
    if module ~= PlayerTimerConfig.netModule then return end
    if command ~= PlayerTimerConfig.netBlocked then return end

    args = args or {}
    local minutes = tonumber(args.minutes) or 0
    local cap = tonumber(args.cap) or 0
    local graceSeconds = tonumber(args.graceSeconds) or PlayerTimerConfig.graceSeconds or 10

    -- The disconnect is armed before the notice: a UI that refuses to open
    -- must not leave the player in a world they are not allowed to be in.
    local clockOk, now = pcall(PlayerTimerClient.hooks.nowMs)
    now = clockOk and now or 0
    disconnectAtMs = now + graceSeconds * 1000

    local shown = pcall(PlayerTimerClient.hooks.showNotice,
        noticeText(minutes, cap, args.resetsAt, graceSeconds))
    if not shown then
        -- Nothing was put on screen, so the grace period buys the player
        -- nothing but confusion. Go almost immediately instead.
        disconnectAtMs = now + 2000
    end

    print(string.format("[PlayerTimer] refused by the server: %d/%d minutes this week",
        minutes, cap))
end

function PlayerTimerClient.update()
    if disconnectAtMs == nil then return end
    local ok, now = pcall(PlayerTimerClient.hooks.nowMs)
    if not ok or now == nil then return end
    if now >= disconnectAtMs then dropNow() end
end

-- Registered unconditionally; every handler checks the side itself. A dedicated
-- server runs this file too and must stay silent, which it does because
-- isClient() is false there when the events actually fire.
Events.OnCreatePlayer.Add(PlayerTimerClient.onCreatePlayer)
Events.OnServerCommand.Add(PlayerTimerClient.onServerCommand)
Events.OnTick.Add(PlayerTimerClient.update)
