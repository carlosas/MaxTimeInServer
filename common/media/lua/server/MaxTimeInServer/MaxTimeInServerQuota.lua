--[[
The engine: counts connected time, and answers whether an account may play.

Counting is driven by EveryOneMinute, which the engine fires on game time
(roughly every 7.5 real seconds on this server, and not at all while the server
is empty with PauseEmpty=true). The interval is therefore enforced against
getTimestamp() rather than against the event, and nothing is credited for time
the server spent empty or down.

Every sweep re-reads the data file and rewrites it when something changed, which
is what lets the operator edit minutes, bonusMinutes, exempt or capMinutes by
hand and have it take effect within one interval.
]]

MaxTimeInServerQuota = MaxTimeInServerQuota or {}

local SECONDS_PER_MINUTE = 60
local SECONDS_PER_WEEK = 7 * 24 * 3600

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

local deps = nil
local lastSweepEpoch = nil
local carriedSeconds = {}        -- username -> seconds not yet worth a minute

local function defaultDeps()
    return {
        config = MaxTimeInServerConfig,
        clock = MaxTimeInServerClock,
        store = MaxTimeInServerStore,
        files = pzFiles,
        players = MaxTimeInServerPlayers,
    }
end

local function log(message)
    print("[MaxTimeInServer] " .. message)
end

--- True only on a machine acting as the server for other people.
-- Checked when an event fires rather than when this file loads: the engine sets
-- GameServer.server / GameClient.client around the Lua load, so a load-time
-- check is not something to rely on.
local function actingAsServer()
    if isClient ~= nil and isClient() then return false end
    return isServer == nil or isServer()
end

--- Swaps in alternative collaborators and forgets all in-memory progress.
function MaxTimeInServerQuota.configure(overrides)
    deps = defaultDeps()
    for key, value in pairs(overrides or {}) do deps[key] = value end
    lastSweepEpoch = nil
    carriedSeconds = {}
end

local function dependencies()
    if deps == nil then deps = defaultDeps() end
    return deps
end

--- Reads the data file and returns (state, info).
function MaxTimeInServerQuota.loadState()
    local d = dependencies()
    return d.store.load(d.files, d.config.dataFile, d.config.capMinutes)
end

local function exemptRoleSet()
    local set = {}
    for _, name in ipairs(dependencies().config.exemptRoles or {}) do
        set[string.lower(tostring(name))] = true
    end
    return set
end

local function roleIsExempt(roleName, exemptRoles)
    if roleName == nil or roleName == "" then return false end
    return exemptRoles[string.lower(tostring(roleName))] == true
end

--- Whether `username` may play, and the numbers to tell them if not.
-- Never raises, and errs towards letting people in: a quota that cannot read
-- its own file must not lock the server.
function MaxTimeInServerQuota.verdict(username, roleName)
    local d = dependencies()
    local exemptRoles = exemptRoleSet()

    local ok, result = pcall(function()
        local state = d.store.load(d.files, d.config.dataFile, d.config.capMinutes)
        local now = d.clock.now()
        local weekStart = d.clock.getWeekStartEpoch(now)
        local record = state.players[username]

        local minutes, bonus, flagged = 0, 0, false
        if record ~= nil then
            flagged = record.exempt == true
            -- Counters from a week that has already rolled over are spent, not
            -- owed: the next sweep will zero them anyway.
            if state.weekStartEpoch == weekStart then
                minutes = record.minutes or 0
                bonus = record.bonusMinutes or 0
            end
        end

        local cap = (state.capMinutes or d.config.capMinutes) + bonus
        local exempt = flagged or roleIsExempt(roleName, exemptRoles)
        local resetsAtEpoch = weekStart + SECONDS_PER_WEEK

        return {
            allowed = exempt or minutes < cap,
            exempt = exempt,
            minutes = minutes,
            cap = cap,
            weekStartEpoch = weekStart,
            resetsAtEpoch = resetsAtEpoch,
            resetsAt = d.clock.formatIso(resetsAtEpoch),
        }
    end)

    if not ok then
        log("could not judge " .. tostring(username) .. ", letting them in: " .. tostring(result))
        return { allowed = true, exempt = false, minutes = 0,
                 cap = d.config.capMinutes, resetsAt = nil }
    end
    return result
end

local function startNewWeek(state, weekStart, d)
    for _, username in ipairs(state.order) do
        local record = state.players[username]
        if record ~= nil then
            record.minutes = 0
            record.bonusMinutes = 0
        end
    end
    state.weekStartEpoch = weekStart
    state.weekStart = d.clock.formatIso(weekStart)
    log("new week starting " .. tostring(state.weekStart))
end

