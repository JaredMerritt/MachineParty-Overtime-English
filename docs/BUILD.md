# Building Overtime yourself

Build an installer equivalent to the `overtime_install.exe` in a release, from scratch. Everything runs on Windows.

## Why this step is needed

This repository publishes **diffs** (`patches/*.patch`), not complete scripts. Most of a complete
script is the game's own decompiled source, which we don't distribute (see the ground rules section
of the README).

So the first build step is **extracting the vanilla scripts from your own legitimate copy of the
game** and applying the patches on top. The result is **byte-for-byte identical** to the author's
(the author's build checks this automatically every time).

## Prerequisites

| Needed | Notes |
| --- | --- |
| Legitimate Machine Party **v2.1.2** (Steam) | The version must match, or the patches won't apply |
| `git` | Patches are applied with `git apply` |
| GDRE Tools (gdsdecomp) **v2.6.4**, Windows build | Extracts and compiles GDScript bytecode. Download it from its GitHub Releases page and extract it to `tools\gdre\`, so that `tools\gdre\gdre_tools.exe` exists. Pin it once as described in `tools\pins\README.md` |
| PowerShell 5.1 | Included with Windows 10 and 11 |
| .NET Framework 4 `csc.exe` | Included with Windows 10 and 11 (`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`), **no SDK needed** |

> ⚠️ **gdre must be v2.6.4.** Different versions decompile slightly differently, and once the line
> numbers don't match the patches won't apply.

## Steps

### 1. Extract the vanilla scripts

The game folder is Steam → right click the game → Manage → Browse local files.

```powershell
tools\gdre\gdre_tools.exe --headless --recover="<game folder>\Machine Party.pck" --output="src"
```

Afterwards `src\` should contain files such as `modules\multiplayer\network_manager.gd`.

> `src\` and `patch\` are both in `.gitignore`. They contain game source, so **don't commit them**.

### 2. Apply the patches

```powershell
powershell -ExecutionPolicy Bypass -File tools\apply_patches.ps1
```

It only passes if all 54 apply. If any fail, the script tells you whether the game version or the
gdre version is wrong.

### 3. Compile to bytecode

```powershell
powershell -ExecutionPolicy Bypass -File tools\build.ps1 -CompileOnly
```

Output goes to `patch_gdc\`. `-CompileOnly` means compile only, without touching any PCK (building the
installer only needs the bytecode, not the 605 MB data pack).

### 4. Build the installer

```powershell
powershell -ExecutionPolicy Bypass -File tools\build_installer.ps1
```

Output goes to `dist\overtime-<version>\`. The two exes are about 60 KB each. All patch bytecode goes
next to them in `overtime_scripts.dat` (about 700 KB). The exe only embeds a manifest with each
script's SHA256, and refuses a data file that doesn't match:

| File | csc arguments | In the release zip? |
| --- | --- | --- |
| `overtime_launcher.exe` | `/target:winexe /define:GUI` (window version) | ✅ **The only program in the release** |
| `overtime_scripts.dat` | — (every `.gdc` back to back, in manifest order) | ✅ Must be in the same folder as the launcher |
| `overtime_install.exe` | `/target:exe` (console version, a different `Main` in the same source) | ❌ For your own troubleshooting and scripted installs |

It also builds `Machine-Party-Overtime-<version>.zip`, holding the launcher, `overtime_scripts.dat`,
the README and `BUILDINFO.json`. **That zip is what goes to players.** The console version stays in the
folder for development. Don't put it in a release.

> Why the scripts are no longer embedded: about 700 KB of compressed bytecode made up 93% of the exe,
> giving it near-random entropy, and antivirus machine learning read it as a packed payload (the
> original 1.7-en was `Wacatac.B!ml` on Defender and 27/70 on VirusTotal). With the scripts split out,
> the exe's code section entropy dropped from 7.94 to 5.31.

The script has two self-checks. The output folder may only hold `.exe`, `.md`, `.zip`, `.json` and
`.txt` files plus `overtime_scripts.dat`, and any exe or data file over 5 MB stops the build. Either
one is a sign that game assets got mixed in.

> Compiling uses `/codepage:65001` because the source is UTF-8 without a BOM, and its non-ASCII
> literals (dashes, arrows, check marks) depend on it. The local csc detects it on its own, but
> another machine might not.

For checking a built exe, see [`VERIFYING.md`](VERIFYING.md).

### 5. (Optional) Build the alternative MPML package

Only needed for the **alternative MachinePartyModLoader install** (the route that coexists with
MachineParty+, first person and similar mods, see "Mod loaders and the alternative MPML install" in the
README). The recommended `.exe` route ends at step 4.

**Extra prerequisite**: a Godot 4 editor executable (this project uses 4.7.2). This step uses it to run
a script, not to open the project.

```powershell
# Looks for the Steam build of Godot by default. If yours is elsewhere, point -Godot at it or set $env:GODOT
powershell -ExecutionPolicy Bypass -File tools\build_mpml_mod.ps1 -Godot "D:\Godot\godot.exe"
```

Output goes to `dist\mpml\`:

| File | What it is |
| --- | --- |
| `overtime\mod.json` | The manifest the loader reads (id, version, entry point) |
| `overtime\main.gd` | **The adapter, the file in this repository you can read line by line.** It doesn't `extends` any vanilla script. It only mounts the overlay into `res://` during the loader's `_init()` |
| `overtime\vanilla_md5.json` | md5 of the 54 **vanilla** files. Each one is checked before mounting, so a game update makes it refuse to mount |
| `overtime\overtime_overlay.zip` | The 54 `.gdc` files compiled in step 3, packed as a resource pack |
| `Machine-Party-Overtime-<version>-MPML.zip` | The whole `overtime\` folder above, which is the release asset |

For players: install MachinePartyModLoader yourself first, then put the `overtime` folder from the zip
into the game's `mods` directory. **We don't bundle the loader itself.** Its repository has no LICENSE,
so we have no right to redistribute it without the author's permission.

> ⚠️ **This step isn't a deterministic build, so don't compare hashes.**
> `overtime_overlay.zip` and the outer zip both write the **packing time** into their zip headers, so
> building the same input twice gives two zips with different SHA256s. In a test of two builds, the
> zips differed byte for byte, but **the contents of all 94 entries were identical**. To check a build,
> extract it and compare the contents, or compare the 54 `.gdc` files in `overtime_overlay.zip` with the
> `patch_gdc\` you compiled yourself in step 3.
> (The same goes for the `.exe` route, since csc also stamps a timestamp into every binary. The SHA256
> lines in the README are for **checking the copy you downloaded**, not a promise that building it
> yourself gives the same hash. `tools\verify_exe.ps1` can compare an exe's code and scripts while
> ignoring those timestamps.)

## Optional: local test bench

To try a build without touching your Steam install, copy the whole game folder to `game_test\`, keep a
copy of the vanilla data pack named `Machine Party.pck.orig`, then run **without** `-CompileOnly`:

```powershell
powershell -ExecutionPolicy Bypass -File tools\build.ps1
```

It builds a new PCK from `.orig` and swaps it in. **Always build from `.orig`, never on top of a pack
that's already patched.**

## Common errors

**`apply_patches.ps1` says a file can't be found in src\**
The game isn't v2.1.2. Wait for a mod release that supports it, or migrate it yourself following
[`UPDATING.md`](UPDATING.md).

**`apply_patches.ps1` says patches failed to apply**
Most likely gdre isn't v2.6.4.

**Every line of the output has an extra byte / hashes don't match the author's output**
git's `core.autocrlf` turned LF into CRLF. `apply_patches.ps1` already forces it off with
`-c core.autocrlf=false -c core.eol=lf`. If you ran `git apply` by hand, add those two options yourself.

**`build.ps1` reports a base name collision in patch\**
gdre's `--output` only takes a folder and drops the hierarchy, so two `.gd` files with the same name in
different folders overwrite each other. You won't normally hit this (the current 54 files all have
different base names). It can only happen if you add files yourself.

**`build_mpml_mod.ps1` says Godot is missing**
It can't find Godot. Point `-Godot "<your godot.exe>"` at it, or set `$env:GODOT` first.

**`build_installer.ps1` can't find `csc.exe`**
The path is hard-coded near the top of the script, in `$csc`. Very old systems or stripped-down images
may not have .NET Framework 4.
