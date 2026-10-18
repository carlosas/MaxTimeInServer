# MaxTimeInServer

A mod for **Project Zomboid Build 42** dedicated servers. It counts the real
minutes each account spends connected during the week and turns away accounts
that have used up their budget. The default is **600 minutes (10 hours)** per
week, Monday 00:00 to Sunday 23:59 in the server's timezone.

It is there to keep the pace of a server shared. When a few players put in many
more hours than everyone else, the map around the group's base is already picked
clean by the time the others log in, and their evening is dull.

## How the block works

Build 42 gives a server-side mod no way to refuse a login: there is no connection
event, and the ban, kick and role APIs are not reachable from the server's Lua at
all. What the server *can* do is talk to a client that has just arrived, so the
mod has two halves:

```
client joins ──► "hello"
                    │
server        looks up the account: 612 of 600 minutes this week
                    │
                    └──► "blocked", with the numbers
                                │
client        shows them, then disconnects itself
```

The player gets a notice saying how much they have used and when it resets, and a
few seconds to read it. They are gone before they can do anything.

That leans on the client cooperating, which is why `DoLuaChecksum=true` matters in
your server config — check that line is enabled. With it on, the server hashes the
Lua both sides load, including the client half of every mod, and the base game
kicks anyone whose copy differs. Editing this mod to dodge the quota gets you
kicked by vanilla before the quota is even consulted. (Roles holding the
`BypassLuaChecksum` capability are exempt from that check.)

A player who crosses the cap *while connected* is not kicked. They finish their
session and simply cannot get back in. That is deliberate.

## Installing on the server

```sh
make test      # the full suite, no server needed
make deploy    # copies the mod to ~/Zomboid/mods/MaxTimeInServer/ on your server
```

`make deploy` reaches the server over SSH. Set `SERVER` and `WORLD` at the top of
the Makefile to your own host and world name first.

Then add the mod id to the server's `.ini`, keeping any mods already listed:

```
Mods=MaxTimeInServer
```

and restart:

```sh
make restart
make logs      # [MaxTimeInServer] ready: cap 600 minutes per week, week starting ...
```

## Installing for the players

**Every player needs the identical `MaxTimeInServer` folder.** Not optional: the
client half is what shows the notice and disconnects, and a client missing a mod
the server lists is turned away at the connection screen anyway.

```sh
make package   # builds build/MaxTimeInServer.zip
```

They unzip it into their own Zomboid directory — `%UserProfile%\Zomboid\mods\` on
Windows, `~/Zomboid/mods/` on Linux and macOS. Nothing to enable in the mod menu;
the server's mod list drives it.

One trap worth knowing: the server hashes the mod's Lua **when it boots**. Change
a file, deploy it, forget to restart, and every player with the new zip gets
kicked on the checksum. The order is deploy, restart, package. `make package`
compares your working tree against the copy sitting on the server and refuses to
build when they differ, which catches a forgotten deploy — it has no way to know
whether the server has restarted since, so that part is on you.

## The counter file

`~/Zomboid/Lua/MaxTimeInServer.txt` on the server. Safe to edit while the server
is running: it is re-read every minute, so changes take effect by themselves.

```
version=1
capMinutes=600
weekStart=2026-10-12T00:00:00+0000
weekStartEpoch=1791763200
savedAt=2026-10-18T16:22:07+0000

[someplayer]
role=user
minutes=132
bonusMinutes=0
exempt=false
```

| Field | Meaning |
|---|---|
| `capMinutes` | the weekly budget for everyone; this wins over the value in `MaxTimeInServerConfig.lua` |
| `minutes` | real minutes spent on the server this week |
| `bonusMinutes` | extra allowance for **this week only**, added to `capMinutes`; cleared at the next reset |
| `exempt` | `true` means never counted and never turned away; a manual override that survives resets |
| `weekStartEpoch` | start of the week these counters belong to; set it to `0` to force a reset |
| `role` | informational, the role the account was last seen holding |

Accounts holding `admin`, `moderator` or `gm` are never counted and never turned
away, so you can always get in yourself. That list lives in
`MaxTimeInServerConfig.lua`.

### Things you will actually want to do

```sh
make data     # read the counters
make roles    # every account and the role it holds right now
make logs     # what the mod has been doing
make help     # the rest of the targets
```

- **Give someone two more hours this week**: set their `bonusMinutes=120`.
- **Let someone back in now**: lower their `minutes`, or set `exempt=true`.
- **Change the cap for everyone**: edit `capMinutes`.
- **Start the week over**: set `weekStartEpoch=0`.

### Seeing a refusal for yourself

The refusal is the one thing no test can cover, because it is the client that
shows the notice and disconnects. Once the mod is installed and somebody has
connected long enough to appear in the counter file:

```sh
make demo-block     # drops capMinutes to 1, so the next join is refused
# reconnect: the notice appears and the client disconnects itself
make logs           # [MaxTimeInServer] refused <name>: 1/1 minutes this week, resets ...
make demo-restore   # puts capMinutes back to 600
```

## How the counting behaves

- Time counts only while somebody is connected. Hours the server spent empty, or
  down, are never charged to anyone.
- The join check happens during the handshake, so it does not depend on the game
  clock and is never late.
- The weekly reset runs on the first pass after the boundary: the server starting
  up, or the first player connecting. Nobody is kept out in the meantime, because
  a counter belonging to a week that has already rolled over is ignored.

That last point matters because a dedicated server has no real-time clock tick in
Lua. The only periodic event available runs on game time, which stops entirely
while the server is empty if `PauseEmpty` is on. The mod is built around that
rather than against it: it measures elapsed real time whenever it does get a tick,
and never trusts the game clock for anything.

## Development

```sh
./tests/run.sh      # or: make test
```

The tests need no game install. `tests/pz_stubs.lua` fakes the parts of the engine
the mod touches — events, file reading and writing, the connected players, the
calendar and the network — so the whole suite runs under any Lua 5.1 compatible
interpreter. `luajit` is what the runner looks for first.

Three traps in Project Zomboid's Lua, all of which cost real time to find:

- **It is Kahlua, not standard Lua.** A pattern that can match the empty string,
  `gmatch("[^\n]*")` for splitting lines being the obvious one, never advances
  past the empty match and loops forever. The same code terminates under
  `luajit`, so the tests stay green while the server hangs on every boot with no
  error at all. Split strings with `find` and `sub`. `string.format` is fussy
  too: `%d` on a float is refused.
- **Log one line when a handler runs.** A handler that hangs, or returns early,
  is indistinguishable from a mod that is working fine. The server reports
  nothing for either.
- **Work out which side you are on when an event fires, not when the file
  loads.** A dedicated server loads and runs client Lua as well as its own, and
  the flags that tell you which side you are on are not dependable that early.

The folder layout is not a matter of taste. Build 42 finds a mod by its version
directory, so `mod.info` must live in `42/`, and a `versionMin` line in the
manifest makes the server skip the mod entirely.

```
MaxTimeInServer/
  42/mod.info                               <- here, and with no versionMin
  42/poster.png
  common/media/lua/shared/MaxTimeInServer/  <- config, both sides need it
  common/media/lua/client/MaxTimeInServer/  <- the notice and the disconnect
  common/media/lua/server/MaxTimeInServer/  <- the counting and the decision
```

## Limitations

- A player who crosses the cap mid-session is not kicked.
- The quota is enforced by the client on the server's instruction. The Lua
  checksum makes editing the mod a kickable offence, but a patched game binary
  could still ignore it. Enforcement that cannot be tampered with would need
  something outside the game reading the counter file and issuing real bans.
- Minutes are counted per account name, not per character.
