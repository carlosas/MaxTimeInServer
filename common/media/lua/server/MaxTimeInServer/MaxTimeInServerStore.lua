--[[
Reads and writes <Zomboid>/Lua/MaxTimeInServer.txt.

The format is deliberately plain so the server owner can edit it while the
server runs: a header of key=value lines, then one [username] section per
player. Keys the mod does not know are carried through untouched, and nothing
in here is allowed to raise - a hand-edited file must never take the mod down.
]]

MaxTimeInServerStore = MaxTimeInServerStore or {}

local KNOWN_HEADER = {
    version = true, capMinutes = true, weekStart = true,
    weekStartEpoch = true, savedAt = true,
}

local KNOWN_RECORD = {
    role = true, minutes = true, bonusMinutes = true, exempt = true,
}

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function toBoolean(value)
    return value:lower() == "true"
end

--- A brand new, empty state seeded with the configured cap.
function MaxTimeInServerStore.newState(capMinutes)
    return {
        version = 1,
        capMinutes = capMinutes,
        weekStart = "",
        weekStartEpoch = 0,
        savedAt = "",
        players = {},
        order = {},
        extra = {},
        extraOrder = {},
        warnings = {},
    }
end

--- The record for `username`, created with safe defaults if it is new.
function MaxTimeInServerStore.player(state, username)
    local record = state.players[username]
    if record then return record end
    record = {
        role = "",
        minutes = 0,
        bonusMinutes = 0,
        exempt = false,
        extra = {},
        extraOrder = {},
    }
    state.players[username] = record
    table.insert(state.order, username)
    return record
end

local function setExtra(target, key, value)
    if target.extra[key] == nil then table.insert(target.extraOrder, key) end
    target.extra[key] = value
end

local function parseNumber(state, where, key, value)
    local number = tonumber(value)
    if number == nil then
        -- Plain concatenation: the engine's Lua is picky about format specifiers
        -- and this warning must never be the thing that breaks the parser.
        table.insert(state.warnings,
            tostring(where) .. ": " .. tostring(key) .. "=\"" .. tostring(value) ..
            "\" is not a number, using 0")
        return 0
    end
    return math.floor(number)
end

--- Parses the file's text. Always returns a usable state.
function MaxTimeInServerStore.parse(text, defaultCapMinutes)
    local state = MaxTimeInServerStore.newState(defaultCapMinutes or MaxTimeInServerConfig.capMinutes)
    state.version = nil
    local current = nil        -- nil while still in the header
    local currentName = nil
    local recognised = 0

    -- Split on newlines with find/sub rather than a pattern. The engine runs
    -- Kahlua, not PUC-Lua, and there gmatch("[^\n]*") never advances past the
    -- empty match it makes at the end of every line: it spins forever and takes
    -- the whole server down with it, silently, because the hang is inside an
    -- event handler. Any pattern that can match the empty string is a trap here.
    local raw = tostring(text or "")
    local length = #raw
    local cursor = 1
    while cursor <= length do
        local rawLine
        local newline = string.find(raw, "\n", cursor, true)
        if newline == nil then
            rawLine = string.sub(raw, cursor)
            cursor = length + 1
        else
            rawLine = string.sub(raw, cursor, newline - 1)
            cursor = newline + 1
        end

        local line = trim((rawLine:gsub("\r", "")))
        if line == "" or line:sub(1, 1) == "#" or line:sub(1, 1) == ";" then
            -- comment or blank, nothing to do
        else
            local section = line:match("^%[(.*)%]$")
            if section then
                currentName = trim(section)
                if currentName ~= "" then
                    current = MaxTimeInServerStore.player(state, currentName)
                    recognised = recognised + 1
                else
                    current = nil
                end
            else
                local key, value = line:match("^([^=]+)=(.*)$")
                if key then
                    key, value = trim(key), trim(value)
                    if current then
                        if key == "minutes" or key == "bonusMinutes" then
                            current[key] = parseNumber(state, currentName, key, value)
                        elseif key == "exempt" then
                            current.exempt = toBoolean(value)
                        elseif KNOWN_RECORD[key] then
                            current[key] = value
                        else
                            setExtra(current, key, value)
                        end
                    else
                        if key == "capMinutes" or key == "weekStartEpoch" or key == "version" then
                            state[key] = parseNumber(state, "header", key, value)
                            recognised = recognised + 1
                        elseif KNOWN_HEADER[key] then
                            state[key] = value
                            recognised = recognised + 1
                        else
                            setExtra(state, key, value)
                        end
                    end
                end
            end
        end
    end

    state.recognised = recognised
    if state.capMinutes == nil then
        state.capMinutes = defaultCapMinutes or MaxTimeInServerConfig.capMinutes
    end
    if state.weekStartEpoch == nil then state.weekStartEpoch = 0 end
    return state
