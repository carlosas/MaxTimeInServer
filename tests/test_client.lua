local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

S.loadModules(S.CLIENT_MODULES, "client")

local function wire(opts)
    opts = opts or {}
    local world = { nowMs = 1000, hellos = 0, notices = {}, disconnects = 0 }
    MaxTimeInServerClient.hooks = {
        sendHello = function(character)
            world.hellos = world.hellos + 1
            world.greetedAs = character
        end,
        showNotice = function(text)
            if opts.noticeThrows then error("ui exploded") end
            table.insert(world.notices, text)
        end,
        disconnect = function() world.disconnects = world.disconnects + 1 end,
        nowMs = function() return world.nowMs end,
    }
    MaxTimeInServerClient.reset()
    return world
end

local BLOCKED = { message = "No more for you this week.", minutes = 612, cap = 600,
                  resetsAt = "2026-10-19T00:00:00+0000", graceSeconds = 12 }

H.test("the client greets the server once its player exists", function()
    local world = wire()
    MaxTimeInServerClient.onCreatePlayer(0)
    H.assertEqual(world.hellos, 1, "one hello")
    H.assertEqual(world.greetedAs, S.localPlayer, "greeted with the local character")
    MaxTimeInServerClient.onCreatePlayer(1)
    H.assertEqual(world.hellos, 1, "split-screen players do not greet again")
end)

H.test("OnGameStart greets too, in case OnCreatePlayer had no character yet", function()
    local world = wire()
    S.localPlayer = nil
    MaxTimeInServerClient.onCreatePlayer(0)
    H.assertEqual(world.hellos, 0, "nothing to greet with yet")

    S.localPlayer = { username = "someplayer" }
    MaxTimeInServerClient.onGameStart()
    H.assertEqual(world.hellos, 1, "greeted on the second chance")
    MaxTimeInServerClient.onGameStart()
    H.assertEqual(world.hellos, 1, "and only once")
end)

H.test("a greeting the engine refuses is retried rather than swallowed", function()
    local world = wire()
    S.localPlayer = { username = "someplayer" }
    MaxTimeInServerClient.hooks.sendHello = function() error("no connection yet") end
    MaxTimeInServerClient.onCreatePlayer(0)

    MaxTimeInServerClient.hooks.sendHello = function() world.hellos = world.hellos + 1 end
    MaxTimeInServerClient.onGameStart()
    H.assertEqual(world.hellos, 1, "the second chance got through")
end)

H.test("a refusal is shown with the numbers in it", function()
    local world = wire()
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule, MaxTimeInServerConfig.netBlocked, BLOCKED)
    H.assertEqual(#world.notices, 1, "one notice")
    H.assertMatch(world.notices[1], "612", "minutes used")
    H.assertMatch(world.notices[1], "600", "the cap")
    H.assertMatch(world.notices[1], "2026%-10%-19", "when it resets")
end)

H.test("the operator's wording is what the player reads first", function()
    local world = wire()
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netBlocked, BLOCKED)
    local notice = world.notices[1]
    H.assertMatch(notice, "No more for you this week%.", "the wording")
    H.assertTrue(notice:find("No more for you") < notice:find("612"),
        "and it comes before the numbers")
end)

H.test("the numbers are the mod's own, whatever the operator writes", function()
    local world = wire()
    local silent = {}
    for key, value in pairs(BLOCKED) do silent[key] = value end
    silent.message = ""
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netBlocked, silent)
    local notice = world.notices[1]
    H.assertMatch(notice, "612", "minutes used")
    H.assertMatch(notice, "600", "the cap")
    H.assertMatch(notice, "2026%-10%-19", "when it resets")
    H.assertFalse(notice:find("^%s") ~= nil, "no empty line where the wording would be")
end)

H.test("the connection is dropped once the grace period is over", function()
    local world = wire()
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule, MaxTimeInServerConfig.netBlocked, BLOCKED)
    world.nowMs = world.nowMs + 11999
    MaxTimeInServerClient.update()
    H.assertEqual(world.disconnects, 0, "not yet")
    world.nowMs = world.nowMs + 1
    MaxTimeInServerClient.update()
    H.assertEqual(world.disconnects, 1, "dropped")
    MaxTimeInServerClient.update()
    H.assertEqual(world.disconnects, 1, "only once")
end)

H.test("a notice the UI refuses to show drops the connection almost at once", function()
    local world = wire({ noticeThrows = true })
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule, MaxTimeInServerConfig.netBlocked, BLOCKED)
    world.nowMs = world.nowMs + 1999
    MaxTimeInServerClient.update()
    H.assertEqual(world.disconnects, 0, "a moment to settle")
    world.nowMs = world.nowMs + 1
    MaxTimeInServerClient.update()
    H.assertEqual(world.disconnects, 1, "dropped without waiting out the grace")
end)

H.test("a refusal with no numbers still reads as a sentence", function()
    local world = wire()
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule, MaxTimeInServerConfig.netBlocked, {})
    H.assertEqual(#world.notices, 1, "one notice")
    H.assertTrue(#world.notices[1] > 20, "not empty")
end)

H.test("unrelated server commands are ignored", function()
    local world = wire()
    MaxTimeInServerClient.onServerCommand("SomeOtherMod", MaxTimeInServerConfig.netBlocked, BLOCKED)
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule, "whatever", BLOCKED)
    H.assertEqual(#world.notices, 0, "nothing shown")
    world.nowMs = world.nowMs + 60000
    MaxTimeInServerClient.update()
    H.assertEqual(world.disconnects, 0, "nothing dropped")
end)

H.test("the client registers itself on the events it needs", function()
    wire()
    H.assertTrue(#Events.OnServerCommand.handlers > 0, "OnServerCommand")
    H.assertTrue(#Events.OnCreatePlayer.handlers > 0, "OnCreatePlayer")
    H.assertTrue(#Events.OnTick.handlers > 0, "OnTick")
end)

H.run("client")
