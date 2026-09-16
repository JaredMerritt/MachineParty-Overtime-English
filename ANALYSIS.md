# Machine Party-Overtime — source analysis

**Scope:** every source file in this repository at `6d81960` (Overtime 1.6, targeting Machine Party
v2.1.2 on Steam).

**Method:** static reading only. Nothing from the repository was compiled, applied, installed or run.
The review had two passes:
1. A full read of the installer, build scripts and mod-loader adapter, plus API sweeps across every
   file. The sweeps covered processes, networking, file access, dynamic code, encoded data, hidden
   Unicode and patch headers.
2. An independent line-by-line security review of all 19,442 added GDScript lines, split into nine
   batches. The reviewers were given the code and a threat model but not the earlier findings.
   Severities were normalized afterwards, and the most severe claims were checked against the code again.

Line numbers for `.patch` files are line numbers inside the patch file.

---

## Verdict

**No malicious behaviour was found.** Nothing in the installer, the build scripts or any added game
script reaches outside the game. There is no code execution on the PC, no data sent anywhere, no
persistence, no hidden trigger and no obfuscation.

The real risks are about trust and fair play, not about the PC:

1. **Ordinary players can wreck matches with launch options.** In-game editors and debug keys
   ship switched on behind command-line flags, and they broadcast unchecked network calls. With the
   **unmodified** mod, one lobby member can hang a match for everyone, teleport players, or double
   their fire rate (F1).
2. **Most new network calls trust whoever sends them.** A modified client can rig scores, disarm or
   freeze players and stall rounds, and a hostile host can freeze or crash clients (F2, F3).
3. **A downloaded release can't be tied to this source** without the new verification tooling (F4).

---

## Fix status (this repository, `overtime-1.7-en`)

The findings below describe the upstream 1.6 code, and their line numbers refer to those patch files.
This repository has since been hardened. The version tag is now `overtime-1.7-en`, so these builds can't
share a lobby with upstream Overtime. The network protocol differs, and the lobby says "different Overtime edition".

**None of the GDScript fixes have been compiled or run yet** (nothing from the repository was built).
They were checked statically:
- **Patch structure:** every original game line in all 54 patches is byte-identical to upstream, so the patches still apply.
- **Helper references:** every shared helper the patches call exists.
- **Manual review:** each changed line was read by hand.

They need an 8-player test session before release.

