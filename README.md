# PlayerTimer

A server-side mod for **Project Zomboid Build 42** dedicated servers. It counts
how many real minutes each account spends connected during the current week and
refuses the login of accounts that have used up their weekly budget. The default
budget is **600 minutes (10 hours)** per week, Monday 00:00 to Sunday 23:59 in
the server's timezone.

It exists to keep the pace of a server fair: when a few players put in many more
hours than the rest, the world is already picked clean by the time everyone else
logs in.

## How it works

Build 42's server-side Lua has no "a player is connecting" event, so the quota
cannot be checked during a login. Instead the mod keeps the block applied ahead
of time:

- Every sweep (once a real minute) it credits the connected players with the
  time that has passed and writes the counters to a plain text file.
- When an account reaches its cap, the mod moves it to the server's **banned
  role** and remembers the role it had. In Build 42 a ban *is* a role, so from
  that moment the server's own login check refuses that account.
- When the week rolls over — or as soon as the file says the account is back
  under its cap — the mod hands the original role back.

Nothing is kicked. A player who crosses the cap while connected keeps playing
until they disconnect; they just cannot get back in. (Kicking is deliberately
left for a later iteration.)

## Installing on the server

```sh
make test      # 50 assertions, no server needed
make deploy    # copies the mod to server-local:~/Zomboid/mods/PlayerTimer/
```

Then add the mod id to the server ini (`~/Zomboid/Server/<World>.ini`):

```
Mods=PlayerTimer
```

and restart the game server:

```sh
make restart
make logs      # should show: [PlayerTimer] ready: cap 600 minutes per week, ...
```

## Installing for the players

**Every player needs the identical `PlayerTimer` folder.** This is not optional:
the client runs `checkMissingMods` while loading and the server compares the Lua
both sides have loaded (`DoLuaChecksum`), so a player without the mod is dropped
at the connection screen.

Copy the folder into their own Zomboid directory:

| OS | Path |
|---|---|
| Windows | `%UserProfile%\Zomboid\mods\PlayerTimer\` |
| Linux | `~/Zomboid/mods/PlayerTimer/` |
| macOS | `~/Zomboid/mods/PlayerTimer/` |

They do not need to enable anything in the mod menu: the server's mod list
drives it.

## The counter file

`~/Zomboid/Lua/PlayerTimer.txt` on the server. It is safe to edit while the
server is running — every sweep re-reads it, so a change takes effect within a
minute.

```
version=1
capMinutes=600
weekStart=2026-10-12T00:00:00+0000
weekStartEpoch=1791763200
savedAt=2026-10-18T14:25:15+0000

[darkkz]
steamid=76561197972620811
role=user
minutes=132
bonusMinutes=0
exempt=false
blockedRole=
```

| Field | Meaning |
|---|---|
| `capMinutes` | the weekly budget for everyone; this value wins over the one in `PlayerTimerConfig.lua` |
| `weekStartEpoch` | start of the week the counters belong to; set it to an older Monday to force a reset |
| `minutes` | real minutes spent on the server this week |
| `bonusMinutes` | extra allowance for **this week only**, added to `capMinutes`; cleared at the next reset |
| `exempt` | `true` = never counted, never blocked (a manual override, survives resets) |
| `role` | informational: the role the account was last seen holding |
| `blockedRole` | set by the mod when it blocks someone — the role to give back. Empty means the mod is not holding anything |

Accounts holding `admin`, `moderator` or `gm` are never counted and never
blocked, so an operator can always get in. The list lives in
`PlayerTimerConfig.lua`.

### Recipes

```sh
make data                       # read the counters
make roles                      # every account and the role it holds right now
make logs                       # what the mod has been doing
```

- **Give someone two more hours this week**: set `bonusMinutes=120` in their
  section.
- **Let someone back in now**: lower their `minutes`, or set `exempt=true`.
- **Raise the cap for everyone**: change `capMinutes`.
- **Start the week over**: set `weekStartEpoch=0`.

`blockedRole` is the mod's own bookkeeping: if you ban somebody by hand, the mod
sees a banned account it did not block and leaves it alone.

## Development

```sh
./tests/run.sh      # or: make test
```

The tests run under any Lua 5.1-compatible interpreter (`luajit` is what the
runner looks for first) against `tests/pz_stubs.lua`, which fakes the parts of
the game the mod touches: `Events`, `getFileReader`/`getFileWriter`,
`getOnlinePlayers`, `java.util.Calendar` and the user database. No game install
is needed.

`tools/probe/` holds two throwaway mods used once to establish which Build 42
mod folder layout a dedicated server actually loads — see `tools/probe/README.md`.

## Limitations

- A player who crosses the cap while connected is not kicked.
- The rejection message is the server's stock "banned" message; a friendlier one
  would need a client-side component.
- Minutes are counted per **username**, not per character or per Steam account.
  The Steam id is recorded alongside for traceability only.
