local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

S.loadModules({ "shared/MaxTimeInServer/MaxTimeInServerText.lua" })

local T = MaxTimeInServerText

local function speaking(code)
    if code == nil then
        _G.Translator = nil
    else
        _G.Translator = { getLanguage = function() return { name = function() return code end } end }
    end
end

H.test("every language carries every key", function()
    -- A half-finished translation should be caught here, not on a player's
    -- screen as a missing line.
    local expected = table.concat(T.keys(), ",")
    for _, code in ipairs(T.languages()) do
        speaking(code)
        for _, key in ipairs(T.keys()) do
            local text = T.format(key)
            H.assertTrue(text ~= nil and text ~= "" and text ~= key,
                code .. " has " .. key)
        end
    end
    H.assertTrue(#expected > 0, "there are keys to check")
end)

H.test("the player's language is used when we have it", function()
    speaking("ES")
    H.assertMatch(T.format("used", 5, 10), "Has jugado 5 de tus 10", "spanish")
    speaking("EN")
    H.assertMatch(T.format("used", 5, 10), "You have used 5 of your 10", "english")
end)

H.test("a language we do not carry falls back to English", function()
    speaking("PL")
    H.assertMatch(T.format("leaving", 9), "Disconnecting in 9 seconds", "fallback")
end)

H.test("no Translator at all is survivable", function()
    speaking(nil)
    H.assertEqual(T.language(), "EN", "falls back")
    H.assertMatch(T.format("leaving", 3), "Disconnecting in 3", "still formats")
end)

H.test("values are substituted in order, not by position in the sentence", function()
    speaking("ES")
    -- Spanish puts the numbers in the same order here, but the point is that
    -- %1 and %2 are named, so a language may reorder them freely.
    H.assertMatch(T.format("used", 1, 2), "1 de tus 2", "both values")
end)

H.test("an unknown key comes back as itself rather than as nothing", function()
    speaking("EN")
    H.assertEqual(T.format("noSuchKey"), "noSuchKey", "visible mistake")
end)

-- The date a player reads --------------------------------------------------

H.test("a timestamp is read out as a date, not as a stamp", function()
    _G.Translator = nil
    H.assertEqual(MaxTimeInServerText.date("2026-10-23T00:00:00+0000"), "October 23",
        "month first in English")

    _G.Translator = { getLanguage = function() return { name = function() return "ES" end } end }
    H.assertEqual(MaxTimeInServerText.date("2026-10-23T00:00:00+0000"), "23 de octubre",
        "day first in Spanish")
    _G.Translator = nil
end)

H.test("the weekday is said too, each language in its own order", function()
    _G.Translator = nil
    H.assertEqual(MaxTimeInServerText.date("2026-10-23T00:00:00+0000", 5),
        "Friday October 23", "weekday first in English")

    _G.Translator = { getLanguage = function() return { name = function() return "ES" end } end }
    H.assertEqual(MaxTimeInServerText.date("2026-10-23T00:00:00+0000", 5),
        "viernes 23 de octubre", "weekday first in Spanish too, the rest in its order")
    _G.Translator = nil
end)

H.test("a weekday that is not one of the seven is simply left out", function()
    H.assertEqual(MaxTimeInServerText.date("2026-10-23T00:00:00+0000", 0), "October 23", "zero")
    H.assertEqual(MaxTimeInServerText.date("2026-10-23T00:00:00+0000", 9), "October 23", "nine")
    H.assertEqual(MaxTimeInServerText.date("2026-10-23T00:00:00+0000"), "October 23", "none")
end)

-- The engine files translations by the prefix of the key, so ours carry
-- Sandbox_ like the settings do. A key without a prefix it knows raises.
H.test("the engine's answer wins over the table, which is the fallback", function()
    _G.getTextOrNull = function(key)
        if key == "Sandbox_MaxTimeInServer_month10" then return "lokakuuta" end
        if key == "Sandbox_MaxTimeInServer_date" then return "%1. %2" end
        return nil
    end
    H.assertEqual(MaxTimeInServerText.date("2026-10-23T00:00:00+0000"), "23. lokakuuta",
        "a language the Lua table has never heard of")
    _G.getTextOrNull = nil
end)

H.test("the month names the mod ships are its own, not the game's", function()
    -- The game's Farming_Month_1..12 are shifted by one in FR, CN, NL, PT and
    -- HU, so a mod reusing them shows the wrong month.
    _G.getTextOrNull = function(key)
        if key == "Farming_Month_10" then return "Novembre" end
        return nil
    end
    H.assertEqual(MaxTimeInServerText.date("2026-10-23T00:00:00+0000"), "October 23",
        "the game's shifted list is not consulted")
    _G.getTextOrNull = nil
end)

H.test("something that is not a date comes back as it arrived", function()
    H.assertEqual(MaxTimeInServerText.date("whenever"), "whenever", "untouched")
    H.assertEqual(MaxTimeInServerText.date(nil), "", "and nil is not an error")
end)

H.test("the engine substitutes its own placeholders, whatever shape they are", function()
    _G.getTextOrNull = function(key)
        if key == "Sandbox_MaxTimeInServer_played" then
            return "Has jugado %1$s minutos esta semana (máximo %2$s)."
        end
    end
    _G.getText = function(key, a, b)
        return "Has jugado " .. tostring(a) .. " minutos esta semana (máximo " .. tostring(b) .. ")."
    end
    H.assertEqual(MaxTimeInServerText.format("played", 0, 3),
        "Has jugado 0 minutos esta semana (máximo 3).", "the engine's own formatting")
    _G.getText = nil
    _G.getTextOrNull = nil
end)

H.test("and if it will not, the %1$s form is substituted here without leftovers", function()
    _G.getTextOrNull = function(key)
        if key == "Sandbox_MaxTimeInServer_played" then
            return "Has jugado %1$s minutos (maximo %2$s)."
        end
    end
    _G.getText = function() error("no formatting today") end
    H.assertEqual(MaxTimeInServerText.format("played", 0, 3),
        "Has jugado 0 minutos (maximo 3).", "no $s left behind")
    _G.getText = nil
    _G.getTextOrNull = nil
end)

H.test("the fallback table still uses the plain %1 form", function()
    H.assertMatch(MaxTimeInServerText.format("played", 7, 9), "7", "substituted")
    H.assertFalse(MaxTimeInServerText.format("played", 7, 9):find("%$s"), "nothing left over")
end)

H.run("text")
