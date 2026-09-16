# Machine Party-Overtime

Raises the multiplayer cap of *Machine Party* to **8 players** — and reworks arenas, scoring and some
mechanics minigame by minigame, rather than just making the player-count constant bigger. Free, open
source, and you can build it yourself.

🎬 **See it in action (Bilibili)**: https://www.bilibili.com/video/BV1Lo8b6QEh7/

> ## ⚠️ This mod is completely FREE. If you paid for it, you were scammed.
> Download it only from this repository's [Releases](../../releases) page. Nobody is authorised to sell it.

It patches only the game's own scripts — **no game assets are redistributed**, and you must own a
legitimate copy. Everyone in a lobby must install the **same** version. See
[`docs/MINIGAMES.en.md`](docs/MINIGAMES.en.md) for a per-minigame changelog and
[`docs/BUILD.md`](docs/BUILD.md) to build it yourself. Not affiliated with or endorsed by the game's
developer or publisher.

---

![Smoke Break: 8 players filling a row of benches](images/03_smoke_break_bench.png)

| | |
| --- | --- |
| ![Lobby: 8 seats](images/01_lobby_8seats.png) | ![Escalator Pit: 8 separate escalators](images/04_escalator_pit_8lanes.png) |
| ![Table Manners: 8 place settings](images/02_green_pea_dinner_table.png) | ![Results: 8 placement slots](images/10_scoreboard_8slots.png) |

<sub>*Real in-game captures (1920×1080, unretouched). Top: Smoke Break. Clockwise from top left:
lobby seats, Escalator Pit, results board, Table Manners. **The arenas are rebuilt, not just a
constant bumped** — seats, place settings, escalators and scoreboard slots are all genuinely
extended to eight.*</sub>

---

## Verifying your download

SHA256 of each **1.6** file:

```
A4F83EA68E7F7DF58817A4C3123ED289672CF2DC4B1C5781B2CA42423FDC2719  Machine-Party-Overtime-1.6.zip
E0BE592B8E432648263C8ABFE74A7AE1A8BD3E2268A11E0131788F8C3753010B  overtime_launcher.exe
6E145C8D42865BA19348825BC12B6C37180752FF92253A9257B7C0E4454179D6  overtime_install.exe
E3BC32E343D85E893177505638465A78B0969A3573BABE562385FF2BD5050BAC  Machine-Party-Overtime-1.6-MPML.zip
```

