# MaxTimeInServer

A mod for **Project Zomboid Build 42** dedicated servers. It counts how many
real minutes each account spends connected during the current week and turns
away accounts that have used up their weekly budget. The default budget is
**600 minutes (10 hours)** per week, Monday 00:00 to Sunday 23:59 in the
server's timezone.

It exists to keep the pace of a server fair: when a few players put in many more
hours than the rest, the world is already picked clean by the time everyone else
logs in.

## How it blocks, and why it works that way

Build 42's server-side Lua cannot refuse a login. There is no connection event
at all (the full event list in `zombie/Lua/LuaEventManager` has no
`OnPlayerConnect`), `zombie.network.GameServer` is annotated `@HiddenFromLua`,
and `ServerWorldDatabase`, `Roles` and `BanSystem` are simply absent from the
server's Lua namespace — all three come back `nil`. There is no reachable way to
ban, kick or change a role from a server mod.

What the server *can* do is talk to a client that has just arrived. So:

1. The mod's client half greets the server as soon as its player exists.
2. The server looks up the account's counter and, if the budget is spent, sends
   back the numbers.
3. The client shows them and disconnects itself — straight away if the player
   dismisses the notice, and in any case once a short grace period is up.

```
client joins ──► sendClientCommand("MaxTimeInServer", "hello")
                            │
server          MaxTimeInServerGate ──► MaxTimeInServerQuota.verdict("darkkz", "user")
                            │        612 of 600 minutes this week
                            ▼
                sendServerCommand(player, "MaxTimeInServer", "blocked",
                                  {minutes=612, cap=600, resetsAt=…})
                            │
client          notice ──► forceDisconnect()
```

