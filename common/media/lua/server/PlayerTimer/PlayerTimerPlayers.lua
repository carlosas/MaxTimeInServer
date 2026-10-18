--[[
What the server can learn about the people currently connected.

Build 42's server-side Lua cannot reach the user database at all
(ServerWorldDatabase, Roles and BanSystem are all absent from the server's Lua
namespace), so everything here comes off the IsoPlayer objects the engine hands
out. That is enough: a quota only ever has to judge somebody who is connected.
]]

PlayerTimerPlayers = PlayerTimerPlayers or {}

--- Lower-cased role name of a connected player, or nil if it cannot be read.
-- Falls back to the access level, which is what an older server reports.
function PlayerTimerPlayers.roleOf(player)
    if player == nil then return nil end

    local ok, name = pcall(function()
        local role = player:getRole()
        if role == nil then return nil end
        return tostring(role:getName())
    end)
    if ok and name ~= nil and name ~= "" then return string.lower(name) end

    local levelOk, level = pcall(function() return player:getAccessLevel() end)
    if levelOk and level ~= nil and tostring(level) ~= "" then
        local lowered = string.lower(tostring(level))
        -- A plain player reports "none"; the quota calls that "user".
        if lowered == "none" then return "user" end
        return lowered
    end

    return nil
end

--- Everyone connected right now, as { username = ..., role = ... }.
function PlayerTimerPlayers.online()
    local out = {}
    local ok, players = pcall(getOnlinePlayers)
    if not ok or players == nil then return out end

    local walked, err = pcall(function()
        for index = 0, players:size() - 1 do
            local player = players:get(index)
            if player ~= nil then
                local username = player:getUsername()
                if username ~= nil and tostring(username) ~= "" then
                    table.insert(out, {
                        username = tostring(username),
                        role = PlayerTimerPlayers.roleOf(player),
                        player = player,
                    })
                end
            end
        end
    end)
    if not walked then
        print("[PlayerTimer] could not list the connected players: " .. tostring(err))
    end
    return out
end
