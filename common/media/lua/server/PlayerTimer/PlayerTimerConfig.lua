--[[
PlayerTimer - weekly connected-time quota (server side only).

Everything here is a seed value. Once the data file exists, the cap and the
per-player allowances are read from it, so the server owner can change them
without redeploying the mod.
]]

PlayerTimerConfig = {
    -- Weekly budget of real connected minutes. Only used the first time the
    -- data file is created; afterwards the file's capMinutes wins.
    capMinutes = 600,

    -- Accounts holding one of these roles are never counted and never blocked,
    -- so an operator can always get in. Role names as stored in the server's
    -- role table: banned, user, priority, observer, gm, moderator, admin.
    exemptRoles = { "admin", "moderator", "gm" },

    -- Lives in <Zomboid>/Lua/. The engine only accepts .lua, .txt and .bin.
    dataFile = "PlayerTimer.txt",

    -- Real seconds between two sweeps. The sweep is driven by a game-time
    -- event, so it is checked far more often than this and simply returns
    -- early until the interval has passed. Every sweep re-reads the data file
    -- and rewrites it if anything changed, which is what makes a hand edit of
    -- the file take effect within one interval.
    sweepIntervalSeconds = 60,

    -- Upper bound on the time credited by a single sweep. Protects the
    -- counters from a clock step or a long server freeze.
    maxCreditSecondsPerSweep = 3600,

    -- Extra log lines for every sweep. Noisy; off by default.
    debug = false,
}
