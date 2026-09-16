# Machine Party 8-player mod — compile + package
#
# Scans every .gd under patch\, derives each res:// path from the folder layout, compiles to .gdc and packs it into the PCK.
# Adding a new patch file **needs no change to this script**. Just drop it into the matching folder under patch\.
#
# Usage   powershell -ExecutionPolicy Bypass -File tools\build.ps1
#
# Things to watch (every one of these was a real pitfall)
#   - Always pack from Machine Party.pck.orig, never on top of an already patched PCK
#   - Patch res://xxx.gdc (the .gd is remapped to it, so patching the .gd does nothing)
#   - Compiling requires --bytecode=4.5.2
#   - Close every game instance before swapping the PCK
#   - gdre_tools writes its progress bar to stderr, so "empty stderr = success" is unreliable.
#     This script filters real errors line by line and checks that every expected output exists instead

#   - -CompileOnly: compiles into patch_gdc\ only, without touching the PCK or killing game processes.
#     Building the installer only needs patch_gdc\ (build_installer.ps1 never reads the PCK), so the public repo's
#     "build your own exe" route doesn't need the 605 MB PCK in game_test\.
#     The full four steps are only needed to run the local test bench.
#   - -Unverified: compile a patch\ that was edited by hand after apply_patches.ps1. The result is marked
#     unverified, and build_installer.ps1 won't package it unless it also gets -Unverified.
#
# Trust checks (tools\trust.psm1, see docs\VERIFYING.md)
#   - gdre_tools.exe must match tools\pins\gdre_tools.sha256, since it compiles every script that ships
#   - patch\ must still match the stamp apply_patches.ps1 wrote, and patches\ must not have changed since
#   - patch_gdc\.overtime-stamp.json records the hash of every source and compiled .gdc for build_installer.ps1

param(
    [switch] $CompileOnly,
    [switch] $Unverified
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "trust.psm1") -Force

$root = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path $root "tools\gdre\gdre_tools.exe"
$p    = Join-Path $root "patch"
$out  = Join-Path $root "patch_gdc"
$gt   = Join-Path $root "game_test"
$orig = Join-Path $gt "Machine Party.pck.orig"

$needs = @($exe, $p)
if (-not $CompileOnly) { $needs += $orig }
foreach ($needed in $needs) {
    if (-not (Test-Path $needed)) { throw "Cannot find $needed" }
}

$gdreSha = Confirm-PinnedHash -Path $exe -PinFile (Join-Path $root "tools\pins\gdre_tools.sha256") -Label "gdre_tools.exe"
Write-Host "      gdre_tools.exe matches its pinned hash"

