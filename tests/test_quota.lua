local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

S.loadModules()
PlayerTimerClock.backend = S.utcCalendarBackend()

local MONDAY = S.MONDAY
local WEEK = 7 * 24 * 3600
local DATA = "PlayerTimer.txt"

local function makeWorld(opts)
    opts = opts or {}
    local world = {}
    world.clock = PlayerTimerClock
    world.clock.backend = S.utcCalendarBackend()
    world.current = opts.startEpoch or (MONDAY + 3600)
    world.clock.backend.now = function() return world.current end

    world.files = S.fakeFiles(opts.files)
    world.players = S.fakePlayers(opts.online)

    world.config = {}
    for key, value in pairs(PlayerTimerConfig) do world.config[key] = value end
    world.config.capMinutes = opts.capMinutes or 600
    if opts.exemptRoles then world.config.exemptRoles = opts.exemptRoles end

    PlayerTimerQuota.configure({
        config = world.config,
        clock = world.clock,
        store = PlayerTimerStore,
        files = world.files,
        players = world.players,
    })
    PlayerTimerQuota.start()

    function world.advance(seconds) world.current = world.current + seconds end
    function world.sweepAfter(seconds)
        world.advance(seconds)
        PlayerTimerQuota.sweep(world.current)
    end
    function world.tickAfter(seconds)
        world.advance(seconds)
        return PlayerTimerQuota.tick()
    end
    function world.state() return PlayerTimerQuota.loadState() end
    function world.record(username) return world.state().players[username] end
    function world.minutes(username)
        local record = world.record(username)
        return record and record.minutes or nil
    end
    return world
end

-- counting -------------------------------------------------------------------

H.test("tick does nothing until the sweep interval has passed", function()
    local world = makeWorld({ online = { { username = "darkkz", role = "user" } } })
    H.assertFalse(world.tickAfter(59), "a 59 second tick")
    H.assertNil(world.minutes("darkkz"), "no record yet")
    H.assertTrue(world.tickAfter(1), "the 60 second tick")
    H.assertEqual(world.minutes("darkkz"), 1, "one minute credited")
end)

H.test("a minute of presence credits exactly one minute", function()
    local world = makeWorld({ online = { { username = "darkkz", role = "user" } } })
    world.sweepAfter(60)
    H.assertEqual(world.minutes("darkkz"), 1, "minutes")
end)

H.test("leftover seconds carry over between sweeps", function()
    local world = makeWorld({ online = { { username = "darkkz", role = "user" } } })
    world.sweepAfter(90)
    H.assertEqual(world.minutes("darkkz"), 1, "after 90s")
    world.sweepAfter(90)
    H.assertEqual(world.minutes("darkkz"), 3, "after 180s")
end)

H.test("an offline player is not credited", function()
    local world = makeWorld({ online = { { username = "darkkz", role = "user" } } })
    world.sweepAfter(600)
    H.assertNil(world.minutes("quiet"), "never seen")
end)

H.test("a huge clock jump credits at most one capped sweep", function()
    local world = makeWorld({ online = { { username = "darkkz", role = "user" } } })
    world.sweepAfter(10000)
    H.assertEqual(world.minutes("darkkz"), 60, "capped at maxCreditSecondsPerSweep")
end)

H.test("an exempt role is never counted", function()
    local world = makeWorld({ online = { { username = "boss", role = "admin" } } })
    world.sweepAfter(600)
    H.assertEqual(world.minutes("boss"), 0, "minutes")
    H.assertEqual(world.record("boss").role, "admin", "role recorded for the operator to see")
end)

H.test("exempt=true in the file is honoured", function()
    local world = makeWorld({
        online = { { username = "darkkz", role = "user" } },
        files = { [DATA] = "version=1\ncapMinutes=600\nweekStartEpoch=" .. MONDAY ..
            "\n\n[darkkz]\nminutes=0\nexempt=true\n" },
    })
    world.sweepAfter(600)
    H.assertEqual(world.minutes("darkkz"), 0, "minutes")
end)

H.test("the role a player holds is written down and kept fresh", function()
    local world = makeWorld({ online = { { username = "darkkz", role = "user" } } })
    world.sweepAfter(60)
    H.assertEqual(world.record("darkkz").role, "user", "first seen")
    world.players.entries[1].role = "priority"
    world.sweepAfter(60)
    H.assertEqual(world.record("darkkz").role, "priority", "updated")
end)

