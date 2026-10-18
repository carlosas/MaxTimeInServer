--[[
MaxTimeInServer - weekly connected-time quota.

Lives in shared/ because both sides need it: the server reads the quota rules,
the client needs the handshake names.

The three settings an operator is expected to change - the weekly budget, who is
exempt from it, and how long a refused player gets to read the notice - come
from the server's sandbox options, declared in media/sandbox-options.txt. The
values below are only the fallbacks used when those are unavailable: in
single-player, or if the sandbox file failed to parse.

Sandbox options are read once when the server boots, so changing one takes a
server restart.
]]

local DEFAULT_CAP_MINUTES = 600
local DEFAULT_EXEMPT_ROLES = { "admin", "moderator", "gm" }
local DEFAULT_GRACE_SECONDS = 12

MaxTimeInServerConfig = {
    -- Set from the sandbox options; see applySandboxOptions below.
    capMinutes = DEFAULT_CAP_MINUTES,
    exemptRoles = { "admin", "moderator", "gm" },
    graceSeconds = DEFAULT_GRACE_SECONDS,

    -- Not worth a server setting: changing either breaks the data file or the
    -- handshake rather than tuning anything.
    dataFile = "MaxTimeInServer.txt",
    netModule = "MaxTimeInServer",
    netHello = "hello",
    netBlocked = "blocked",

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
local function wholeNumberAtLeast(value, minimum, name)
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
    return number
end

local function parseRoleList(text)
    local roles = {}
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
        piece = string.lower((piece:gsub("^%s+", ""):gsub("%s+$", "")))
        if piece ~= "" then table.insert(roles, piece) end
    end
    return roles
end

--- Reads the server's sandbox options over the defaults.
-- Always starts from the defaults, so calling it twice is the same as calling
-- it once. Returns true when a settings page was found.
function MaxTimeInServerConfig.applySandboxOptions(vars)
    MaxTimeInServerConfig.capMinutes = DEFAULT_CAP_MINUTES
    MaxTimeInServerConfig.graceSeconds = DEFAULT_GRACE_SECONDS
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
        local minutes = wholeNumberAtLeast(page.CapMinutes, 1, "CapMinutes")
        if minutes ~= nil then MaxTimeInServerConfig.capMinutes = minutes end
    end

    if page.GraceSeconds ~= nil then
        local seconds = wholeNumberAtLeast(page.GraceSeconds, 0, "GraceSeconds")
        if seconds ~= nil then MaxTimeInServerConfig.graceSeconds = seconds end
    end

    -- An empty list is a deliberate answer: limit everybody, operators too.
    if page.ExemptRoles ~= nil then
        MaxTimeInServerConfig.exemptRoles = parseRoleList(page.ExemptRoles)
    end

    return true
end

--- One line naming the settings in force, for the start-up log.
function MaxTimeInServerConfig.describe()
    local roles = table.concat(MaxTimeInServerConfig.exemptRoles, ", ")
    if roles == "" then roles = "none" end
    return "cap " .. tostring(MaxTimeInServerConfig.capMinutes) ..
        " minutes per week, exempt roles: " .. roles ..
        ", " .. tostring(MaxTimeInServerConfig.graceSeconds) ..
        " seconds to read the notice"
end
