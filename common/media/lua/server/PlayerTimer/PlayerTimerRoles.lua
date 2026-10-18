--[[
The only place that talks to the server's user database.

Build 42 has no "banned" flag on an account: being banned *is* holding the
banned role, so blocking a player means moving their account to that role and
unblocking means putting the old one back. Both zombie.network.ServerWorldDatabase
and zombie.characters.Roles are reachable from the server's Lua (unlike
zombie.network.GameServer, which is hidden from it).

Every raw call lives in PlayerTimerRoles.java so it can be swapped out in tests,
and every one of them is wrapped: a database hiccup must degrade to "no change
this sweep", never to an error escaping an event handler.
]]

PlayerTimerRoles = PlayerTimerRoles or {}

local cachedSnapshot = nil

local javaCalls = {}

function javaCalls.bannedRoleName()
    local role = Roles.getDefaultForBanned()
    if role == nil then return nil end
    return tostring(role:getName())
end

function javaCalls.getRoleName(username)
    local role = ServerWorldDatabase.instance:getUserRoleNameByUsername(username)
    if role == nil then return nil end
    return tostring(role:getName())
end

function javaCalls.setRole(username, roleName)
    local role = Roles.getRole(roleName)
    if role == nil then error("unknown role " .. tostring(roleName)) end
    -- Returns a message string on failure, null on success. The caller does not
    -- trust that and re-reads the role instead.
    return ServerWorldDatabase.instance:setRole(username, role)
end

--- username -> { steamid, role } for every account the server knows.
function javaCalls.snapshot()
    local users = HashMap.new()
    ServerWorldDatabase.instance:getWhitelistUsers(users)
    local out = {}
    local iterator = users:keySet():iterator()
    while iterator:hasNext() do
        local username = iterator:next()
        local user = users:get(username)
        local entry = { steamid = nil, role = nil }
        if user ~= nil then
            local steamid = user:getSteamid()
            if steamid ~= nil and tostring(steamid) ~= "" then entry.steamid = tostring(steamid) end
            local role = user:getRole()
            if role ~= nil then entry.role = tostring(role:getName()) end
        end
        out[tostring(username)] = entry
    end
    return out
end

PlayerTimerRoles.java = javaCalls

local function logFailure(what, err)
    print("[PlayerTimer] " .. what .. " failed: " .. tostring(err))
end

--- Name of the role that denies a login. Falls back to the stock name.
function PlayerTimerRoles.bannedRoleName()
    local ok, name = pcall(PlayerTimerRoles.java.bannedRoleName)
    if ok and name ~= nil and name ~= "" then return name end
    if not ok then logFailure("reading the banned role", name) end
    return "banned"
end

--- Current role name of an account, or nil if it cannot be read.
function PlayerTimerRoles.getRoleName(username)
    local ok, name = pcall(PlayerTimerRoles.java.getRoleName, username)
    if not ok then
        logFailure("reading the role of " .. tostring(username), name)
        return nil
    end
    if name == nil or name == "" then return nil end
    return name
end

--- Moves an account to `roleName` and confirms it stuck.
-- Returns true, or nil plus a message.
function PlayerTimerRoles.setRole(username, roleName)
    local ok, err = pcall(PlayerTimerRoles.java.setRole, username, roleName)
    if not ok then return nil, tostring(err) end

    cachedSnapshot = nil
    local actual = PlayerTimerRoles.getRoleName(username)
    if actual ~= roleName then
        return nil, string.format("role of %s is still %s after setting it to %s",
            tostring(username), tostring(actual), tostring(roleName))
    end
    return true
end

--- Drops the cached account snapshot, so the next lookup re-reads the database.
function PlayerTimerRoles.clearCache()
    cachedSnapshot = nil
end

local function snapshot()
    if cachedSnapshot ~= nil then return cachedSnapshot end
    local ok, result = pcall(PlayerTimerRoles.java.snapshot)
    if not ok or type(result) ~= "table" then
        if not ok then logFailure("reading the account list", result) end
        return nil
    end
    cachedSnapshot = result
    return cachedSnapshot
end

--- Steam id of an account as a string, or nil when it is not known.
function PlayerTimerRoles.getSteamId(username)
    local users = snapshot()
    if users == nil then return nil end
    local entry = users[username]
    if entry == nil then return nil end
    return entry.steamid
end
