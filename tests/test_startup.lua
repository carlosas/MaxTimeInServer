local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

-- Covers the wiring the other suites inject around: the real config table,
-- reading the server's sandbox options, and the start-up log line.
S.loadModules()
MaxTimeInServerClock.backend = S.utcCalendarBackend()
MaxTimeInServerClock.backend.now = function() return S.MONDAY + 3600 end

_G.SandboxVars = { MaxTimeInServer = {
    CapMinutes = 250, ExemptRoles = "overseer", GraceSeconds = 4 } }

local files = S.fakeFiles()
MaxTimeInServerQuota.configure({
    config = MaxTimeInServerConfig,
    clock = MaxTimeInServerClock,
    store = MaxTimeInServerStore,
    files = files,
    players = S.fakePlayers({}),
})

local function fireServerStarted()
    for _, handler in ipairs(Events.OnServerStarted.handlers) do handler() end
end

H.test("start-up reads the server's settings and says what it will enforce", function()
    fireServerStarted()
    local log = S.logText()
    H.assertMatch(log, "ready", "announced itself")
    H.assertMatch(log, "250", "the cap from the sandbox options")
    H.assertMatch(log, "overseer", "the exempt roles from the sandbox options")
    H.assertMatch(log, "4 seconds", "the grace from the sandbox options")
end)

H.test("and those settings are what the quota then enforces", function()
    H.assertEqual(MaxTimeInServerConfig.capMinutes, 250, "cap in force")
    files.files[MaxTimeInServerConfig.dataFile] =
        "version=1\nweekStartEpoch=" .. S.MONDAY .. "\n\n[someone]\nminutes=250\n"
    H.assertFalse(MaxTimeInServerQuota.verdict("someone", "user").allowed, "at the cap")
    H.assertTrue(MaxTimeInServerQuota.verdict("someone", "overseer").allowed, "exempt role")
    H.assertTrue(MaxTimeInServerQuota.verdict("someone", "admin").allowed == false,
        "a role the operator left out of the list is no longer exempt")
end)

H.test("with no settings page it falls back and says so", function()
    _G.SandboxVars = nil
    S.logLines = {}
    fireServerStarted()
    H.assertMatch(S.logText(), "built%-in defaults", "warned")
    H.assertEqual(MaxTimeInServerConfig.capMinutes, 600, "the shipped default")
end)

H.run("startup")
