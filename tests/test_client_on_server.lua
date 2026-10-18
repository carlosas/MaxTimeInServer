local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

-- The dedicated server loads client Lua too (GameServer.doMinimumInit runs
-- shared, client and server), so the client module must sit still there.
S.loadModules(S.CLIENT_MODULES, "server")

H.test("the client module stays out of the way on a server", function()
    H.assertFalse(PlayerTimerClient.active, "not active server-side")
    H.assertEqual(#Events.OnServerCommand.handlers, 0, "no server command handler")
end)

H.run("client/server")
