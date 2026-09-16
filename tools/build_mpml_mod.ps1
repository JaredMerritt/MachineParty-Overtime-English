# Machine Party 8-player mod — build the alternative MPML install package
#
# Usage   powershell -ExecutionPolicy Bypass -File tools\build_mpml_mod.ps1
# Run tools\build.ps1 first (this script consumes the .gdc files in patch_gdc\)
#
# Output is dist\mpml\overtime\ — players drop this whole folder into the game's mods\
#
# This is the **alternative** install method. overtime_launcher.exe is still the recommended one.
# It exists for one reason only. Players on the exe route can't install MPML, and so can't use
# MachineParty+ / first person / offline bots. This route is for anyone who wants them side by side.
#
# MachinePartyModLoader itself is not bundled. Its repo has no LICENSE
# (the GitHub API reports license:null), so we have no right to redistribute it without the author's permission.
# The loader author's own three-in-one bundle doesn't include the loader either. Linking to it is the ecosystem norm.

# Godot editor executable. The author's machine uses the Steam build, so that is the default.
# Anyone who cloned the repo can install it anywhere, with two ways to override
#   powershell ... -File tools\build_mpml_mod.ps1 -Godot "D:\Godot\godot.exe"
#   $env:GODOT = "D:\Godot\godot.exe"; powershell ... -File tools\build_mpml_mod.ps1
param([string]$Godot = "")

$ErrorActionPreference = "Stop"
$root  = Split-Path -Parent $PSScriptRoot
$godot = $Godot
if ([string]::IsNullOrWhiteSpace($godot)) { $godot = $env:GODOT }
if ([string]::IsNullOrWhiteSpace($godot)) {
    $godot = "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
}

foreach ($needed in @((Join-Path $root "patch_gdc"), (Join-Path $root "mpml\overtime"), $godot)) {
    if (-not (Test-Path $needed)) { throw "Missing: $needed" }
}

# Release packages must have every developer tool switched off (see MP8_DEV_TOOLS in network_manager.gd)
$nmSource = Get-Content (Join-Path $root "patch\modules\multiplayer\network_manager.gd") -Raw
if ($nmSource -notmatch 'const MP8_DEV_TOOLS\s*:\s*bool\s*=\s*false') {
    throw "MP8_DEV_TOOLS isn't false in network_manager.gd. Refusing to build a package for players"
}

$n = (Get-ChildItem (Join-Path $root "patch_gdc") -Filter *.gdc).Count
if ($n -eq 0) { throw "patch_gdc is empty — run tools\build.ps1 first" }
Write-Host "patch_gdc contains $n .gdc files"

$out = Join-Path $root "dist\mpml\overtime"
Remove-Item (Join-Path $out "*") -Force -ErrorAction SilentlyContinue

# Use Start-Process -Wait, not `&`. In testing `&` returned before Godot had written its files,
# so the Test-Path right after reliably reported "missing output". build.ps1 calls gdre the same way.
Start-Process $godot -ArgumentList @(
    "--headless", "--path", (Join-Path $root "tools\probe"), "--script", "build_mpml_mod.gd"
) -NoNewWindow -Wait

# Judge success by **whether all outputs exist**. Godot's exit code doesn't come back reliably through PowerShell
# ($LASTEXITCODE was empty in testing), same approach as build.ps1 checking for new.pck.
foreach ($f in @("mod.json", "main.gd", "vanilla_md5.json", "overtime_overlay.zip")) {
    $q = Join-Path $out $f
    if (-not (Test-Path $q)) { throw "Build failed: missing output $f" }
}

# ── Package as a Release asset ───────────────────────────────────
# A loose folder can't be uploaded as a Release asset, and the public repo can't hold it either
# (the cleanliness gate in make_release_repo.ps1 throws straight away on .zip / .gdc).
# So the zip is made right here, in the same step as the folder — doing them separately by hand would inevitably
# lead to the day when "the folder is new, the zip is old" and nobody notices.
#
# The version number comes from game_version in vanilla_md5.json — build_mpml_mod.gd
# just read that from MP8_VERSION_TAG, the one authority. No second source is introduced.
# ⚠️ Don't drop -Encoding UTF8. This JSON can contain non-ASCII text (the original had Chinese), and Windows PowerShell 5.1 reads files
# as the system ANSI code page by default, which garbles it so ConvertFrom-Json fails with "':' or '}' expected".
$ver = ((Get-Content (Join-Path $out "vanilla_md5.json") -Raw -Encoding UTF8 | ConvertFrom-Json).game_version) -replace '^overtime-', ''
if ([string]::IsNullOrWhiteSpace($ver)) { throw "Could not read the version number from vanilla_md5.json" }

$zip = Join-Path $root ("dist/mpml/Machine-Party-Overtime-" + $ver + "-MPML.zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $out -DestinationPath $zip
Write-Host ("      " + (Split-Path $zip -Leaf) + "  " + (Get-Item $zip).Length + " bytes (Release asset)")

Write-Host ""
Write-Host "Player install: put the whole dist\mpml\overtime folder into the mods folder inside the game directory." -ForegroundColor Green
Write-Host "Players must install MachinePartyModLoader themselves first — we don't bundle it." -ForegroundColor DarkGray
