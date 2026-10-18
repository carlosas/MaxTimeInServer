local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

S.loadModules(S.CLIENT_MODULES, "client")

local function wire(opts)
    opts = opts or {}
    local world = { nowMs = 1000, hellos = 0, notices = {}, disconnects = 0 }
    PlayerTimerClient.hooks = {
        sendHello = function() world.hellos = world.hellos + 1 end,
        showNotice = function(text)
            if opts.noticeThrows then error("ui exploded") end
            table.insert(world.notices, text)
        end,
        disconnect = function() world.disconnects = world.disconnects + 1 end,
        nowMs = function() return world.nowMs end,
    }
    PlayerTimerClient.reset()
    return world
end

local BLOCKED = { minutes = 612, cap = 600, resetsAt = "2026-10-19T00:00:00+0000", graceSeconds = 12 }

H.test("the client greets the server once its player exists", function()
    local world = wire()
    PlayerTimerClient.onCreatePlayer(0)
    H.assertEqual(world.hellos, 1, "one hello")
    PlayerTimerClient.onCreatePlayer(1)
    H.assertEqual(world.hellos, 1, "split-screen players do not greet again")
end)

H.test("a refusal is shown with the numbers in it", function()
    local world = wire()
    PlayerTimerClient.onServerCommand(PlayerTimerConfig.netModule, PlayerTimerConfig.netBlocked, BLOCKED)
    H.assertEqual(#world.notices, 1, "one notice")
    H.assertMatch(world.notices[1], "612", "minutes used")
    H.assertMatch(world.notices[1], "600", "the cap")
    H.assertMatch(world.notices[1], "2026%-10%-19", "when it resets")
end)

H.test("the connection is dropped once the grace period is over", function()
    local world = wire()
    PlayerTimerClient.onServerCommand(PlayerTimerConfig.netModule, PlayerTimerConfig.netBlocked, BLOCKED)
    world.nowMs = world.nowMs + 11999
    PlayerTimerClient.update()
    H.assertEqual(world.disconnects, 0, "not yet")
    world.nowMs = world.nowMs + 1
    PlayerTimerClient.update()
    H.assertEqual(world.disconnects, 1, "dropped")
    PlayerTimerClient.update()
    H.assertEqual(world.disconnects, 1, "only once")
end)

H.test("a notice the UI refuses to show still drops the connection", function()
    local world = wire({ noticeThrows = true })
    PlayerTimerClient.onServerCommand(PlayerTimerConfig.netModule, PlayerTimerConfig.netBlocked, BLOCKED)
    world.nowMs = world.nowMs + 12000
    PlayerTimerClient.update()
    H.assertEqual(world.disconnects, 1, "dropped anyway")
end)

H.test("a refusal with no numbers still reads as a sentence", function()
    local world = wire()
    PlayerTimerClient.onServerCommand(PlayerTimerConfig.netModule, PlayerTimerConfig.netBlocked, {})
    H.assertEqual(#world.notices, 1, "one notice")
    H.assertTrue(#world.notices[1] > 20, "not empty")
end)

H.test("unrelated server commands are ignored", function()
    local world = wire()
    PlayerTimerClient.onServerCommand("SomeOtherMod", PlayerTimerConfig.netBlocked, BLOCKED)
    PlayerTimerClient.onServerCommand(PlayerTimerConfig.netModule, "whatever", BLOCKED)
    H.assertEqual(#world.notices, 0, "nothing shown")
    world.nowMs = world.nowMs + 60000
    PlayerTimerClient.update()
    H.assertEqual(world.disconnects, 0, "nothing dropped")
end)

H.test("the client registers itself on the events it needs", function()
    wire()
    H.assertTrue(#Events.OnServerCommand.handlers > 0, "OnServerCommand")
    H.assertTrue(#Events.OnCreatePlayer.handlers > 0, "OnCreatePlayer")
    H.assertTrue(#Events.OnTick.handlers > 0, "OnTick")
end)

H.run("client")
