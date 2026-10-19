--[[
The join check.

Build 42's server-side Lua cannot refuse a login: there is no connection event,
GameServer is hidden from Lua, and the ban/role APIs are not in the server's Lua
namespace. What the server can do is talk to a client that has just arrived.

So the mod's client half greets the server as soon as its player exists, and
this is what answers: if the account has spent its weekly budget, the server
sends back the numbers and the client shows them and disconnects itself.

That leans on the client cooperating, which the stock anti-cheat already
enforces: with DoLuaChecksum=true the server hashes every Lua file both sides
load - its own and the mods' client files - and kicks any client whose hashes
disagree, so editing this mod locally gets you dropped by the base game before
the quota is even consulted.
]]

MaxTimeInServerGate = MaxTimeInServerGate or {}

local deps = nil

local function defaultDeps()
    return {
        config = MaxTimeInServerConfig,
        quota = MaxTimeInServerQuota,
        players = MaxTimeInServerPlayers,
        net = {
            send = function(player, module, command, args)
                sendServerCommand(player, module, command, args)
            end,
        },
    }
end

local function log(message)
    print("[MaxTimeInServer] " .. message)
end

function MaxTimeInServerGate.configure(overrides)
    deps = defaultDeps()
    for key, value in pairs(overrides or {}) do deps[key] = value end
end

local function dependencies()
    if deps == nil then deps = defaultDeps() end
    return deps
end

--- Server-side handler for the client's greeting.
function MaxTimeInServerGate.onClientCommand(module, command, player)
    local d = dependencies()
    if module ~= d.config.netModule then return end
    if command ~= d.config.netHello then return end

    local ok, err = pcall(function()
        if player == nil then return end
        local username = player:getUsername()
        if username == nil or tostring(username) == "" then return end
        username = tostring(username)

        local roleName = d.players.roleOf(player)
        local verdict = d.quota.verdict(username, roleName)

        -- One line per join. It is the only proof that the two halves are
        -- talking to each other at all.
        log(username .. " joined as " .. tostring(roleName or "?") .. ": " ..
            tostring(verdict.minutes or 0) .. "/" .. tostring(verdict.cap or 0) ..
            " minutes this week")

        if verdict.allowed then return end

        d.net.send(player, d.config.netModule, d.config.netBlocked, {
            message = d.config.blockedMessage,
            minutes = verdict.minutes,
            cap = verdict.cap,
            resetsAt = verdict.resetsAt,
            graceSeconds = d.config.graceSeconds,
        })
        log("refused " .. username .. ": " .. tostring(verdict.minutes or 0) ..
            "/" .. tostring(verdict.cap or 0) .. " minutes this week, resets " ..
            tostring(verdict.resetsAt))
    end)

    if not ok then log("handshake failed: " .. tostring(err)) end
end

function MaxTimeInServerGate.registerEvents()
    -- Keyed to the event object, not to a boolean: see MaxTimeInServerQuota.
    if MaxTimeInServerGate.registeredOn == Events.OnClientCommand then return end
    MaxTimeInServerGate.registeredOn = Events.OnClientCommand
    Events.OnClientCommand.Add(MaxTimeInServerGate.onClientCommand)
end

-- Registered unconditionally: OnClientCommand only ever fires on a server, so
-- there is no need to work out which side this is at load time.
MaxTimeInServerGate.registerEvents()
