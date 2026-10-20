--[[
MaxTimeInServer - weekly connected-time quota.

Lives in shared/ because both sides need it: the server reads the quota rules,
the client needs the handshake names.

The settings an operator is expected to change - the weekly budget, who is
exempt from it, what a refused player is told, and how long they get to read it
- come from the server's sandbox options, declared in media/sandbox-options.txt.
The values below are only the fallbacks used when those are unavailable: in
single-player, or if the sandbox file failed to parse.

Sandbox options are read once when the server boots, so changing one takes a
server restart.
]]

local DEFAULT_CAP_MINUTES = 600
local DEFAULT_EXEMPT_ROLES = { "admin", "moderator", "gm" }
local DEFAULT_GRACE_SECONDS = 5
-- The weekday the week turns over on, 1 = Monday .. 7 = Sunday, which is the
-- contract MaxTimeInServerClock works in. 5 is Friday.
local DEFAULT_RESET_DAY = 5
-- How much warning a player gets, in minutes left, largest first. Empty means
-- they are told nothing until their time is up.
local DEFAULT_WARN_MINUTES = { 30, 5 }
local DAY_NAMES = {
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
}
-- An empty default means "say nothing of your own", and the client then shows
-- its own translated line instead. That way a server that never touches the
-- setting still speaks to each player in their language.
local DEFAULT_BLOCKED_MESSAGE = ""
-- Fallback for a server that will not say its name; see resolveDataFile.
local DEFAULT_DATA_FILE = "MaxTimeInServer.txt"

MaxTimeInServerConfig = {
    -- Set from the sandbox options; see applySandboxOptions below.
    capMinutes = DEFAULT_CAP_MINUTES,
    exemptRoles = { "admin", "moderator", "gm" },
    graceSeconds = DEFAULT_GRACE_SECONDS,
    blockedMessage = DEFAULT_BLOCKED_MESSAGE,
    resetDay = DEFAULT_RESET_DAY,
    warnMinutes = { 30, 5 },

    -- Not worth a server setting: changing either breaks the data file or the
    -- handshake rather than tuning anything.
    --
    -- The counter file is named after the server, because ~/Zomboid/Lua is
    -- shared by every server run out of one data folder while Server/ and
    -- Saves/ are not. Two servers writing one file would not interleave their
    -- counters, they would overwrite them: each sweep rewrites the whole file.
    -- The server fills this in at start-up from resolveDataFile.
    dataFile = DEFAULT_DATA_FILE,
    netModule = "MaxTimeInServer",
    netHello = "hello",
    netBlocked = "blocked",
    netAllowed = "allowed",
    netWarning = "warning",

    -- How long the lines over a player's head stay there. The engine's own
    -- default is 2.5 seconds, which is enough for "you picked up a nail" and
    -- not for a sentence with two numbers in it. Not a server setting: it is
    -- about reading speed, not about the quota.
    noteSeconds = 10,

    -- The greeting is retried until the server answers. A command sent before
    -- the connection can carry it is dropped without an error, so one attempt
    -- is not enough to rely on.
    helloRetrySeconds = 2,
    helloAttempts = 15,

    -- Real seconds between two sweeps. The sweep is driven by a game-time
    -- event, so it is checked far more often than this and returns early until
    -- the interval has passed. Every sweep re-reads the data file and rewrites
    -- it if anything changed, which is what makes a hand edit of a player's
    -- minutes take effect within one interval.
    sweepIntervalSeconds = 60,

    -- Upper bound on the time credited by a single sweep. Protects the counters
    -- from a clock step or a long server freeze.
    maxCreditSecondsPerSweep = 3600,

    -- Extra log lines on every sweep. Noisy; off by default.
    debug = false,
}

local function log(message)
    print("[MaxTimeInServer] " .. message)
end

-- Sandbox integers arrive as numbers, but a hand-edited SandboxVars.lua can
-- hold anything at all.
local function wholeNumberInRange(value, minimum, maximum, name)
    local number = tonumber(value)
    if number == nil then
        log("sandbox option " .. name .. " is not a number (" .. tostring(value) ..
            "), keeping the default")
        return nil
    end
    number = math.floor(number + 0.5)
    if number < minimum then
        log("sandbox option " .. name .. " is " .. tostring(number) ..
            ", which is below the minimum of " .. tostring(minimum) ..
            "; keeping the default")
        return nil
    end
    if maximum ~= nil and number > maximum then
        log("sandbox option " .. name .. " is " .. tostring(number) ..
            ", which is above the maximum of " .. tostring(maximum) ..
            "; keeping the default")
        return nil
    end
    return number
end

local function dayName(number)
    return DAY_NAMES[tonumber(number) or 0] or ("day " .. tostring(number))
end

-- Sandbox strings cannot hold a comma - the parser splits a block on them - so
-- every list setting is separated by semicolons.
local function splitList(text)
    local pieces = {}
    local raw = tostring(text or "")
    local cursor = 1
    while cursor <= #raw do
        local separator = string.find(raw, ";", cursor, true)
        local piece
        if separator == nil then
            piece = string.sub(raw, cursor)
            cursor = #raw + 1
        else
            piece = string.sub(raw, cursor, separator - 1)
            cursor = separator + 1
        end
        piece = (piece:gsub("^%s+", ""):gsub("%s+$", ""))
        if piece ~= "" then table.insert(pieces, piece) end
    end
    return pieces
end

local function parseRoleList(text)
    local roles = {}
    for _, piece in ipairs(splitList(text)) do
        table.insert(roles, string.lower(piece))
    end
    return roles
end

