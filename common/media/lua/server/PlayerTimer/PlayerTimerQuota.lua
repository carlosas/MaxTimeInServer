--[[
The engine: counts connected time and keeps the block state in sync with it.

Build 42's server-side Lua has no "a player is connecting" event, so the quota
cannot be checked at login. Instead the mod keeps the block applied ahead of
time: as soon as an account has spent its weekly budget it is moved to the
banned role, and the server's own login check refuses it from then on. The role
is handed back when the week rolls over, or as soon as the data file says the
account is under its cap again.

A sweep runs at most once per sweepIntervalSeconds of *real* time. It is driven
by EveryOneMinute, which the engine fires on game time (roughly every 7.5 real
seconds on this server), so the interval is enforced against getTimestamp()
rather than against the event itself.

Every sweep re-reads the data file and rewrites it when something changed, which
is what lets the operator edit minutes, bonusMinutes, exempt or capMinutes by
hand and have it take effect within one interval.
]]

PlayerTimerQuota = PlayerTimerQuota or {}

local SECONDS_PER_MINUTE = 60

-- Replaced wholesale in tests.
local pzFiles = {
    read = function(_, name)
        local reader = getFileReader(name, false)
        if reader == nil then return nil end
        local lines = {}
        local line = reader:readLine()
        while line ~= nil do
            table.insert(lines, line)
            line = reader:readLine()
        end
        reader:close()
        return table.concat(lines, "\n")
    end,

    write = function(_, name, text)
        local writer = getFileWriter(name, true, false)
        if writer == nil then return false end
        writer:write(text)
        writer:close()
        return true
    end,
}

local function pzOnline()
    local out = {}
    local players = getOnlinePlayers()
    if players == nil then return out end
    for index = 0, players:size() - 1 do
        local player = players:get(index)
        if player ~= nil then
            local username = player:getUsername()
            if username ~= nil and tostring(username) ~= "" then
                table.insert(out, { username = tostring(username) })
            end
        end
    end
    return out
end

local deps = nil
local lastSweepEpoch = nil
local carriedSeconds = {}        -- username -> seconds not yet worth a minute
local registered = false

local function defaultDeps()
    return {
        config = PlayerTimerConfig,
        clock = PlayerTimerClock,
        store = PlayerTimerStore,
        roles = PlayerTimerRoles,
        files = pzFiles,
        online = pzOnline,
    }
end

local function log(message)
    print("[PlayerTimer] " .. message)
end

--- Swaps in alternative collaborators and forgets all in-memory progress.
function PlayerTimerQuota.configure(overrides)
    deps = defaultDeps()
    for key, value in pairs(overrides or {}) do deps[key] = value end
    lastSweepEpoch = nil
    carriedSeconds = {}
end

local function dependencies()
    if deps == nil then deps = defaultDeps() end
    return deps
end

--- Reads the data file and returns the state it describes.
function PlayerTimerQuota.loadState()
    local d = dependencies()
    local state, info = d.store.load(d.files, d.config.dataFile, d.config.capMinutes)
    return state, info
end

local function exemptRoleSet()
    local set = {}
    for _, name in ipairs(dependencies().config.exemptRoles or {}) do
        set[tostring(name):lower()] = true
    end
    return set
end

-- The role an account would hold if the mod were not blocking it.
local function underlyingRole(username, record)
    if record.blockedRole ~= nil and record.blockedRole ~= "" then
        return record.blockedRole
    end
    return dependencies().roles.getRoleName(username)
end

local function isExempt(username, record, exemptRoles)
    if record.exempt then return true end
    local roleName = underlyingRole(username, record)
    return roleName ~= nil and exemptRoles[tostring(roleName):lower()] == true
end

local function effectiveCap(state, record)
    return (state.capMinutes or 0) + (record.bonusMinutes or 0)
end