That leans on the client cooperating, and the base game already enforces it.
`DoLuaChecksum=true` makes the server MD5 every Lua file both sides load —
`GameServer.doMinimumInit` runs `initChecksum()`, then `LoadDirBase("shared")`,
`LoadDirBase("client")`, `LoadDirBase("server")`, then `finishChecksum()`, so
the server hashes the **client** Lua of every mod too. A client whose hashes
disagree is dropped by vanilla ("*incorrect checksum … will be kicked in N ms
because Lua/script checksums do not match*") before the quota is even
consulted, and only the `admin` role holds the `BypassLuaChecksum` capability.
Editing this mod locally therefore gets you kicked; defeating the quota means
patching the game's Java, not editing a `.lua`.

A player who crosses the cap *while connected* is not kicked — they keep playing
until they disconnect and simply cannot get back in. That is deliberate; the
mid-session case is a later iteration.

## Build 42 folder layout

Build 42 discovers a mod by its **version directory**, and `versionMin` in the
manifest makes it skip the mod entirely. Both facts were measured against the
live server — see `tools/layout-probe/`, which records the two probe rounds and
their results.

```
MaxTimeInServer/
  42/mod.info                                     <- the manifest must live here, with no versionMin
  42/poster.png
  common/media/lua/shared/MaxTimeInServer/            <- config, needed by both sides
  common/media/lua/client/MaxTimeInServer/            <- the notice and the disconnect
  common/media/lua/server/MaxTimeInServer/            <- the counting and the decision
```

## Installing on the server

```sh
make test      # the full suite, no server needed
make deploy    # copies the mod to server-local:~/Zomboid/mods/MaxTimeInServer/
```

Then add the mod id to `~/Zomboid/Server/<World>.ini`:

```
Mods=MaxTimeInServer
```

and restart the game server:

```sh
make restart
make logs      # [MaxTimeInServer] ready: cap 600 minutes per week, week starting ...
```

## Installing for the players

**Every player needs the identical `MaxTimeInServer` folder**, both because the
client half does the disconnecting and because the client runs
`checkMissingMods` while loading — a player without it is turned away at the
connection screen.

```sh
make package    # runs the tests, checks the server is in sync, builds build/MaxTimeInServer.zip
```

`make package` refuses to build unless the server's copy of the mod matches this
working tree, and that check matters: the server hashes the mod's Lua **when it
boots** and kicks clients whose copies disagree. Change a file, deploy it and
forget to restart, and every player with the new zip is turned away at the
connection screen. Deploy, restart, then package.

They unzip it into their own Zomboid directory:

| OS | Path |
|---|---|
| Windows | `%UserProfile%\Zomboid\mods\` |
| Linux / macOS | `~/Zomboid/mods/` |

They do not need to enable anything in the mod menu: the server's mod list
drives it.

## The counter file

`~/Zomboid/Lua/MaxTimeInServer.txt` on the server. Safe to edit while the server is
running — every sweep re-reads it, so a change takes effect within a minute.

```
version=1
capMinutes=600
weekStart=2026-10-12T00:00:00+0000
weekStartEpoch=1791763200
savedAt=2026-10-18T16:22:07+0000

[darkkz]
role=user
minutes=132
bonusMinutes=0
exempt=false
```

| Field | Meaning |
|---|---|
| `capMinutes` | the weekly budget for everyone; this value wins over the one in `MaxTimeInServerConfig.lua` |
| `weekStartEpoch` | start of the week the counters belong to; set it to `0` to force a reset |
| `minutes` | real minutes spent on the server this week |
| `bonusMinutes` | extra allowance for **this week only**, added to `capMinutes`; cleared at the next reset |
| `exempt` | `true` = never counted, never turned away (a manual override that survives resets) |
| `role` | informational: the role the account was last seen holding |

Accounts holding `admin`, `moderator` or `gm` are never counted and never turned
away, so an operator can always get in. The list lives in
`MaxTimeInServerConfig.lua`.

### Recipes

```sh
make data     # read the counters
make roles    # every account and the role it holds right now
make logs     # what the mod has been doing
```

- **Give someone two more hours this week**: set `bonusMinutes=120` in their
  section.
- **Let someone back in now**: lower their `minutes`, or set `exempt=true`.
- **Raise the cap for everyone**: change `capMinutes`.
- **Start the week over**: set `weekStartEpoch=0`.

## Timing: the server has no real-time tick

`GameServer` triggers only `OnClientCommand`, `OnGameBoot`, `OnGameTimeLoaded`,
`OnReceiveItemListNet` and `OnServerStarted`. `OnTick` comes from `IngameState`,
which a dedicated server never runs. The only periodic driver is
`EveryOneMinute`, fired by `GameTime` — and with `PauseEmpty=true` (the stock
setting, and this server's) game time stops while nobody is on.

That is fine for this design:

- Minutes are counted only while somebody is connected, which is exactly what
  the quota is about, and the time the server spent empty or down is never
  credited.
- The join check runs on the handshake, not on a timer, so it does not depend on
  game time at all.
- The weekly reset happens on the first sweep after the boundary: the server
  starting up, or the first player connecting. A player who is over the cap is
  judged against the live week either way, because the verdict ignores counters
  belonging to a week that has already rolled over.

## Development

```sh
./tests/run.sh      # or: make test
```

The tests run under any Lua 5.1-compatible interpreter (`luajit` is what the
runner looks for first) against `tests/pz_stubs.lua`, which fakes the parts of
the game the mod touches: `Events`, `getFileReader`/`getFileWriter`,
`getOnlinePlayers`, `java.util.Calendar`, the connected players and the network.
No game install is needed. `tests/test_client_on_server.lua` covers the one
thing easy to get wrong: a dedicated server runs client Lua too, so the client
half must sit still there.

Three rules the live server taught us, all of them the hard way:

- **The engine runs Kahlua, not PUC-Lua.** A pattern that can match the empty
  string — `gmatch("[^\n]*")` to split lines, say — never advances past the
  empty match there and spins forever. The same code terminates under `luajit`,
  so the tests were green while the server hung on every boot, silently, at 200%
  CPU until systemd killed it. Split strings with `find` and `sub`;
  `string.format` is likewise fussy (`%d` on a float is refused).
- **Always log one line on entry.** A handler that hangs or returns early looks
  exactly like a mod that is working fine, and the server logs nothing for it.
- **Key a registration guard to the event object, not to a boolean.** A flag on
  a global table survives a Lua reload while the `Events` table may not, which
  would leave the mod flagged as registered and attached to nothing.

## Limitations

- A player who crosses the cap while connected is not kicked.
- The quota is enforced by the client on the server's instruction. The stock Lua
  checksum makes editing the mod a kickable offence, but a patched game binary
  could still ignore it. For a tamper-proof version the counter file would have
  to be read by something outside the game that can issue real bans.
- Minutes are counted per **username**, not per character or per Steam account.
