# Machine Party 8-player mod — apply patches\ onto the src\ you unpacked yourself
#
# This mod publishes **diff patches**, not full scripts — most of a full script is the game's own
# decompiled source, which we don't redistribute. Unpack src\ from your own legitimate copy, run this
# script, and you get a patch\ that is **byte-for-byte identical** for anyone applying these same patches.
#
# Before git sees a patch it is vetted by Confirm-SafePatch (tools\trust.psm1). Only plain text edits of
# the one file each patch is named after are allowed. Afterwards patch\.overtime-stamp.json records the
# hash of every patch, source and output, so later build steps can prove nothing changed in between.
#
# Usage
#   powershell -ExecutionPolicy Bypass -File tools\apply_patches.ps1
#   powershell -ExecutionPolicy Bypass -File tools\apply_patches.ps1 -Src D:\mp\src
#
# Prerequisites are in docs\BUILD.md (gdre_tools v2.6.4 + game v2.1.2 + git)

param(
    [string] $Src = "",       # Folder of unpacked vanilla scripts, defaults to <repo>\src
    [string] $Out = "",       # Output folder, defaults to <repo>\patch
    [switch] $Force           # Clear the output folder first if it already exists
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "trust.psm1") -Force

$root    = Split-Path -Parent $PSScriptRoot
$patches = Join-Path $root "patches"

if ($Src -eq "") { $Src = Join-Path $root "src" }
if ($Out -eq "") { $Out = Join-Path $root "patch" }

if (-not (Test-Path $patches)) { throw "Cannot find $patches" }
if (-not (Test-Path $Src)) {
    throw @"
Cannot find $Src

First unpack your own copy of the game's PCK into scripts with gdre_tools. See docs\BUILD.md for the steps.
The short version:
  gdre_tools.exe --headless --recover="<game folder>\Machine Party.pck" --output="$Src"
"@
}

$git = (Get-Command git -ErrorAction SilentlyContinue)
if ($null -eq $git) { throw "git is required (patches are applied with git apply)" }

$list = Get-ChildItem $patches -Recurse -Filter "*.patch" -File
if ($list.Count -eq 0) { throw "patches\ contains no .patch files" }