# patch\ has to be exactly what apply_patches.ps1 produced from the current patches\
$applyStampPath = Join-Path $p ".overtime-stamp.json"
$drift = @()
if (-not (Test-Path $applyStampPath)) {
    $drift += "patch\ has no apply stamp (it wasn't produced by tools\apply_patches.ps1)"
} else {
    $applyStamp = Read-JsonFile $applyStampPath
    # An older apply_patches.ps1 could record a run where git skipped every patch. Compiling that would ship vanilla scripts.
    $applySrc = ConvertTo-Lookup $applyStamp.src
    $applyOut = ConvertTo-Lookup $applyStamp.output
    $unpatched = @($applyOut.Keys | Where-Object { $applySrc.ContainsKey($_) -and $applySrc[$_] -eq $applyOut[$_] })
    if ($unpatched.Count -gt 0) {
        throw "$($unpatched.Count) file(s) in patch\ are still the unpatched game scripts, for example $($unpatched[0]). Re-run tools\apply_patches.ps1 -Force"
    }
    foreach ($pair in @(
        @{ Name = "patch\";   Want = (ConvertTo-Lookup $applyStamp.output);  Have = (Get-TreeHashes -Root $p -Extension ".gd") },
        @{ Name = "patches\"; Want = (ConvertTo-Lookup $applyStamp.patches); Have = (Get-TreeHashes -Root (Join-Path $root "patches") -Extension ".patch") }
    )) {
        foreach ($k in $pair.Want.Keys) {
            if (-not $pair.Have.Contains($k)) { $drift += "$($pair.Name)$k is gone" }
            elseif ($pair.Have[$k] -ne $pair.Want[$k]) { $drift += "$($pair.Name)$k changed" }
        }
        foreach ($k in $pair.Have.Keys) {
            if (-not $pair.Want.ContainsKey($k)) { $drift += "$($pair.Name)$k is new" }
        }
    }
}
$verified = ($drift.Count -eq 0)
if (-not $verified) {
    foreach ($x in $drift | Select-Object -First 20) { Write-Host "    $x" -ForegroundColor Red }
    if (-not $Unverified) {
        throw "patch\ doesn't match what apply_patches.ps1 produced. Re-run tools\apply_patches.ps1 -Force, or pass -Unverified for a local test build"
    }
    Write-Host "      -Unverified given, continuing. This build will be marked unverified." -ForegroundColor Yellow
}

if ($CompileOnly) {
    Write-Host "[1/4] Compile-only mode: not closing game instances, not touching the PCK"
} else {
    Write-Host "[1/4] Closing all game instances"
    # Only instances started from the local test bench folder, never a copy of the game running from anywhere else
    Get-Process "Machine Party" -ErrorAction SilentlyContinue |
        Where-Object { $exePath = $null; try { $exePath = $_.Path } catch { }; $exePath -and $exePath.StartsWith($gt + "\", [System.StringComparison]::OrdinalIgnoreCase) } |
        Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

$sources = Get-ChildItem $p -Recurse -Filter "*.gd" -File
if ($sources.Count -eq 0) { throw "patch\ contains no .gd files" }

# Compiled output lands in patch_gdc\ by **base name** (gdre's --output only takes a folder and drops the hierarchy),
# so two same-named .gd files in different folders overwrite each other. The last one compiled wins, **both** res:// paths
# get the same bytecode, and packing says nothing. State machine scripts collide especially easily
# (names like idle_state.gd / play_state.gd can exist once per minigame).
$dupes = $sources | Group-Object BaseName | Where-Object { $_.Count -gt 1 }
if ($dupes) {
    Write-Host "Base name collision (compiled outputs would overwrite each other, rename first or change the build script):" -ForegroundColor Red
    foreach ($d in $dupes) {
        Write-Host ("  {0}.gd :" -f $d.Name) -ForegroundColor Red
        foreach ($f in $d.Group) {
            Write-Host ("      " + $f.FullName.Substring($p.Length + 1)) -ForegroundColor Red
        }
    }
    throw "patch\ has scripts with the same name"
}

Write-Host "[2/4] Compiling $($sources.Count) scripts -> .gdc"
New-Item -ItemType Directory -Force $out | Out-Null
Get-ChildItem $out -Filter "*.gdc" -ErrorAction SilentlyContinue | Remove-Item -Force
$compileStampPath = Join-Path $out ".overtime-stamp.json"
if (Test-Path $compileStampPath) { Remove-Item $compileStampPath -Force }

$cargs = @("--headless")
foreach ($s in $sources) { $cargs += "--compile=`"$($s.FullName)`"" }
$cargs += @("--bytecode=4.5.2", "--output=`"$out`"")

$cerr = Join-Path $env:TEMP "mp8_compile.err"
Start-Process $exe -ArgumentList $cargs -NoNewWindow -Wait `
    -RedirectStandardOutput (Join-Path $env:TEMP "mp8_compile.out") -RedirectStandardError $cerr

# Every source file must produce a .gdc with the same name. A missing one means compilation failed
$missing = @()
foreach ($s in $sources) {
    $gdc = Join-Path $out ($s.BaseName + ".gdc")
    if (-not (Test-Path $gdc)) { $missing += $s.Name }
}
if ($missing.Count -gt 0) {
    Write-Host "Compilation failed, missing outputs: $($missing -join ', ')" -ForegroundColor Red
    ((Get-Content $cerr -Raw) -split "`r|`n") |
        Where-Object { $_ -match "rror|ailed" } | Select-Object -First 20
    throw "Compilation failed"
}

# Compile stamp. build_installer.ps1 checks every hash in here before embedding anything.
$stampFiles = @()
$bySource = @{}
foreach ($s in $sources) { $bySource[$s.FullName.Substring($p.Length + 1).Replace('\', '/')] = $s }
$sourceKeys = [string[]]@($bySource.Keys)
[Array]::Sort($sourceKeys, [StringComparer]::Ordinal)
foreach ($k in $sourceKeys) {
    $s = $bySource[$k]
    $gdcPath = Join-Path $out ($s.BaseName + ".gdc")
    $stampFiles += [ordered]@{
        source        = $k
        source_sha256 = Get-FileSha256 $s.FullName
        gdc           = $s.BaseName + ".gdc"
        gdc_sha256    = Get-FileSha256 $gdcPath
        res_path      = "res://" + ($k -replace '\.gd$', '.gdc')
    }
}
Write-JsonFile -Path $compileStampPath -Data ([ordered]@{
    stage              = "compile"
    created            = (Get-Date).ToUniversalTime().ToString("o")
    verified           = $verified
    apply_stamp_sha256 = $(if (Test-Path $applyStampPath) { Get-FileSha256 $applyStampPath } else { "" })
    gdre               = [ordered]@{ sha256 = $gdreSha; pin = "tools/pins/gdre_tools.sha256" }
    bytecode           = "4.5.2"
    files              = $stampFiles
})

if ($CompileOnly) {
    Write-Host "[3/4] Skipping packing (-CompileOnly)"
    Write-Host "[4/4] Skipping PCK swap (-CompileOnly)"
    Write-Host ""
    Write-Host ("Done: {0} .gdc files → {1}" -f $sources.Count, $out) -ForegroundColor Green
    Write-Host "      Next: tools\build_installer.ps1" -ForegroundColor Green
    return
}

Write-Host "[3/4] Packing from .orig"
$pargs = @("--headless", "--pck-patch=`"$orig`"")
foreach ($s in $sources) {
    # patch\modules\multiplayer\network_manager.gd
    #   -> res://modules/multiplayer/network_manager.gdc
    $rel = $s.FullName.Substring($p.Length + 1) -replace '\\', '/' -replace '\.gd$', '.gdc'
    $gdc = Join-Path $out ($s.BaseName + ".gdc")
    $pargs += "--patch-file=$gdc=res://$rel"
    Write-Host ("      res://{0}" -f $rel)
}
$newPck = Join-Path $gt "new.pck"
if (Test-Path $newPck) { Remove-Item $newPck -Force }
$pargs += "--output=`"$newPck`""

Start-Process $exe -ArgumentList $pargs -NoNewWindow -Wait `
    -RedirectStandardError (Join-Path $env:TEMP "mp8_pack.err")

if (-not (Test-Path $newPck)) { throw "Packing failed: no new.pck was produced" }

# ── [3b] Trim the extra 32-byte trailer gdre writes ────────────────────────────────
# gdre's --pck-patch appends 28 \0 bytes + "GDPC" to the end. That is the trailer marker for Godot **embedded PCKs**
# (the kind appended to an exe). A standalone .pck has no use for it — the vanilla Steam
# Machine Party.pck doesn't have a single byte of it. The engine finds the pack from the header, so it ignores the trailer.
#
# But **external tools do check it**. MachinePartyModLoader's index parser has a hard rule
#     if self.fmt >= 3 and pos != len(region): return None
# meaning "the index must end exactly at the end of the file". With these extra 32 bytes it reports
#     "Could not locate the file index"
# and simply won't install on our PCK. The result is that players with Overtime couldn't also install MPML,
# and lost the whole MachineParty+ / first person / offline bots set — it was one or the other.
#
# Tested 2026-09-03. With the trailer trimmed, MPML installs right away and the game runs normally
# (headless single instance + play.ps1 -Room -Count 8 windowed full lobby with 0 script errors
#  + both install methods mixed in one online lobby).
#
# ⚠️ **Detect by pattern, never blindly trim 32 bytes.** A newer gdre might not write this trailer,
#    and blind trimming would then cut real data and corrupt the PCK. If the pattern isn't recognised, leave it alone —
#    the only cost is that MPML can't install, and the PCK stays intact.
$TRAILER = 32
$tail = New-Object byte[] $TRAILER
$fsr = [System.IO.File]::OpenRead($newPck)
try {
    $pckLen = $fsr.Length
    if ($pckLen -gt $TRAILER) {
        $fsr.Seek($pckLen - $TRAILER, 'Begin') | Out-Null
        $fsr.Read($tail, 0, $TRAILER) | Out-Null
    }
} finally { $fsr.Close() }

# Expect 28 zero bytes followed by "GDPC" (0x47 0x44 0x50 0x43)
$looksLikeTrailer = ($pckLen -gt $TRAILER) -and
                    ($tail[28] -eq 0x47) -and ($tail[29] -eq 0x44) -and
                    ($tail[30] -eq 0x50) -and ($tail[31] -eq 0x43)
if ($looksLikeTrailer) {
    for ($i = 0; $i -lt 28; $i++) { if ($tail[$i] -ne 0) { $looksLikeTrailer = $false; break } }
}

if ($looksLikeTrailer) {
    $fsw = [System.IO.File]::Open($newPck, 'Open', 'Write')
    try { $fsw.SetLength($pckLen - $TRAILER) } finally { $fsw.Close() }

    # Self-check. The index offset stored at header offset 0x20 must still fall inside the file. A bad trim blows up here,
    # while new.pck hasn't been swapped in yet and the live PCK is still intact.
    $fsc = [System.IO.File]::OpenRead($newPck)
    try {
        $hdr = New-Object byte[] 40
        $fsc.Read($hdr, 0, 40) | Out-Null
        $newLen = $fsc.Length
    } finally { $fsc.Close() }
    $dirOff = [System.BitConverter]::ToUInt64($hdr, 32)
    if ($dirOff -ge $newLen) {
        throw "Self-check after trimming the trailer failed: index offset $dirOff is past the file length $newLen — PCK not swapped, the live one is still the old one"
    }
    Write-Host ("      Trimmed the {0}-byte embedded-PCK trailer (28×00 + GDPC) — without this players can't install MPML" -f $TRAILER)
} else {
    Write-Host "      ⚠️ Trailer isn't the expected '28×00 + GDPC', leaving it as is (not trimmed, safe)" -ForegroundColor Yellow
    Write-Host "         gdre may have changed its format. Consequence: players can't install MachinePartyModLoader. See section [3b] of build.ps1." -ForegroundColor Yellow
}

Write-Host "[4/4] Swapping in the new PCK"
$live = Join-Path $gt "Machine Party.pck"
if (Test-Path $live) { Remove-Item $live -Force }
Rename-Item $newPck "Machine Party.pck" -Force

$info = Get-Item $live
Write-Host ""
Write-Host ("Done: {0}  {1:N0} bytes  {2}" -f $info.Name, $info.Length, $info.LastWriteTime) -ForegroundColor Green