| # | Status | What changed |
| --- | --- | --- |
| F1 | **Fixed** | New `NetworkManager.MP8_DEV_TOOLS` constant (false). Every mod read of command-line flags goes through `NetworkManager.mp8_args()` or checks `MP8_DEV_TOOLS` directly, and `mp8_args()` returns nothing in release builds, so every editor, debug key and rule switch keeps its default. `build_installer.ps1` and `build_mpml_mod.ps1` refuse to package a build with dev tools on. |
| F2 | **Fixed** | Burn Recycle's whole-game pause only exists in dev builds. The station count from the host is clamped to 4–8, and every other value is clamped or finiteness-checked. |
| F3 | **Fixed, one residual** | 22 mod RPCs return unless the host sent them (`mp8_sender_is_host`). Numeric arguments are finiteness- and range-checked. Knife at the Office binds the searcher's id to the real sender and only accepts item finds the server recorded. `mp8_device_place_rpc` only moves Spine Breaker's own devices. `rotate_camera_rpc` and the mod-added `setup_rpc` arguments are host-only. **Residual:** Spine Breaker targeting still reads `has_spine_breaker` and `active`, which vanilla RPCs let any peer set. Fixing that means changing vanilla RPCs whose callers aren't visible. |
| F4 | **Mitigated** | Build trust tooling (see [Build trust](#build-trust)). Code signing isn't done. |
| F5 | **Fixed** | Votes only count while a round is live (closed in `update_scores`, reopened on load), and the round is rechecked when the countdown ends. Restarts are capped at 2 per minigame. Only lobby members can vote, at most twice a second. |
| F6 | **Fixed** | The hello RPCs moved to their own `MP8Hello` child node, host-only for the host's report. Version strings are cut to 64 version characters and cleared when the backend changes. |
| F7 | **Fixed** | See F3. `mp8_finite*` checks on every float and vector that arrives over the network in the mod's RPCs. |
| F8 | **Fixed** | Screenshots are dev-only, and file name parts go through `mp8_file_text` (no path characters). |
| F9 | **Fixed** | All 8 layout loaders return the built-in layout unless `MP8_DEV_TOOLS` is on. The parsers that accepted junk now validate numbers, and Escalator Pit caps rows. |
| F10 | **Fixed** | The debug lobby is editor-only again unless dev tools are on, and ENet via `-debug-tools` is dev-only. |
| F11 | **Fixed** | The lobby-size guard only restores the known clamp to 4. It leaves a host's own choice of 2 or 3 alone. |
| F12 | **Fixed** | The banner prints `%APPDATA%\Godot\app_userdata\Machine Party\logs\godot.log` instead of the resolved path. |
| F13 | **Fixed** | Duck Hunt escapes names for BBCode. The Burn Recycle leaderboard and Junk Platform labels strip control characters. |
| F14 | **Fixed** | `build_mpml_mod.gd` records the overlay zip's SHA256, and `main.gd` refuses to mount a zip that doesn't match. It can't catch someone who replaces both files. |
| F15 | **Fixed** | The hello RPCs no longer live on `NetworkManager`, so vanilla's RPC indexes there are untouched. |
| F16 | **Partly fixed** | GDRE Tools is pinned. `build.ps1` only kills game processes inside its own test folder. `parsecheck.ps1` explains that its probe script was never published. `BUILD.md` says 54. `-ExecutionPolicy Bypass` is still required because the scripts are unsigned. |

Not changed:
- **Vanilla weaknesses the mod doesn't touch:** for example any-peer `teleport_rpc` and `set_held_rpc`.
- **Knife at the Office secrets:**
  - Who found the first syringe is still broadcast.
  - A hostile finder can still withhold their own result.
- **Stale gameplay comments** listed under Correctness.

---

## What the code is

| Part | What it does | Runs on |
| --- | --- | --- |
| [`patches/`](patches) — 54 unified diffs | Changes to the game's own decompiled GDScript. They raise the player cap from 4 to 8 and rework 15 minigames. 19,442 added lines, 397 removed vanilla lines. | Inside the game, on every player's machine, with full engine privileges |
| [`installer/Installer.cs`](installer/Installer.cs) | Single-file .NET Framework 4 program, built as console `overtime_install.exe` and WinForms `overtime_launcher.exe`. Reads the compiled `.gdc` files from `overtime_scripts.dat` next to the exe, checks them against an embedded SHA256 manifest, and patches `Machine Party.pck` in place. | Player's PC |
| [`mpml/overtime/`](mpml/overtime) | Alternative install through MachinePartyModLoader. Mounts a zip of the same 54 `.gdc` files over `res://` during the loader's `_init`. | Inside the game |
| [`tools/`](tools) | PowerShell build chain: `git apply` → gdre_tools compile → PCK pack → `csc.exe` installer build → Godot headless MPML package | Builder's PC |

### How the installer patches the game

- **Append, then repoint.** It appends each replacement `.gdc` to the end of the 605 MB PCK and
  overwrites exactly 32 bytes of that file's index entry: offset, size and md5
  ([`Installer.cs:605-653`](installer/Installer.cs:605)). Paths, flags and other entries are never
  touched, and a patch can only replace an entry that already exists.
- **Restoring is cheap.** The original bytes are never overwritten, so restoring only means writing
  the saved index fields back and truncating ([`Installer.cs:723-750`](installer/Installer.cs:723)).
- **Hash gate.** Before patching, the whole PCK must match a hard-coded SHA256
  ([`Installer.cs:59`](installer/Installer.cs:59), checked at `:812`) unless `--force` is given. When the
  base was verified, a restore is re-hashed to prove it is byte-exact.

The design is careful and memory-safe. The code is managed C# with no `unsafe`, pointers or native calls.

---

## Security findings

No finding reaches the PC outside the game. "Needs no modded client" means an ordinary player with
the unmodified mod can do it, which is what makes F1 the most important finding here.

| # | Severity | Finding | Who can do it |
| --- | --- | --- | --- |
| F1 | **High** | Launch-option editors and debug keys let a lobby member hang, rig or cheat matches | Any player, **no modded client** |
| F2 | **Medium** | A hostile host can freeze every client's whole game, or exhaust its memory | Host (one path needs no modded client) |
| F3 | **Medium** | 23 of 25 new network calls act on anyone's request | Modded client |
| F4 | **Medium** | Release binaries are opaque compiled bytecode and can't be verified against source | Whoever built the release |
| F5 | Low | Restart-round vote can fire outside a live round, and a majority can repeat it | A lobby majority |
| F6 | Low | Spoofable version text in the refusal dialog and the host's lobby bar | Modded client or host |
| F7 | Low | NaN or infinite floats from peers reach physics transforms (crash not confirmed) | Modded client |
| F8 | Low | Screenshot file names can escape `user://` | Host, only against players using the `mp8shot` dev flag |
| F9 | Low | Layout files in `user://` load every match, several without validation | Local file |
| F10 | Low | `-debug-tools` now opens the debug lobby and a non-Steam ENet backend in retail | The player themselves |
| F11 | Low | The lobby-size guard overrides a host's own lower limit | — |
| F12 | Info | Logs contain the Windows account path, and players are asked to post them publicly | — |
| F13 | Info | Unescaped player names in rich text and leaderboards | Name choice |
| F14 | Info | MPML overlay zip isn't integrity-checked | Local file |
| F15 | Info | Handshake message may land on a different RPC in vanilla clients (unconfirmed) | — |
| F16 | Info | Build-time supply chain (now mostly addressed) | — |

### F1 — Launch-option editors let an ordinary player hang or cheat matches (High)

The author's tuning tools are compiled into every build. Each one is switched on by a plain
command-line flag on the player's own machine, never checks whether the player is the host, and
sends network calls that every machine, the host included, obeys.

| Minigame | Flag | What that player can do | Where |
| --- | --- | --- | --- |
| Smoke Break | `mp8smokeedit` (5+ players) | Press P to pause the round countdown **forever**. The match hangs for everyone even after the attacker leaves. The same player can also teleport seated players and move or hide crates | [`smoke_break.gd.patch:144`](patches/minigames/smoke_break/scripts/smoke_break.gd.patch:144), `:574`, `:699`, [`round_play_state.gd.patch:11`](patches/minigames/smoke_break/states/round_play_state.gd.patch:11) |
| Junk Platform | `mp8junkkeys` or `mp8junkdebug` | Press 5 to stop rock drops for the rest of the minigame. It has no timeout, so the match stalls | [`junk_platform.gd.patch:176`](patches/minigames/junk_platform/scripts/junk_platform.gd.patch:176), `:362` |
| Exploding Collar Race | `mp8mineedit` (any player count) | Press 9 to send every player back to the start mid-race, probably behind the harvester | [`exploding_collar_race.gd.patch:183`](patches/minigames/exploding_collar_race/scripts/exploding_collar_race.gd.patch:183), `:572`, `:611` |
| Spine Breaker | `mp8spineedit` | Press T to teleport every player, as often as they like | [`spine_breaker.gd.patch:703`](patches/minigames/spine_breaker/scripts/spine_breaker.gd.patch:703), `:1475`, `:1531` |
| Manufacture Gun | `mp8gunedit` (5+) | Move the extra workstations, even during loading, which can spawn players 5–8 outside the walls | [`manufacture_gun.gd.patch:216`](patches/minigames/manufacture_gun/scripts/manufacture_gun.gd.patch:216), `:892` |
| Escalator Pit | `mp8escedit` (5+) | Move, hide or duplicate the escalators and scenery on everyone's screen | [`escalator_pit.gd.patch:168`](patches/minigames/escalator_pit/scripts/escalator_pit.gd.patch:168), `:842`, `:1043` |
| Knife at the Office | `mp8knifeedit`, `mp8knifedebug` (host), `mp8knifemark` (anyone) | Host: teleport any player, see who is secretly infected and where the syringes are. Anyone: see unsearched containers through walls | [`knife_at_the_office.gd.patch:161-178`](patches/minigames/knife_at_the_office/scripts/knife_at_the_office.gd.patch:161), `:531` |
| Duck Hunt | `mp8ratekeys`, `mp8spread=0` | As hunter, fire about twice as fast with no hip-fire spread. A comment claims release builds can't trigger this, but nothing checks | [`hunter_player.gd.patch:124`](patches/minigames/duck_hunt/components/hunter_player/scripts/hunter_player.gd.patch:124), `:304-323`, `:441` |
| Collar Race, Junk Platform | `mp8minewide=`, `mp8junkr=`, `mp8junkview=` | Build a different arena locally from the host's, possibly walking where the host has walls or void (depends on vanilla movement authority, unconfirmed) | [`exploding_collar_race.gd.patch:233`](patches/minigames/exploding_collar_race/scripts/exploding_collar_race.gd.patch:233), [`junk_platform.gd.patch:713`](patches/minigames/junk_platform/scripts/junk_platform.gd.patch:713) |

Hosts also get undisclosed rule switches that change the game for everyone without telling them:
`mp8gunpower=`, `mp8lone`, `mp8spinefuse=`, `mp8devwait=`, `mp8game=` and `mp8hunterme`. The last one
favours players literally named "P1" or "P2".

**Fix:** gate every editor, debug key and rule switch behind `OS.has_feature("editor")` or remove them
from release builds, and add host or sender checks to the network calls they use (see F3).

### F2 — A hostile host can freeze or crash clients (Medium)

- **Whole-game pause.** In Burn Recycle, a host launched with `mp8burnedit` who presses P sets
  `get_tree().paused = true` on every client ([`burn_recycle.gd.patch:1442-1469`](patches/minigames/burn_recycle/scripts/burn_recycle.gd.patch:1442), `:1547`).
  That freezes the entire game, menus included, not just the minigame. Only the host can undo it. If
  the host leaves while paused, clients probably have to restart the game. This path needs no modded client.
- **Unbounded station count.** A modded host can send any value to `_mp8_sync_rpc`
  ([`burn_recycle.gd.patch:410-423`](patches/minigames/burn_recycle/scripts/burn_recycle.gd.patch:410)).
  The value only has a floor, `maxi(seats, 4)`, and it drives array growth and node duplication on
  every client, which can freeze them or run them out of memory.

### F3 — New network calls trust whoever sends them (Medium)

Only 2 of the 25 `any_peer` RPCs the mod adds are built around the caller's identity: the restart vote,
which records the sender's vote, and the version echo. The vanilla game already uses `any_peer` widely,
but the mod adds a lot of new surface. A modified client can:

| Call | Effect | Where |
| --- | --- | --- |
| `mp8_device_place_rpc` | Move **any** 3D node (camera, players, devices) to any position on every machine | [`spine_breaker.gd.patch:974`](patches/minigames/spine_breaker/scripts/spine_breaker.gd.patch:974) |
| `mp8_set_score_mult_rpc` | Set a team's score multiplier with no upper bound. That decides eliminations, and huge values wrap negative | [`forklift_certified_delivery_area.gd.patch:114`](patches/minigames/forklift_certified/components/delivery_area/forklift_certified_delivery_area.gd.patch:114) |
| `mp8_set_gun_power_rpc` | Disarm any player (60 s cooldown) or give anyone a 24 m kill radius | [`manufacture_gun_player.gd.patch:131`](patches/minigames/manufacture_gun/components/player/scripts/manufacture_gun_player.gd.patch:131) |
| `mp8_set_infected_speed_rpc` | Freeze, reverse or fling infected players (any float) | [`knife_at_the_office_player.gd.patch:85`](patches/minigames/knife_at_the_office/components/player/scripts/knife_at_the_office_player.gd.patch:85) |
| `request_item_find_rpc` (vanilla, extended by the mod) | Fake a syringe find with a bogus player id, so the hunt phase never starts and the match hangs | [`knife_at_the_office.gd.patch:1162`](patches/minigames/knife_at_the_office/scripts/knife_at_the_office.gd.patch:1162) |
| `mp8_device_reset_rpc`, `mp8_retire_quiet_rpc`, `mp8_ensure_devices_rpc` | Stall every Spine Breaker device so nobody dies and the round never ends | [`spine_breaker.gd.patch:1106`](patches/minigames/spine_breaker/scripts/spine_breaker.gd.patch:1106), `:995`, [`spine_breaker_device.gd.patch:164`](patches/minigames/spine_breaker/components/device/spine_breaker_device.gd.patch:164) |
| Vanilla `set_spine_breaker_rpc` / `set_active_rpc` | The mod's new targeting trusts these flags, so a player can make themselves immune to devices | [`follow_state.gd.patch:173-183`](patches/minigames/spine_breaker/components/device/states/follow_state.gd.patch:173) |
| `set_hunters_rpc` | Flip everyone's hunter/duck role and capture their mouse | [`duck_hunt.gd.patch:501`](patches/minigames/duck_hunt/scripts/duck_hunt.gd.patch:501) |
| `mp8_esc_dup_rpc` | Duplicate scenery meshes on every machine without limit, a memory and frame-rate DoS | [`escalator_pit.gd.patch:1043`](patches/minigames/escalator_pit/scripts/escalator_pit.gd.patch:1043) |
| `mp8_set_junk_speed_rpc`, `mp8_set_pause_rpc`, the seat, crate, spawn and editor calls | Everything in F1, without needing the flag | see F1 |

None of these reach files, processes or code loading. Arguments are plain values, and Godot's object
decoding stays off.

**Fix:** reject calls unless `multiplayer.get_remote_sender_id()` is 0 or 1 wherever only the host should
act, turn server-only calls into `@rpc("authority")`, and bound or `is_finite()`-check every numeric argument.

### F4 — Release binaries can't be verified against the source (Medium)

- **Opaque payload.** The gameplay code shipped with `overtime_launcher.exe` and in the MPML zip is compiled
  GDScript bytecode, which can do anything the engine can.
- **No proof of origin.** The exe is unsigned and builds aren't reproducible, so the README's SHA256
  values only prove a download matches the author's upload.
- **This source review doesn't cover a downloaded release.**

**Addressed for builds made from this repository:** see [Build trust](#build-trust) and
[`docs/VERIFYING.md`](docs/VERIFYING.md). `tools\verify_exe.ps1` can compare any exe against its
`BUILDINFO.json` or against your own build without running it.

### F5 — Restart vote can fire outside a live round (Low)

When the 5-second countdown ends, nothing re-checks that a round is still running
([`game.gd.patch:644-695`](patches/scripts/scenes/game/game.gd.patch:644)). A late majority vote can
trigger a restart during the score screen, on top of vanilla's own next load. There is also no
cooldown, so two friends in a three-player public lobby can keep wiping a stranger's round points. A
modded client can flood the vote call, and each call logs on the host and broadcasts to everyone.

### F6 — Spoofable version text (Low)

`mp8_hello_rpc` and `mp8_hello_back_rpc` accept any string from any peer, with no length limit
([`network_manager.gd.patch:975-985`](patches/modules/multiplayer/network_manager.gd.patch:975)). The
stored host version is never cleared. So a hostile host or peer can plant text such as "your Overtime
is older… get the fix at <url>" in a player's version-mismatch dialog. That's a plausible lure to a
trojaned "update". A peer that connects and drops can also put its text in the host's lobby message
bar. Whether that bar renders markup depends on vanilla code that isn't visible.

### F7 — Non-finite floats reach physics (Low, unconfirmed)

Several of the F3 calls pass peer floats straight into node transforms, scales and physics queries
with no `is_finite()` check. Note that `maxf(0.05, NaN)` returns NaN. Whether Godot 4.5's physics
server only logs errors or crashes was not checked. If it crashes, F3 becomes a remote crash of every player.

### F8 — Screenshot file names can escape `user://` (Low)

The `mp8shot` debug screenshots build their file names from unsanitized strings:
- the host-supplied `tag` in [`chisel_gauntlet.gd.patch:404-422`](patches/minigames/chisel_gauntlet_multiplayer/scripts/chisel_gauntlet.gd.patch:404)
- the player's network name in [`escalator_pit.gd.patch:1241`](patches/minigames/escalator_pit/scripts/escalator_pit.gd.patch:1241) and [`junk_platform.gd.patch:1502`](patches/minigames/junk_platform/scripts/junk_platform.gd.patch:1502)

With `..` in the string, a PNG screenshot could be written outside the game's data folder. This only
affects a player who launched with the developer flag `mp8shot`. The content is always a screenshot
with a `.png` extension. Whether Godot resolves `..` out of `user://` was not confirmed.

### F9 — Layout files load every match (Low)

Smoke Break, Collar Race, Forklift Certified, Knife at the Office, Spine Breaker, Escalator Pit and
Burn Recycle read `user://mp8_*` layout files whenever they exist, not only in edit mode. The host then
applies or broadcasts the contents. **Correction to the first draft of this report:** only Smoke Break
validates the numbers. The Spine Breaker, Forklift, Knife and Burn Recycle parsers use plain `float()`
with no range or finiteness check, and Escalator Pit clones one mesh per row with no row limit. There's
no injection risk (fixed paths, numbers only), but a stale or planted file silently breaks spawns for a
host's whole lobby.

### F10 — `-debug-tools` in retail builds (Low)

The mod removes the editor-only guards in [`bootstrap.gd.patch:8`](patches/scenes/bootstrap/scripts/bootstrap.gd.patch:8)
and [`network_manager.gd.patch:134-136`](patches/modules/multiplayer/network_manager.gd.patch:134).
With `-debug-tools`, a retail build enters the debug lobby and uses the ENet backend. Hosting that way
opens a UDP port reachable by IP. Only players who add the flag are affected.

### F11–F16 (Low and Info)

- **F11 — Lobby-size guard.** Every 2 s the host pushes the Steam lobby limit back up to 8 whenever
  it's lower ([`network_manager.gd.patch:1162-1202`](patches/modules/multiplayer/network_manager.gd.patch:1162)).
  That overrides a host who deliberately made a small public lobby.
- **F12 — Privacy.** The startup banner prints `OS.get_user_data_dir()` (which contains the Windows
  account name) and the list of installed mods, then asks players to post the block in public GitHub
  issues ([`network_manager.gd.patch:224-225`](patches/modules/multiplayer/network_manager.gd.patch:224)).
  Nothing is sent automatically.
- **F13 — Unescaped names.**
  - Duck Hunt puts Steam names into BBCode unescaped ([`duck_hunt.gd.patch:234`](patches/minigames/duck_hunt/scripts/duck_hunt.gd.patch:234)).
    That is only neutralized by `.to_upper()`, because Godot's tags are lowercase and case-sensitive.
  - Burn Recycle's leaderboard joins names with newlines ([`burn_recycle.gd.patch:766-795`](patches/minigames/burn_recycle/scripts/burn_recycle.gd.patch:766)),
    so a name containing newlines can forge rows. The intermission screens are safe: plain labels, truncated names.
- **F14 — MPML overlay.** [`main.gd:77-115`](mpml/overtime/main.gd:77) checks the vanilla files it
  replaces, but mounts `overtime_overlay.zip` without checking it. Anyone who can swap that zip runs arbitrary code.
- **F15 — Handshake RPC indexes.** The host sends `mp8_hello_rpc` to every connecting peer before the
  version check. Godot identifies RPCs by index, so on a vanilla client that index might resolve to a
  different vanilla method. This depends on engine checksum handling and vanilla method names, and is unconfirmed.
- **F16 — Build-time supply chain.**
  - GDRE Tools compiles every shipped script and wasn't pinned. It is now pinned (see Build trust).
  - Scripts run with `-ExecutionPolicy Bypass`.
  - [`build.ps1:44`](tools/build.ps1:44) force-kills every "Machine Party" process when run without `-CompileOnly`.
  - [`parsecheck.ps1`](tools/parsecheck.ps1) needs `tools/probe/parsecheck.gd`, which isn't in the repo.

---

## Checked and clean

**Installer ([`installer/Installer.cs`](installer/Installer.cs)).** Every safety claim in the README holds.

| Claim | Evidence |
| --- | --- |
| Zero network calls | No `System.Net`, `HttpClient`, `WebClient`, `WebRequest` or `Socket` anywhere |
| No native or dynamic code | No `DllImport`, `extern`, `Marshal`, `Assembly.Load`, `Reflection.Emit` or `Activator`. `System.Reflection` is only used for `GetManifestResourceStream` |
| Registry read-only | `OpenSubKey` + `GetValue` on `Valve\Steam` only ([`:129-149`](installer/Installer.cs:129)) |
| Writes nothing unexpected | Only the game PCK, `overtime_restore.dat` beside it and `%TEMP%\overtime_install.log`. File deletes only touch its own restore data |
| No persistence | No services, scheduled tasks, Run keys or startup entries. It exits after acting |
| "Game log" only opens a folder | `explorer.exe /select` ([`:1028-1048`](installer/Installer.cs:1028)). The other launches are `steam://validate`, `steam://rungameid` and `notepad.exe` on its own log |

**In-game GDScript (every added line, all 54 patches, plus `mpml/overtime/main.gd`).**

- **No reach outside the game:**
  - No process launching, HTTP, sockets or `JavaScriptBridge`.
  - Network traffic is limited to gameplay RPCs between lobby members and the Steam lobby member limit.
  - No dynamic code: `load()` is only ever called on constant paths, and there is no `set_script`, `Expression` or `str_to_var`.
- **No hidden behavior:**
  - No encoded blobs, hidden Unicode or bidi characters.
  - No triggers based on dates, Steam IDs or locale. The only name-based switch is the host-flag test hook `mp8hunterme` (F1).
- **Files stay contained:** everything is written under `user://`, apart from the dev-flag screenshot names (F8).
- **Patch files are clean:** each one edits only its own target, with no file creation, rename, mode change, symlink or binary hunks.
- **The translation changed no code:** only comments and string literals differ from HEAD. A validator
  confirmed this per line, and the security reviewers confirmed it again independently with `git show HEAD`.

The 397 removed vanilla lines are mostly constants and control flow for 8 players, and several patches
add bounds checks that vanilla lacked. The only removed safeguards are the two editor guards in F10.

---

## Correctness and maintainability

These aren't security issues, but they matter if you plan to build, maintain or ship this.

- **Comments often contradict the code.** The translation kept them as written. The important ones:
  - **Junk Platform isn't vanilla at 4 players or fewer.** Expansion targets `NetworkManager.MAX_PLAYERS`
    and the camera pulls back at any player count
    ([`junk_platform.gd.patch:147`](patches/minigames/junk_platform/scripts/junk_platform.gd.patch:147), `:413`, `:539-541`).
    Its own log line and `docs/MINIGAMES.en.md` say the camera is unchanged.
  - **Forklift Certified scoring changed.** The file header says scoring is untouched, but the `break`
    was removed so both members of a winning pair score
    ([`forklift_certified.gd.patch:345-352`](patches/minigames/forklift_certified/scripts/forklift_certified.gd.patch:345)).
  - **Spine Breaker** retires a device at `player count − 2` kills (comments say the 4th). It also uses
    25 baked-in spawn coordinates, where comments say it falls back to the 4 vanilla points.
  - **Installer comments:**
    - Line 16 refers to a `TryLegacyBackup` function that doesn't exist.
    - Lines 852-853 claim an interrupted install fixes itself on rerun. In fact the half-patched PCK
      fails the SHA256 gate, and the player needs Steam's "Verify integrity of game files".
  - **Duck Hunt** has a comment saying the fire-rate keys "can't be triggered in release builds". They can (F1).
- **Chinese and English UI text mostly agree.** The Chinese version-mismatch messages add a "what to do"
  sentence the English drops for label-height reasons. Duck Hunt's Chinese hint calls a cycle time "fire rate".
- **Fragile couplings:**
  - Installer control flow matches on exception message text (`Installer.cs:986`).
  - Duck Hunt tip numbers are hand-copied from the hunter tables, and a comment records that they once drifted for 9 days.
  - Test tooling, probes and diagnostics make up a large share of the 19k added lines inside production scripts (see F1).
- **Documentation drift:** `docs/BUILD.md:46` says "51" patches, but there are 54.

---

## Effects of this translation

**What was translated.** 6,708 lines across 65 files: all 54 patches, `Installer.cs`, both `.gd` files,
the 5 PowerShell scripts, `.gitignore`, `.gitattributes` and `VERSION.txt`. Only comments and string
contents changed. A validator re-lexed every changed line and confirmed that code tokens, format
specifiers, escapes, indentation, diff prefixes, line counts, BOMs and line endings are identical to
`HEAD`. Patches are still LF.

**What changed in behaviour.**
- **Chinese players now see English.** The Chinese halves of bilingual text (`L.T(zh, en)`, `if zh:`
  branches, the `ZHS`/`ZHT` vote tables) were translated too. The original is in git history.
- **Builds from this repo won't match upstream byte for byte.** String literals changed, so the compiled
  `.gdc` files differ, but the handshake tag is still `overtime-1.6`, so such builds can join upstream
  1.6 lobbies. Gameplay logic is identical. If you distribute builds, consider a distinct tag such as
  `overtime-1.6-en`, which blocks cross-play with upstream.
- **One code-coupled string was updated on both sides:** the installer's low-disk-space message and its
  `StartsWith` check (`Installer.cs:981`, `:986`).
- **Log tags renamed:** `[MP8-投票]` and `[MP8-重开]` are now `[MP8-VOTE]` and `[MP8-RESTART]`.

**Documentation.** `README.md`, `installer/README.md` (shipped in the release zip), `docs/BUILD.md` and
`docs/UPDATING.md` are now English only. Their changelog entries use the English text upstream already
wrote, and anything that only existed in Chinese was translated. `docs/MINIGAMES.md` was removed in favour
of the existing `docs/MINIGAMES.en.md`.

---

## Build trust

The build chain was hardened so an exe built from this repository can be checked by anyone.
[`docs/VERIFYING.md`](docs/VERIFYING.md) has the details.

- **[`tools/trust.psm1`](tools/trust.psm1)** is a new shared module. It hashes files, checks Authenticode
  publishers, enforces pinned tool hashes, vets patches, and reads exe resources without running the exe.
- **[`apply_patches.ps1`](tools/apply_patches.ps1)** rejects any patch that isn't a plain edit of its own
  target file before `git apply` sees it. It stops git from finding the surrounding repository, which made it
  silently skip every patch, and fails if any output still matches its source. It then writes a stamp of every
  patch, source and output hash.
- **[`build.ps1`](tools/build.ps1)** requires `gdre_tools.exe` to match `tools/pins/gdre_tools.sha256`
  and `patch\` to match its stamp, then records a compile stamp.
- **[`build_installer.ps1`](tools/build_installer.ps1)**:
  - requires a valid Microsoft signature on `csc.exe`
  - requires `FileVersion` in `Installer.cs` to match `ReleaseNum`, so the exe's version info can't go stale
  - checks the whole stamp chain by hash, replacing a timestamp check that an edited `.gdc` could pass
  - stages resources in a fresh random folder and quotes compiler paths
  - ships the scripts in `overtime_scripts.dat` instead of inside the exe, see below
  - reads each finished exe back to prove it embeds exactly the staged manifest, and that the manifest accepts the shipped data file
  - writes `BUILDINFO.json` (shipped in the zip) and `SHA256SUMS.txt`
- **[`tools/verify_exe.ps1`](tools/verify_exe.ps1)** reports `IDENTICAL`, `MATCH`, `PAYLOAD ONLY`,
  `MISMATCH` or `INCONSISTENT RECORD`. It checks `overtime_scripts.dat` against the exe's own manifest,
  and still understands the schema 1 records of builds that embedded their scripts.

**Scripts moved out of the exe.** The first 1.7-en launcher was blocked by Windows Defender as
`Trojan:Win32/Wacatac.B!ml` and flagged by 27 of 70 engines on VirusTotal, almost all generic or
machine-learning verdicts. The 54 `.gdc` files are zstd-compressed by Godot, so the ~715 KB embedded in the
~754 KB exe gave its code section an entropy of 7.94 out of 8, which looks like a packed payload.
They now ship next to the exe in `overtime_scripts.dat`. The exe embeds only a manifest of each script's
offset, size and SHA256, and [`LoadPatches`](installer/Installer.cs) refuses a data file with a wrong hash,
a gap, an overlap or trailing bytes. The launcher shrank to 63 KB with a code-section entropy of 5.31.
A missing or mismatched data file gets its own state, where switching back to vanilla still works and
installing stops before anything is touched.

**What was tested and what wasn't:**
- **Tested:**
  - The module functions, against Microsoft framework executables and throwaway copies: resource
    reading, normalized hashing with timestamp, checksum, MVID and signature noise, and real edits.
  - The Microsoft signer check, pin enforcement, and rejection of seven crafted hostile patches.
  - `verify_exe.ps1`'s five verdicts. All scripts pass PowerShell's parser.
  - `build_installer.ps1` end to end, then `verify_exe.ps1` against the new build, a flipped byte, a trailing
    byte, a missing data file, and the old embedded 1.7-en exe with its schema 1 record.
  - The console build's `--status` against a real game install with the data file present, missing and
    tampered. With it present, an install made by the old embedded exe is recognised as installed.
- **Not tested:** whether two compiles of `Installer.cs` produce equal normalized hashes, and whether GDRE
  Tools compiles deterministically, are still unconfirmed. The window build's new state was compiled but not
  clicked through.

---

## Coverage and limits

- **Not covered:**
  - **Downloaded release files.** Use `verify_exe.ps1` or build your own.
  - **Vanilla game code and engine behaviour.** The patches only show the vanilla code around each change.
    Several findings are marked plausible because they depend on code or engine behaviour that couldn't be
    seen: NaN handling in physics, RPC index checksums, BBCode case sensitivity, and whether vanilla has
    match timeouts.
  - **Third-party tools:** GDRE Tools, Godot and MachinePartyModLoader.
  - **Dynamic testing:** no fuzzing and no live multiplayer tests. Every finding comes from reading code.
  - **Git history:** only the current commit.
- **How the review was done.** The line-by-line review used nine independent AI reviewers. The
  most severe claims were re-checked against the code by hand:
  - the Smoke Break pause loop
  - the Burn Recycle whole-tree pause and unbounded station count
  - the Chisel Gauntlet screenshot path (downgraded from the reviewer's High to Low because it needs a dev flag on the victim)
  - `mp8_device_place_rpc`
  - the Duck Hunt fire-rate keys

---

## Recommendations

1. **Build from this source with the hardened chain** instead of running a downloaded release. Pin GDRE
   Tools after downloading it yourself, and check exes with `tools\verify_exe.ps1`.
2. **Before shipping to players you don't know, fix F1 and F3.** Gate every editor, debug key and rule
   switch behind `OS.has_feature("editor")`, and add host or sender checks to the network calls listed.
   F1 matters most because it needs no modified client.
3. **Bound untrusted values:**
   - the Burn Recycle station count
   - the Forklift score multiplier
   - every float with `is_finite()`
   - the handshake strings, capped at about 64 characters of `[A-Za-z0-9.+-]`
4. **Re-check that a round is live before a vote restart,** and add a cooldown (F5).
5. **Sanitize screenshot names** (F8), and **only load layout files in edit mode** (F9).
6. **Print `user://logs/godot.log`** instead of the resolved user-data path (F12).
7. **Consider code signing and a deterministic compiler** so whole builds become reproducible (see `docs/VERIFYING.md`).