-- Minute marks, largest first and without repeats, so each one speaks once.
local function parseWarnMinutes(text)
    local seen = {}
    local marks = {}
    for _, piece in ipairs(splitList(text)) do
        local number = tonumber(piece)
        if number == nil or number < 1 then
            log("sandbox option WarnMinutes has \"" .. piece ..
                "\" in it, which is not a number of minutes; ignoring that one")
        else
            number = math.floor(number + 0.5)
            if not seen[number] then
                seen[number] = true
                table.insert(marks, number)
            end
        end
    end
    table.sort(marks, function(a, b) return a > b end)
    return marks
end

--- Reads the server's sandbox options over the defaults.
-- Always starts from the defaults, so calling it twice is the same as calling
-- it once. Returns true when a settings page was found.
function MaxTimeInServerConfig.applySandboxOptions(vars)
    MaxTimeInServerConfig.capMinutes = DEFAULT_CAP_MINUTES
    MaxTimeInServerConfig.graceSeconds = DEFAULT_GRACE_SECONDS
    MaxTimeInServerConfig.blockedMessage = DEFAULT_BLOCKED_MESSAGE
    MaxTimeInServerConfig.resetDay = DEFAULT_RESET_DAY
    MaxTimeInServerConfig.warnMinutes = {}
    for _, mark in ipairs(DEFAULT_WARN_MINUTES) do
        table.insert(MaxTimeInServerConfig.warnMinutes, mark)
    end
    MaxTimeInServerConfig.exemptRoles = {}
    for _, role in ipairs(DEFAULT_EXEMPT_ROLES) do
        table.insert(MaxTimeInServerConfig.exemptRoles, role)
    end

    if vars == nil then vars = SandboxVars end
    local page = nil
    if vars ~= nil then
        local ok, value = pcall(function() return vars.MaxTimeInServer end)
        if ok then page = value end
    end
    if page == nil then return false end

    if page.CapMinutes ~= nil then
        local minutes = wholeNumberInRange(page.CapMinutes, 1, nil, "CapMinutes")
        if minutes ~= nil then MaxTimeInServerConfig.capMinutes = minutes end
    end

    if page.GraceSeconds ~= nil then
        local seconds = wholeNumberInRange(page.GraceSeconds, 0, nil, "GraceSeconds")
        if seconds ~= nil then MaxTimeInServerConfig.graceSeconds = seconds end
    end

    -- An enum, so the engine and the admin panel both hand this over as the
    -- index of the day: 1 = Monday .. 7 = Sunday.
    if page.ResetDay ~= nil then
        local day = wholeNumberInRange(page.ResetDay, 1, 7, "ResetDay")
        if day ~= nil then MaxTimeInServerConfig.resetDay = day end
    end

    -- An empty message is a deliberate answer too: show the numbers alone.
    if page.BlockedMessage ~= nil then
        MaxTimeInServerConfig.blockedMessage =
            (tostring(page.BlockedMessage):gsub("^%s+", ""):gsub("%s+$", ""))
    end

    -- An empty list is a deliberate answer here too: say nothing until their
    -- time is up.
    if page.WarnMinutes ~= nil then
        MaxTimeInServerConfig.warnMinutes = parseWarnMinutes(page.WarnMinutes)
    end

    -- An empty list is a deliberate answer: limit everybody, operators too.
    if page.ExemptRoles ~= nil then
        MaxTimeInServerConfig.exemptRoles = parseRoleList(page.ExemptRoles)
    end

    return true
end

-- Keeps a server name to characters that are safe in a file name. A server
-- name already is one as far as the engine is concerned - Server/<name>.ini,
-- db/<name>.db - so this should never have anything to do, which is exactly
-- why it is cheap to keep.
local function fileSafe(name)
    local out = (tostring(name or ""):gsub("[^%w%._%-]", "_"))
    out = (out:gsub("^_+", ""):gsub("_+$", ""))
    if #out > 48 then out = string.sub(out, 1, 48) end
    return out
end

--- Names this server's own counter file, without storing it anywhere.
-- Returns the name and whether the server could be identified at all; the
-- caller is the one that owns a config table and assigns it. Unidentified, it
-- falls back to one shared name, which only costs anything if a second server
-- runs out of the same folder - and that is what the caller logs.
-- getServerName() is what the base game itself builds its per-server file
-- names from, inside an isServer() branch (media/lua/shared/SpawnRegions.lua).
function MaxTimeInServerConfig.resolveDataFile(serverName)
    if serverName == nil and getServerName ~= nil then
        local ok, value = pcall(getServerName)
        if ok then serverName = value end
    end

    local safe = fileSafe(serverName)
    if safe == "" then return DEFAULT_DATA_FILE, false end
    return "MaxTimeInServer_" .. safe .. ".txt", true
end

--- One line naming the settings that decide who may play, for the start-up log.
-- The refusal wording is deliberately not here: it changes nothing about who
-- gets in, it is already visible in the world's sandbox file, and when it is
-- left empty each client words the notice itself anyway.
function MaxTimeInServerConfig.describe()
    local roles = table.concat(MaxTimeInServerConfig.exemptRoles, ", ")
    if roles == "" then roles = "none" end
    local marks = table.concat(MaxTimeInServerConfig.warnMinutes, ", ")
    if marks == "" then
        marks = "no warning"
    else
        marks = "warning at " .. marks .. " minutes left"
    end
    return "cap " .. tostring(MaxTimeInServerConfig.capMinutes) ..
        " minutes per week resetting " .. dayName(MaxTimeInServerConfig.resetDay) ..
        "s at 00:00, exempt roles: " .. roles ..
        ", " .. marks ..
        ", " .. tostring(MaxTimeInServerConfig.graceSeconds) ..
        " seconds to read the notice"
end

--- The configured reset day in words, for a log line or a message.
function MaxTimeInServerConfig.resetDayName()
    return dayName(MaxTimeInServerConfig.resetDay)
end
