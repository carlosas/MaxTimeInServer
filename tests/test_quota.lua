local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

S.loadModules()
PlayerTimerClock.backend = S.utcCalendarBackend()

local MONDAY = S.MONDAY
local WEEK = 7 * 24 * 3600
local DATA = "PlayerTimer.txt"

-- Builds a fresh engine wired to fakes. Returns the knobs the tests poke.
local function makeWorld(opts)
    opts = opts or {}
    local world = {}
    world.clock = PlayerTimerClock
    world.clock.backend = S.utcCalendarBackend()
    world.current = opts.startEpoch or (MONDAY + 3600)
    world.clock.backend.now = function() return world.current end

    world.files = S.fakeFiles(opts.files)
    world.roles = S.fakeRoles(opts.roles or { darkkz = "user" }, opts.steamIds or {})
    world.onlineUsers = opts.online or {}

    world.config = {}
    for key, value in pairs(PlayerTimerConfig) do world.config[key] = value end
    world.config.capMinutes = opts.capMinutes or 600
    if opts.exemptRoles then world.config.exemptRoles = opts.exemptRoles end

    PlayerTimerQuota.configure({
        config = world.config,
        clock = world.clock,
        store = PlayerTimerStore,
        roles = world.roles,
        files = world.files,
        online = function()
            local out = {}
            for _, username in ipairs(world.onlineUsers) do
                table.insert(out, { username = username })
            end
            return out
        end,
    })
    PlayerTimerQuota.start()

    function world.advance(seconds)
        world.current = world.current + seconds
    end
    function world.sweepAfter(seconds)
        world.advance(seconds)
        PlayerTimerQuota.sweep(world.current)
    end
    function world.tickAfter(seconds)
        world.advance(seconds)
        return PlayerTimerQuota.tick()
    end
    function world.state()
        return PlayerTimerQuota.loadState()
    end
    function world.record(username)
        return world.state().players[username]
    end
    function world.minutes(username)
        local record = world.record(username)
        return record and record.minutes or nil
    end
    return world
end

H.test("tick does nothing until the sweep interval has passed", function()
    local world = makeWorld({ online = { "darkkz" } })
    H.assertFalse(world.tickAfter(59), "a 59 second tick")
    H.assertNil(world.minutes("darkkz"), "no record yet")
    H.assertTrue(world.tickAfter(1), "the 60 second tick")
    H.assertEqual(world.minutes("darkkz"), 1, "one minute credited")
end)

H.test("a minute of presence credits exactly one minute", function()
    local world = makeWorld({ online = { "darkkz" } })
    world.sweepAfter(60)
    H.assertEqual(world.minutes("darkkz"), 1, "minutes")
end)

H.test("leftover seconds carry over between sweeps", function()
    local world = makeWorld({ online = { "darkkz" } })
    world.sweepAfter(90)
    H.assertEqual(world.minutes("darkkz"), 1, "after 90s")
    world.sweepAfter(90)
    H.assertEqual(world.minutes("darkkz"), 3, "after 180s")
end)

H.test("an offline player is not credited", function()
    local world = makeWorld({ online = { "darkkz" }, roles = { darkkz = "user", quiet = "user" } })
    world.sweepAfter(600)
    H.assertNil(world.minutes("quiet"), "never seen")
end)

H.test("a huge clock jump credits at most one capped sweep", function()
    local world = makeWorld({ online = { "darkkz" } })
    world.sweepAfter(10000)
    H.assertEqual(world.minutes("darkkz"), 60, "capped at maxCreditSecondsPerSweep")
end)

