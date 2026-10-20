local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

S.loadModules(S.CLIENT_MODULES, "client")

local function wire(opts)
    opts = opts or {}
    local world = { nowMs = 1000, hellos = 0, notices = {}, warnings = {}, disconnects = 0,
                    serverKey = opts.serverKey or "Alpha|10.0.0.1|16261" }
    MaxTimeInServerClient.hooks = {
        sendHello = function(character)
            world.hellos = world.hellos + 1
            world.greetedAs = character
        end,
        showNotice = function(text)
            if opts.noticeThrows then error("ui exploded") end
            table.insert(world.notices, text)
        end,
        showWarning = function(text) table.insert(world.warnings, text) end,
        disconnect = function() world.disconnects = world.disconnects + 1 end,
        nowMs = function() return world.nowMs end,
        serverKey = function() return world.serverKey end,
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

H.test("an unanswered greeting is retried, because a dropped one is silent", function()
    local world = wire()
    MaxTimeInServerClient.onCreatePlayer(0)
    H.assertEqual(world.hellos, 1, "first attempt")

    MaxTimeInServerClient.update()
    H.assertEqual(world.hellos, 1, "not immediately again")

    world.nowMs = world.nowMs + 2000
    MaxTimeInServerClient.update()
    H.assertEqual(world.hellos, 2, "retried once the interval passed")
end)

H.test("an answer stops the retries", function()
    local world = wire()
    MaxTimeInServerClient.onCreatePlayer(0)
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netAllowed, { ok = true })
    for _ = 1, 5 do
        world.nowMs = world.nowMs + 5000
        MaxTimeInServerClient.update()
    end
    H.assertEqual(world.hellos, 1, "no further greetings")
end)

H.test("a refusal stops the retries too", function()
    local world = wire()
    MaxTimeInServerClient.onCreatePlayer(0)
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netBlocked, BLOCKED)
    world.nowMs = world.nowMs + 5000
    MaxTimeInServerClient.update()
    H.assertEqual(world.hellos, 1, "no further greetings")
end)

H.test("the retries give up rather than going on forever", function()
    local world = wire()
    for _ = 1, 40 do
        MaxTimeInServerClient.update()
        world.nowMs = world.nowMs + 2500
    end
    H.assertEqual(world.hellos, MaxTimeInServerConfig.helloAttempts, "stopped at the limit")
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
    H.assertEqual(world.hellos, 1, "and not twice in the same breath")
end)

H.test("a greeting the engine refuses is retried rather than swallowed", function()
    local world = wire()
    S.localPlayer = { username = "someplayer" }
    MaxTimeInServerClient.hooks.sendHello = function() error("no connection yet") end
    MaxTimeInServerClient.onCreatePlayer(0)

    MaxTimeInServerClient.hooks.sendHello = function() world.hellos = world.hellos + 1 end
    world.nowMs = world.nowMs + 2000
    MaxTimeInServerClient.update()
    H.assertEqual(world.hellos, 1, "the retry got through")
end)

H.test("a refusal is shown with the numbers in it", function()
    local world = wire()
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule, MaxTimeInServerConfig.netBlocked, BLOCKED)
    H.assertEqual(#world.notices, 1, "one notice")
    H.assertMatch(world.notices[1], "612", "minutes used")
    H.assertMatch(world.notices[1], "600", "the cap")
    H.assertMatch(world.notices[1], "2026%-10%-19", "when it resets")
end)

H.test("the mod speaks the player's language when the operator said nothing", function()
    local world = wire()
    _G.Translator = { getLanguage = function() return { name = function() return "ES" end } end }
    local silent = {}
    for key, value in pairs(BLOCKED) do silent[key] = value end
    silent.message = ""
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netBlocked, silent)
    local notice = world.notices[1]
    H.assertMatch(notice, "Has alcanzado", "its own wording in Spanish")
    H.assertMatch(notice, "Has jugado 612 de tus 600", "and the numbers too")
    H.assertMatch(notice, "Desconectando en 12", "and the countdown")
    _G.Translator = nil
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
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netBlocked, BLOCKED)
    local notice = world.notices[1]
    H.assertMatch(notice, "612", "minutes used")
    H.assertMatch(notice, "600", "the cap")
    H.assertMatch(notice, "2026%-10%-19", "when it resets")
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

-- Running out while connected: the server says so, and the client says it on.

H.test("a warning is shown and nothing is armed by it", function()
    local world = wire()
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netWarning, { remaining = 7, minutes = 593, cap = 600 })
    H.assertEqual(#world.warnings, 1, "one line over their head")
    H.assertMatch(world.warnings[1], "7", "with the minutes left in it")

    world.nowMs = world.nowMs + 600000
    MaxTimeInServerClient.update()
    H.assertEqual(world.disconnects, 0, "a warning ends nothing")
end)

