local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

-- Two servers running this mod must not touch each other's counters. The place
-- they would collide is ~/Zomboid/Lua: Server/ and Saves/ are named after the
-- server, that folder is not, and every sweep rewrites the whole counter file,
-- so sharing one would not interleave the counts but overwrite them.

S.loadModules()
local clock = MaxTimeInServerClock
clock.backend = S.utcCalendarBackend()

local MONDAY = S.MONDAY
local current = MONDAY + 3600
clock.backend.now = function() return current end

local shared = S.fakeFiles()

local function weekFile(minutes)
    return "version=1\nweekStartEpoch=" .. MONDAY ..
        "\n\n[someplayer]\nminutes=" .. minutes .. "\n"
end

--- Brings the mod up as the server called `name`, the way OnServerStarted does.
local function bootServer(name, online, fs)
    S.serverName = name
    MaxTimeInServerQuota.configure({
        config = MaxTimeInServerConfig,
        clock = clock,
        store = MaxTimeInServerStore,
        files = fs or shared,
        players = S.fakePlayers(online or {}),
    })
    for _, handler in ipairs(Events.OnServerStarted.handlers) do handler() end
end

local function sweepAfter(seconds)
    current = current + seconds
    MaxTimeInServerQuota.sweep(current)
end

local function minutesIn(fileName, username, fs)
    local state = MaxTimeInServerStore.load(fs or shared, fileName)
    local record = state.players[username]
    if record == nil then return nil end
    return record.minutes
end

H.test("each server counts the same account in its own file", function()
    bootServer("Alpha", { { username = "someplayer", role = "user" } })
    sweepAfter(600)

    bootServer("Bravo", { { username = "someplayer", role = "user" } })
    sweepAfter(1800)

    H.assertEqual(minutesIn("MaxTimeInServer_Alpha.txt", "someplayer"), 10, "ten minutes on Alpha")
    H.assertEqual(minutesIn("MaxTimeInServer_Bravo.txt", "someplayer"), 30, "thirty on Bravo")
end)

H.test("and the start-up line names the file it counts in", function()
    S.logLines = {}
    bootServer("Alpha", {})
    H.assertMatch(S.logText(), "counting in MaxTimeInServer_Alpha%.txt", "said which file")
end)

H.test("neither server answers with the other's minutes", function()
    shared.files["MaxTimeInServer_Alpha.txt"] = weekFile(700)
    shared.files["MaxTimeInServer_Bravo.txt"] = weekFile(5)

    bootServer("Alpha", {})
    H.assertFalse(MaxTimeInServerQuota.verdict("someplayer", "user").allowed,
        "out of time on Alpha")

    bootServer("Bravo", {})
    H.assertTrue(MaxTimeInServerQuota.verdict("someplayer", "user").allowed,
        "still welcome on Bravo")
end)

H.test("the file from before this change is carried over to the server's own", function()
    local fs = S.fakeFiles({ ["MaxTimeInServer.txt"] = weekFile(300) })
    S.logLines = {}
    bootServer("Alpha", {}, fs)

    H.assertEqual(minutesIn("MaxTimeInServer_Alpha.txt", "someplayer", fs), 300,
        "nobody starts the week again")
    H.assertMatch(S.logText(), "carried the counters over", "and it says so")
end)

H.test("a server with a file of its own ignores the old shared one", function()
    local fs = S.fakeFiles({
        ["MaxTimeInServer.txt"] = weekFile(300),
        ["MaxTimeInServer_Alpha.txt"] = weekFile(7),
    })
    S.logLines = {}
    bootServer("Alpha", {}, fs)

    H.assertEqual(minutesIn("MaxTimeInServer_Alpha.txt", "someplayer", fs), 7, "its own count stands")
    H.assertFalse(S.logText():find("carried the counters over"), "nothing was copied over it")
end)

H.test("a server name that is no use as a file name still gets its own file", function()
    local eu = MaxTimeInServerConfig.resolveDataFile("Carlos' server (EU)")
    local us = MaxTimeInServerConfig.resolveDataFile("Carlos' server (US)")
    H.assertEqual(eu, "MaxTimeInServer_Carlos__server__EU.txt", "nothing a path would refuse")
    H.assertTrue(eu ~= us, "and the two are still told apart")
end)

H.test("a server that will not say its name keeps the old file, and warns", function()
    S.logLines = {}
    local name, named = MaxTimeInServerConfig.resolveDataFile("")
    H.assertEqual(name, MaxTimeInServerConfig.legacyDataFile, "the name it always had")
    H.assertFalse(named, "and it admits it cannot tell servers apart")

    bootServer("", {}, S.fakeFiles())
    H.assertMatch(S.logText(), "%-cachedir", "warns what to do with a second server")
end)

H.run("two servers")