-- Hands every role the mod is holding back to its owner and zeroes the week.
local function startNewWeek(state, weekStart, d)
    for _, username in ipairs(state.order) do
        local record = state.players[username]
        if record ~= nil then
            if record.blockedRole ~= nil and record.blockedRole ~= "" then
                local ok, err = d.roles.setRole(username, record.blockedRole)
                if ok then
                    log(string.format("new week: unblocked %s, role back to %s",
                        username, record.blockedRole))
                    record.blockedRole = ""
                else
                    -- Keep the mark so the next sweep tries again.
                    log(string.format("new week: could not unblock %s: %s",
                        username, tostring(err)))
                end
            end
            record.minutes = 0
            record.bonusMinutes = 0
        end
    end
    state.weekStartEpoch = weekStart
    state.weekStart = d.clock.formatIso(weekStart)
    log("new week starting " .. tostring(state.weekStart))
end

-- Credits `seconds` of presence to everyone currently connected.
local function creditOnlinePlayers(state, seconds, d, exemptRoles)
    local changed = false
    if seconds <= 0 then return changed end

    for _, player in ipairs(d.online() or {}) do
        local username = player.username
        local isNewAccount = state.players[username] == nil
        local record = d.store.player(state, username)
        if isNewAccount then changed = true end

        if record.steamid == nil or record.steamid == "" then
            local steamid = d.roles.getSteamId(username)
            if steamid ~= nil and steamid ~= "" then
                record.steamid = steamid
                changed = true
            end
        end

        local blocked = record.blockedRole ~= nil and record.blockedRole ~= ""
        if not blocked then
            local roleName = d.roles.getRoleName(username)
            if roleName ~= nil and roleName ~= record.role then
                record.role = roleName
                changed = true
            end
        end

        if not blocked and not isExempt(username, record, exemptRoles) then
            local carried = (carriedSeconds[username] or 0) + seconds
            local wholeMinutes = math.floor(carried / SECONDS_PER_MINUTE)
            carriedSeconds[username] = carried - wholeMinutes * SECONDS_PER_MINUTE
            if wholeMinutes > 0 then
                record.minutes = (record.minutes or 0) + wholeMinutes
                changed = true
            end
        end
    end

    return changed
end

-- Brings the block state in line with the counters.
local function reconcileBlocks(state, d, exemptRoles)
    local changed = false
    local bannedRole = d.roles.bannedRoleName()

    for _, username in ipairs(state.order) do
        local record = state.players[username]
        if record ~= nil then
            local cap = effectiveCap(state, record)
            local exempt = isExempt(username, record, exemptRoles)
            local holdingRole = record.blockedRole ~= nil and record.blockedRole ~= ""

            if holdingRole then
                if exempt or (record.minutes or 0) < cap then
                    local roleToRestore = record.blockedRole
                    local ok, err = d.roles.setRole(username, roleToRestore)
                    if ok then
                        record.blockedRole = ""
                        record.role = roleToRestore
                        changed = true
                        log(string.format("unblocked %s (%d/%d minutes), role back to %s",
                            username, record.minutes or 0, cap, roleToRestore))
                    else
                        log(string.format("could not unblock %s: %s", username, tostring(err)))
                    end
                end
            elseif not exempt and (record.minutes or 0) >= cap then
                local currentRole = d.roles.getRoleName(username)
                if currentRole == nil then
                    log(string.format("cannot block %s: the server has no role for that account",
                        username))
                elseif tostring(currentRole):lower() == tostring(bannedRole):lower() then
                    -- Someone else banned this account; leave it to them.
                    log(string.format("%s is over the cap but already banned, leaving it alone",
                        username))
                elseif exemptRoles[tostring(currentRole):lower()] then
                    log(string.format("%s is over the cap but holds the exempt role %s",
                        username, currentRole))
                else
                    local ok, err = d.roles.setRole(username, bannedRole)
                    if ok then
                        record.blockedRole = currentRole
                        changed = true
                        log(string.format("blocked %s: %d/%d minutes this week, role %s -> %s",
                            username, record.minutes or 0, cap, currentRole, bannedRole))
                    else
                        log(string.format("could not block %s: %s", username, tostring(err)))
                    end
                end
            end
        end
    end

    return changed
end

