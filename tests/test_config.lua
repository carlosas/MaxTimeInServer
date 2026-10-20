local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

S.loadModules({ "shared/MaxTimeInServer/MaxTimeInServerConfig.lua" })

local C = MaxTimeInServerConfig

local function roleList()
    local out = {}
    for _, role in ipairs(C.exemptRoles) do table.insert(out, role) end
    table.sort(out)
    return table.concat(out, ",")
end

H.test("without the sandbox page the shipped defaults stand", function()
    H.assertFalse(C.applySandboxOptions({}), "nothing applied")
    H.assertEqual(C.capMinutes, 600, "capMinutes")
    H.assertEqual(C.graceSeconds, 5, "graceSeconds")
    H.assertEqual(C.resetDay, 5, "resetDay is friday")
    H.assertEqual(table.concat(C.warnMinutes, ","), "30,5", "warnMinutes")
    H.assertEqual(roleList(), "admin,gm,moderator", "exemptRoles")
end)

H.test("the reset day is taken as the index of a weekday", function()
    C.applySandboxOptions({ MaxTimeInServer = { ResetDay = 1 } })
    H.assertEqual(C.resetDay, 1, "monday")
    H.assertEqual(C.resetDayName(), "Monday", "named in the log")

    C.applySandboxOptions({ MaxTimeInServer = { ResetDay = 7 } })
    H.assertEqual(C.resetDay, 7, "sunday")
    H.assertEqual(C.resetDayName(), "Sunday", "named in the log")
end)

H.test("a day outside the week is refused and friday stands", function()
    for _, bad in ipairs({ 0, 8, -3, "friday", "" }) do
        C.applySandboxOptions({ MaxTimeInServer = { ResetDay = bad } })
        H.assertEqual(C.resetDay, 5, "refused " .. tostring(bad))
    end
    H.assertMatch(S.logText(), "ResetDay", "and said which option it was")
end)

H.test("the notes stay long enough to read a sentence with numbers in it", function()
    H.assertTrue(C.noteSeconds >= 5, "at least five seconds, got " .. tostring(C.noteSeconds))
end)

H.test("the warning marks are a list, largest first and without repeats", function()
    C.applySandboxOptions({ MaxTimeInServer = { WarnMinutes = "5;30;5" } })
    H.assertEqual(table.concat(C.warnMinutes, ","), "30,5", "sorted and deduplicated")
end)

H.test("an empty list of marks means nothing is said until the time is up", function()
    C.applySandboxOptions({ MaxTimeInServer = { WarnMinutes = "" } })
    H.assertEqual(#C.warnMinutes, 0, "no marks")
    H.assertMatch(C.describe(), "no warning", "and the start-up line says so")
end)

H.test("a mark that is not a number is dropped, and the rest survive", function()
    S.logLines = {}
    C.applySandboxOptions({ MaxTimeInServer = { WarnMinutes = "10; soon ;0;2" } })
    H.assertEqual(table.concat(C.warnMinutes, ","), "10,2", "kept what made sense")
    H.assertMatch(S.logText(), "WarnMinutes", "and named the option")
end)

H.test("the start-up line says when the week turns over", function()
    C.applySandboxOptions({ MaxTimeInServer = { ResetDay = 3 } })
    H.assertMatch(C.describe(), "Wednesdays at 00:00", "in words, not as a number")
end)

H.test("a missing SandboxVars altogether is survivable", function()
    H.assertFalse(C.applySandboxOptions(nil), "nothing applied")
    H.assertEqual(C.capMinutes, 600, "capMinutes")
end)

H.test("the server's settings replace the defaults", function()
    H.assertTrue(C.applySandboxOptions({ MaxTimeInServer = {
        CapMinutes = 300, ExemptRoles = "admin;gm", GraceSeconds = 30 } }), "applied")
    H.assertEqual(C.capMinutes, 300, "capMinutes")
    H.assertEqual(C.graceSeconds, 30, "graceSeconds")
    H.assertEqual(roleList(), "admin,gm", "exemptRoles")
end)

H.test("applying twice gives the same answer, not a stacked one", function()
    local vars = { MaxTimeInServer = { CapMinutes = 300, ExemptRoles = "gm" } }
    C.applySandboxOptions(vars)
    C.applySandboxOptions(vars)
    H.assertEqual(C.capMinutes, 300, "capMinutes")
    H.assertEqual(roleList(), "gm", "exemptRoles")
    H.assertEqual(C.graceSeconds, 5, "a setting left out falls back to its default")
end)

H.test("role names are tidied up and case does not matter", function()
    C.applySandboxOptions({ MaxTimeInServer = { ExemptRoles = " Admin ;; GM ;moderator; " } })
    H.assertEqual(roleList(), "admin,gm,moderator", "exemptRoles")
end)

H.test("an empty role list means nobody is exempt", function()
    C.applySandboxOptions({ MaxTimeInServer = { ExemptRoles = "" } })
    H.assertEqual(#C.exemptRoles, 0, "exemptRoles")
end)

H.test("nonsense is refused and reported, and the default stands", function()
    C.applySandboxOptions({ MaxTimeInServer = { CapMinutes = "lots", GraceSeconds = -5 } })
    H.assertEqual(C.capMinutes, 600, "capMinutes")
    H.assertEqual(C.graceSeconds, 5, "graceSeconds")
    H.assertMatch(S.logText(), "CapMinutes", "says which setting")
    H.assertMatch(S.logText(), "GraceSeconds", "says which setting")
end)

H.test("a cap of zero is refused: it would lock out the whole server", function()
    C.applySandboxOptions({ MaxTimeInServer = { CapMinutes = 0 } })
    H.assertEqual(C.capMinutes, 600, "capMinutes")
end)

H.test("a float from the sandbox is rounded rather than refused", function()
    C.applySandboxOptions({ MaxTimeInServer = { CapMinutes = 300.0, GraceSeconds = 7.0 } })
    H.assertEqual(C.capMinutes, 300, "capMinutes")
    H.assertEqual(C.graceSeconds, 7, "graceSeconds")
end)

H.test("it describes the settings that decide who may play", function()
    C.applySandboxOptions({ MaxTimeInServer = { CapMinutes = 42, ExemptRoles = "gm",
        GraceSeconds = 5, BlockedMessage = "go away" } })
    local summary = C.describe()
    H.assertMatch(summary, "42", "the cap")
    H.assertMatch(summary, "gm", "the roles")
    H.assertMatch(summary, "5", "the grace")
    H.assertFalse(summary:find("go away") ~= nil,
        "and not the wording, which decides nothing")
end)

H.run("config")
