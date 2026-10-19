-- Fake Project Zomboid environment so the mod's modules can run under a plain
-- Lua interpreter. The modules are written PZ-style (they assign globals and
-- never call require), so loading them is just dofile.
local S = {}

local LUA_ROOT = "common/media/lua/"

-- Loaded in the same order the dedicated server loads a mod folder: every
-- module must be safe to load without its siblings being present yet.
-- Loaded in the order a dedicated server loads them (shared, then client,
-- then server - GameServer.doMinimumInit runs all three): every module must be
-- safe to load without its siblings being present yet.
S.SERVER_MODULES = {
    "shared/MaxTimeInServer/MaxTimeInServerConfig.lua",
    "shared/MaxTimeInServer/MaxTimeInServerText.lua",
    "server/MaxTimeInServer/MaxTimeInServerClock.lua",
    "server/MaxTimeInServer/MaxTimeInServerGate.lua",
    "server/MaxTimeInServer/MaxTimeInServerPlayers.lua",
    "server/MaxTimeInServer/MaxTimeInServerQuota.lua",
    "server/MaxTimeInServer/MaxTimeInServerStore.lua",
}

S.CLIENT_MODULES = {
    "shared/MaxTimeInServer/MaxTimeInServerConfig.lua",
    "shared/MaxTimeInServer/MaxTimeInServerText.lua",
    "client/MaxTimeInServer/MaxTimeInServerClient.lua",
}

S.MODULES = S.SERVER_MODULES

-- Collects everything the mod logs, so tests can assert on it.
S.logLines = {}

function S.loadModules(moduleList, side)
    moduleList = moduleList or S.MODULES
    S.side = side or "server"
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
    _G.isServer = function() return S.side ~= "client" end
    _G.isClient = function() return S.side == "client" end
    -- OnCreatePlayer hands over an index, and the game resolves the character
    -- with these. Tests set S.localPlayer to decide what they get back.
    S.localPlayer = { username = "someplayer", isLocalPlayer = function() return true end }
    _G.getSpecificPlayer = function(index)
        if index == 0 then return S.localPlayer end
        return nil
    end
    _G.getPlayer = function() return S.localPlayer end
    for _, name in ipairs(moduleList) do
        local chunk, err = loadfile(LUA_ROOT .. name)
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
-- dayOfWeek is 1 = Monday .. 7 = Sunday, matching MaxTimeInServerClock's contract.
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

-- Stand-in for the connected players the server can see. Each entry is what
-- MaxTimeInServerPlayers.online() yields: a username and the role it holds.
function S.fakePlayers(entries)
    local players = { entries = entries or {} }
    function players.online()
        local out = {}
        for _, entry in ipairs(players.entries) do
            table.insert(out, { username = entry.username, role = entry.role })
        end
        return out
    end
    function players.find(username)
        for _, entry in ipairs(players.entries) do
            if entry.username == username then return entry end
        end
        return nil
    end
    return players
end

-- Records everything the server would send to a client.
function S.fakeNetwork()
    local net = { sent = {} }
    function net.send(player, module, command, args)
        table.insert(net.sent, { player = player, module = module, command = command, args = args })
    end
    function net.lastTo(username)
        for index = #net.sent, 1, -1 do
            local message = net.sent[index]
            if message.player ~= nil and message.player.username == username then return message end
        end
        return nil
    end
    return net
end

-- Monday 2026-10-12 00:00:00 UTC, used as the anchor in most tests.
S.MONDAY = 1791763200

return S
