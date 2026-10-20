local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

-- Everything a player or an operator reads is declared in one place and worded
-- in another: the settings in sandbox-options.txt, the mod's own lines in the
-- Lua table, and the words for both in one file per language. A key missing
-- from one language shows up as a raw key in somebody's settings page, or as a
-- bare number where a weekday should be, and nothing else complains.

S.loadModules({ "shared/MaxTimeInServer/MaxTimeInServerText.lua" })

local OPTIONS_FILE = "common/media/sandbox-options.txt"
local TRANSLATE = "common/media/lua/shared/Translate"

-- Whatever the mod actually ships, rather than a list that goes stale.
local function shippedLanguages()
    local codes = {}
    local pipe = io.popen("ls " .. TRANSLATE .. " 2>/dev/null")
    if pipe ~= nil then
        for line in pipe:lines() do
            local code = (line:gsub("%s+$", ""))
            if code ~= "" then table.insert(codes, code) end
        end
        pipe:close()
    end
    return codes
end

local LANGUAGES = shippedLanguages()

local function read(path)
    local handle = io.open(path, "r")
    if handle == nil then error("cannot open " .. path) end
    local text = handle:read("*a")
    handle:close()
    return text
end

local function translationPath(language)
    return TRANSLATE .. "/" .. language .. "/Sandbox.json"
end

-- Every `option Name { ... }` block, as a table of its properties.
local function declaredOptions(text)
    local options = {}
    local cursor = 1
    while true do
        local blockStart, braceStart, name = string.find(text, "option%s+([%w%.]+)%s*{", cursor)
        if blockStart == nil then break end
        local blockEnd = string.find(text, "}", braceStart, true)
        if blockEnd == nil then error("unterminated option block for " .. name) end
        local body = string.sub(text, braceStart + 1, blockEnd - 1)
        local props = {}
        for key, value in string.gmatch(body, "(%w+)%s*=%s*([^,\n]*)") do
            props[key] = (value:gsub("^%s+", ""):gsub("%s+$", ""))
        end
        options[name] = props
        cursor = blockEnd + 1
    end
    return options
end

-- Both prefixes: Sandbox_ for what the settings page shows, MaxTimeInServer_
-- for the lines the mod says to a player.
local function jsonKeys(text)
    local keys = {}
    for key in string.gmatch(text, '"([%w_]+)"%s*:') do keys[key] = true end
    return keys
end

local optionsText = read(OPTIONS_FILE)
local options = declaredOptions(optionsText)
local translations = {}
for _, language in ipairs(LANGUAGES) do
    translations[language] = jsonKeys(read(translationPath(language)))
end

-- Keys the declarations call for: a label and a tooltip each, plus one label
-- per value of an enum, plus the page the options sit on.
local function expectedKeys()
    local expected = {}
    for name, props in pairs(options) do
        local base = "Sandbox_" .. (props.translation or name:gsub("%.", "_"))
        expected[base] = true
        expected[base .. "_tooltip"] = true
        if props.page ~= nil then expected["Sandbox_" .. props.page] = true end
        if props.type == "enum" then
            local values = "Sandbox_" .. (props.valueTranslation or props.translation or name)
            for index = 1, tonumber(props.numValues) do
                expected[values .. "_option" .. index] = true
            end
        end
    end
    -- And every line the mod says to a player. The Lua table is the English
    -- fallback and therefore the list of what each language has to carry.
    for _, key in ipairs(MaxTimeInServerText.keys()) do
        expected["MaxTimeInServer_" .. key] = true
    end
    return expected
end

H.test("the mod ships the languages the game has, and no stray folder", function()
    H.assertTrue(#LANGUAGES >= 20, "found " .. #LANGUAGES .. " languages")
    local seen = {}
    for _, code in ipairs(LANGUAGES) do seen[code] = true end
    for _, code in ipairs({ "EN", "ES", "FR", "DE", "RU", "JP", "CN", "PTBR", "ES_MX" }) do
        H.assertTrue(seen[code], "ships " .. code)
    end
end)

H.test("the options file declares something to begin with", function()
    local count = 0
    for _ in pairs(options) do count = count + 1 end
    H.assertTrue(count >= 5, "found " .. count .. " options")
end)

H.test("every enum says how many values it has and defaults inside that range", function()
    for name, props in pairs(options) do
        if props.type == "enum" then
            local values = tonumber(props.numValues)
            H.assertTrue(values ~= nil and values > 1, name .. " numValues")
            local default = tonumber(props.default)
            H.assertTrue(default ~= nil and default >= 1 and default <= values,
                name .. " default " .. tostring(props.default) .. " within 1.." .. tostring(values))
            H.assertTrue(props.valueTranslation ~= nil, name .. " names its value translation")
        end
    end
end)

H.test("every option has a name and a tooltip in every language we ship", function()
    for _, language in ipairs(LANGUAGES) do
        for key in pairs(expectedKeys()) do
            H.assertTrue(translations[language][key],
                language .. " is missing " .. key)
        end
    end
end)

H.test("and ships no label for a setting that does not exist", function()
    local expected = expectedKeys()
    for _, language in ipairs(LANGUAGES) do
        for key in pairs(translations[language]) do
            H.assertTrue(expected[key], language .. " has a stray " .. key)
        end
    end
end)

H.test("every language carries exactly the same keys as English", function()
    for _, language in ipairs(LANGUAGES) do
        for key in pairs(translations.EN) do
            H.assertTrue(translations[language][key], language .. " is missing " .. key)
        end
        for key in pairs(translations[language]) do
            H.assertTrue(translations.EN[key], language .. " has a stray " .. key)
        end
    end
end)

H.run("sandbox declaration")