local function creditOnlinePlayers(state, seconds, d, exemptRoles)
    local changed = false

    for _, entry in ipairs(d.players.online() or {}) do
        local username = entry.username
        local isNewAccount = state.players[username] == nil
        local record = d.store.player(state, username)
        if isNewAccount then changed = true end

        if entry.role ~= nil and entry.role ~= "" and entry.role ~= record.role then
            record.role = entry.role
            changed = true
        end

        local exempt = record.exempt == true or roleIsExempt(entry.role, exemptRoles)
        if not exempt and seconds > 0 then
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
        log(tostring(d.config.dataFile) .. " could not be read; keeping a copy in " ..
            rescueName(d.config.dataFile) .. " and starting a fresh one")
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
            log("clock moved " .. tostring(elapsed) ..
                " seconds since the last sweep; crediting " .. tostring(maximum))
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

    if changed then
        local ok, err = d.store.save(d.files, d.config.dataFile, state, now)
        if not ok then
            log("could not write " .. tostring(d.config.dataFile) .. ": " .. tostring(err))
        end
    end

    if d.config.debug then
        log("sweep at " .. tostring(d.clock.formatIso(now)) ..
            " credited " .. tostring(elapsed) .. " seconds")
    end
end

--- One full pass. Swallows every error: an event handler that raises can take
--- the rest of the server's Lua with it.
function MaxTimeInServerQuota.sweep(now)
    local ok, err = pcall(sweepBody, now)
    if not ok then log("sweep failed: " .. tostring(err)) end
    lastSweepEpoch = now
    return ok
end

--- Runs a sweep if enough real time has passed. Returns true when it did.
-- EveryOneMinute fires on clients too, so this checks which side it is on.
function MaxTimeInServerQuota.tick()
    if not actingAsServer() then return false end
    local d = dependencies()
    local now = d.clock.now()
    if lastSweepEpoch ~= nil and (now - lastSweepEpoch) < (d.config.sweepIntervalSeconds or 60) then
        return false
    end
    MaxTimeInServerQuota.sweep(now)
    return true
end

--- Anchors the clock, so the time the server spent down is never credited.
function MaxTimeInServerQuota.start()
    local d = dependencies()
    lastSweepEpoch = d.clock.now()
    carriedSeconds = {}
end

-- Every handler says it ran and reports its own failure. An error escaping an
-- event handler is swallowed by the engine, and a mod that silently does
-- nothing looks exactly like one that is working.
local function onServerStarted()
    log("OnServerStarted fired (isServer=" .. tostring(isServer ~= nil and isServer()) ..
        " isClient=" .. tostring(isClient ~= nil and isClient()) ..
        " store=" .. tostring(MaxTimeInServerStore ~= nil) ..
        " config=" .. tostring(MaxTimeInServerConfig ~= nil) .. ")")

    if not actingAsServer() then
        log("not acting as the server, standing down")
        return
    end

    local ok, err = pcall(function()
        MaxTimeInServerQuota.start()
        local d = dependencies()
        local state = MaxTimeInServerQuota.loadState()
        log("ready: cap " .. tostring(state.capMinutes or 0) ..
            " minutes per week, week starting " .. tostring(state.weekStart) ..
            ", " .. tostring(#state.order) .. " accounts on record")
        -- Apply the week reset right away rather than waiting out the interval.
        MaxTimeInServerQuota.sweep(d.clock.now())
    end)
    if not ok then log("start-up failed: " .. tostring(err)) end
end

local function onSaving()
    if not actingAsServer() then return end
    local ok, err = pcall(function()
        MaxTimeInServerQuota.sweep(dependencies().clock.now())
    end)
    if not ok then log("save-time sweep failed: " .. tostring(err)) end
end

function MaxTimeInServerQuota.registerEvents()
    -- The guard is keyed to the identity of the event object, not to a boolean.
    -- A plain flag kept on this table survives a Lua reload while the Events
    -- table does not, which would leave the mod loaded, flagged as registered,
    -- and attached to event objects nobody triggers any more.
    if MaxTimeInServerQuota.registeredOn == Events.OnServerStarted then return end
    MaxTimeInServerQuota.registeredOn = Events.OnServerStarted
    Events.OnServerStarted.Add(onServerStarted)
    Events.EveryOneMinute.Add(MaxTimeInServerQuota.tick)
    Events.OnServerStartSaving.Add(onSaving)
end

-- Registered every time this file is executed, whatever side we are on:
-- OnServerStarted and OnServerStartSaving only ever fire on a server, and
-- tick() checks the side itself, so there is nothing to gain from guessing at
-- load time - and plenty to lose if the guess is wrong.
MaxTimeInServerQuota.registerEvents()

-- One line per boot, so a silent mod is never mistaken for a working one. The
-- side flags are printed because they are not reliable this early: that is why
-- nothing here is decided at load time.
print("[MaxTimeInServer] server half loaded (isServer=" ..
    tostring(isServer ~= nil and isServer()) ..
    " isClient=" .. tostring(isClient ~= nil and isClient()) ..
    " config=" .. tostring(MaxTimeInServerConfig ~= nil) .. ")")