H.test("running out mid-session does not read like being turned away", function()
    local world = wire()
    local timeUp = {}
    for key, value in pairs(BLOCKED) do timeUp[key] = value end
    timeUp.message = ""
    timeUp.reason = "timeUp"
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netBlocked, timeUp)
    H.assertMatch(world.notices[1], "time for this week is up", "the mid-session wording")

    local atTheDoor = {}
    for key, value in pairs(timeUp) do atTheDoor[key] = value end
    atTheDoor.reason = "join"
    local door = wire()
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netBlocked, atTheDoor)
    H.assertMatch(door.notices[1], "Weekly play limit reached", "the door's wording")
end)

H.test("the operator's wording still wins over either of them", function()
    local world = wire()
    local timeUp = {}
    for key, value in pairs(BLOCKED) do timeUp[key] = value end
    timeUp.reason = "timeUp"
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netBlocked, timeUp)
    H.assertMatch(world.notices[1], "No more for you this week%.", "the operator's line")
end)

H.test("a warning the UI refuses to show costs the player nothing", function()
    local world = wire()
    MaxTimeInServerClient.hooks.showWarning = function() error("no halo today") end
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netWarning, { remaining = 3 })
    world.nowMs = world.nowMs + 600000
    MaxTimeInServerClient.update()
    H.assertEqual(world.disconnects, 0, "still nothing armed")
end)

H.test("the client registers itself on the events it needs", function()
    wire()
    H.assertTrue(#Events.OnServerCommand.handlers > 0, "OnServerCommand")
    H.assertTrue(#Events.OnCreatePlayer.handlers > 0, "OnCreatePlayer")
    H.assertTrue(#Events.OnTick.handlers > 0, "OnTick")
    H.assertTrue(#Events.OnConnected.handlers > 0, "OnConnected")
    H.assertTrue(#Events.OnDisconnect.handlers > 0, "OnDisconnect")
    H.assertTrue(#Events.OnMainMenuEnter.handlers > 0, "OnMainMenuEnter")
end)

-- One game process can visit several servers, and more than one of them may be
-- running this mod. Anything remembered from the last one is either a way past
-- this one's quota or a disconnect nobody earned.

H.test("a second server is greeted even after the first said yes", function()
    local world = wire()
    MaxTimeInServerClient.onCreatePlayer(0)
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netAllowed, { ok = true })
    H.assertEqual(world.hellos, 1, "answered by the first server")

    world.serverKey = "Bravo|10.0.0.2|16261"
    world.nowMs = world.nowMs + 1000
    MaxTimeInServerClient.update()
    H.assertEqual(world.hellos, 2, "the new server is asked on its own account")
end)

H.test("a pending disconnect does not follow the player to another server", function()
    local world = wire()
    MaxTimeInServerClient.onCreatePlayer(0)
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netBlocked, BLOCKED)

    world.serverKey = "Bravo|10.0.0.2|16261"
    world.nowMs = world.nowMs + 1000
    MaxTimeInServerClient.update()
    world.nowMs = world.nowMs + 60000
    MaxTimeInServerClient.update()
    H.assertEqual(world.disconnects, 0, "nobody is dropped for the other server's quota")
    -- Asked again, and asked until answered: the retries start over too.
    H.assertTrue(world.hellos > 1, "and this server is asked on its own account")
end)

H.test("leaving a server forgets its answer, so a reconnect is checked again", function()
    local world = wire()
    MaxTimeInServerClient.onCreatePlayer(0)
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netAllowed, { ok = true })

    MaxTimeInServerClient.onSessionEnd()
    MaxTimeInServerClient.onConnected()
    MaxTimeInServerClient.onCreatePlayer(0)
    H.assertEqual(world.hellos, 2, "greeted again on the new session")
end)

H.test("a grace period still running is dropped when the session ends", function()
    local world = wire()
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netBlocked, BLOCKED)
    MaxTimeInServerClient.onSessionEnd()
    world.nowMs = world.nowMs + 60000
    MaxTimeInServerClient.update()
    H.assertEqual(world.disconnects, 0, "the player has already gone")
end)

H.test("a server that will not identify itself is not mistaken for a new one", function()
    local world = wire({ serverKey = "||" })
    MaxTimeInServerClient.onCreatePlayer(0)
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netAllowed, { ok = true })
    for _ = 1, 10 do
        world.nowMs = world.nowMs + 2000
        MaxTimeInServerClient.update()
    end
    H.assertEqual(world.hellos, 1, "no greeting storm from an unreadable key")
end)

H.test("an identity the engine refuses to give does not stop the handshake", function()
    local world = wire()
    MaxTimeInServerClient.hooks.serverKey = function() error("no connection yet") end
    MaxTimeInServerClient.onCreatePlayer(0)
    H.assertEqual(world.hellos, 1, "greeted anyway")
end)

H.run("client")
