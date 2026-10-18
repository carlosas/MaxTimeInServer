--[[
MaxTimeInServer - weekly connected-time quota.

Lives in shared/ because both sides need it: the server reads the quota rules,
the client needs the handshake names.

The cap and the per-player allowances here are only seed values. Once
<Zomboid>/Lua/MaxTimeInServer.txt exists, that file is authoritative, so the server
owner can change them without redeploying the mod to everybody.
]]

MaxTimeInServerConfig = {
    -- Weekly budget of real connected minutes, used only when the data file is
    -- first created. Afterwards the file's capMinutes wins.
    capMinutes = 600,

    -- Accounts holding one of these roles are never counted and never blocked,
    -- so an operator can always get in. Role names as the server stores them:
    -- banned, user, priority, observer, gm, moderator, admin.
    exemptRoles = { "admin", "moderator", "gm" },

    -- Lives in <Zomboid>/Lua/. The engine only accepts .lua, .txt and .bin.
    dataFile = "MaxTimeInServer.txt",

    -- Real seconds between two sweeps. The sweep is driven by a game-time
    -- event, so it is checked far more often than this and returns early until
    -- the interval has passed. Every sweep re-reads the data file and rewrites
    -- it if anything changed, which is what makes a hand edit of the file take
    -- effect within one interval.
    sweepIntervalSeconds = 60,

    -- Upper bound on the time credited by a single sweep. Protects the counters
    -- from a clock step or a long server freeze.
    maxCreditSecondsPerSweep = 3600,

    -- Handshake between the client and the server.
    netModule = "MaxTimeInServer",
    netHello = "hello",
    netBlocked = "blocked",

    -- How long a blocked player gets to read the notice before their client
    -- drops the connection by itself.
    graceSeconds = 12,

    -- Extra log lines on every sweep. Noisy; off by default.
    debug = false,
}
