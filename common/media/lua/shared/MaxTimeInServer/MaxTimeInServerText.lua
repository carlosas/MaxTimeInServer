--[[
The mod's own strings, in the player's language.

These are the lines the mod says to a player, so they are kept here rather than
in the engine's translation files: a mod's Translate/<LANG>/Sandbox.json is read
by the client's mod scan, which is right for the names of settings, while this
table is read by our own code wherever it runs and is covered by a test.

Adding a language is one block below. Anything missing falls back to English,
per key, so a half-finished translation degrades to English rather than to a
blank line. Language codes are what Translator.getLanguage():name() returns.
]]

MaxTimeInServerText = MaxTimeInServerText or {}

-- %1, %2 ... are replaced in order by the values passed to format().
local STRINGS = {
    EN = {
        used = "You have used %1 of your %2 minutes this week.",
        resets = "Your allowance resets on %1.",
        leaving = "Disconnecting in %1 seconds.",
        limitReached = "Weekly play limit reached.",
        timeUp = "Your time for this week is up.",
        warning = "%1 minutes of play left this week.",
        -- %1 is the day of the month, %2 the name of the month.
        date = "%2 %1",
    },
    ES = {
        used = "Has jugado %1 de tus %2 minutos de esta semana.",
        resets = "Tu tiempo se renueva el %1.",
        leaving = "Desconectando en %1 segundos.",
        limitReached = "Has alcanzado tu limite de juego semanal.",
        timeUp = "Se te ha acabado el tiempo de esta semana.",
        warning = "Te quedan %1 minutos de juego esta semana.",
        date = "%1 de %2",
    },
}

local FALLBACK = "EN"

-- Only reached when the base game cannot name a month: see date() below.
local MONTHS_EN = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}

--- The language the player is reading the game in, as a code like "ES".
function MaxTimeInServerText.language()
    local ok, name = pcall(function()
        return Translator.getLanguage():name()
    end)
    if ok and name ~= nil and name ~= "" then return tostring(name) end
    return FALLBACK
end

local function lookup(key)
    local code = MaxTimeInServerText.language()
    local table_ = STRINGS[code]
    if table_ ~= nil and table_[key] ~= nil then return table_[key] end
    return STRINGS[FALLBACK][key]
end

--- The string for `key`, with %1, %2 ... replaced by the values given.
-- Never raises and never returns nil: an unknown key comes back as itself, so a
-- mistake shows up on screen as a name rather than as nothing at all.
function MaxTimeInServerText.format(key, ...)
    local text = lookup(key)
    if text == nil then return tostring(key) end

    local values = { ... }
    local out = tostring(text)
    for index = 1, #values do
        -- "%%" .. index matches the two characters %1, with no pattern that
        -- could match the empty string: see the note in the store about Kahlua.
        out = string.gsub(out, "%%" .. tostring(index), tostring(values[index]))
    end
    return out
end

--- Every language this mod carries, for tests and for the log.
--- A timestamp as a player would say it: "October 23", "23 de Octubre".
-- The month's name comes from the base game, which has one in every language
-- it ships (Farming_Month_1 to 12), so this reads properly for a player whose
-- language the mod itself does not speak. Anything that cannot be read comes
-- back untouched: a stamp is ugly, a blank line is worse.
function MaxTimeInServerText.date(stamp)
    local text = tostring(stamp or "")
    local _, _, _, month, day = string.find(text, "(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if day == nil then return text end

    local number = tonumber(month)
    local name = nil
    if getTextOrNull ~= nil and number ~= nil then
        local ok, value = pcall(getTextOrNull, "Farming_Month_" .. tostring(number))
        if ok and value ~= nil and tostring(value) ~= "" then name = tostring(value) end
    end
    if name == nil and number ~= nil then name = MONTHS_EN[number] end
    if name == nil then return text end

    return MaxTimeInServerText.format("date", tostring(tonumber(day)), name)
end

function MaxTimeInServerText.languages()
    local codes = {}
    for code in pairs(STRINGS) do table.insert(codes, code) end
    table.sort(codes)
    return codes
end

--- The keys a language has to provide, taken from the fallback.
function MaxTimeInServerText.keys()
    local keys = {}
    for key in pairs(STRINGS[FALLBACK]) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end
