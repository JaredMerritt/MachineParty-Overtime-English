# Trusting a built exe

This page covers two cases: building `overtime_launcher.exe` so others can trust it, and checking an
exe someone else built. None of it needs the exe to be run.

## The trust chain

A launcher is made in four steps. Each one now records hashes of what it read and wrote, and the next
step refuses to continue if anything changed in between.

| Step | Script | What it checks | What it records |
| --- | --- | --- | --- |
| 1. Apply patches | `tools\apply_patches.ps1` | Every patch is a plain text edit of exactly the file it's named after, and must actually change that file. No new, deleted, renamed, symlinked or binary files, no path traversal. | `patch\.overtime-stamp.json`: git commit and dirty state, hashes of every patch, every vanilla source used and every patched script |
| 2. Compile scripts | `tools\build.ps1 -CompileOnly` | `gdre_tools.exe` matches `tools\pins\gdre_tools.sha256`. `patch\` and `patches\` still match the step 1 stamp. | `patch_gdc\.overtime-stamp.json`: hash of the step 1 stamp, the gdre hash, and the hash of every source and compiled `.gdc` |
| 3. Build the exe | `tools\build_installer.ps1` | `MP8_DEV_TOOLS` is `false` in `network_manager.gd` (`-DevBuild` overrides that for local test builds only). `csc.exe` has a valid Microsoft signature. Every script and `.gdc` matches the step 2 stamp, which chains back to the step 1 stamp. After compiling, each exe is read back. It must embed exactly the staged manifest and version, and that manifest must accept the shipped `overtime_scripts.dat` byte for byte. | `BUILDINFO.json` (shipped inside the zip, including `dev_tools`) and `SHA256SUMS.txt` |
| 4. Verify | `tools\verify_exe.ps1` | Compares any exe with a `BUILDINFO.json` or with your own build | — |

`BUILDINFO.json` holds:
- **Build identity:** the mod and installer versions, and the target game's PCK hash.
- **Source:** the git commit and whether uncommitted changes were present.
- **Tools:** the compiler's version, hash and signer, and the pinned gdre hash.
- **Input hashes:** `Installer.cs` and every patch.
- **Payload:** the hash of `overtime_scripts.dat` and of the embedded manifest, plus the `res://` path,
  offset, size and hash of every script in the data file.
- **Output hashes:** the plain and normalized hash of each exe.

Before the first build you need to pin GDRE Tools once. See `tools\pins\README.md`.

## Checking an exe

Everything here runs in Windows PowerShell 5.1 (`powershell.exe`).

Against the build record that came with it:

```powershell
powershell -ExecutionPolicy Bypass -File tools\verify_exe.ps1 -Exe overtime_launcher.exe -BuildInfo BUILDINFO.json
```

Against an exe you built yourself from the same commit:

```powershell
powershell -ExecutionPolicy Bypass -File tools\verify_exe.ps1 -Exe their\overtime_launcher.exe -Reference dist\overtime-1.6\overtime_launcher.exe
```

`overtime_scripts.dat` is read from the exe's folder. Pass `-Scripts <path>` if it's somewhere else.
Builds up to the first 1.7-en embedded every script inside the exe and have no data file. Their
schema 1 `BUILDINFO.json` records still verify the same way as before.

| Result | Meaning | Exit code |
| --- | --- | --- |
| `IDENTICAL` | Byte-for-byte the same file | 0 |
| `MATCH` | Same installer code and the same game scripts. Only compile timestamps and the random module id differ | 0 |
| `PAYLOAD ONLY` | Same game scripts, but the installer program differs, for example because a different `csc.exe` version built it. **The installer code is not verified** | 2 |
| `MISMATCH` | The game scripts are different, in the exe's manifest or in `overtime_scripts.dat`. Don't run it | 1 |
| `INCONSISTENT RECORD` | The file hash matches the record but its payload doesn't, so the record itself can't be trusted | 1 |

### How the exe is read without running it

- **Hashes:** the file hash and the normalized hash are computed from raw bytes.
- **Manifest:** the exe's embedded resources are read by loading it "reflection-only" from a byte array,
  inside a separate PowerShell process. The .NET runtime parses its metadata but can't execute any code
  from a reflection-only assembly.
- **Scripts:** `overtime_scripts.dat` is then checked against that manifest the same way the launcher
  checks it. Every script must sit at its listed offset with its listed SHA256, and no byte may be left over.

### The normalized hash

Two compiles of identical source with the Windows `csc.exe` still produce different files, because
the compiler stamps a build time and a random module id into every exe. The normalized hash blanks
those out:
- the PE timestamp and checksum
- debug directory entries
- the metadata `#GUID` heap
- any Authenticode signature block

It then hashes the rest. Matching normalized hashes mean the same compiled code and resources.

**This has not been confirmed against two real builds yet.** It was tested on Microsoft framework
executables with those fields altered, not on two separate compiles of `Installer.cs`. If you build
twice and the normalized hashes differ, please report it. `verify_exe.ps1` will then fall back to
`PAYLOAD ONLY`, which still verifies the game scripts.

## What this does and doesn't prove

It proves:
- The game scripts a verified exe will install are byte-for-byte the ones in the build record, or in your own build.
  The launcher refuses any `overtime_scripts.dat` that doesn't match its embedded manifest.
- A build record can't claim inputs that its build steps didn't actually see, as long as nobody edits the stamps by hand.
- A tampered patch, a swapped `gdre_tools.exe`, an edited intermediate file or an unsigned `csc.exe` stops the build.

It doesn't prove:
- **That the source is safe.** That's what the review in `ANALYSIS.md` is for.
- **That a `BUILDINFO.json` from a stranger is honest.** Anyone can write one. A record only means something
  if it comes from someone you trust, or if you rebuild from the recorded commit and compare with `-Reference`.
- **That GDRE Tools compiles deterministically.** If two people's `.gdc` files differ for the same sources,
  their payloads won't match even though neither build was tampered with. Check this by comparing
  `patch_gdc\.overtime-stamp.json` between two machines.
- **Much about the MPML package.** `tools\build_mpml_mod.ps1` refuses to package a dev build, and the loader
  adapter checks the overlay zip against the SHA256 in its manifest before mounting. It doesn't use the stamp chain
  or produce a `BUILDINFO.json`, though.

## Further steps worth considering

- **Code signing.** The exe is still unsigned, so Windows SmartScreen and antivirus heuristics will
  keep warning. Moving the scripts out of the exe removed the biggest trigger, a near-random 700 KB blob
  that made machine-learning scanners read the launcher as packed. Low-cost options include Azure Trusted Signing (paid monthly) and SignPath's free
  program for open-source projects. SignPath expects builds to run in CI, which isn't possible here,
  because the build needs the game's own files.
- **A deterministic compiler.** Building with the Roslyn compiler from the .NET SDK and `/deterministic`
  would make the whole exe reproducible, not just the payload. That adds the .NET SDK as a build dependency.
