local H = dofile("tests/harness.lua")
local S = dofile("tests/pz_stubs.lua")

S.loadModules()
MaxTimeInServerClock.backend = S.utcCalendarBackend()

local MONDAY = S.MONDAY
local DATA = "MaxTimeInServer.txt"

-- A stand-in for the IsoPlayer the server hands to OnClientCommand.
local function fakePlayer(username, role)
    return {
        username = username,
        getUsername = function(self) return self.username end,
        getRole = function(self)
            if self.role == nil then return nil end
            local name = self.role
            return { getName = function() return name end }
        end,
        getAccessLevel = function(self) return self.accessLevel end,
        role = role,
    }
end

local function makeGate(opts)
    opts = opts or {}
    local gate = {}
    MaxTimeInServerClock.backend = S.utcCalendarBackend()
    local now = opts.startEpoch or (MONDAY + 3600)
    MaxTimeInServerClock.backend.now = function() return now end

    gate.files = S.fakeFiles(opts.files)
    gate.net = S.fakeNetwork()
    gate.config = {}
    for key, value in pairs(MaxTimeInServerConfig) do gate.config[key] = value end
    gate.config.capMinutes = opts.capMinutes or 600
    gate.config.resetDay = 1  -- these fixtures are anchored on a Monday

    MaxTimeInServerQuota.configure({
        config = gate.config,
        clock = MaxTimeInServerClock,
        store = MaxTimeInServerStore,
        files = gate.files,
        players = S.fakePlayers({}),
    })
    MaxTimeInServerQuota.start()

    MaxTimeInServerGate.configure({
        config = gate.config,
        quota = MaxTimeInServerQuota,
        players = MaxTimeInServerPlayers,
        net = gate.net,
    })
    return gate
end

local OVER_CAP = "version=1\nweekStartEpoch=" .. MONDAY ..
    "\n\n[darkkz]\nminutes=612\n"

H.test("a player who is let in is told where they stand", function()
    local gate = makeGate({ files = { [DATA] = "version=1\nweekStartEpoch=" .. MONDAY ..
        "\n\n[darkkz]\nminutes=132\n" } })
    MaxTimeInServerGate.onClientCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netHello, fakePlayer("darkkz", "user"))

    local message = gate.net.lastTo("darkkz")
    H.assertEqual(message.command, MaxTimeInServerConfig.netAllowed, "let in")
    H.assertEqual(message.args.minutes, 132, "with the minutes")
    H.assertEqual(message.args.cap, 600, "and the cap")
end)

H.test("an exempt player is let in without numbers about themselves", function()
    local gate = makeGate({ files = { [DATA] = "version=1\nweekStartEpoch=" .. MONDAY ..
        "\n\n[theboss]\nminutes=0\n" } })
    MaxTimeInServerGate.onClientCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netHello, fakePlayer("theboss", "admin"))

    local message = gate.net.lastTo("theboss")
    H.assertEqual(message.command, MaxTimeInServerConfig.netAllowed, "let in")
    H.assertNil(message.args.minutes, "nothing is counted for them, so nothing is said")
    H.assertNil(message.args.cap, "nor a cap they are not held to")
end)

H.test("the door says it is the door, so the client can word it", function()
    local gate = makeGate({ files = { [DATA] = OVER_CAP } })
    MaxTimeInServerGate.onClientCommand(MaxTimeInServerConfig.netModule,
        MaxTimeInServerConfig.netHello, fakePlayer("darkkz", "user"))
    local message = gate.net.lastTo("darkkz")
    H.assertEqual(message.command, MaxTimeInServerConfig.netBlocked, "refused")
    H.assertEqual(message.args.reason, "join", "turned away at the door")
end)

H.test("a player over the cap is told to leave, with the numbers", function()
    local gate = makeGate({ files = { [DATA] = OVER_CAP } })
    local player = fakePlayer("darkkz", "user")
    MaxTimeInServerGate.onClientCommand(gate.config.netModule, gate.config.netHello, player)

    local message = gate.net.lastTo("darkkz")
    H.assertTrue(message ~= nil, "a message was sent")
    H.assertEqual(message.command, gate.config.netBlocked, "command")
    H.assertEqual(message.args.minutes, 612, "minutes")
    H.assertEqual(message.args.cap, 600, "cap")
    H.assertEqual(message.args.graceSeconds, gate.config.graceSeconds, "grace")
    H.assertEqual(message.args.message, gate.config.blockedMessage, "the operator's wording")
    H.assertMatch(message.args.resetsAt, "2026%-10%-19", "reset stamp")
    H.assertMatch(S.logText(), "refused darkkz", "logged")
end)

H.test("a player under the cap is told they may play, so they stop asking", function()
    local gate = makeGate({ files = { [DATA] = "version=1\nweekStartEpoch=" ..
        MONDAY .. "\n\n[darkkz]\nminutes=10\n" } })
    MaxTimeInServerGate.onClientCommand(gate.config.netModule, gate.config.netHello,
        fakePlayer("darkkz", "user"))
    local message = gate.net.lastTo("darkkz")
    H.assertEqual(message.command, gate.config.netAllowed, "an answer, not silence")
end)

H.test("an exempt role is allowed even over the cap", function()
    local gate = makeGate({ files = { [DATA] = OVER_CAP } })
    MaxTimeInServerGate.onClientCommand(gate.config.netModule, gate.config.netHello,
        fakePlayer("darkkz", "moderator"))
    H.assertEqual(gate.net.lastTo("darkkz").command, gate.config.netAllowed, "allowed")
end)

H.test("commands from other modules are ignored", function()
    local gate = makeGate({ files = { [DATA] = OVER_CAP } })
    MaxTimeInServerGate.onClientCommand("SomeOtherMod", gate.config.netHello, fakePlayer("darkkz", "user"))
    MaxTimeInServerGate.onClientCommand(gate.config.netModule, "somethingElse", fakePlayer("darkkz", "user"))
    H.assertEqual(#gate.net.sent, 0, "nothing sent")
end)

H.test("a player the server cannot name is ignored", function()
    local gate = makeGate({ files = { [DATA] = OVER_CAP } })
    MaxTimeInServerGate.onClientCommand(gate.config.netModule, gate.config.netHello, nil)
    MaxTimeInServerGate.onClientCommand(gate.config.netModule, gate.config.netHello, fakePlayer("", "user"))
    H.assertEqual(#gate.net.sent, 0, "nothing sent")
end)

H.test("the role falls back to the access level when there is no role object", function()
    local gate = makeGate({ files = { [DATA] = OVER_CAP } })
    local player = fakePlayer("darkkz", nil)
    player.accessLevel = "Admin"
    MaxTimeInServerGate.onClientCommand(gate.config.netModule, gate.config.netHello, player)
    H.assertEqual(gate.net.lastTo("darkkz").command, gate.config.netAllowed,
        "an admin by access level is exempt too")
end)

H.test("a handshake never raises, however broken the player object is", function()
    local gate = makeGate({ files = { [DATA] = OVER_CAP } })
    local broken = { getUsername = function() error("no username for you") end }
    H.assertTrue(pcall(MaxTimeInServerGate.onClientCommand,
        gate.config.netModule, gate.config.netHello, broken), "survived")
end)

H.test("the gate registers itself on OnClientCommand", function()
    makeGate({})
    MaxTimeInServerGate.registerEvents()
    H.assertTrue(#Events.OnClientCommand.handlers > 0, "OnClientCommand")
end)

H.run("gate")
