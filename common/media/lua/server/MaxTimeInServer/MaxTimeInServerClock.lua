--[[
Week boundaries. A week runs for seven days from 00:00:00 on the day the server
picks, in the timezone the game server's JVM runs in. On a UTC host there is no
DST to worry about; on one that observes it, the week containing a clock change
is an hour out.

The civil-time lookup sits behind MaxTimeInServerClock.backend so the week maths can
be exercised without a running game.
]]

MaxTimeInServerClock = MaxTimeInServerClock or {}

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

MaxTimeInServerClock.backend = javaBackend

--- Epoch second of the 00:00:00 that opens the week containing `epoch`.
-- `startDay` is the weekday the week begins on, 1 = Monday .. 7 = Sunday, and
-- defaults to Monday so a caller that does not care keeps the old behaviour.
function MaxTimeInServerClock.getWeekStartEpoch(epoch, startDay)
    startDay = tonumber(startDay) or 1
    local fields = MaxTimeInServerClock.backend.fields(epoch)
    local secondsIntoDay = fields.hour * 3600 + fields.minute * 60 + fields.second
    local daysIntoWeek = (fields.dayOfWeek - startDay + 7) % 7
    return epoch - secondsIntoDay - daysIntoWeek * SECONDS_PER_DAY
end

--- Human-readable stamp for the data file and the log.
function MaxTimeInServerClock.formatIso(epoch)
    return MaxTimeInServerClock.backend.formatIso(epoch)
end

--- Current real time in epoch seconds.
function MaxTimeInServerClock.now()
    return MaxTimeInServerClock.backend.now()
end