end

--- Renders the state back to text. Player order is preserved.
function MaxTimeInServerStore.serialize(state)
    local out = {}
    local function put(line) table.insert(out, line) end

    put("# MaxTimeInServer - weekly connected-time quota. Minutes are real minutes.")
    put("# A week runs from Monday 00:00:00 to Sunday 23:59:59, server timezone.")
    put("# Safe to edit while the server runs: changes are picked up within a minute.")
    put("#   minutes       real minutes spent on the server this week")
    put("#   bonusMinutes  extra allowance for this week only (added to capMinutes)")
    put("#   exempt        true = never counted, never blocked")
    put("#   role          informational: the role the account was last seen holding")
    put("version=" .. tostring(state.version or 1))
    put("capMinutes=" .. tostring(state.capMinutes or 0))
    put("weekStart=" .. tostring(state.weekStart or ""))
    put("weekStartEpoch=" .. tostring(state.weekStartEpoch or 0))
    put("savedAt=" .. tostring(state.savedAt or ""))
    for _, key in ipairs(state.extraOrder or {}) do
        put(key .. "=" .. tostring(state.extra[key]))
    end

    for _, username in ipairs(state.order) do
        local record = state.players[username]
        if record then
            put("")
            put("[" .. username .. "]")
            put("role=" .. tostring(record.role or ""))
            put("minutes=" .. tostring(record.minutes or 0))
            put("bonusMinutes=" .. tostring(record.bonusMinutes or 0))
            put("exempt=" .. tostring(record.exempt and true or false))
            for _, key in ipairs(record.extraOrder or {}) do
                put(key .. "=" .. tostring(record.extra[key]))
            end
        end
    end

    return table.concat(out, "\n") .. "\n"
end

--- Loads the data file. Returns (state, info); never raises.
-- info.created is true when there was no file, info.corrupt when there was one
-- but nothing in it could be understood (info.raw then holds the original text).
function MaxTimeInServerStore.load(files, name, capMinutes)
    local ok, text = pcall(files.read, files, name)
    if not ok then text = nil end

    if text == nil or trim(text) == "" then
        local state = MaxTimeInServerStore.newState(capMinutes)
        return state, { created = true, corrupt = false }
    end

    local parsedOk, state = pcall(MaxTimeInServerStore.parse, text, capMinutes)
    if not parsedOk or state == nil or (state.recognised or 0) == 0 then
        local fallback = MaxTimeInServerStore.newState(capMinutes)
        return fallback, { created = false, corrupt = true, raw = text }
    end

    if state.version == nil then state.version = 1 end
    return state, { created = false, corrupt = false, warnings = state.warnings }
end

--- Writes the data file. Returns true on success, nil plus a message otherwise.
function MaxTimeInServerStore.save(files, name, state, nowEpoch)
    state.savedAt = MaxTimeInServerClock.formatIso(nowEpoch)
    local ok, result = pcall(files.write, files, name, MaxTimeInServerStore.serialize(state))
    if not ok then return nil, tostring(result) end
    if result == false then return nil, "writer refused " .. tostring(name) end
    return true
end
