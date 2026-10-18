local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

S.loadModules({ "PlayerTimerConfig.lua", "PlayerTimerRoles.lua" })

-- Replaces the raw ServerWorldDatabase / Roles calls.
local function fakeJava(opts)
    opts = opts or {}
    local roles = opts.roles or { darkkz = "user" }
    local java = { roles = roles, setCalls = 0, snapshotCalls = 0 }
    function java.bannedRoleName() return "banned" end
    function java.getRoleName(username)
        if opts.readThrows then error("db offline") end
        return java.roles[username]
    end
    function java.setRole(username, roleName)
        java.setCalls = java.setCalls + 1
        if opts.writeThrows then error("db offline") end
        if opts.writeSilentlyIgnored then return nil end
        java.roles[username] = roleName
        return nil
    end
    function java.snapshot()
        java.snapshotCalls = java.snapshotCalls + 1
        if opts.snapshotThrows then error("db offline") end
        return { darkkz = { steamid = "76561197972620811", role = "user" } }
    end
    return java
end

H.test("the banned role name comes from the server", function()
    PlayerTimerRoles.java = fakeJava()
    H.assertEqual(PlayerTimerRoles.bannedRoleName(), "banned", "banned role")
end)

H.test("a successful role change is confirmed by re-reading it", function()
    local java = fakeJava()
    PlayerTimerRoles.java = java
    H.assertTrue(PlayerTimerRoles.setRole("darkkz", "banned"), "setRole")
    H.assertEqual(java.roles.darkkz, "banned", "stored role")
    H.assertEqual(java.setCalls, 1, "one write")
end)

H.test("a role change the database silently ignored is reported as a failure", function()
    PlayerTimerRoles.java = fakeJava({ writeSilentlyIgnored = true })
    local ok, err = PlayerTimerRoles.setRole("darkkz", "banned")
    H.assertNil(ok, "setRole")
    H.assertMatch(err, "still", "explains the mismatch")
end)

H.test("a throwing role change is caught", function()
    PlayerTimerRoles.java = fakeJava({ writeThrows = true })
    local ok, err = PlayerTimerRoles.setRole("darkkz", "banned")
    H.assertNil(ok, "setRole")
    H.assertMatch(err, "db offline", "message carried")
end)

H.test("a throwing role read yields nil instead of an error", function()
    PlayerTimerRoles.java = fakeJava({ readThrows = true })
    H.assertNil(PlayerTimerRoles.getRoleName("darkkz"), "getRoleName")
end)

H.test("steam ids come from a snapshot that is only taken once", function()
    local java = fakeJava()
    PlayerTimerRoles.java = java
    PlayerTimerRoles.clearCache()
    H.assertEqual(PlayerTimerRoles.getSteamId("darkkz"), "76561197972620811", "steamid")
    H.assertEqual(PlayerTimerRoles.getSteamId("darkkz"), "76561197972620811", "steamid again")
    H.assertEqual(java.snapshotCalls, 1, "one snapshot")
end)

H.test("an unknown account has no steam id and does not blow up", function()
    PlayerTimerRoles.java = fakeJava()
    PlayerTimerRoles.clearCache()
    H.assertNil(PlayerTimerRoles.getSteamId("nobody"), "steamid")
end)

H.test("a failing snapshot is survivable", function()
    PlayerTimerRoles.java = fakeJava({ snapshotThrows = true })
    PlayerTimerRoles.clearCache()
    H.assertNil(PlayerTimerRoles.getSteamId("darkkz"), "steamid")
end)

H.run("roles")