-- weeks ----------------------------------------------------------------------

H.test("a new week zeroes the counters and the bonuses", function()
    local world = makeWorld({
        online = { { username = "darkkz", role = "user" } },
        startEpoch = MONDAY + WEEK - 120,
        files = { [DATA] = "version=1\ncapMinutes=600\nweekStartEpoch=" .. MONDAY ..
            "\n\n[darkkz]\nminutes=300\nbonusMinutes=60\n" },
    })
    world.sweepAfter(60)
    H.assertEqual(world.minutes("darkkz"), 301, "still the old week")

    world.players.entries = {}
    world.sweepAfter(120)
    H.assertEqual(world.state().weekStartEpoch, MONDAY + WEEK, "new week stored")
    H.assertEqual(world.minutes("darkkz"), 0, "counter reset")
    H.assertEqual(world.record("darkkz").bonusMinutes, 0, "bonus cleared")
    H.assertMatch(S.logText(), "new week", "logged")
end)

H.test("a sweep that straddles the boundary only credits the part in the new week", function()
    local world = makeWorld({
        online = { { username = "darkkz", role = "user" } },
        startEpoch = MONDAY + WEEK - 60,
    })
    world.sweepAfter(120)
    H.assertEqual(world.state().weekStartEpoch, MONDAY + WEEK, "new week stored")
    H.assertEqual(world.minutes("darkkz"), 1, "only the new week's minute")
end)

H.test("a week that passed while the server was down resets on the next sweep", function()
    local world = makeWorld({
        online = {}, startEpoch = MONDAY + WEEK + 3600,
        files = { [DATA] = "version=1\ncapMinutes=600\nweekStartEpoch=" .. MONDAY ..
            "\n\n[darkkz]\nminutes=600\n" },
    })
    world.sweepAfter(60)
    H.assertEqual(world.minutes("darkkz"), 0, "counter reset")
end)

-- the verdict the gate asks for ----------------------------------------------

H.test("a player under the cap is allowed", function()
    local world = makeWorld({
        capMinutes = 600,
        files = { [DATA] = "version=1\ncapMinutes=600\nweekStartEpoch=" .. MONDAY ..
            "\n\n[darkkz]\nminutes=599\n" },
    })
    local verdict = PlayerTimerQuota.verdict("darkkz", "user")
    H.assertTrue(verdict.allowed, "allowed")
    H.assertEqual(verdict.minutes, 599, "minutes")
    H.assertEqual(verdict.cap, 600, "cap")
end)

H.test("a player at the cap is denied and told when it resets", function()
    local world = makeWorld({
        capMinutes = 600,
        files = { [DATA] = "version=1\ncapMinutes=600\nweekStartEpoch=" .. MONDAY ..
            "\n\n[darkkz]\nminutes=600\n" },
    })
    local verdict = PlayerTimerQuota.verdict("darkkz", "user")
    H.assertFalse(verdict.allowed, "allowed")
    H.assertEqual(verdict.minutes, 600, "minutes")
    H.assertEqual(verdict.resetsAtEpoch, MONDAY + WEEK, "next Monday")
    H.assertMatch(verdict.resetsAt, "2026%-10%-19", "readable reset stamp")
end)

H.test("bonusMinutes raises the threshold for one player", function()
    local world = makeWorld({
        capMinutes = 600,
        files = { [DATA] = "version=1\ncapMinutes=600\nweekStartEpoch=" .. MONDAY ..
            "\n\n[darkkz]\nminutes=620\nbonusMinutes=60\n" },
    })
    local verdict = PlayerTimerQuota.verdict("darkkz", "user")
    H.assertTrue(verdict.allowed, "allowed")
    H.assertEqual(verdict.cap, 660, "cap includes the bonus")
end)

H.test("an exempt role is always allowed", function()
    local world = makeWorld({
        capMinutes = 600,
        files = { [DATA] = "version=1\ncapMinutes=600\nweekStartEpoch=" .. MONDAY ..
            "\n\n[darkkz]\nminutes=9000\n" },
    })
    H.assertTrue(PlayerTimerQuota.verdict("darkkz", "moderator").allowed, "moderator")
    H.assertTrue(PlayerTimerQuota.verdict("darkkz", "ADMIN").allowed, "case does not matter")
    H.assertFalse(PlayerTimerQuota.verdict("darkkz", "user").allowed, "plain user")
end)

