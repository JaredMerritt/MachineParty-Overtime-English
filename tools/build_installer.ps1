# Machine Party 8-player mod — build the single-file installer
#
# Output goes to dist\mp8-<version>\overtime_install.exe
#   — all patch bytecode is embedded, users just double-click it, **no .NET SDK install and no gdre download needed**.
#
# The compiler is csc.exe, which ships with Windows (.NET Framework 4, present on every Win10/11),
# so nothing needs installing here or on a friend's machine (Framework 4 is a system component).
#
# Usage   powershell -ExecutionPolicy Bypass -File tools\build_installer.ps1
# Run tools\build.ps1 first (this script only copies the compiled output from patch_gdc\)
#
# Trust checks (tools\trust.psm1, see docs\VERIFYING.md)
#   - csc.exe must carry a valid Microsoft signature
#   - every patch\ script and patch_gdc\ .gdc must match the hashes build.ps1 recorded, chained back to patches\
#   - each finished exe is read back as data and must embed exactly the staged payload, nothing more or less
#   - BUILDINFO.json (shipped in the zip) and SHA256SUMS.txt record what went in and what came out
#   - -Unverified is required to package a build made from a hand-edited patch\
#   - MP8_DEV_TOOLS in network_manager.gd must be false. -DevBuild overrides that for a local test build only

param(
    [switch] $Unverified,
    [switch] $DevBuild
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "trust.psm1") -Force

$root  = Split-Path -Parent $PSScriptRoot
$patch = Join-Path $root "patch"
$gdc   = Join-Path $root "patch_gdc"
$src   = Join-Path $root "installer\Installer.cs"
$csc   = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

foreach ($needed in @($patch, $gdc, $src, $csc)) {
    if (-not (Test-Path $needed)) { throw "Cannot find $needed" }
}

$cscSigner = Confirm-SignedBy -Path $csc -SubjectPattern 'O=Microsoft Corporation' -Label "csc.exe"

# The single source of the version number is MP8_VERSION_TAG in network_manager.gd (it also decides who can play with whom)
$nm = Get-Content (Join-Path $patch "modules\multiplayer\network_manager.gd") -Raw
$m  = [regex]::Match($nm, 'MP8_VERSION_TAG\s*:\s*String\s*=\s*"([^"]+)"')
if (-not $m.Success) { throw "Could not read MP8_VERSION_TAG from network_manager.gd" }
$tag = $m.Groups[1].Value

# Release builds must have every developer tool switched off. With MP8_DEV_TOOLS true, any player could turn on
# the in-game editors and debug keys with launch options and wreck matches for everyone.
$dm = [regex]::Match($nm, 'const MP8_DEV_TOOLS\s*:\s*bool\s*=\s*(true|false)')
if (-not $dm.Success) { throw "Could not read MP8_DEV_TOOLS from network_manager.gd" }
$devTools = ($dm.Groups[1].Value -eq "true")
if ($devTools -and -not $DevBuild) {
    throw "MP8_DEV_TOOLS is true in network_manager.gd. Set it to false for anything given to players, or pass -DevBuild for a local test build"
}
if ($devTools) { Write-Host "      ⚠️ DEV BUILD. Developer tools are on, never give this exe to players" -ForegroundColor Yellow }

# The installer's own release number (ReleaseNum in Installer.cs) is kept separate from the mod version.
# An installer-only release (1.3 → 1.3.1) leaves the mod version and PCK bytes unchanged, so existing players don't
# reinstall and the multiplayer handshake is unaffected. The output folder still has to differ, or the Remove-Item below would
# delete the already shipped dist\overtime-1.3\ along with its zip.
$cs  = Get-Content $src -Raw
$mr  = [regex]::Match($cs, 'ReleaseNum\s*=\s*"([^"]+)"')
if (-not $mr.Success) { throw "Could not read ReleaseNum from Installer.cs" }
# Don't name this variable $rel. The embedded resource loop below already has a $rel (the patch's relative path),
# and the clash would send the output folder to dist\overtime-scripts\scenes\... instead.
$instRev = $mr.Groups[1].Value
Write-Host "[1/4] mod version = $tag    installer release = $instRev"

# Integrity check. Every patch\ script and every compiled .gdc must still match the hashes build.ps1 recorded,
# and that stamp must chain back to the apply stamp for the current patches\. This replaces an older timestamp
# check, which let a hand-edited .gdc through because an edited file is always newer.
$stampPath = Join-Path $gdc ".overtime-stamp.json"
$applyStampPath = Join-Path $patch ".overtime-stamp.json"
if (-not (Test-Path $stampPath)) { throw "patch_gdc\ has no build stamp. Run tools\build.ps1 first" }
$stamp = Read-JsonFile $stampPath
if (-not $stamp.verified -and -not $Unverified) {
    throw "patch_gdc\ was compiled from a hand-edited patch\ (build.ps1 -Unverified). Rebuild from patches\, or pass -Unverified for a local test build"
}

