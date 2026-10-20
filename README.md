# MaxTimeInServer

A mod for **Project Zomboid Build 42** dedicated servers. It counts the real
minutes each account spends connected during the week and turns away accounts
that have used up their budget. By default that is **600 minutes (10 hours)** a
week, and the week turns over at **00:00 every Friday** in the server's
timezone. Both are settings.

It is there to keep the pace of a server shared. When a few players put in many
more hours than everyone else, the map around the group's base is already picked
clean by the time the others log in, and their evening is dull.

## How the block works

A server-side mod cannot refuse a login in Build 42, but it can talk to a client
that has just arrived, so the mod has two halves:

```
client joins ──► "hello"
                    │
server        looks up the account: 612 of 600 minutes this week
                    │
                    └──► "blocked", with the numbers
                                │
client        shows them, then disconnects itself
```

The player reads how much they have used and when it resets, and gets a few
seconds before their game drops the connection.

Since the client is the half that acts, keep **`DoLuaChecksum=true`** in the
server config. The server then hashes the Lua both sides load, the client half
of every mod included, and vanilla kicks anyone whose copy differs: editing this
mod to dodge the quota gets you kicked before the quota is even consulted.
(Roles holding the `BypassLuaChecksum` capability are exempt from that check.)

The same conversation happens while people play. The server counts every
minute, so it knows when somebody is running out: it warns them with a line over
their head as the cap approaches, and when they cross it, sends the same notice
as the door and their game disconnects itself. Nobody is caught by surprise, and
nobody keeps playing on a budget they have spent.

## Installing

The mod is generic — everything that varies between servers is a sandbox option.
Put the folder in the server's `mods/`, add the id to the `.ini` alongside any
mods already listed, and restart.

```
Mods=MaxTimeInServer
```

**Every player needs the same mod.** The client half is what shows the notice
and disconnects, and a client missing a mod the server lists is turned away at
the connection screen anyway. From the Workshop that takes care of itself. By
hand, each player unzips the folder into their own Zomboid folder, so that it
lands at `<Zomboid>/mods/MaxTimeInServer/` with `42/` and `common/` inside it:

| | |
|---|---|
| Windows | `%UserProfile%\Zomboid\mods\` |
| macOS, Linux | `~/Zomboid/mods/` |

Nothing to tick in the mod menu — that list is for single-player. Joining the
server is what switches the mod on. The copies do have to be identical: the
server hashes its Lua when it boots and kicks clients that disagree, so a
hand-installed copy must be the one the server is actually running.

### With the Makefile

`make` here is a convenience for deploying to one server over SSH, not part of
the mod. Set `SERVER` and `WORLD` at the top of the `Makefile`, or ignore it and
copy the folder however you like.

```sh
make test             # the whole suite, no server or game install needed
make deploy restart   # copy the mod to the server, then restart it
make logs             # what the mod has been doing
make package          # build/MaxTimeInServer.zip, the mod as it would be published
make handout          # the same archive, but only once the server has those files
make help             # the rest
```

## Server settings

The settings live in the server's **sandbox options**, under a page called *Max
Time In Server*. Set them from the admin panel or by editing
`<World>_SandboxVars.lua`:

| Setting | Default | What it is |
|---|---|---|
| Weekly minutes per account | `600` | the budget, in real minutes, per account per week |
| Day the week resets | `Friday` | everyone's minutes go back to zero at 00:00 on this day, in the night between the day before and it. A dropdown of the seven days. Changing the setting puts everyone back to zero within a minute, without waiting for that day |
| Roles that are never limited | `admin;moderator;gm` | semicolon-separated; never counted and never turned away, so you can always get in yourself. Empty means nobody is exempt, operators included |
| What a refused player is told | *(empty)* | empty means the mod says it in each player's own language; set it to use your own wording instead, the same for everyone. It cannot contain a comma, because the sandbox file splits on them |
| Warn when this much is left | `30;5` | minutes left, separated by semicolons, at which a player is warned while they play. Each mark is said once per session; empty means they hear nothing until their time is up |
| Seconds to read the notice | `5` | how long a refused player gets before their game disconnects itself |

Whatever the wording, the numbers are the mod's own and always follow
underneath, in the player's language, so rewriting the message cannot hide what
the player needs to know:

```
No more for you this week.

You have used 612 of your 600 minutes this week.
Your allowance resets on 2026-10-19.

Disconnecting in 5 seconds.
```

Sandbox options are read when the server boots, so a change takes a restart. On
start-up the mod logs what it is enforcing:

```
[MaxTimeInServer] ready: cap 600 minutes per week resetting Fridays at 00:00, exempt roles: admin, moderator, gm, warning at 30, 5 minutes left, 5 seconds to read the notice, counting in MaxTimeInServer_MyServer.txt, week starting 2026-10-16T00:00:00+0000, 3 accounts on record
```

If it cannot find its settings page it says so and falls back to the defaults
above, rather than letting everybody in or nobody.

### Languages

The mod's own lines follow each player's game language. English and Spanish ship
with it; any other language falls back to English, line by line. Adding one is a
single block in `common/media/lua/shared/MaxTimeInServer/MaxTimeInServerText.lua`,
keyed by the code `Translator.getLanguage():name()` returns, and a test fails if
a language is missing a line.

The names of the settings themselves, their tooltips and the weekday list come
from `common/media/lua/shared/Translate/<LANG>/Sandbox.json`, which is what makes
them read as sentences instead of as raw keys. A test fails if an option, a
tooltip or one of the seven days has no label in a language the mod ships.

## The counter file

`~/Zomboid/Lua/MaxTimeInServer_<ServerName>.txt` on the server, named after the
server's own `-servername`. Safe to edit while the server is running: it is
re-read every minute, so changes take effect by themselves.

```
version=1
weekStart=2026-10-16T00:00:00+0000
weekStartEpoch=1792108800
savedAt=2026-10-18T16:22:07+0000

