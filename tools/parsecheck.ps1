# Machine Party 8-player mod — **runtime parse** smoke check for patched scripts
#
# Usage   powershell -ExecutionPolicy Bypass -File tools\parsecheck.ps1
# Run tools\build.ps1 first (this script mounts the patched PCK)
#
# ── What problem it solves ─────────────────────────────────────────────
# `build.ps1` only guarantees gdre can compile .gd into .gdc. **It doesn't resolve base class identifiers**.
# Found in testing on 2026-08-16. `Minigame extends Node` (not Node3D), and a patch used
# `self.global_transform` — compile all green, packing all green, and it only blew up when the game loaded
#     Parse Error: Identifier "global_transform" not declared in the current scope
#     → Failed to load script → node has no script → @export can't connect → the minigame never starts
# The visible symptom was "stuck in SessionIntro", which looks like a player count or spawn point problem. Very misleading.
# That round wasted 7 minutes. This script exists to catch this class of error within 20 seconds.
#
# ── ⚠️ Its limits (you must know these or you'll misread the results) ────────────────────
# This check **really compiles the source through GDScript.reload()**, while a class of the same name has also been
# loaded from the PCK. That produces a batch of **noise unrelated to us**, which a baseline run on vanilla src\ reports too
#   - "Cannot assign a value of type X as Y" (one class with two identities, so the types don't match)
#   - "Node export is only supported in Node-derived classes ... inherits RefCounted"
#   - "Compile Error: Identifier not found: GameManager" (the autoload wasn't really instantiated)
#   - "class_name isn't allowed in built-in scripts"
# On top of that, **which errors appear depends on scan order** (scripts compiled earlier affect later ones).
# So **don't treat "zero errors" as the pass criterion**. Only look at the one high-signal pattern below.
#
# ── The criterion (just one) ──────────────────────────────────────────
#   `not declared in the current scope` appearing = a real mistake that must be fixed.
#   Ignore all other noise.
# For a stricter verdict, run a baseline comparison
#   Set $env:MP8_CHECK_DIR="...\src" and run it again. Only errors the patches report and vanilla doesn't are ours.

$ErrorActionPreference = "Stop"

$root  = Split-Path -Parent $PSScriptRoot
$godot = "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
$probe = Join-Path $root "tools\probe"
$pck   = Join-Path $root "game_test\Machine Party.pck"

# tools\probe\parsecheck.gd is part of the author's local test bench and isn't published in this repository,
# so this check only works where that probe script has been added by hand.
if (-not (Test-Path (Join-Path $probe "parsecheck.gd"))) {
    throw "tools\probe\parsecheck.gd isn't in this repository (it was never published), so this check can't run"
}
foreach ($needed in @($godot, $pck, (Join-Path $probe "parsecheck.gd"))) {
    if (-not (Test-Path $needed)) { throw "Cannot find $needed" }
}

$out = Join-Path $env:TEMP "mp8_parsecheck.out"
$err = Join-Path $env:TEMP "mp8_parsecheck.err"

Write-Host "Mounting the PCK and parsing every .gd under patch\ ..." -ForegroundColor Cyan
Start-Process $godot `
    -ArgumentList @("--headless", "--path", "`"$probe`"", "--script", "`"$probe\parsecheck.gd`"") `
    -NoNewWindow -Wait -RedirectStandardOutput $out -RedirectStandardError $err | Out-Null

# In stderr, "---- <file name>" lines are separators, used to attribute errors to files.
#
# ⭐ The key distinction (without this step it's all noise)
#   If a file reports `inherits "RefCounted"`, **its base class didn't resolve**,
#   so every Node member after it (multiplayer / visible / global_transform …)
#   cascades into "not declared" — scope errors from such a file **can't be trusted and count as undetermined**.
#   Conversely, in a file whose base class resolved normally, a reported scope error is **a real error**.
#   The `global_transform` case we're after (Minigame is Node, not Node3D) is the latter kind.
# `Steam` / `SteamMultiplayerPeer` are singletons from the Steam GDExtension, which the headless probe doesn't load.
#   They have nothing to do with the patches and are filtered out separately.
$lines = (Get-Content $err -Raw) -split "`r?`n"
$current = "?"
$scope = @{}
$baseBroken = @{}
foreach ($l in $lines) {
    if ($l -match '^----\s*(.+)$') { $current = $Matches[1].Trim(); continue }
    if ($l -match 'inherits "RefCounted"') { $baseBroken[$current] = $true; continue }
    if ($l -match 'Identifier "(.+?)" not declared in the current scope') {
        $id = $Matches[1]
        if ($id -like "Steam*") { continue }
        if (-not $scope.ContainsKey($current)) { $scope[$current] = @() }
        if ($scope[$current] -notcontains $id) { $scope[$current] += $id }
    }
}

$real = @()
$unknown = @()
foreach ($f in $scope.Keys) {
    if ($baseBroken.ContainsKey($f)) { $unknown += $f } else { $real += $f }
}

Write-Host ""
if ($real.Count -gt 0) {
    Write-Host "❌ Real scope errors — this PCK will fail to load, don't run it:" -ForegroundColor Red
    foreach ($f in $real) {
        Write-Host ("   {0}: {1}" -f $f, ($scope[$f] -join ", ")) -ForegroundColor Red
    }
    exit 1
}

Write-Host "✅ No scope errors in scripts whose base class resolved normally." -ForegroundColor Green
if ($unknown.Count -gt 0) {
    Write-Host ("   Undetermined (base class didn't resolve in the probe, probe noise): {0}" -f ($unknown -join ", ")) -ForegroundColor DarkGray
}
Write-Host "   This doesn't mean zero risk. See the top of this script for its limits." -ForegroundColor DarkGray
exit 0