# Vet every patch before touching anything. One bad patch stops the whole run.
foreach ($p in $list) {
    $target = $p.FullName.Substring($patches.Length + 1)
    $target = $target.Substring(0, $target.Length - 6).Replace('\', '/')
    Confirm-SafePatch -PatchPath $p.FullName -Target $target
}
Write-Host "Vetted $($list.Count) patches: each is a plain text edit of its own target file"

if (Test-Path $Out) {
    if ($Force) { Remove-Item $Out -Recurse -Force }
    else { throw "$Out already exists. Re-run with -Force once you are sure it can be overwritten." }
}
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path

# Inside a git work tree, git apply reads patch paths from the repo root and silently skips every file outside
# the current folder, still exiting 0. The default patch\ is inside this repo, so git is kept from looking above
# the output folder, then asked to confirm it can't see a repository.
$oldCeiling = $env:GIT_CEILING_DIRECTORIES
$env:GIT_CEILING_DIRECTORIES = Split-Path -Parent $Out
Push-Location $Out
$ErrorActionPreference = "Continue"
git rev-parse --git-dir 2>&1 | Out-Null
$seesRepo = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = "Stop"
Pop-Location
if ($seesRepo) {
    $env:GIT_CEILING_DIRECTORIES = $oldCeiling
    throw "git still sees a repository from $Out, so git apply would skip files. Pass an -Out folder that isn't a git repository."
}

Write-Host "Applying patches: $($list.Count)"

$missing   = @()
$failed    = @()
$unchanged = @()
$ok        = 0
$usedSrc   = @{}

foreach ($p in $list) {
    # patches\modules\multiplayer\network_manager.gd.patch
    #   -> modules\multiplayer\network_manager.gd
    $rel = $p.FullName.Substring($patches.Length + 1)
    $rel = $rel.Substring(0, $rel.Length - 6)      # strip .patch

    $from = Join-Path $Src $rel
    if (-not (Test-Path $from)) { $missing += $rel; continue }
    $usedSrc[$rel.Replace('\', '/')] = Get-FileSha256 $from

    $dest = Join-Path $Out $rel
    New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
    Copy-Item $from $dest -Force

    # ⚠️ Both -c flags are required. If local git has core.autocrlf on (common with a default Windows install),
    #    apply writes every LF as CRLF, adding one byte per line. It still compiles, but the output no longer
    #    matches the author's and any byte-level check fails. The author hit this exact problem locally.
    # Continue keeps git's error text on a failed patch from stopping the script before the report below
    Push-Location $Out
    $ErrorActionPreference = "Continue"
    git -c core.autocrlf=false -c core.eol=lf apply --whitespace=nowarn "$($p.FullName)" 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    Pop-Location

    # A file that still matches its source was skipped, whatever the exit code says
    if ($code -ne 0) { $failed += $rel }
    elseif ((Get-FileSha256 $dest) -eq $usedSrc[$rel.Replace('\', '/')]) { $unchanged += $rel }
    else { $ok++ }
}
$env:GIT_CEILING_DIRECTORIES = $oldCeiling

Write-Host ""
if ($missing.Count -gt 0) {
    Write-Host "These files are missing from src\ ($($missing.Count)):" -ForegroundColor Red
    foreach ($x in $missing) { Write-Host "    $x" -ForegroundColor Red }
    Write-Host "→ Almost certainly the **wrong game version**. This mod targets v2.1.2." -ForegroundColor Yellow
    Write-Host "  This shows up after a game update. Wait for an updated mod, or port it yourself with docs\UPDATING.md." -ForegroundColor Yellow
}
if ($failed.Count -gt 0) {
    Write-Host "These patches failed to apply ($($failed.Count)):" -ForegroundColor Red
    foreach ($x in $failed) { Write-Host "    $x" -ForegroundColor Red }
    Write-Host "→ Two common causes:" -ForegroundColor Yellow
    Write-Host "  ① The gdre used for unpacking is not v2.6.4 (decompiled output differs, so line numbers don't match)." -ForegroundColor Yellow
    Write-Host "  ② The game is not v2.1.2." -ForegroundColor Yellow
}
if ($unchanged.Count -gt 0) {
    Write-Host "These patches ran but changed nothing ($($unchanged.Count)):" -ForegroundColor Red
    foreach ($x in $unchanged) { Write-Host "    $x" -ForegroundColor Red }
    Write-Host "→ git skipped them. This happens when git finds a repository around the output folder." -ForegroundColor Yellow
}
if ($missing.Count -gt 0 -or $failed.Count -gt 0 -or $unchanged.Count -gt 0) {
    throw "Not all patches applied: $ok succeeded out of $($list.Count)"
}

# Build stamp. build.ps1 refuses to compile a patch\ that no longer matches it.
$srcKeys = [string[]]@($usedSrc.Keys)
[Array]::Sort($srcKeys, [StringComparer]::Ordinal)
$srcHashes = [ordered]@{}
foreach ($k in $srcKeys) { $srcHashes[$k] = $usedSrc[$k] }
Write-JsonFile -Path (Join-Path $Out ".overtime-stamp.json") -Data ([ordered]@{
    stage   = "apply"
    created = (Get-Date).ToUniversalTime().ToString("o")
    git     = Get-GitProvenance -Root $root
    patches = Get-TreeHashes -Root $patches -Extension ".patch"
    src     = $srcHashes
    output  = Get-TreeHashes -Root $Out -Extension ".gd"
})

Write-Host "All succeeded: $ok → $Out" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  powershell -ExecutionPolicy Bypass -File tools\build.ps1 -CompileOnly" -ForegroundColor Yellow
Write-Host "  powershell -ExecutionPolicy Bypass -File tools\build_installer.ps1" -ForegroundColor Yellow
