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
    H.assertEqual(C.graceSeconds, 12, "graceSeconds")
    H.assertEqual(roleList(), "admin,gm,moderator", "exemptRoles")
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
    H.assertEqual(C.graceSeconds, 12, "a setting left out falls back to its default")
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
    H.assertEqual(C.graceSeconds, 12, "graceSeconds")
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

H.test("it describes itself for the log", function()
    C.applySandboxOptions({ MaxTimeInServer = { CapMinutes = 42, ExemptRoles = "gm", GraceSeconds = 5 } })
    local summary = C.describe()
    H.assertMatch(summary, "42", "the cap")
    H.assertMatch(summary, "gm", "the roles")
    H.assertMatch(summary, "5", "the grace")
end)

H.run("config")
