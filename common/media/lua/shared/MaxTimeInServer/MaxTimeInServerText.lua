--[[
The mod's own strings, in the player's language.

Every line the mod says to a player, in whatever language they are reading the
game in.

The translations themselves live in media/lua/shared/Translate/<LANG>/Sandbox.json,
one file per language, keyed MaxTimeInServer_<name>. That is the engine's own
path - a mod's translations are read when the client scans the mods - so the
text is UTF-8 in a format the game already renders, rather than a Lua literal
whose encoding nobody has measured.

The table below is the last resort: what a player reads if the engine cannot
answer, which is why it is English, complete, and covered by a test. Spanish is
kept beside it because this mod was written for a Spanish server and it costs
four lines.

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
        played = "You have played %1 minutes this week (limit %2).",
        -- %1 is the day of the month, %2 the name of the month, %3 the day
        -- of the week. Each language puts them in its own order.
        date = "%2 %1",
        dateWithDay = "%3 %2 %1",
        day1 = "Monday",
        day2 = "Tuesday",
        day3 = "Wednesday",
        day4 = "Thursday",
        day5 = "Friday",
        day6 = "Saturday",
        day7 = "Sunday",
        month1 = "January",
        month2 = "February",
        month3 = "March",
        month4 = "April",
        month5 = "May",
        month6 = "June",
        month7 = "July",
        month8 = "August",
        month9 = "September",
        month10 = "October",
        month11 = "November",
        month12 = "December",
    },
    ES = {
        used = "Has jugado %1 de tus %2 minutos de esta semana.",
        resets = "Tu tiempo se renueva el %1.",
        leaving = "Desconectando en %1 segundos.",
        limitReached = "Has alcanzado tu limite de juego semanal.",
        timeUp = "Se te ha acabado el tiempo de esta semana.",
        warning = "Te quedan %1 minutos de juego esta semana.",
        played = "Has jugado %1 minutos esta semana (máximo %2).",
        date = "%1 de %2",
        dateWithDay = "%3 %1 de %2",
        day1 = "lunes",
        day2 = "martes",
        day3 = "miercoles",
        day4 = "jueves",
        day5 = "viernes",
        day6 = "sabado",
        day7 = "domingo",
        month1 = "enero",
        month2 = "febrero",
        month3 = "marzo",
        month4 = "abril",
        month5 = "mayo",
        month6 = "junio",
        month7 = "julio",
        month8 = "agosto",
        month9 = "septiembre",
        month10 = "octubre",
        month11 = "noviembre",
        month12 = "diciembre",
    },
}

local FALLBACK = "EN"

-- Where the engine keeps our lines, so they cannot collide with anyone else's.
local ENGINE_PREFIX = "MaxTimeInServer_"

-- Codes that read the same language as far as these lines are concerned. The
-- game ships four Spanish variants and a player set to any of them would
-- otherwise fall back to English with Spanish sitting right there.
local ALIASES = {
    AR = "ES", ES_CL = "ES", ES_MX = "ES",
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
    -- The engine knows every language the mod ships a file for, and which one
    -- this player is reading. Ask it first.
    if getTextOrNull ~= nil then
        local ok, value = pcall(getTextOrNull, ENGINE_PREFIX .. key)
        if ok and value ~= nil and tostring(value) ~= "" then return tostring(value) end
    end

    local code = MaxTimeInServerText.language()
    code = ALIASES[code] or code
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
--- A timestamp as a player would say it: "Friday October 23".
-- The month's name is the mod's own rather than the base game's: the game's
-- Farming_Month_1 to 12 are shifted by one in several languages - French names
-- October "Novembre", and so do Chinese, Dutch, Portuguese and Hungarian - so
-- reusing them would put the wrong month in front of a player. Anything that
-- cannot be read comes back untouched: a stamp is ugly, a blank line is worse.
function MaxTimeInServerText.date(stamp, weekday)
    local text = tostring(stamp or "")
    local _, _, _, month, day = string.find(text, "(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if day == nil then return text end

    local number = tonumber(month)
    if number == nil or number < 1 or number > 12 then return text end
    local name = MaxTimeInServerText.format("month" .. tostring(math.floor(number)))

    local dayNumber = tonumber(weekday)
    if dayNumber ~= nil and dayNumber >= 1 and dayNumber <= 7 then
        return MaxTimeInServerText.format("dateWithDay", tostring(tonumber(day)), name,
            MaxTimeInServerText.format("day" .. tostring(math.floor(dayNumber))))
    end
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
