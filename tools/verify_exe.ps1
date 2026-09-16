# Check an Overtime exe against a build record or against your own build, without ever running it
#
# Usage
#   powershell -ExecutionPolicy Bypass -File tools\verify_exe.ps1 -Exe <exe> -BuildInfo <BUILDINFO.json>
#   powershell -ExecutionPolicy Bypass -File tools\verify_exe.ps1 -Exe <exe> -Reference <exe you built yourself>
#   Add -Scripts <path> if overtime_scripts.dat isn't next to the exe
#
# It compares three things
#   - The file hash. Equal means the very same file.
#   - The normalized PE hash, which ignores compile timestamps, the random module id and any code signature.
#     Equal means the same compiled installer code.
#   - The game script payload. Current builds embed a manifest with every script's hash and keep the scripts in
#     overtime_scripts.dat next to the exe, which is checked against that manifest exactly as the launcher does.
#     Builds up to 1.7-en embedded every script as its own resource, and those are still checked one by one.
#
# The exe is only ever read as bytes. See Get-EmbeddedResources in trust.psm1 for how resources are read safely.
#
# Exit codes
#   0  identical, or same code and same payload
#   1  the game script payload differs, or the exe or its data file couldn't be read
#   2  same payload but different installer code (a different compiler can cause this, the code is NOT verified)

param(
	[Parameter(Mandatory = $true)] [string] $Exe,
	[string] $BuildInfo = "",
	[string] $Reference = "",
	[string] $Scripts = ""
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "trust.psm1") -Force

if (($BuildInfo -eq "") -eq ($Reference -eq "")) { throw "Pass exactly one of -BuildInfo or -Reference" }
if (-not (Test-Path -LiteralPath $Exe)) { throw "Cannot find $Exe" }

function Write-Row($label, $ok, $text) {
	$color = if ($ok) { "Green" } else { "Red" }
	Write-Host ("  {0,-22} " -f $label) -NoNewline
	Write-Host $text -ForegroundColor $color
}

try {
	$exeName = Split-Path -Leaf $Exe
	$actualSha = Get-FileSha256 $Exe
	$actualNorm = Get-NormalizedPeSha256 $Exe
	$actualRes = Get-EmbeddedResources -Path $Exe -WithContent @("mp8.version", "mp8.manifest")
} catch {
	Write-Host "Couldn't read $Exe as a .NET exe: $($_.Exception.Message)" -ForegroundColor Red
	exit 1
}

# A current build is only complete with its data file, so check that file against the exe's own manifest first
$usesScriptsFile = $false
$scriptCount = 0
$scriptsProblems = @()
$scriptsSha = ""
if ($actualRes.ContainsKey("mp8.manifest") -and $null -ne $actualRes["mp8.manifest"].content) {
	try { $parsed = ConvertFrom-ScriptsManifest -Bytes $actualRes["mp8.manifest"].content }
	catch {
		Write-Host "The manifest inside $Exe can't be read: $($_.Exception.Message)" -ForegroundColor Red
		exit 1
	}
	if (-not $parsed.legacy) {
		$usesScriptsFile = $true
		$scriptCount = @($parsed.entries).Count
		if ($Scripts -eq "") { $Scripts = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Exe).Path) "overtime_scripts.dat" }
		if (-not (Test-Path -LiteralPath $Scripts)) {
			Write-Host "$Exe keeps its game scripts in overtime_scripts.dat, and there's none at $Scripts." -ForegroundColor Red
			Write-Host "Pass the data file from the same release with -Scripts <path>." -ForegroundColor Red
			exit 1
		}
		$scriptsProblems = @(Test-ScriptsFile -Entries $parsed.entries -Path $Scripts)
		$scriptsSha = Get-FileSha256 $Scripts
	}
}

