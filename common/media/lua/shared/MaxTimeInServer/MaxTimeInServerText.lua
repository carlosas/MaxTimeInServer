--[[
The mod's own strings, in the player's language.

Deliberately not using the engine's translation files. Those live at
media/lua/shared/Translate/<LANG>/<Name>.json, and every name there belongs to
the base game: a mod shipping one shadows the game's own file, which holds
hundreds of keys. Four lines of our own are not worth that risk, and a table
here is read by nothing but us.

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
    },
    ES = {
        used = "Has jugado %1 de tus %2 minutos de esta semana.",
        resets = "Tu tiempo se renueva el %1.",
        leaving = "Desconectando en %1 segundos.",
        limitReached = "Has alcanzado tu limite de juego semanal.",
    },
}

local FALLBACK = "EN"

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
