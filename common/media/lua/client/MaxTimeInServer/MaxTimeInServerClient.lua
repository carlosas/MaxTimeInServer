--[[
The client half of the join check.

A dedicated server loads and runs client Lua as well (GameServer.doMinimumInit
walks shared, client and server), so every handler checks which side it is on
before doing anything, and this module stays silent on a server.

On arrival it greets the server and keeps greeting until the server answers. A
client command sent before the connection can carry it is dropped with no error
at all, so a single attempt is not something to rely on. The server always
answers - "you may play" or "you may not" - which is what stops the retries.

If the answer is no, the player is shown the numbers and the game disconnects
itself: immediately if they dismiss the notice, and in any case once the grace
period is up.
]]

MaxTimeInServerClient = MaxTimeInServerClient or {}

local acknowledged = false
local attempts = 0
local nextHelloMs = nil
local disconnectAtMs = nil

--- True only on a machine with a local player, i.e. not a dedicated server.
-- Checked when an event fires rather than when this file loads, because the
-- engine sets GameClient.client around the Lua load.
local function actingAsClient()
    return isClient ~= nil and isClient()
end

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
    -- The character matters: the base game always sends client commands with
    -- one, and the form without it does not reach the server from here.
    sendHello = function(character)
        sendClientCommand(character, MaxTimeInServerConfig.netModule,
            MaxTimeInServerConfig.netHello, { version = 1 })
    end,
    showNotice = defaultShowNotice,
    disconnect = function() forceDisconnect() end,
    nowMs = function() return getTimestampMs() end,
}

local function now()
    local ok, value = pcall(MaxTimeInServerClient.hooks.nowMs)
    if ok and value ~= nil then return value end
    return 0
end

--- Forgets everything about this session. Used by the tests and on a new one.
function MaxTimeInServerClient.reset()
    acknowledged = false
    attempts = 0
    nextHelloMs = nil
    disconnectAtMs = nil
end

local function localCharacter(playerIndex)
    if playerIndex ~= nil then
        local ok, character = pcall(getSpecificPlayer, playerIndex)
        if ok and character ~= nil then return character end
    end
    local ok, character = pcall(getPlayer)
    if ok then return character end
    return nil
end

-- Sends the greeting, unless the server has already answered or the last
-- attempt was too recent. Returns true when something was actually sent.
local function greet(character)
    if acknowledged then return false end
    if attempts >= (MaxTimeInServerConfig.helloAttempts or 15) then return false end

    local moment = now()
    if nextHelloMs ~= nil and moment < nextHelloMs then return false end

    character = character or localCharacter(nil)
    if character == nil then return false end

    attempts = attempts + 1
    nextHelloMs = moment + (MaxTimeInServerConfig.helloRetrySeconds or 2) * 1000

    local ok, err = pcall(MaxTimeInServerClient.hooks.sendHello, character)
    if not ok then
        print("[MaxTimeInServer] could not greet the server: " .. tostring(err))
        return false
    end
    if attempts == 1 then
        print("[MaxTimeInServer] greeted the server, waiting to hear whether we may play")
    end
    return true
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
    greet(localCharacter(playerIndex))
end

function MaxTimeInServerClient.onGameStart()
    if not actingAsClient() then return end
    greet(nil)
end

function MaxTimeInServerClient.onServerCommand(module, command, args)
    if not actingAsClient() then return end
    if module ~= MaxTimeInServerConfig.netModule then return end

    if command == MaxTimeInServerConfig.netAllowed then
        acknowledged = true
        print("[MaxTimeInServer] the server says we may play")
        return
    end

    if command ~= MaxTimeInServerConfig.netBlocked then return end
    acknowledged = true

    args = args or {}
    local minutes = tonumber(args.minutes) or 0
    local cap = tonumber(args.cap) or 0
    local graceSeconds = tonumber(args.graceSeconds) or MaxTimeInServerConfig.graceSeconds or 10

    -- The disconnect is armed before the notice: a UI that refuses to open
    -- must not leave the player in a world they are not allowed to be in.
    local moment = now()
    disconnectAtMs = moment + graceSeconds * 1000

    local shown = pcall(MaxTimeInServerClient.hooks.showNotice,
        noticeText(args.message, minutes, cap, args.resetsAt, graceSeconds))
    if not shown then
        -- Nothing was put on screen, so the grace period buys the player
        -- nothing but confusion. Go almost immediately instead.
        disconnectAtMs = moment + 2000
    end

    print("[MaxTimeInServer] refused by the server: " .. tostring(minutes) ..
        "/" .. tostring(cap) .. " minutes this week")
end

function MaxTimeInServerClient.update()
    if not actingAsClient() then return end

    if not acknowledged then greet(nil) end

    if disconnectAtMs ~= nil and now() >= disconnectAtMs then dropNow() end
end

function MaxTimeInServerClient.registerEvents()
    -- Keyed to the event object so a Lua reload re-attaches us, instead of a
    -- boolean that would survive the reload and skip it.
    if MaxTimeInServerClient.registeredOn == Events.OnServerCommand then return end
    MaxTimeInServerClient.registeredOn = Events.OnServerCommand
    Events.OnCreatePlayer.Add(MaxTimeInServerClient.onCreatePlayer)
    Events.OnGameStart.Add(MaxTimeInServerClient.onGameStart)
    Events.OnServerCommand.Add(MaxTimeInServerClient.onServerCommand)
    Events.OnTick.Add(MaxTimeInServerClient.update)
end

MaxTimeInServerClient.registerEvents()

print("[MaxTimeInServer] client half loaded (isClient=" ..
    tostring(isClient ~= nil and isClient()) .. ")")