H.test("exempt=true is always allowed", function()
    local world = makeWorld({
        capMinutes = 600,
        files = { [DATA] = "version=1\ncapMinutes=600\nweekStartEpoch=" .. MONDAY ..
            "\n\n[darkkz]\nminutes=9000\nexempt=true\n" },
    })
    H.assertTrue(PlayerTimerQuota.verdict("darkkz", "user").allowed, "allowed")
end)

H.test("an account nobody has counted yet is allowed", function()
    local world = makeWorld({})
    local verdict = PlayerTimerQuota.verdict("newcomer", "user")
    H.assertTrue(verdict.allowed, "allowed")
    H.assertEqual(verdict.minutes, 0, "minutes")
end)

H.test("a verdict for a week that has rolled over treats the counter as spent", function()
    local world = makeWorld({
        capMinutes = 600, startEpoch = MONDAY + WEEK + 3600,
        files = { [DATA] = "version=1\ncapMinutes=600\nweekStartEpoch=" .. MONDAY ..
            "\n\n[darkkz]\nminutes=600\n" },
    })
    local verdict = PlayerTimerQuota.verdict("darkkz", "user")
    H.assertTrue(verdict.allowed, "a stale week must not keep anyone out")
end)

-- robustness -----------------------------------------------------------------

H.test("nothing is written when nothing happened", function()
    local world = makeWorld({ online = {} })
    world.sweepAfter(60)
    local writes = world.files.writes
    world.sweepAfter(60)
    H.assertEqual(world.files.writes, writes, "no extra write")
end)

H.test("an unparseable data file is rescued, not overwritten in place", function()
    local world = makeWorld({
        online = { { username = "darkkz", role = "user" } },
        files = { [DATA] = "\1\2\3 garbage" },
    })
    world.sweepAfter(60)
    H.assertEqual(world.files.files["PlayerTimer.broken.txt"], "\1\2\3 garbage", "rescue copy")
    H.assertEqual(world.minutes("darkkz"), 1, "counting carried on")
    H.assertMatch(S.logText(), "could not be read", "logged")
end)

H.test("a sweep never raises, even with every backend broken", function()
    local world = makeWorld({ online = { { username = "darkkz", role = "user" } } })
    world.files.read = function() error("disk on fire") end
    world.files.write = function() error("disk still on fire") end
    world.players.online = function() error("no world") end
    world.advance(60)
    H.assertTrue(pcall(PlayerTimerQuota.sweep, world.current), "sweep survived")
end)

H.test("a verdict never raises, even with a broken data file", function()
    local world = makeWorld({})
    world.files.read = function() error("disk on fire") end
    local ok, verdict = pcall(PlayerTimerQuota.verdict, "darkkz", "user")
    H.assertTrue(ok, "no error")
    H.assertTrue(verdict.allowed, "a broken file must not lock people out")
end)

H.test("the mod registers itself on the server's events", function()
    makeWorld({})
    PlayerTimerQuota.registerEvents()
    H.assertTrue(#Events.OnServerStarted.handlers > 0, "OnServerStarted")
    H.assertTrue(#Events.EveryOneMinute.handlers > 0, "EveryOneMinute")
    H.assertTrue(#Events.OnServerStartSaving.handlers > 0, "OnServerStartSaving")
end)

H.test("registering twice against the same Events table does not duplicate", function()
    local before = #Events.OnServerStarted.handlers
    PlayerTimerQuota.registerEvents()
    H.assertEqual(#Events.OnServerStarted.handlers, before, "no duplicate")
end)

H.test("a rebuilt Events table is registered on again", function()
    -- A Lua reload gives the mod a fresh Events table while the globals it set
    -- survive. A boolean guard would skip re-registration and leave the mod
    -- attached to event objects nobody triggers any more.
    local fresh = { handlers = {} }
    fresh.Add = function(fn) table.insert(fresh.handlers, fn) end
    local saved = Events.OnServerStarted
    Events.OnServerStarted = fresh
    PlayerTimerQuota.registerEvents()
    H.assertTrue(#fresh.handlers > 0, "re-registered on the new table")
    Events.OnServerStarted = saved
end)

H.run("quota")
