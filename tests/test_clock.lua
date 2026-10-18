local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

S.loadModules({ "PlayerTimerConfig.lua", "PlayerTimerClock.lua" })
PlayerTimerClock.backend = S.utcCalendarBackend()

local MONDAY = S.MONDAY           -- 2026-10-12 00:00:00 UTC
local WEEK = 7 * 24 * 3600

H.test("the start of a week maps to itself", function()
    H.assertEqual(PlayerTimerClock.getWeekStartEpoch(MONDAY), MONDAY, "monday 00:00")
end)

H.test("one second into the week still maps to the same Monday", function()
    H.assertEqual(PlayerTimerClock.getWeekStartEpoch(MONDAY + 1), MONDAY, "monday 00:00:01")
end)

H.test("the last second of Sunday maps back to the same Monday", function()
    H.assertEqual(PlayerTimerClock.getWeekStartEpoch(MONDAY + WEEK - 1), MONDAY, "sunday 23:59:59")
end)

H.test("the next second starts a new week", function()
    H.assertEqual(PlayerTimerClock.getWeekStartEpoch(MONDAY + WEEK), MONDAY + WEEK, "next monday")
end)

H.test("a mid-week timestamp maps to the Monday of its week", function()
    local thursday = MONDAY + 3 * 24 * 3600 + 13 * 3600 + 37 * 60 + 5
    H.assertEqual(PlayerTimerClock.getWeekStartEpoch(thursday), MONDAY, "thursday 13:37:05")
end)

H.test("every second of a week maps to that week's Monday", function()
    for offset = 0, WEEK - 1, 997 do
        local got = PlayerTimerClock.getWeekStartEpoch(MONDAY + offset)
        if got ~= MONDAY then
            error("offset " .. offset .. " mapped to " .. tostring(got))
        end
    end
end)

H.test("formatIso renders a readable UTC stamp", function()
    H.assertEqual(PlayerTimerClock.formatIso(MONDAY), "2026-10-12T00:00:00+0000", "iso")
end)

H.test("now() reads the injected timestamp source", function()
    PlayerTimerClock.backend.now = function() return 1234567 end
    H.assertEqual(PlayerTimerClock.now(), 1234567, "now")
end)

H.run("clock")
