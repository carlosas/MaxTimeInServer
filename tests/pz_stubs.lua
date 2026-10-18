-- Fake Project Zomboid environment so the mod's modules can run under a plain
-- Lua interpreter. The modules are written PZ-style (they assign globals and
-- never call require), so loading them is just dofile.
local S = {}

local MOD_DIR = "common/media/lua/server/PlayerTimer/"

-- Loaded in the same order the dedicated server loads a mod folder: every
-- module must be safe to load without its siblings being present yet.
S.MODULES = {
    "PlayerTimerConfig.lua",
    "PlayerTimerClock.lua",
    "PlayerTimerStore.lua",
    "PlayerTimerRoles.lua",
    "PlayerTimerQuota.lua",
}

-- Collects everything the mod logs, so tests can assert on it.
S.logLines = {}

function S.loadModules(moduleList)
    moduleList = moduleList or S.MODULES
    S.logLines = {}
    -- PZ exposes print(); the mod uses it for its own log lines.
    local realPrint = print
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        table.insert(S.logLines, table.concat(parts, " "))
    end
    -- Events is created by the engine; the mod only calls Events.X.Add.
    _G.Events = setmetatable({}, {
        __index = function(tbl, key)
            local handlers = {}
            local event = { handlers = handlers, Add = function(_, fn) table.insert(handlers, fn) end }
            event.Add = function(fn) table.insert(handlers, fn) end
            tbl[key] = event
            return event
        end,
    })
    _G.isServer = function() return true end
    for _, name in ipairs(moduleList) do
        local chunk, err = loadfile(MOD_DIR .. name)
        if not chunk then
            _G.print = realPrint
            error("cannot load " .. name .. ": " .. tostring(err))
        end
        chunk()
    end
    S.restorePrint = function() _G.print = realPrint end
end

function S.logText()
    return table.concat(S.logLines, "\n")
end

-- A civil-time backend equivalent to java.util.Calendar on a UTC server.
-- dayOfWeek is 1 = Monday .. 7 = Sunday, matching PlayerTimerClock's contract.
function S.utcCalendarBackend()
    return {
        fields = function(epoch)
            local t = os.date("!*t", epoch)
            return {
                hour = t.hour,
                minute = t.min,
                second = t.sec,
                dayOfWeek = (t.wday + 5) % 7 + 1, -- os.date: 1 = Sunday
            }
        end,
        formatIso = function(epoch)
            return os.date("!%Y-%m-%dT%H:%M:%S+0000", epoch)
        end,
    }
end

-- In-memory stand-in for getFileReader/getFileWriter.
function S.fakeFiles(initial)
    local files = {}
    for name, text in pairs(initial or {}) do files[name] = text end
    return {
        files = files,
        writes = 0,
        read = function(self, name) return self.files[name] end,
        write = function(self, name, text)
            self.files[name] = text
            self.writes = self.writes + 1
            return true
        end,
    }
end

-- Stand-in for ServerWorldDatabase/Roles. Tracks every role change.
function S.fakeRoles(roleByUser, steamIdByUser)
    local backend = {
        roles = roleByUser or {},
        steamIds = steamIdByUser or {},
        calls = {},
        failSetRole = false,
    }
    function backend.bannedRoleName() return "banned" end
    function backend.getRoleName(username) return backend.roles[username] end
    function backend.getSteamId(username) return backend.steamIds[username] end
    function backend.setRole(username, roleName)
        table.insert(backend.calls, { username = username, role = roleName })
        if backend.failSetRole then return nil, "db offline" end
        backend.roles[username] = roleName
        return true
    end
    function backend.setRoleCallsFor(username)
        local out = {}
        for _, call in ipairs(backend.calls) do
            if call.username == username then table.insert(out, call.role) end
        end
        return out
    end
    return backend
end

-- Monday 2026-10-12 00:00:00 UTC, used as the anchor in most tests.
S.MONDAY = 1791763200

return S