$sources = Get-ChildItem $patch -Recurse -Filter "*.gd" -File
$problems = @()
if ($stamp.verified) {
    if (-not (Test-Path $applyStampPath) -or (Get-FileSha256 $applyStampPath) -ne $stamp.apply_stamp_sha256) {
        $problems += "patch\.overtime-stamp.json isn't the one build.ps1 compiled from"
    } else {
        $applyStamp = Read-JsonFile $applyStampPath
        $wantPatches = ConvertTo-Lookup $applyStamp.patches
        $havePatches = Get-TreeHashes -Root (Join-Path $root "patches") -Extension ".patch"
        foreach ($k in $wantPatches.Keys) { if (-not $havePatches.Contains($k) -or $havePatches[$k] -ne $wantPatches[$k]) { $problems += "patches\$k changed since the build" } }
        foreach ($k in $havePatches.Keys) { if (-not $wantPatches.ContainsKey($k)) { $problems += "patches\$k is new since the build" } }
    }
}
$stampBySource = @{}
foreach ($f in @($stamp.files)) { $stampBySource[[string]$f.source] = $f }
if ($stampBySource.Count -ne $sources.Count) { $problems += "the build stamp lists $($stampBySource.Count) scripts but patch\ has $($sources.Count)" }
foreach ($s in $sources) {
    $relSource = $s.FullName.Substring($patch.Length + 1).Replace('\', '/')
    $entry = $stampBySource[$relSource]
    if ($null -eq $entry) { $problems += "$relSource isn't in the build stamp"; continue }
    if ((Get-FileSha256 $s.FullName) -ne $entry.source_sha256) { $problems += "$relSource changed since it was compiled" }
    $o = Join-Path $gdc ($s.BaseName + ".gdc")
    if (-not (Test-Path $o)) { $problems += "$($s.BaseName).gdc is missing"; continue }
    if ((Get-FileSha256 $o) -ne $entry.gdc_sha256) { $problems += "$($s.BaseName).gdc changed since it was compiled" }
}
if ($problems.Count -gt 0) {
    foreach ($x in $problems | Select-Object -First 30) { Write-Host "    $x" -ForegroundColor Red }
    throw "Build inputs don't match their stamps. Re-run tools\apply_patches.ps1 -Force and tools\build.ps1 -CompileOnly"
}
Write-Host "[2/4] Integrity check passed ($($sources.Count) patches, every hash matches the build stamps)"

# ── Prep the embedded resources ──────────────────────────────────────────────────
# Resource names are sequence numbers (mp8.0 / mp8.1 …) rather than res:// paths.
# csc's `/resource:` flag takes a comma separated "file,resource name", and slashes or colons in paths tend to break it,
# so numbers are the safest choice. The path mapping is recorded in mp8.manifest.
# The staging folder gets a fresh random name so nothing left over, or planted, can end up embedded.
$work = Join-Path $env:TEMP ("mp8_installer_build_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $work | Out-Null

$resArgs = @()
$manifest = @("# <index>|<res:// path>    generated by tools\build_installer.ps1")
$expectRes = [ordered]@{}
$payload = @()
$i = 0
foreach ($s in $sources) {
    $rel = $s.FullName.Substring($patch.Length + 1) -replace '\\', '/' -replace '\.gd$', '.gdc'
    $blob = Join-Path $work "$i.bin"
    Copy-Item (Join-Path $gdc ($s.BaseName + ".gdc")) $blob -Force
    $blobSha = Get-FileSha256 $blob
    $relSource = $s.FullName.Substring($patch.Length + 1).Replace('\', '/')
    if ($blobSha -ne $stampBySource[$relSource].gdc_sha256) { throw "$($s.BaseName).gdc changed while it was being staged" }
    $expectRes["mp8.$i"] = $blobSha
    $payload += [ordered]@{ resource = "mp8.$i"; res_path = "res://$rel"; size = (Get-Item $blob).Length; sha256 = $blobSha }
    $resArgs += "/resource:`"$blob`",mp8.$i"
    $manifest += "$i|res://$rel"
    $i++
}

$manFile = Join-Path $work "manifest.txt"
[System.IO.File]::WriteAllText($manFile, ($manifest -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
$resArgs += "/resource:`"$manFile`",mp8.manifest"
$expectRes["mp8.manifest"] = Get-FileSha256 $manFile

$verFile = Join-Path $work "version.txt"
[System.IO.File]::WriteAllText($verFile, $tag, (New-Object System.Text.UTF8Encoding($false)))
$resArgs += "/resource:`"$verFile`",mp8.version"
$expectRes["mp8.version"] = Get-FileSha256 $verFile

# ── Compile ────────────────────────────────────────────────────────────
# Every rebuild starts from an empty folder. Leftovers from a previous version would muddle "which version did friends actually get"
$outDir = Join-Path $root "dist\overtime-$instRev"
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Force $outDir | Out-Null

# Two exes from the same source. A console build (full command line) + a windowed build (double-click, one-click toggle).
# The windowed build uses /define:GUI for a different Main, and /target:winexe so no black console window pops up.
$targets = @(
    @{ Name = "overtime_install.exe";  Kind = "/target:exe";    Extra = @() },
    @{ Name = "overtime_launcher.exe"; Kind = "/target:winexe"; Extra = @(
           "/define:GUI",
           "/reference:System.Windows.Forms.dll",
           "/reference:System.Drawing.dll") }
)

Write-Host "[3/4] Compiling (csc.exe, embedding $i patches)"
$log = Join-Path $env:TEMP "mp8_csc.log"
$built = @()

foreach ($t in $targets) {
    $exe = Join-Path $outDir $t.Name
    # /codepage:65001 is set because the source is UTF-8 without a BOM, and its non-ASCII literals (dashes, arrows, check marks) depend on it.
    # The local csc detects it on its own, but another machine might not, so hard-coding it is safer.
    # Paths are quoted because Start-Process doesn't quote arguments, and a space in the repo or TEMP path would split them.
    $cargs = @(
        "/nologo", $t.Kind, "/platform:anycpu", "/optimize+", "/codepage:65001",
        "/reference:System.dll", "/reference:System.Core.dll"
    ) + $t.Extra + @("/out:`"$exe`"", "`"$src`"") + $resArgs

    if (Test-Path $log) { Remove-Item $log -Force }
    Start-Process $csc -ArgumentList $cargs -NoNewWindow -Wait -RedirectStandardOutput $log
    if (-not (Test-Path $exe)) {
        Get-Content $log | Select-Object -First 30
        throw "Compilation failed: $($t.Name)"
    }
    $warn = Get-Content $log | Where-Object { $_ -match "error|warning" }
    if ($warn) { $warn | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow } }

    # Read the finished exe back as data and prove it embeds exactly the staged payload
    $found = Get-EmbeddedResources -Path $exe
    $resProblems = @()
    foreach ($name in $expectRes.Keys) {
        if (-not $found.ContainsKey($name)) { $resProblems += "$name is missing" }
        elseif ($found[$name].sha256 -ne $expectRes[$name]) { $resProblems += "$name doesn't match what was staged" }
    }
    foreach ($name in $found.Keys) {
        if (-not $expectRes.Contains($name)) { $resProblems += "$name was never staged" }
    }
    if ($resProblems.Count -gt 0) {
        foreach ($x in $resProblems) { Write-Host "    $x" -ForegroundColor Red }
        Remove-Item $exe -Force
        throw "$($t.Name) doesn't embed the expected payload, so it was deleted"
    }
    Write-Host ("      {0}  {1:N0} bytes, all {2} embedded resources verified" -f $t.Name, (Get-Item $exe).Length, $expectRes.Count)
    $built += $exe
}

Copy-Item (Join-Path $root "installer\README.md") $outDir -Force
Remove-Item $work -Recurse -Force

# ── Build record ────────────────────────────────────────────────────────
# Everything someone needs to check these exes against this source without running them.
# tools\verify_exe.ps1 reads this file.
$git = Get-GitProvenance -Root $root
if ($git.available -and $git.dirty) {
    Write-Host "      ⚠️ Built with uncommitted changes under patches\, installer\, tools\ or mpml\. BUILDINFO.json records git.dirty = true" -ForegroundColor Yellow
}
$outputs = [ordered]@{}
foreach ($e in $built) {
    $outputs[(Split-Path -Leaf $e)] = [ordered]@{
        size              = (Get-Item $e).Length
        sha256            = Get-FileSha256 $e
        normalized_sha256 = Get-NormalizedPeSha256 $e
    }
}
$buildInfo = [ordered]@{
    schema            = 1
    how_to_verify     = "powershell -ExecutionPolicy Bypass -File tools\verify_exe.ps1 -Exe <exe> -BuildInfo BUILDINFO.json"
    mod_version       = $tag
    installer_release = $instRev
    built_utc         = (Get-Date).ToUniversalTime().ToString("o")
    verified_sources  = [bool]$stamp.verified
    dev_tools         = $devTools
    target_game       = [ordered]@{
        version    = [regex]::Match($cs, 'GameVersion\s*=\s*"([^"]+)"').Groups[1].Value
        pck_sha256 = [regex]::Match($cs, 'VanillaSha\s*=\s*"([0-9A-Fa-f]{64})"').Groups[1].Value
        pck_size   = [regex]::Match($cs, 'VanillaSize\s*=\s*(\d+)L').Groups[1].Value
    }
    git               = $git
    toolchain         = [ordered]@{
        csc      = [ordered]@{ path = $csc; file_version = (Get-Item $csc).VersionInfo.FileVersion; sha256 = Get-FileSha256 $csc; signer = $cscSigner }
        gdre     = $stamp.gdre
        bytecode = $stamp.bytecode
    }
    sources           = [ordered]@{
        installer_cs_sha256 = Get-FileSha256 $src
        patches             = Get-TreeHashes -Root (Join-Path $root "patches") -Extension ".patch"
    }
    payload           = [ordered]@{
        resources       = $payload
        manifest_sha256 = $expectRes["mp8.manifest"]
        version_sha256  = $expectRes["mp8.version"]
    }
    outputs           = $outputs
}
Write-JsonFile -Path (Join-Path $outDir "BUILDINFO.json") -Data $buildInfo

# ── Release package. One zip holding only the launcher + README ────────────────────────
# Decided by the user on 2026-08-18. **Players should only ever see one program**.
# The console build is still compiled (for troubleshooting, scripted installs, and people building from source),
# but it **stays out of the release package** — two exes side by side only leave players wondering which one to click.
$zipName = "Machine-Party-Overtime-$instRev.zip"
$zip     = Join-Path $outDir $zipName
$stage   = Join-Path $env:TEMP ("ot_zip_stage_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $outDir "overtime_launcher.exe") $stage -Force
Copy-Item (Join-Path $outDir "README.md")             $stage -Force
Copy-Item (Join-Path $outDir "BUILDINFO.json")        $stage -Force
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -Force
Remove-Item $stage -Recurse -Force
Write-Host ("      Release package {0}  {1:N0} bytes" -f $zipName, (Get-Item $zip).Length)

# Checksums to publish alongside the release (same format as the README's list)
$sums = foreach ($f in @($zipName, "overtime_launcher.exe", "overtime_install.exe", "BUILDINFO.json")) {
    "{0}  {1}" -f (Get-FileSha256 (Join-Path $outDir $f)), $f
}
[System.IO.File]::WriteAllText((Join-Path $outDir "SHA256SUMS.txt"), (($sums -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

# ── Self-check. Game assets must never sneak in ────────────────────────────────────────
$bad = Get-ChildItem $outDir -Recurse -File | Where-Object { $_.Extension -notin @(".exe", ".md", ".zip", ".json", ".txt") }
if ($bad) {
    foreach ($b in $bad) { Write-Host "    Unexpected file: $($b.Name)" -ForegroundColor Red }
    throw "The release folder contains files that shouldn't ship"
}
foreach ($e in $built) {
    $sz = (Get-Item $e).Length
    if ($sz -gt 5MB) {
        throw ("{0} is {1:N0} bytes, over 5 MB — game assets probably got mixed in, stop and check" -f (Split-Path -Leaf $e), $sz)
    }
}

Write-Host "[4/4] Self-check passed"
Write-Host ""
Write-Host "Done: $outDir" -ForegroundColor Green
foreach ($e in $built) {
    $sz = (Get-Item $e).Length
    Write-Host ("      {0,-18} {1,10:N0} bytes ({2:N0} KB)" -f (Split-Path -Leaf $e), $sz, ($sz / 1KB)) -ForegroundColor Green
}
Write-Host ("      {0} patches embedded, no external dependencies" -f $i) -ForegroundColor Green
Write-Host ""
Write-Host ("      Players only get {0} (launcher + README + BUILDINFO.json)" -f $zipName) -ForegroundColor Green
Write-Host "      Publish SHA256SUMS.txt with the release. Anyone can check an exe with tools\verify_exe.ps1" -ForegroundColor Green
Write-Host "      overtime_install.exe is the command line build, for troubleshooting only, **not shipped**" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Make it clear to friends: they need their own legitimate copy, and everyone playing together must install the same version." -ForegroundColor Yellow