local function rescueName(dataFile)
    local base = tostring(dataFile):gsub("%.txt$", "")
    return base .. ".broken.txt"
end

local function sweepBody(now)
    local d = dependencies()
    local exemptRoles = exemptRoleSet()

    local state, info = d.store.load(d.files, d.config.dataFile, d.config.capMinutes)
    local changed = info.created == true

    if info.corrupt then
        log(string.format("%s could not be read; keeping a copy in %s and starting a fresh one",
            d.config.dataFile, rescueName(d.config.dataFile)))
        pcall(d.files.write, d.files, rescueName(d.config.dataFile), info.raw)
        changed = true
    end
    for _, warning in ipairs(info.warnings or {}) do
        log(d.config.dataFile .. ": " .. warning)
    end

    local elapsed = 0
    if lastSweepEpoch ~= nil then
        elapsed = now - lastSweepEpoch
        if elapsed < 0 then elapsed = 0 end
        local maximum = d.config.maxCreditSecondsPerSweep or 3600
        if elapsed > maximum then
            log(string.format("clock moved %d seconds since the last sweep; crediting %d",
                elapsed, maximum))
            elapsed = maximum
        end
    end

    local weekStart = d.clock.getWeekStartEpoch(now)
    if weekStart ~= state.weekStartEpoch then
        startNewWeek(state, weekStart, d)
        changed = true
        -- Only the part of this sweep that falls inside the new week counts.
        local secondsInNewWeek = now - weekStart
        if elapsed > secondsInNewWeek then elapsed = secondsInNewWeek end
        carriedSeconds = {}
    end

    if creditOnlinePlayers(state, elapsed, d, exemptRoles) then changed = true end
    if reconcileBlocks(state, d, exemptRoles) then changed = true end

    if changed then
        local ok, err = d.store.save(d.files, d.config.dataFile, state, now)
        if not ok then
            log("could not write " .. tostring(d.config.dataFile) .. ": " .. tostring(err))
        end
    end

    if d.config.debug then
        log(string.format("sweep at %s credited %d seconds", d.clock.formatIso(now), elapsed))
    end
end

--- One full pass. Swallows every error: an event handler that raises can take
--- the rest of the server's Lua with it.
function PlayerTimerQuota.sweep(now)
    local ok, err = pcall(sweepBody, now)
    if not ok then
        log("sweep failed: " .. tostring(err))
    end
    lastSweepEpoch = now
    return ok
end

--- Runs a sweep if enough real time has passed. Returns true when it did.
function PlayerTimerQuota.tick()
    local d = dependencies()
    local now = d.clock.now()
    if lastSweepEpoch ~= nil and (now - lastSweepEpoch) < (d.config.sweepIntervalSeconds or 60) then
        return false
    end
    PlayerTimerQuota.sweep(now)
    return true
end

--- Called once when the server is up: anchors the clock so the time the server
--- spent down is never credited to anyone.
function PlayerTimerQuota.start()
    local d = dependencies()
    lastSweepEpoch = d.clock.now()
    carriedSeconds = {}
    if d.roles.clearCache then d.roles.clearCache() end
end

local function onServerStarted()
    PlayerTimerQuota.start()
    local d = dependencies()
    local state = PlayerTimerQuota.loadState()
    log(string.format("ready: cap %d minutes per week, week starting %s, %d accounts on record",
        state.capMinutes or 0, tostring(state.weekStart), #state.order))
    -- Apply the week reset and any pending block right away rather than waiting
    -- out the first interval.
    PlayerTimerQuota.sweep(d.clock.now())
end

local function onSaving()
    PlayerTimerQuota.sweep(dependencies().clock.now())
end

function PlayerTimerQuota.registerEvents()
    if registered then return end
    registered = true
    Events.OnServerStarted.Add(onServerStarted)
    Events.EveryOneMinute.Add(PlayerTimerQuota.tick)
    Events.OnServerStartSaving.Add(onSaving)
end

if isServer == nil or isServer() then
    PlayerTimerQuota.registerEvents()
end