$expectRes = @{}
if ($Reference -ne "") {
	if (-not (Test-Path -LiteralPath $Reference)) { throw "Cannot find $Reference" }
	$source = "reference exe $Reference"
	$expectSha = Get-FileSha256 $Reference
	$expectNorm = Get-NormalizedPeSha256 $Reference
	# The manifest holds every script's hash, so matching resources plus a data file that satisfies the manifest means the same scripts
	$refRes = Get-EmbeddedResources -Path $Reference
	foreach ($k in $refRes.Keys) { $expectRes[$k] = $refRes[$k].sha256 }
	$compilerNote = ""
} else {
	$info = Read-JsonFile $BuildInfo
	if ($info.schema -ne 1 -and $info.schema -ne 2) { throw "$BuildInfo uses schema $($info.schema), this script understands schemas 1 and 2" }
	$outputs = ConvertTo-Lookup $info.outputs
	# Match by file name first. A renamed file is matched by its code instead, falling back to the launcher.
	$entryName = $exeName
	if (-not $outputs.ContainsKey($entryName)) {
		$entryName = "overtime_launcher.exe"
		foreach ($k in $outputs.Keys) { if ($outputs[$k].normalized_sha256 -eq $actualNorm) { $entryName = $k } }
	}
	if (-not $outputs.ContainsKey($entryName)) { throw "$BuildInfo has no entry for $exeName" }
	$entry = $outputs[$entryName]
	$source = "$BuildInfo ($entryName, mod $($info.mod_version), commit $($info.git.commit))"
	$expectSha = $entry.sha256
	$expectNorm = $entry.normalized_sha256
	if ($info.schema -eq 1) {
		foreach ($r in @($info.payload.resources)) { $expectRes[[string]$r.resource] = [string]$r.sha256 }
	} elseif ($usesScriptsFile -and $scriptsSha -ne [string]$info.payload.scripts_file.sha256) {
		$scriptsProblems += "overtime_scripts.dat isn't the file in the build record"
	}
	$expectRes["mp8.manifest"] = [string]$info.payload.manifest_sha256
	$expectRes["mp8.version"] = [string]$info.payload.version_sha256
	$compilerNote = "csc $($info.toolchain.csc.file_version)"
	if ($info.dev_tools -eq $true) {
		Write-Host "WARNING. This build record says developer tools were ON (MP8_DEV_TOOLS). Such a build must never be given to players." -ForegroundColor Red
	}
}

$resProblems = @()
foreach ($k in $expectRes.Keys) {
	if (-not $actualRes.ContainsKey($k)) { $resProblems += "$k is missing" }
	elseif ($actualRes[$k].sha256 -ne $expectRes[$k]) { $resProblems += "$k differs" }
}
foreach ($k in $actualRes.Keys) {
	if (-not $expectRes.ContainsKey($k)) { $resProblems += "$k is unexpected" }
}
$exeResProblemCount = $resProblems.Count
$resProblems += $scriptsProblems

$identical = ($actualSha -eq $expectSha)
$sameCode = ($actualNorm -eq $expectNorm)
$samePayload = ($resProblems.Count -eq 0)

$version = "(none)"
if ($actualRes.ContainsKey("mp8.version") -and $null -ne $actualRes["mp8.version"].content) {
	$version = [System.Text.Encoding]::UTF8.GetString($actualRes["mp8.version"].content)
}
$sig = Get-SignerInfo $Exe
$payloadText = if ($usesScriptsFile) { "manifest matches, overtime_scripts.dat holds all $scriptCount scripts" } else { "all $($expectRes.Count) embedded resources match" }

Write-Host ""
Write-Host "Checking $Exe"
if ($usesScriptsFile) { Write-Host "With     $Scripts" }
Write-Host "Against  $source"
Write-Host ""
Write-Host ("  {0,-22} {1}" -f "Embedded mod version", $version)
Write-Host ("  {0,-22} {1} {2}" -f "Code signature", $sig.status, $sig.subject)
Write-Row "Identical file" $identical $(if ($identical) { "yes" } else { "no (expected when builds happen at different times)" })
Write-Row "Installer code" $sameCode $(if ($sameCode) { "matches" } else { "DIFFERS" })
Write-Row "Game script payload" $samePayload $(if ($samePayload) { $payloadText } else { "$($resProblems.Count) problem(s)" })
foreach ($x in $resProblems | Select-Object -First 20) { Write-Host "      $x" -ForegroundColor Red }
Write-Host ""

# The payload is checked first. A file hash match can't vouch for a record whose payload list disagrees with it.
if (-not $samePayload) {
	if ($identical -and $exeResProblemCount -gt 0) {
		Write-Host "INCONSISTENT RECORD. The file matches the recorded hash but not the recorded payload. Don't trust this record or this exe." -ForegroundColor Red
	} elseif ($identical) {
		Write-Host "MISMATCH. The exe is the recorded one, but overtime_scripts.dat isn't. Don't use this data file." -ForegroundColor Red
	} else {
		Write-Host "MISMATCH. The game scripts are not the ones described. Don't run this exe." -ForegroundColor Red
	}
	exit 1
}
if ($identical) {
	Write-Host "IDENTICAL. This is the exact file described." -ForegroundColor Green
	exit 0
}
if ($sameCode) {
	Write-Host "MATCH. Same installer code and same game scripts. Only build timestamps and ids differ." -ForegroundColor Green
	exit 0
}
Write-Host "PAYLOAD ONLY. The game scripts match, but the installer program itself differs." -ForegroundColor Yellow
Write-Host "A different csc.exe version can cause this. $compilerNote" -ForegroundColor Yellow
Write-Host "The installer code is NOT verified. Build it yourself from the same commit to compare." -ForegroundColor Yellow
exit 2