[someplayer]
role=user
minutes=132
bonusMinutes=0
exempt=false
```

It holds the counters and the per-player exceptions, nothing else; the cap
itself is a server setting.

| Field | Meaning |
|---|---|
| `minutes` | real minutes spent on the server this week |
| `bonusMinutes` | extra allowance for **this week only**, on top of the cap; cleared at the next reset |
| `exempt` | `true` means never counted and never turned away; a manual override that survives resets |
| `weekStartEpoch` | start of the week these counters belong to; set it to `0` to force a reset |
| `role` | informational, the role the account was last seen holding |

- **Give someone two more hours this week**: set their `bonusMinutes=120`.
- **Let someone back in now**: lower their `minutes`, or set `exempt=true`.
- **Start the week over**: set `weekStartEpoch=0`.
- **Change the cap for everyone**: that one is a sandbox option, and takes a restart.
- **See a refusal for yourself**: `make demo-block PLAYER=someplayer` pushes one
  account past the cap and `make demo-restore PLAYER=someplayer` puts it back.
  Both work on this file, so neither needs a restart or touches anyone else.

Everything in this file takes effect within a minute, with no restart.

```sh
make data     # read the counters
make roles    # every account and the role it holds right now
make sandbox  # the settings as the server has them written down
```

## More than one server

The budget belongs to a server, not to a player across the world: two servers
running this mod count their own minutes, in their own file, against their own
cap, and ten hours on one does not spend the other's. A shared budget across
servers is not something this mod does — the counters would have to live
somewhere both servers can write.

Nothing leaks the other way either. `~/Zomboid/Lua/` is shared by every server
run out of one data folder while `Server/` and `Saves/` are not, which is why
the counter file is named after the server. And since one game process can visit
several servers without restarting, the client half keeps what it is told
against the server that said it, and drops it on reaching a different one, on
disconnecting, and on returning to the main menu: one server's "you may play" is
never an answer for another, and a disconnect still counting down does not
follow a player to the next server.

One thing to watch is the game's rule rather than this mod's: a player holds one
copy of a mod, and a server kicks clients whose Lua does not hash to the same
thing. Two servers on different versions of this mod cannot both match that one
copy, so keep servers that share players on the same version.

## How the counting behaves

- Each player is charged for the time since **they** were last seen online, not
  for the time since the mod last looked — with `PauseEmpty` on, nothing runs
  while the server is empty, and that gap is not anybody's playing time.
- A player's first sighting only starts their clock, so nobody pays for time
  before the mod saw them, and leaving for an hour costs nothing.
- The join check happens during the handshake, so it never arrives late. The
  checks during a session ride on the same pass that counts the minutes, so
  they are at most one interval behind.
- The weekly reset runs on the first pass after the boundary: the server
  starting up, or the first player connecting. Nobody is kept out in the
  meantime, because a counter belonging to a week that has rolled over is
  ignored.

A dedicated server has no real-time clock tick in Lua; the only periodic event
runs on game time, which stops entirely while the server is empty. So the mod
measures elapsed real time whenever it does get a tick, and never trusts the
game clock.

## Development

```sh
./tests/run.sh      # or: make test
```

The tests need no game install. `tests/pz_stubs.lua` fakes the parts of the
engine the mod touches — events, file reading and writing, the connected
players, the calendar and the network — so the suite runs under any Lua 5.1
compatible interpreter. `luajit` is what the runner looks for first.

Three constraints worth knowing before editing the Lua:

- **The engine runs Kahlua, not standard Lua.** A pattern that can match the
  empty string, `gmatch("[^\n]*")` for splitting lines being the obvious one,
  never advances past the empty match and loops forever — and the same code
  terminates under `luajit`, so the test suite will not catch it. Split strings
  with `find` and `sub`. `string.format("%d", x)` refuses a float.
- **Log a line when a handler runs.** The server reports nothing for a handler
  that hangs or returns early, so it looks exactly like one that is working.
- **Decide which side you are on when an event fires, not when the file loads.**
  A dedicated server loads and runs client Lua too, and the flags that say which
  side you are on are not dependable that early.

The layout is not a matter of taste either: Build 42 finds a mod by its version
directory, and a `versionMin` line in the manifest makes a server skip the mod
entirely.

```
MaxTimeInServer/
  42/mod.info                               <- here, and with no versionMin
  42/poster.png
  common/media/lua/shared/MaxTimeInServer/  <- config and text, both sides need it
  common/media/lua/shared/Translate/        <- the settings' names in each language
  common/media/lua/client/MaxTimeInServer/  <- the notice and the disconnect
  common/media/lua/server/MaxTimeInServer/  <- the counting and the decision
```

## Limitations

- A player who crosses the cap while connected is told within a minute, not
  instantly: that is how often the counting runs.
- The quota is enforced by the client on the server's instruction. The Lua
  checksum makes editing the mod a kickable offence, but a patched game binary
  could still ignore it. Enforcement that cannot be tampered with would need
  something outside the game reading the counter file and issuing real bans.
- Minutes are counted per account name, not per character.
