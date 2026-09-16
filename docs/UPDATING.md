# Moving to a new game version

This is for anyone who wants to move the mod to a new game version themselves, and it's also the
author's own runbook. The v2.1.1 → v2.1.2 update was done by following it.

## Why the mod has to be rebuilt after every game update

It isn't "just to be safe", it's a hard requirement. Both of the game's multiplayer backends compare
the `game_version` a client reports with their own and refuse entry to the lobby if they differ. A mod
built on the old baseline can't connect to anyone running the current retail version, so it has to be
rebuilt on the new baseline.

The installer blocks it too. It embeds the vanilla PCK's SHA256 and size, and if they don't match it
**refuses to install and leaves your files alone**.

## Process

### 1. Find out what upstream changed first, don't rebuild blindly

Dump the md5 of every file in both the old and new PCK, then diff them.

> ⚠️ **Don't skip `res://.godot/`**: compiled scenes (`.scn`) live under `res://.godot/exported/`.
> Skip it and you'll miss scene changes and wrongly conclude "the scenes didn't change".

### 2. Check whether any of the 54 scripts we change are on the changed list

- **None are** → the patches will most likely work as they are. Go to step 3.
- **Some are** → upstream's changes to those files have to be merged into the patches. Otherwise
  applying them would roll back the developer's fixes.

### 3. Extract `src\` again and reapply the patches

```powershell
tools\gdre\gdre_tools.exe --headless --recover="<new game folder>\Machine Party.pck" --output="src"
powershell -ExecutionPolicy Bypass -File tools\apply_patches.ps1 -Force
```

The patches that fail are the files with conflicts. Merge those by hand.

### 4. Update the version fingerprint in the installer (three lines)

At the top of `Core` in `installer/Installer.cs`:

```csharp
public const string GameVersion = "v2.1.2";
public const string VanillaSha  = "326CC398…3DFA8E";
public const long   VanillaSize = 634798100L;
```

All three have to change together to the values of the **new vanilla PCK**, or old patches get applied
to a new pack.

Get the new values like this (from a pack with **no mod installed**):

```powershell
Get-FileHash "<game folder>\Machine Party.pck" -Algorithm SHA256
(Get-Item "<game folder>\Machine Party.pck").Length
```

### 5. Bump the mod version

`MP8_VERSION_TAG` in `patch/modules/multiplayer/network_manager.gd`.

> The code is full of `MP8_` / `_mp8_` prefixes. That's the project's **internal code name**, which
> predates the name "Overtime". They're internal identifiers and were deliberately not renamed. There
> are thousands of them across dozens of verified files, so renaming them would be pure risk for no gain.

It's the **only** source of the mod version: the version the installer embeds and the multiplayer
handshake both read it from here.

The launcher's own release number is separate. It's `ReleaseNum` in `installer/Installer.cs`, with its
numeric `FileVersion` right below it, and it names the `dist\` folder and the release zip.
`build_installer.ps1` refuses to build if the two don't agree.

> ⚠️ Changing `MP8_VERSION_TAG` means **people on the old version can't join lobbies on the new one**.
> This is deliberate (mismatched versions fail mid-match in ways that are very hard to diagnose), but
> it also means **a new release has to be announced so everyone updates together**.

### 6. Recompile and package

```powershell
powershell -ExecutionPolicy Bypass -File tools\build.ps1 -CompileOnly
powershell -ExecutionPolicy Bypass -File tools\build_installer.ps1
```

### 7. Test it in the real game before releasing

At the very least, confirm the main menu version ends with `+overtime`, you can create a lobby, the
lobby shows 8 seats, and minigames load. Ideally, play a real match with 5 or more people.

## If the game's structure changes a lot

Everything above assumes a minor update where the scripts barely changed. If the developer rewrote a
minigame, its patch has to be rewritten rather than merged, which means redoing that minigame's
8-player adaptation.

How to tell: count the files `apply_patches.ps1` reports conflicts in. A handful means merging. If
more than half fail to apply, it's a rewrite, so be ready to redo them.