H.test("reaching the cap moves the account to the banned role exactly once", function()
    local world = makeWorld({ online = { "darkkz" }, capMinutes = 2 })
    world.sweepAfter(120)
    H.assertEqual(world.roles.roles.darkkz, "banned", "role")
    H.assertEqual(world.record("darkkz").blockedRole, "user", "role remembered")
    world.sweepAfter(60)
    H.assertEqual(#world.roles.setRoleCallsFor("darkkz"), 1, "only one role change")
    H.assertMatch(S.logText(), "blocked darkkz", "logged")
end)

H.test("the data file is written as soon as someone is blocked", function()
    local world = makeWorld({ online = { "darkkz" }, capMinutes = 1 })
    world.sweepAfter(60)
    H.assertMatch(world.files.files[DATA], "blockedRole=user", "persisted immediately")
end)

H.test("a blocked player stops accumulating minutes", function()
    local world = makeWorld({ online = { "darkkz" }, capMinutes = 1 })
    world.sweepAfter(60)
    local blockedAt = world.minutes("darkkz")
    world.sweepAfter(300)
    H.assertEqual(world.minutes("darkkz"), blockedAt, "frozen while blocked")
end)

H.test("an exempt role is never counted and never blocked", function()
    local world = makeWorld({ online = { "boss" }, roles = { boss = "admin" }, capMinutes = 1 })
    world.sweepAfter(600)
    H.assertEqual(world.minutes("boss"), 0, "minutes")
    H.assertEqual(world.roles.roles.boss, "admin", "role untouched")
    H.assertEqual(world.record("boss").role, "admin", "role recorded for the operator to see")
end)

H.test("exempt=true in the file wins over the role", function()
    local world = makeWorld({
        online = { "darkkz" }, capMinutes = 1,
        files = { [DATA] = "version=1\ncapMinutes=1\n\n[darkkz]\nminutes=0\nexempt=true\n" },
    })
    world.sweepAfter(600)
    H.assertEqual(world.minutes("darkkz"), 0, "minutes")
    H.assertEqual(world.roles.roles.darkkz, "user", "role untouched")
end)

H.test("bonusMinutes raises the threshold for one player", function()
    local world = makeWorld({
        online = { "darkkz" }, capMinutes = 2,
        -- weekStartEpoch is the current week: a rollover would clear the bonus,
        -- which is the point of bonusMinutes being a one-week grant.
        files = { [DATA] = "version=1\ncapMinutes=2\nweekStartEpoch=" .. MONDAY ..
            "\n\n[darkkz]\nminutes=0\nbonusMinutes=3\n" },
    })
    world.sweepAfter(120)
    H.assertEqual(world.roles.roles.darkkz, "user", "still allowed at 2 minutes")
    world.sweepAfter(180)
    H.assertEqual(world.roles.roles.darkkz, "banned", "blocked once past 5")
end)

H.test("lowering minutes by hand unblocks and restores the old role", function()
    local world = makeWorld({ online = { "darkkz" }, capMinutes = 1 })
    world.sweepAfter(60)
    H.assertEqual(world.roles.roles.darkkz, "banned", "blocked")

    local text = world.files.files[DATA]:gsub("minutes=%d+", "minutes=0", 1)
    world.files.files[DATA] = text
    world.sweepAfter(60)
    H.assertEqual(world.roles.roles.darkkz, "user", "restored")
    H.assertEqual(world.record("darkkz").blockedRole, "", "mark cleared")
    H.assertMatch(S.logText(), "unblocked darkkz", "logged")
end)

H.test("raising the cap by hand unblocks", function()
    local world = makeWorld({ online = { "darkkz" }, capMinutes = 1 })
    world.sweepAfter(60)
    world.files.files[DATA] = world.files.files[DATA]:gsub("capMinutes=1", "capMinutes=600")
    world.sweepAfter(60)
    H.assertEqual(world.roles.roles.darkkz, "user", "restored")
end)

H.test("a new week zeroes the counters and gives every role back", function()
    local world = makeWorld({ online = { "darkkz" }, capMinutes = 1, startEpoch = MONDAY + WEEK - 120 })
    world.sweepAfter(60)
    H.assertEqual(world.roles.roles.darkkz, "banned", "blocked before the boundary")

    world.onlineUsers = {}       -- they log off before the boundary
    world.sweepAfter(120)        -- crosses into the next week
    H.assertEqual(world.roles.roles.darkkz, "user", "role restored")
    H.assertEqual(world.state().weekStartEpoch, MONDAY + WEEK, "new week stored")
    H.assertEqual(world.minutes("darkkz"), 0, "counter reset")
    H.assertEqual(world.record("darkkz").bonusMinutes, 0, "bonus cleared")
    H.assertMatch(S.logText(), "new week", "logged")
end)

H.test("a sweep that straddles the boundary only credits the part in the new week", function()
    local world = makeWorld({ online = { "darkkz" }, capMinutes = 600, startEpoch = MONDAY + WEEK - 60 })
    world.sweepAfter(120)        -- 60s in the old week, 60s in the new one
    H.assertEqual(world.state().weekStartEpoch, MONDAY + WEEK, "new week stored")
    H.assertEqual(world.minutes("darkkz"), 1, "only the new week's minute")
end)

H.test("a week that passed while the server was down still resets on the next sweep", function()
    local world = makeWorld({
        online = {}, capMinutes = 600, startEpoch = MONDAY + WEEK + 3600,
        files = { [DATA] = "version=1\ncapMinutes=600\nweekStartEpoch=" .. MONDAY ..
            "\n\n[darkkz]\nminutes=600\nblockedRole=user\n" },
        roles = { darkkz = "banned" },
    })
    world.sweepAfter(60)
    H.assertEqual(world.roles.roles.darkkz, "user", "role restored on start-up")
    H.assertEqual(world.minutes("darkkz"), 0, "counter reset")
end)

H.test("a role change the database refuses is retried on the next sweep", function()
    local world = makeWorld({ online = { "darkkz" }, capMinutes = 1 })
    world.roles.failSetRole = true
    world.sweepAfter(60)
    H.assertEqual(world.roles.roles.darkkz, "user", "not blocked")
    H.assertEqual(world.record("darkkz").blockedRole, "", "nothing claimed")
    H.assertMatch(S.logText(), "could not block", "logged")

    world.roles.failSetRole = false
    world.sweepAfter(60)
    H.assertEqual(world.roles.roles.darkkz, "banned", "blocked on the retry")
end)

H.test("an account an operator banned by hand is left alone", function()
    local world = makeWorld({ online = { "darkkz" }, capMinutes = 1, roles = { darkkz = "banned" } })
    world.sweepAfter(60)
    H.assertEqual(world.record("darkkz").blockedRole, "", "not claimed by the mod")
    H.assertEqual(#world.roles.setRoleCallsFor("darkkz"), 0, "no role change")
end)

H.test("the steam id is recorded once", function()
    local world = makeWorld({
        online = { "darkkz" }, steamIds = { darkkz = "76561197972620811" },
    })
    world.sweepAfter(60)
    H.assertEqual(world.record("darkkz").steamid, "76561197972620811", "steamid")
end)

H.test("an unparseable data file is rescued, not overwritten in place", function()
    local world = makeWorld({ online = { "darkkz" }, files = { [DATA] = "\1\2\3 garbage" } })
    world.sweepAfter(60)
    H.assertEqual(world.files.files["PlayerTimer.broken.txt"], "\1\2\3 garbage", "rescue copy")
    H.assertEqual(world.minutes("darkkz"), 1, "counting carried on")
    H.assertMatch(S.logText(), "could not be read", "logged")
end)

H.test("nothing is written when nothing happened", function()
    local world = makeWorld({ online = {} })
    world.sweepAfter(60)
    local writes = world.files.writes
    world.sweepAfter(60)
    H.assertEqual(world.files.writes, writes, "no extra write")
end)

H.test("a sweep never raises, even with every backend broken", function()
    local world = makeWorld({ online = { "darkkz" } })
    world.files.read = function() error("disk on fire") end
    world.files.write = function() error("disk still on fire") end
    world.roles.getRoleName = function() error("db gone") end
    world.roles.setRole = function() error("db gone") end
    world.advance(60)
    local ok = pcall(PlayerTimerQuota.sweep, world.current)
    H.assertTrue(ok, "sweep survived")
end)

H.test("the mod registers itself on the server's events", function()
    makeWorld({})
    PlayerTimerQuota.registerEvents()
    H.assertTrue(#Events.OnServerStarted.handlers > 0, "OnServerStarted")
    H.assertTrue(#Events.EveryOneMinute.handlers > 0, "EveryOneMinute")
    H.assertTrue(#Events.OnServerStartSaving.handlers > 0, "OnServerStartSaving")
end)

H.run("quota")