The last one is the alternative MPML install package, only needed by players taking that route. See
[Mod loaders and the alternative MPML install](#mod-loaders-and-the-alternative-mpml-install) below.

⚠️ These lines are for **checking the copy you downloaded**. They don't mean "building it yourself
should give the same hash" — zips and exes both record their build time, so the same input built twice
gives different hashes. For checking your own build, see [`docs/BUILD.md`](docs/BUILD.md).

Check a file in PowerShell:

```powershell
Get-FileHash <file> -Algorithm SHA256
```

A match proves the file you have is the one built here and that nobody modified it in between.
⚠️ It does **not** by itself prove the file is safe. The public source and building it yourself
([`docs/BUILD.md`](docs/BUILD.md)) are the stronger guarantee.

**This matters more than usual for this mod.** Many players receive the zip forwarded by someone else
and never open this page, so the hash is the only way they can check nobody tampered with the file.

## About antivirus warnings

The launcher is a small **unsigned** .NET executable (a signing certificate costs money), rebuilt for
every release, that rewrites the game's data pack. That combination trips some antivirus heuristics
and machine-learning checks, and what they report are generic buckets (`Wacatac.B!ml`,
`Gen:Variant.MSILHeracles`) rather than a named malware family.

The patch scripts now ship in `overtime_scripts.dat` next to the launcher instead of inside it. About
700 KB of compressed bytecode made up 93% of the old exe and looked like a packed payload to
machine-learning scanners. The exe is now about 60 KB, it embeds the SHA256 of every script, and it
refuses a data file that doesn't match.

The launcher has been built under a set of self-imposed restrictions from the start, all checkable in
the source:

- **Zero network calls** — no `System.Net` / `HttpClient` / `WebClient` / `Socket` / `WebRequest`
- No P/Invoke, `Marshal`, `Assembly.Load` or `Reflection.Emit`, and no dynamic code of any kind
- The registry is **read only** (just to find your Steam library paths), never written
- The **Game log** button **only opens a folder**. It never reads, packages or uploads any of your files
- **Nothing stays resident**: it exits after changing the game data, with no services, scheduled tasks or autostart
- Uninstalling is **byte-exact and provable**: the restored data pack's SHA256 must match the vanilla fingerprint, or nothing is changed

The installer is a **single public file**, [`installer/Installer.cs`](installer/Installer.cs), that you
can read line by line. Full discussion in [issue #2](../../issues/2).

---

## Changelog

### 1.6 — a "restart this round" vote, plus fixes for Duck Hunt and Table Manners

Download:
https://github.com/DarkJadeStone/MachineParty-Overtime/releases/tag/v1.6

Most players only need `Machine-Party-Overtime-1.6.zip`. If you already have an older version you do
**not** need to uninstall first: quit the game completely, extract the new archive, run
`overtime_launcher.exe` inside it, and click **Enable Overtime**.

This update changes gameplay in **Duck Hunt and Table Manners only**. No other minigame was adjusted.

- **New: a "restart this round" vote.** Any player can start one with F5 or from the pause menu. Once
  more than half the lobby agrees, a 5-second confirmation countdown begins (withdrawing a vote during
  it cancels the restart). On confirmation the round returns to its start and the score earned in it
  is rolled back. The threshold is a majority rather than unanimity, so a disconnected or idle player
  cannot make the vote impossible to pass.
- **Duck Hunt**: fixed a character getting stuck in the arena geometry with the movement keys doing
  nothing. The problem cannot be reproduced locally, so this version adds an automatic escape: hold a
  direction for 3 seconds with almost no movement and you are returned to where you were about a
  metre earlier. The stuck coordinates are written to the game log. If it happens again, please send
  the log using the launcher's **Game log** button. That log is the only way to pin this down.
- **Table Manners**: fixed the new seats 5–8 being noticeably slower to pick the fork back up after
  eating resumes (the per-seat wake-up wait used to accumulate player by player — about 2.6 seconds at
  worst for seat 8). Each player is now timed independently, so the total delay no longer depends on
  the player count. With four players or fewer the values match the original game exactly.
- **Version mismatch messages**: the "version does not match" notice used to give no clue as to why
  (1.5 rewrote it, but the rewrite never actually took effect). It now distinguishes five cases and
  prints both version strings: your version is older or newer than the host's, the other side has no
  mod or too old a one, or both mod versions match but the base game differs. A Chinese line-wrapping
  bug in the same dialog is fixed as well.
- **Player-cap protection**: the 8-player cap is now pinned by the mod, and writes from other mods
  trying to force it back to 4 are ignored. The Steam lobby capacity is re-checked and restored
  periodically as well.
- **New: an alternative MPML install (experimental)** for players who want Overtime alongside other
  mods such as MachineParty+. It requires MachinePartyModLoader to be installed first, and the
  `overtime` folder from `Machine-Party-Overtime-1.6-MPML.zip` — the second asset on this release — to
  be placed in the game's `mods` directory. The `.exe` launcher is still the recommended route. The two
  install methods can share a lobby, but each machine has to pick one. The package verifies the
  original game files before mounting and refuses to mount after a game update, so it can never lay
  old scripts over a newer game.

The restart vote and the version messages were both verified locally with 8 connected instances. The
Duck Hunt and Table Manners fixes could not be — the first cannot be reproduced locally and the second
is beyond what static checking covers — so both need confirmation from real matches. Please keep the
reports coming.

⚠️ **1.6 is not compatible with 1.5 or earlier** — everyone in the lobby must update to 1.6.
If joining shows "your client version does not match the host version", check the bottom right of the
main menu. Everyone should read `v2.1.2+overtime-1.6`.
If someone forwarded you the archive, please send them the new one too, so no old version ends up in
the lobby.

---

### 1.5 — Spine Breaker devices that latch on but never execute

Download:
https://github.com/DarkJadeStone/MachineParty-Overtime/releases/tag/v1.5

Most players only need `Machine-Party-Overtime-1.5.zip`. If you already have an older version you do
**not** need to uninstall first: quit the game completely, extract the new archive, run
`overtime_launcher.exe` inside it, and click **Enable Overtime**.

This update changes gameplay in **Spine Breaker only**. No other minigame was adjusted.

- Fixed a device latching onto a player and then never executing them.
- Fixed the player being unable to act in that state — inputs did nothing and the device could not be
  thrown off.
- Fixed the permanent stall this caused: the pinned player neither died nor got free, so once only two
  players were left the round could never settle.
- A retired device now blinks slowly in green instead of going dark. Red and fast means the fuse is
  burning. Green and slow means the device has retired and will not act again.

The first three are the same bug. A device's earlier "find a new target" request is executed after a
delay. During that wait it may already have latched onto a player — but when the old request comes
due, it is still sent off to chase someone else.

The device has effectively left, yet the model and state on the player's back are never cleared. The
server also no longer considers that device to be riding the player, so it neither continues the
execution nor finds a device that can be thrown — leaving that player stuck on the field forever and
the round unable to end.

Now a device that is already riding a player, or currently executing one, is no longer reassigned. The
fuse counts down normally and the player can throw it off as usual.

Separately, when only two players remain one device retires by design, leaving the other for the final
1v1. Previously it simply went dark, which looked a lot like the device had frozen again. 1.5 makes it
blink slowly in green so "retired normally" and "still hunting" can be told apart at a glance.

Three players reported this independently in the comments — "the spider hangs on and won't bite", "the
red spider can't be thrown", "the last two players can't finish" — all confirmed to be the same bug.
The fix was verified locally with 8 instances, intercepting three incorrect target reassignments, with
normal execution and reset flows still running.

⚠️ **1.5 is not compatible with 1.4 or earlier** — everyone in the lobby must update to 1.5.
If joining shows "your client version does not match the host version", check the bottom right of the
main menu. Everyone should read `v2.1.2+overtime-1.5`.
If someone forwarded you the archive, please send them the new one too, so no old version ends up in
the lobby.

---

### 1.4 — Debris Platforms rounds that could never end

This update changes **Debris Platforms only**. No other minigame was touched.

- **Fixed 8-player rounds that could not end**: every player on the field was already gone, yet the
  round never settled — junk kept falling and the frame rate kept dropping.
- **Fixed compactors being matched to the wrong platform**: some platforms would pile up with debris
  while the compactor above them never came down, and a compactor somewhere else fired instead.
- **Compactor eliminations are now decided by the host**, so clients no longer each resolve a player's
  death according to their own view, and the same player can no longer be counted out twice.
- **Added a settlement safety net**: if a player ever ends up "out, but not registered by the host"
  again, it is corrected automatically after about 3 seconds instead of hanging the whole round forever.

This was introduced in 1.3 together with the 8-direction independent camera: the compactors were
incorrectly reassigned along with the camera. Visuals and gameplay decisions are now fully separated.
Reproduced locally with 8 instances, and confirmed the round settles again after the fix.

If you are still on 1.3, the 1.4 launcher also includes the 1.3.1 fix for the false "the game is
running" report.

The "Spine Breaker: cannot throw when only two players remain" report from the comments is **not**
included in this update — still being investigated.

⚠️ **1.4 is not compatible with 1.3 or 1.3.1** — everyone in the lobby has to update to 1.4.
(The main menu bottom right reads `v2.1.2+overtime-1.4`, so it's easy to check.)

---

### 1.3.1 — launcher only: fixes "the game is running" when it isn't

⚠️ **This release changes the launcher only. Not one byte of game content changed.**

- **If you already have 1.3 installed, do nothing** — the main menu still reads `v2.1.2+overtime-1.3`.
- **1.3.1 and 1.3 play together**, so a lobby does not have to update in lockstep.
- Only download this if the installer refused to work for you.

Changes:

- **Fixed**: for a few players, "Enable Overtime" always popped up "The game is running. Fully exit it
  first" even though the game was closed — and neither rebooting nor reinstalling the game helped,
  making it impossible to install at all. The old check went purely by **process name**: any process
  called `Machine Party.exe` anywhere on the system (a leftover process that never exited, one Windows
  kept alive after a crash, or an unrelated program with the same name) would block it. It now
  **checks whether the game's PCK is actually locked**, and only treats a same-named process as the
  game when it really lives inside the game folder you picked.
- **Clearer message**: when something genuinely is holding the file, the dialog now lists the PID and
  full path of that process, so you can end it in Task Manager directly.
- **Install log**: fixed the same batch of lines being written to the file twice, plus one redundant
  line per launch. The log is readable now.
- **UI**: the top right corner now also shows an "installer" build number, which makes bug reports much
  easier to place.

---

### 1.3 — a disconnect during loading, plus issues that actually show up in multiplayer

- **Disconnects**: fixed a player dropping *during minigame loading* leaving the whole round silent and
  every player on a black screen at the end. Twelve minigames also got a guard against running
  end-of-round logic before the round started, and cleanup errors in Manufacture Gun and Smoke Break at
  that same moment are fixed.
- **Spine Breaker**: fixed being unable to throw while facing a player directly, a second device
  endlessly chasing someone who was already carrying one, and throws picking a device on someone
  else's back — or one already in flight — instead of your own, so the throw did nothing.
- **Debris Platforms**: arena and cameras reworked so each of the 8 players gets their own 45° view,
  greatly reducing players blocking each other. Idle debris is now recycled after 30 seconds instead
  of 60.
- **Debris Platforms**: fixed debris being able to pass through a player permanently after several
  players contested the same piece.
- **Duck Hunt**: hunter fire rate reduced by 20% in 6-player rounds. Fixed the 7-player lone-hunter
  round showing "HUNTER NERFED" when the hunter is actually buffed.
- **Duck Hunt**: fixed the death animation, blood and sound effects firing twice when two hunters hit
  the same duck simultaneously. Scoring itself never double-counted.
- **Launcher**: new **Game log** button that takes you straight to the current `godot.log`. The old
  "Open log" is now **Install log**. The buttons only open a local folder — nothing is uploaded.
- **Log cleanup**: the developer `[MP8-AUDIT]` diagnostic dump is now opt-in, so normal play no longer
  floods the log with diagnostics nobody needs.
- **Install notes**: documented that Overtime is not currently compatible with MachinePartyModLoader,
  or with any other mod that modifies the game's PCK. This is not new in 1.3.

⚠️ **1.3 is not compatible with 1.2** — everyone in the lobby has to update to 1.3.
(The main menu bottom right reads `v2.1.2+overtime-1.3`, so it's easy to check.)

---

### 1.2 — two game-breaking hangs fixed, plus duplicated sound effects

**Inside Job: if the player already holding a syringe picked up a second one, the round hung.**
The hunt phase never started — nobody could stab, other players' cameras never zoomed in, the lights
never went out. That syringe had already been taken from the cabinet, so there was no other one to
find, and the round could only wait for the timeout. The root cause was that the "syringes found"
counter was de-duplicated per **player** when it should have counted per **syringe**.

**Debris Platforms: debris stopped falling in the second half of a round.**
Debris that came to rest on a platform was never recycled (in vanilla, the only way back was "fell off
the platform"), so once 40 pieces had piled up nothing dropped again and the minigame simply stopped
being played. It was much worse at 8 players: every player is a drop point, so each tick drops 8
pieces and the pool empties within a dozen or so seconds. Debris idle for over a minute is now actively
recycled and dropped again.

**Duplicated sound effects.** Several sounds were broadcast once by each of the 8 machines, so every
client ended up playing them 8 times over (the heart monitor beep, reloading, picking up a gun, the
death sound, the delivery area light). Now each client plays them once. This also fixed a chained
broadcast that counted a single Inside Job search 7 times.

⚠️ **1.2 is not compatible with 1.1**: the version string is part of the multiplayer handshake, so
everyone in the lobby has to update. (The main menu bottom right reads `v2.1.2+overtime-1.2`.)

---

### 1.1 — fixed the host seeing a different arena from everyone else

Three **host/client desyncs** found in real 5- and 6-player sessions, all fixed. All three had the same
cause: those props are **placed locally by each machine**, from data only the host had. Neither side
reported an error, so the only way to catch it was comparing screens.

| Minigame | What happened before |
| --- | --- |
| **Manufacture Gun** | The host saw an empty walkway, while **everyone else had a workbench standing in the middle of theirs, blocking the way** (with collision) |
| **Chisel Gauntlet** | During the memorise phase (watching the big screen), other players vanished out of the way on the host's screen, **but everyone else still saw a row of heads** |
| **Smoke Break** | The layout of the 8 seats and the two crates differed between the host and everyone else |

⚠️ **1.1 is not compatible with 1.0**: the version string is part of the multiplayer handshake, so
everyone in the lobby has to update. (The main menu bottom right reads `v2.1.2+overtime-1.1`.)

---

## What this is

The vanilla multiplayer cap is 4 players. This mod raises it to 8 and **adapts every minigame for 8
players** — it isn't just a bigger player-count constant (that alone makes most minigames break on the
spot, or puts two players on the same spawn point, or leaves places 5–8 unable to see their score).

All 15 playable minigames were touched: extra spawn points, item and device counts, arena layout,
placement scoring, scoreboard slots, and lobby seats and chairs.

**Game version: v2.1.2 (Steam).** Don't force an install after a game update — the installer checks,
and if the version doesn't match it refuses and tells you why. It won't break your game.

## How to install

Download **`Machine-Party-Overtime-x.y.zip`** from [Releases](../../releases) and extract it.
**Fully exit the game**, run **`overtime_launcher.exe`** from the extracted folder, and click
**Enable Overtime**. Once installed, the version in the bottom right of the main menu becomes
`v2.1.2+overtime-x.y`.

The zip holds the **launcher** (no runtime to install), `overtime_scripts.dat` with the patch
scripts it needs next to it, a readme and the build record.

**The launcher doesn't need to stay running.** Overtime isn't loaded at runtime. Enabling it rewrites
the game data once, and after that you **launch the game from Steam as usual**. The launcher's **Play**
button is just a convenience. You only need to open it again to switch back to vanilla, switch back to
Overtime, or check the current state.

**Switching takes a second.** The restore data is only a few KB (see how below), so to play with
friends who don't have the mod, click once to switch back to vanilla and click again afterwards. After
switching back, the launcher checks the result is **byte-for-byte identical** to vanilla before
reporting success.

The full guide (getting past Windows SmartScreen, picking the game folder by hand, FAQ) is in
[`installer/README.md`](installer/README.md).

### Three things you must know

1. **You need a legitimate copy of the game.** The installer contains no game files. It patches your
   own copy.
2. **Everyone playing together must install the same version.** The version is written into the
   multiplayer handshake, and the host refuses mismatches outright. This is deliberate: mixing modded
   and unmodded players fails mid-match in ways that are very hard to diagnose. The cost is that **with
   the mod installed you can't play with vanilla friends**. Run `--uninstall` first if you want to.
3. **You can restore at any time**, and the restore is exact (the next section explains why it only
   takes a few KB).

### How restoring only needs a few KB

Patching works by **appending the new content to the end of the data pack and pointing that index
entry at it**. Not a single byte of the original file is overwritten, and it all still sits in the
pack. So restoring doesn't need a 605 MB backup of the whole pack. It just writes those few index
fields back and truncates the file to its original length.

This is actually **safer**. After restoring, the SHA256 can be compared with the vanilla fingerprint,
which **proves the restore is byte-for-byte exact**. A whole-pack copy gives no such guarantee. Before
restoring, it also confirms entry by entry that the current pack is exactly the one it patched. If it
isn't (Steam updated it, or you clicked "Verify integrity of game files"), it refuses to touch
anything rather than write blindly.

## Known limitations (worth knowing before you install)

| Item | Details |
| --- | --- |
| **Pick one install method, they don't stack** | The recommended launcher install rewrites the game's data pack (`.pck`), so it **can't be combined with [MachinePartyModLoader](https://github.com/Krunk-theduck/MachinePartyModLoader) or any other tool that also modifies the PCK**. Since 1.6 there's also an **alternative MPML install** (experimental) that can coexist with loader-based mods such as MachineParty+ and first person. **Each machine can only use one**, but players using different methods **can join the same lobby**. The reasons and how to choose are below |
| Only 5 character colours | The game ships 5 colours, so in an 8-player match **some players always share a colour**. The mod doesn't add new ones |
| Longer matches | Elimination minigames have more rounds with more players. Burn Recycle with 8 players runs up to 7 rounds, and a full match takes about twice as long as a 4-player one |
| Some minigames look different below 5 players | A few minigames' arena expansions aren't gated on player count, so 2–4 player matches show the extra chairs and platforms. Gameplay isn't affected |
| 8-player Duck Hunt is 6 ducks and 2 hunters | Vanilla is 3 ducks and 1 hunter. 8 players keep the same ratio instead of 7 ducks and 1 hunter |
| The camera sometimes shows past the set | Some minigames pull the camera back to fit 8 players, so the edges can reveal scenery that was originally out of frame |

### Mod loaders and the alternative MPML install

The player cap lives in `const MAX_PLAYERS`, and **GDScript inlines constants at compile time** — every
use of it has `4` baked in when it's compiled, so there's no way to change it at runtime, only by
replacing the compiled bytecode in the data pack. That's why the recommended launcher install has to
rewrite the PCK.

Loaders like MachinePartyModLoader override scripts by `extends`-ing the originals. That design is
clearly better for stacking several mods, **but inheritance can't reach an inlined constant**. Declaring
`MAX_PLAYERS = 8` in a subclass doesn't change code that was already compiled with `4`.

**Since 1.6 there's a different approach: replace whole scripts instead of inheriting.** The loader's
autoload runs first, and during its `_init()` not a single line of the game's own scripts has been
loaded yet. Mounting the 54 compiled scripts into `res://` as a resource pack at that moment swaps the
bytecode out before any compiled constants take effect. This route doesn't need to include a single
line of vanilla code, so it stays within the "don't distribute game source" rule.

**So there are now two install methods. Choose by what you need:**

| | Recommended: `overtime_launcher.exe` | Alternative: MPML package (experimental) |
| --- | --- | --- |
| How to install | Download `Machine-Party-Overtime-x.y.zip`, extract it, run the launcher and click **Enable Overtime** | Install MachinePartyModLoader yourself first, then download `Machine-Party-Overtime-x.y-MPML.zip` (the second asset on the same release) and put its `overtime` folder in the game's `mods` directory |
| Works with other mods? | ❌ No | ✅ Yes (MachineParty+, first person, offline bots and so on) |
| Switching back to vanilla | ✅ One click, provably byte-exact | Handled by the loader (delete `overtime` from `mods`) |
| After a game update | Asks you to reinstall | **Refuses to mount automatically** — it checks the md5 of all 54 vanilla files before mounting, so it never lays old scripts over a newer game |

**Both routes install the same mod version.** The multiplayer handshake strings are identical, so they
can share a lobby. **But each machine can only use one.** The loader can't read a data pack the launcher
has patched (the patch data is appended after the index, and the loader requires the index to end
exactly at the end of the file). To move from the launcher to MPML, switch back to vanilla with the
launcher first, then install the loader.

We **don't bundle the loader itself**. Its repository has no LICENSE, so we have no right to
redistribute it without the author's permission. Get it from [its Releases](https://github.com/Krunk-theduck/MachinePartyModLoader/releases).

## What's in the repository (and why it isn't complete scripts)

```
patches/      54 diffs (.patch) against the game's own scripts
installer/    full C# source of the installer
mpml/         source of the adapter for the alternative MPML install (our own code, readable line by line)
tools/        build chain: apply patches → compile → build the exe → (optional) build the MPML package
docs/         per-minigame changes, build guide, guide to moving to a new game version
```

**Want to know exactly what changed in gameplay?** See [`docs/MINIGAMES.en.md`](docs/MINIGAMES.en.md). It
goes through all 15 minigames: what was changed for 8 players, whether scoring changed, and what was
deliberately kept vanilla.

**Why diffs instead of complete `.gd` files.** Those 54 files mix the game's decompiled source with our
changes (34,538 lines in total). Publishing them whole would release about 15,100 lines of the game's own
source code. This project's rule is **not to distribute the game's original assets**, so only the part we
wrote (19,442 lines) is published, plus the context the diffs need (2,237 lines).

**The two files under `mpml/` are the exception and are published whole.** The adapter `main.gd` doesn't
`extends` any vanilla script and contains no game code, so the rule above doesn't apply. That's
deliberate too: if the `-MPML.zip` release asset came without source, it would be a binary you could
only take on trust.

Extract the scripts from your own legitimate copy, run one command to apply the patches, and the result
is **byte-for-byte identical** to the author's (the build checks this every time). The steps are in
[`docs/BUILD.md`](docs/BUILD.md).

## Building it yourself

```powershell
# 1. Extract the vanilla scripts from your own copy of the game (needs gdre_tools v2.6.4)
# 2. Apply the patches
powershell -ExecutionPolicy Bypass -File tools\apply_patches.ps1
# 3. Compile
powershell -ExecutionPolicy Bypass -File tools\build.ps1 -CompileOnly
# 4. Build the installer
powershell -ExecutionPolicy Bypass -File tools\build_installer.ps1
# 5. (Optional, only for the alternative MPML install) build the MPML package
powershell -ExecutionPolicy Bypass -File tools\build_mpml_mod.ps1
```

Details, prerequisites and common errors are in [`docs/BUILD.md`](docs/BUILD.md).
How to move to a new game version is in [`docs/UPDATING.md`](docs/UPDATING.md).

## Ground rules (what this project won't do)

- **Legitimate copies only.** Nothing that lets pirated copies play online.
- **No redistribution of the game's original assets.** No art, audio, scenes, complete scripts or data packs.
- Never touches the game exe or any Steam dll, never changes achievement logic, and never touches anything to do with purchases or licensing.

## License and disclaimer

See [`LICENSE`](LICENSE) for the code license (MIT, covering the parts of this repository we wrote).

This mod is an **unofficial** third-party modification. It has no connection with the game's developer or
publisher and isn't endorsed by them. Copyright in the game's own code and assets belongs to its owners.

If anything goes wrong, first `--uninstall` to restore vanilla, then report it to the game's developers —
**don't report bugs to them while the mod is installed.**

If the rights holders want this repository taken down, please say so in Issues and it will be handled.
