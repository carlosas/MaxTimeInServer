local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

S.loadModules({ "shared/MaxTimeInServer/MaxTimeInServerConfig.lua", "server/MaxTimeInServer/MaxTimeInServerClock.lua" })
MaxTimeInServerClock.backend = S.utcCalendarBackend()

local MONDAY = S.MONDAY           -- 2026-10-12 00:00:00 UTC
local WEEK = 7 * 24 * 3600

H.test("the start of a week maps to itself", function()
    H.assertEqual(MaxTimeInServerClock.getWeekStartEpoch(MONDAY), MONDAY, "monday 00:00")
end)

H.test("one second into the week still maps to the same Monday", function()
    H.assertEqual(MaxTimeInServerClock.getWeekStartEpoch(MONDAY + 1), MONDAY, "monday 00:00:01")
end)

H.test("the last second of Sunday maps back to the same Monday", function()
    H.assertEqual(MaxTimeInServerClock.getWeekStartEpoch(MONDAY + WEEK - 1), MONDAY, "sunday 23:59:59")
end)

H.test("the next second starts a new week", function()
    H.assertEqual(MaxTimeInServerClock.getWeekStartEpoch(MONDAY + WEEK), MONDAY + WEEK, "next monday")
end)

H.test("a mid-week timestamp maps to the Monday of its week", function()
    local thursday = MONDAY + 3 * 24 * 3600 + 13 * 3600 + 37 * 60 + 5
    H.assertEqual(MaxTimeInServerClock.getWeekStartEpoch(thursday), MONDAY, "thursday 13:37:05")
end)

H.test("every second of a week maps to that week's Monday", function()
    for offset = 0, WEEK - 1, 997 do
        local got = MaxTimeInServerClock.getWeekStartEpoch(MONDAY + offset)
        if got ~= MONDAY then
            error("offset " .. offset .. " mapped to " .. tostring(got))
        end
    end
end)

-- The week can start on any weekday; 1 = Monday .. 7 = Sunday. MONDAY + (d-1)
-- days is 00:00 of day d in the same calendar week, which is what these use as
-- the expected boundary.
local DAY = 24 * 3600

H.test("every weekday can open the week", function()
    for day = 1, 7 do
        local boundary = MONDAY + (day - 1) * DAY
        H.assertEqual(MaxTimeInServerClock.getWeekStartEpoch(boundary, day), boundary,
            "day " .. day .. " 00:00 maps to itself")
        H.assertEqual(MaxTimeInServerClock.getWeekStartEpoch(boundary + DAY + 3600, day),
            boundary, "the day after still belongs to it")
        H.assertEqual(MaxTimeInServerClock.getWeekStartEpoch(boundary - 1, day),
            boundary - WEEK, "one second earlier is the week before")
    end
end)

H.test("with Friday weeks, Thursday night is still the old week", function()
    local friday = MONDAY + 4 * DAY
    H.assertEqual(MaxTimeInServerClock.getWeekStartEpoch(friday, 5), friday, "friday 00:00")
    H.assertEqual(MaxTimeInServerClock.getWeekStartEpoch(friday - 1, 5), friday - WEEK,
        "thursday 23:59:59 belongs to the previous friday")
    H.assertEqual(MaxTimeInServerClock.getWeekStartEpoch(friday + 6 * DAY + 86399, 5),
        friday, "the following thursday is the last day of it")
end)

H.test("every second of a Friday week maps to that Friday", function()
    local friday = MONDAY + 4 * DAY
    for offset = 0, WEEK - 1, 997 do
        local got = MaxTimeInServerClock.getWeekStartEpoch(friday + offset, 5)
        if got ~= friday then
            error("offset " .. offset .. " mapped to " .. tostring(got))
        end
    end
end)

H.test("omitting the day means Monday, so an old caller is unaffected", function()
    local thursday = MONDAY + 3 * DAY
    H.assertEqual(MaxTimeInServerClock.getWeekStartEpoch(thursday),
        MaxTimeInServerClock.getWeekStartEpoch(thursday, 1), "same answer")
end)

H.test("formatIso renders a readable UTC stamp", function()
    H.assertEqual(MaxTimeInServerClock.formatIso(MONDAY), "2026-10-12T00:00:00+0000", "iso")
end)

H.test("now() reads the injected timestamp source", function()
    MaxTimeInServerClock.backend.now = function() return 1234567 end
    H.assertEqual(MaxTimeInServerClock.now(), 1234567, "now")
end)

H.run("clock")
