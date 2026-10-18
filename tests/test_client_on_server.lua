local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

-- The dedicated server loads client Lua too (GameServer.doMinimumInit runs
-- shared, client and server), so every client handler must decide for itself
-- that it is on a server and do nothing.
S.loadModules(S.CLIENT_MODULES, "server")

local sent = 0
PlayerTimerClient.hooks = {
    sendHello = function() sent = sent + 1 end,
    showNotice = function() error("a server has no screen") end,
    disconnect = function() error("a server must not disconnect itself") end,
    nowMs = function() return 0 end,
}
PlayerTimerClient.reset()

H.test("a player appearing on the server does not greet anybody", function()
    PlayerTimerClient.onCreatePlayer(0)
    H.assertEqual(sent, 0, "no hello")
end)

H.test("a stray server command is ignored rather than shown", function()
    PlayerTimerClient.onServerCommand(PlayerTimerConfig.netModule,
        PlayerTimerConfig.netBlocked, { minutes = 1, cap = 1 })
    H.assertTrue(pcall(PlayerTimerClient.update), "nothing scheduled")
end)

H.run("client/server")
