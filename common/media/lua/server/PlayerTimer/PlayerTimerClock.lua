--[[
Week boundaries. A week runs from Monday 00:00:00 inclusive to the next Monday
00:00:00 exclusive, in the timezone the game server's JVM runs in (the host is
Etc/UTC, so there is no DST to worry about).

The civil-time lookup sits behind PlayerTimerClock.backend so the week maths can
be exercised without a running game.
]]

PlayerTimerClock = PlayerTimerClock or {}

local SECONDS_PER_DAY = 86400

-- java.util.Calendar / SimpleDateFormat are both reachable from PZ's Lua and are
-- used by the base game, so this is the production backend.
local javaBackend = {
    -- Returns { hour, minute, second, dayOfWeek } with dayOfWeek 1 = Monday .. 7 = Sunday.
    fields = function(epoch)
        local cal = Calendar.getInstance()
        cal:setTimeInMillis(epoch * 1000)
        return {
            hour = cal:get(Calendar.HOUR_OF_DAY),
            minute = cal:get(Calendar.MINUTE),
            second = cal:get(Calendar.SECOND),
            -- Calendar.DAY_OF_WEEK is 1 = Sunday .. 7 = Saturday.
            dayOfWeek = (cal:get(Calendar.DAY_OF_WEEK) + 5) % 7 + 1,
        }
    end,

    formatIso = function(epoch)
        local formatter = SimpleDateFormat.new("yyyy-MM-dd'T'HH:mm:ssZ")
        return formatter:format(epoch * 1000)
    end,

    now = function()
        return getTimestamp()
    end,
}

PlayerTimerClock.backend = javaBackend

--- Epoch second of the Monday 00:00:00 that opens the week containing `epoch`.
function PlayerTimerClock.getWeekStartEpoch(epoch)
    local fields = PlayerTimerClock.backend.fields(epoch)
    local secondsIntoDay = fields.hour * 3600 + fields.minute * 60 + fields.second
    local daysIntoWeek = fields.dayOfWeek - 1
    return epoch - secondsIntoDay - daysIntoWeek * SECONDS_PER_DAY
end

--- Human-readable stamp for the data file and the log.
function PlayerTimerClock.formatIso(epoch)
    return PlayerTimerClock.backend.formatIso(epoch)
end

--- Current real time in epoch seconds.
function PlayerTimerClock.now()
    return PlayerTimerClock.backend.now()
end
