# Machine Party-Overtime

Raises the multiplayer cap from **4 to 8 players** — and reworks arenas, scoring and some
mechanics per minigame so that eight actually works. Free and open source.
**Game version: v2.1.2 (Steam).**

🎬 **See it in action**: https://www.bilibili.com/video/BV1Lo8b6QEh7/

> ## ⚠️ This mod is completely FREE. If you paid for it, you were scammed.
> Get it only from the official Releases page. Nobody is authorised to sell it.

---

## Install

1. **Extract the whole zip into a folder.** `overtime_launcher.exe` needs `overtime_scripts.dat`
   next to it, so running it straight from inside the zip won't work.
2. **Fully exit the game.** (Wait until Steam stops showing you as In-Game.)
3. Run **`overtime_launcher.exe`**.
4. Press **Enable Overtime**.

That is the whole thing. No runtime to install, nothing else to download.

**Installed correctly** = the version in the bottom right of the main menu ends with `+overtime`.

> Windows may show "Windows protected your PC" because this exe is not code-signed
> (a signing certificate costs money). Click **More info → Run anyway**. If you would rather not,
> the source is public — build it yourself.

## The launcher does not stay running

**Overtime is not loaded at runtime.** Enabling it rewrites your game data once, and that is the
end of it:

- Once enabled, **launch the game from Steam exactly as you always have.** The mod is already in
  your game files.
- Nothing runs in the background, nothing starts with Windows, nothing hooks the game process.
- The **Play** button is a convenience — it just asks Steam to start the game. Ignoring it changes
  nothing.
- You only open the launcher again to **switch back to vanilla**, switch back to Overtime, or check
  which state you are in.

## What the buttons do

| Button | What it does |
| --- | --- |
| **Enable Overtime** / **Switch to vanilla** | Flips between the two. Takes about a second. |
| **Play** | Asks Steam to launch the game. Optional. |
| **Steam repair** | Opens Steam's "verify integrity of game files". Use it if something is broken and you have no way back. |
| **Install log** | Shows exactly what the launcher did. **Attach this when reporting a problem.** |
| **Game log** | Opens the folder holding the game's current `godot.log`. Attach that one when reporting an in-game bug (a crash, a black screen). It only opens a local folder — nothing is uploaded anywhere. |

## Three things you must know

1. **You need a legitimate copy of the game.** This download contains no game files, only the few
   dozen scripts the mod changes (a few hundred KB in `overtime_scripts.dat`). It patches your own
   installation.
2. **Everyone in the lobby must run the same mod version.** The version is part of the multiplayer
   handshake and the host refuses mismatches. This is deliberate — mixing modded and unmodded
   players fails mid-match in ways that are very hard to diagnose. So **while Overtime is enabled
   you cannot play with unmodded friends**; switch back to vanilla first (one click).
3. **Reverting is exact.** After switching back, the launcher verifies the result is byte-for-byte
   identical to the original game data before telling you it succeeded.

## FAQ

**The mod disappeared after a few days.**
Steam updated the game, or you ran "Verify integrity of game files" — both replace the game data.
Just enable it again. If the *game version* changed, the launcher will stop and tell you: wait for
an Overtime build that targets it. It will not patch a version it does not know.

**"Patch data missing or damaged."**
`overtime_scripts.dat` isn't next to the launcher, or it comes from a different release. Extract the
whole zip into one folder and run the launcher from there. If that doesn't help, download the release
again. You can still switch back to vanilla while this message is showing.

**"The current PCK does not match the vanilla build this mod knows."**
Your game is not v2.1.2 (it updated), or another mod is installed. **Nothing was changed.** Safest
fix: Steam → right click the game → Properties → Installed Files → Verify integrity, then check
whether Overtime has a build for your version.

**Can I use this together with a mod loader?**
**Not right now.** Overtime installs by rewriting the game's `.pck`, so it is mutually exclusive with
MachinePartyModLoader and any other tool that also modifies the PCK — pick one. The reason: the
player cap lives in `const MAX_PLAYERS`, and GDScript inlines constants at compile time, so it
cannot be changed at runtime, only by replacing compiled bytecode inside the PCK. Loaders that
override scripts by `extends`-ing them cannot reach an inlined constant.

**The launcher cannot find my game.**
Use **Browse…** and pick the folder that contains `Machine Party.pck`
(Steam → right click the game → Manage → Browse local files).

**My friend cannot join / version mismatch.**
You are on different Overtime versions, or one of you has it disabled. Compare the version strings
in the bottom right of the main menu.

**Can I delete the restore data (`overtime_restore.dat`)?**
Then you can no longer switch back to vanilla in one click, only through Steam's "Verify integrity of
game files". It's only a few KB, so keep it.

**Will this get me banned / break achievements?**
It replaces the game's own script data pack only — it does not touch the exe, any Steam dll, or
achievement logic. It is still an unofficial modification: if something breaks, **revert to vanilla
before reporting the bug to the developers.**

## What it changes

- Multiplayer cap 4 → 8 (lobby slots, spawn points, scoreboards and so on change with it)
- **Every minigame** is adapted for 8 players: spawn points, item counts, arena layout and placement
  scoring. Two minigames also have changed mechanics (listed one by one in the repository's
  `docs/MINIGAMES.en.md`)
- Adds a `+overtime` suffix to the game's version, so modded and unmodded players can't join each other

**Not changed:** the game's art, audio, achievement logic, or anything to do with purchases or licensing.

## Source

Fully open source. The repository publishes diffs against the game's own scripts — no game code or
assets are redistributed — plus the launcher's complete source, so you can rebuild it yourself from
your own legitimate copy.

Unofficial third-party modification. Not affiliated with, authorized by, or endorsed by the
developer or publisher of Machine Party.
