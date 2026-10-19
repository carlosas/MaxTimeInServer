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

H.run("text")
