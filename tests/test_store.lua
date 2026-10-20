local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

S.loadModules({ "shared/MaxTimeInServer/MaxTimeInServerConfig.lua", "server/MaxTimeInServer/MaxTimeInServerClock.lua", "server/MaxTimeInServer/MaxTimeInServerStore.lua" })
MaxTimeInServerClock.backend = S.utcCalendarBackend()

local MONDAY = S.MONDAY
local DATA = "MaxTimeInServer.txt"

local SAMPLE = [[
# MaxTimeInServer
version=1
weekStart=2026-10-12T00:00:00+0000
weekStartEpoch=1791763200

[darkkz]
role=user
minutes=132
bonusMinutes=30
exempt=false

[someone]
role=priority
minutes=600
exempt=true
]]

H.test("a fresh state has no week and no players", function()
    local state = MaxTimeInServerStore.newState()
    H.assertEqual(state.weekStartEpoch, 0, "weekStartEpoch")
    H.assertNil(next(state.players), "players")
end)

H.test("parse reads the header and every player section", function()
    local state = MaxTimeInServerStore.parse(SAMPLE)
    H.assertEqual(state.weekStartEpoch, MONDAY, "weekStartEpoch")
    H.assertEqual(state.players.darkkz.minutes, 132, "darkkz minutes")
    H.assertEqual(state.players.darkkz.bonusMinutes, 30, "darkkz bonus")
    H.assertEqual(state.players.darkkz.role, "user", "darkkz role")
    H.assertFalse(state.players.darkkz.exempt, "darkkz exempt")
    H.assertTrue(state.players.someone.exempt, "someone exempt")
    H.assertEqual(state.players.someone.role, "priority", "someone role")
end)

H.test("parse tolerates comments, blank lines, CRLF and stray spaces", function()
    local text = "; a comment\r\n\r\n  version = 1  \r\n\r\n [ ragged ] \r\n  minutes = 7 \r\n"
    local state = MaxTimeInServerStore.parse(text)
    H.assertEqual(state.version, 1, "version")
    H.assertEqual(state.players.ragged.minutes, 7, "ragged minutes")
end)

H.test("parse handles every shape of line ending and never loops", function()
    -- The engine's Lua spins forever on a pattern that can match the empty
    -- string, so the parser splits lines with find/sub. These inputs are the
    -- ones that produced empty matches: blank lines, no trailing newline, a
    -- trailing newline, and a single line.
    local cases = {
        "version=1\nweekStartEpoch=7",                 -- no trailing newline
        "version=1\nweekStartEpoch=7\n",               -- trailing newline
        "version=1\n\n\n\nweekStartEpoch=7\n\n\n",     -- runs of blank lines
        "weekStartEpoch=7",                            -- one line, no newline
        "\n\n\nweekStartEpoch=7",                      -- leading blank lines
        "weekStartEpoch=7\r\n\r\n",                    -- CRLF with a blank line
    }
    for index, text in ipairs(cases) do
        local state = MaxTimeInServerStore.parse(text)
        H.assertEqual(state.weekStartEpoch, 7, "case " .. index)
    end
end)

H.test("parse copes with a file of many accounts", function()
    local parts = { "version=1", "" }
    for index = 1, 500 do
        table.insert(parts, "[player" .. index .. "]")
        table.insert(parts, "minutes=" .. index)
        table.insert(parts, "")
    end
    local state = MaxTimeInServerStore.parse(table.concat(parts, "\n"))
    H.assertEqual(state.players.player1.minutes, 1, "first")
    H.assertEqual(state.players.player500.minutes, 500, "last")
    H.assertEqual(#state.order, 500, "all of them")
end)

H.test("serialize then parse is a round trip", function()
    local original = MaxTimeInServerStore.parse(SAMPLE)
    local again = MaxTimeInServerStore.parse(MaxTimeInServerStore.serialize(original))
    H.assertEqual(again.weekStartEpoch, original.weekStartEpoch, "weekStartEpoch")
    for username, record in pairs(original.players) do
        local copy = again.players[username]
        H.assertTrue(copy ~= nil, username .. " present")
        H.assertEqual(copy.minutes, record.minutes, username .. " minutes")
        H.assertEqual(copy.bonusMinutes, record.bonusMinutes, username .. " bonus")
        H.assertEqual(copy.exempt, record.exempt, username .. " exempt")
        H.assertEqual(copy.role, record.role, username .. " role")
    end
end)

H.test("serialize keeps players in a stable order", function()
    local state = MaxTimeInServerStore.parse(SAMPLE)
    MaxTimeInServerStore.player(state, "aaron")
    local text = MaxTimeInServerStore.serialize(state)
    local first = text:find("%[darkkz%]")
    local second = text:find("%[someone%]")
    local third = text:find("%[aaron%]")
    H.assertTrue(first < second, "darkkz before someone")
    H.assertTrue(second < third, "someone before the newcomer")
end)

H.test("unknown keys survive a round trip", function()
    local state = MaxTimeInServerStore.parse("version=1\nmysteryHeader=keep me\n\n[darkkz]\nminutes=1\nmysteryField=also keep\n")
    local text = MaxTimeInServerStore.serialize(state)
    H.assertMatch(text, "mysteryHeader=keep me", "header passthrough")
    H.assertMatch(text, "mysteryField=also keep", "record passthrough")
end)

H.test("nonsense numbers become zero and are reported", function()
    local state = MaxTimeInServerStore.parse("version=1\n\n[darkkz]\nminutes=abc\n")
    H.assertEqual(state.players.darkkz.minutes, 0, "minutes")
    H.assertTrue(#state.warnings > 0, "warnings")
end)

H.test("player() creates a record with safe defaults", function()
    local state = MaxTimeInServerStore.newState()
    local record = MaxTimeInServerStore.player(state, "newbie")
    H.assertEqual(record.minutes, 0, "minutes")
    H.assertEqual(record.bonusMinutes, 0, "bonusMinutes")
    H.assertEqual(record.role, "", "role")
    H.assertFalse(record.exempt, "exempt")
    H.assertEqual(MaxTimeInServerStore.player(state, "newbie"), record, "same record on second call")
end)

H.test("load of a missing file yields defaults and says it is new", function()
    local files = S.fakeFiles()
    local state, info = MaxTimeInServerStore.load(files, DATA)
    H.assertTrue(info.created, "created")
    H.assertFalse(info.corrupt, "corrupt")
    H.assertNil(next(state.players), "no players")
end)

H.test("load of an unparseable file does not throw and flags the content", function()
    local files = S.fakeFiles({ [DATA] = "\0\1\2 not a data file at all" })
    local state, info = MaxTimeInServerStore.load(files, DATA)
    H.assertTrue(info.corrupt, "corrupt")
    H.assertEqual(info.raw, "\0\1\2 not a data file at all", "raw kept for the rescue copy")
    H.assertNil(next(state.players), "usable state")
end)

H.test("save writes the file and stamps it", function()
    local files = S.fakeFiles()
    local state = MaxTimeInServerStore.newState()
    state.weekStartEpoch = MONDAY
    MaxTimeInServerStore.player(state, "darkkz").minutes = 5
    H.assertTrue(MaxTimeInServerStore.save(files, DATA, state, MONDAY + 60), "save returns ok")
    H.assertEqual(files.writes, 1, "one write")
    H.assertMatch(files.files[DATA], "%[darkkz%]", "player written")
    H.assertMatch(files.files[DATA], "savedAt=", "stamped")
end)

H.run("store")
