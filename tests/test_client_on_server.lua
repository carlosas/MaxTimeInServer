local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

-- The dedicated server loads client Lua too (GameServer.doMinimumInit runs
-- shared, client and server), so every client handler must decide for itself
-- that it is on a server and do nothing.
S.loadModules(S.CLIENT_MODULES, "server")

local sent = 0
MaxTimeInServerClient.hooks = {
    sendHello = function() sent = sent + 1 end,
    showNotice = function() error("a server has no screen") end,
    disconnect = function() error("a server must not disconnect itself") end,
    nowMs = function() return 0 end,
}
MaxTimeInServerClient.reset()

H.test("a player appearing on the server does not greet anybody", function()
    MaxTimeInServerClient.onCreatePlayer(0)
    H.assertEqual(sent, 0, "no hello")
end)

H.test("a stray server command is ignored rather than shown", function()
    MaxTimeInServerClient.onServerCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netBlocked, { minutes = 1, cap = 1 })
    H.assertTrue(pcall(MaxTimeInServerClient.update), "nothing scheduled")
end)

H.run("client/server")
