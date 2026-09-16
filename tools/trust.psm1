# Overtime build trust helpers
#
# Hashing, publisher checks, pinned tool hashes, patch vetting, build stamps and read-only
# inspection of built executables. Nothing in this module ever runs a built exe. Exe files are
# only read as data.
#
# Needs Windows PowerShell 5.1 (powershell.exe), which is what every tools\*.ps1 script runs under.

Set-StrictMode -Version 2.0

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# -- Hashing and JSON ------------------------------------------------------

function Get-FileSha256 {
	param([Parameter(Mandatory = $true)] [string] $Path)
	(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-BytesSha256 {
	param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [byte[]] $Bytes)
	$sha = [System.Security.Cryptography.SHA256]::Create()
	try { ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "") }
	finally { $sha.Dispose() }
}

function Write-JsonFile {
	param([Parameter(Mandatory = $true)] [string] $Path, [Parameter(Mandatory = $true)] $Data)
	$json = ConvertTo-Json -InputObject $Data -Depth 12
	[System.IO.File]::WriteAllText($Path, $json + "`n", $script:Utf8NoBom)
}

function Read-JsonFile {
	param([Parameter(Mandatory = $true)] [string] $Path)
	if (-not (Test-Path -LiteralPath $Path)) { throw "Missing $Path" }
	[System.IO.File]::ReadAllText($Path, $script:Utf8NoBom) | ConvertFrom-Json
}

# SHA256 of every file under Root with the given extension, keyed by forward-slash relative path.
# Keys are sorted ordinally so the same tree always produces the same JSON.
function Get-TreeHashes {
	param([Parameter(Mandatory = $true)] [string] $Root, [Parameter(Mandatory = $true)] [string] $Extension)
	$rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
	$byRel = @{}
	foreach ($f in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File)) {
		if ($f.Extension -ne $Extension) { continue }
		$byRel[$f.FullName.Substring($rootFull.Length + 1).Replace('\', '/')] = $f.FullName
	}
	$keys = [string[]]@($byRel.Keys)
	[Array]::Sort($keys, [StringComparer]::Ordinal)
	$map = [ordered]@{}
	foreach ($k in $keys) { $map[$k] = Get-FileSha256 $byRel[$k] }
	$map
}

# Turns the PSCustomObject that ConvertFrom-Json returns back into a plain lookup table
function ConvertTo-Lookup {
	param($Object)
	$t = @{}
	if ($null -ne $Object) {
		foreach ($p in $Object.PSObject.Properties) { $t[$p.Name] = $p.Value }
	}
	$t
}

# -- Tool identity ---------------------------------------------------------

function Get-SignerInfo {
	param([Parameter(Mandatory = $true)] [string] $Path)
	$sig = Get-AuthenticodeSignature -LiteralPath $Path
	$subject = ""
	$thumb = ""
	if ($null -ne $sig.SignerCertificate) {
		$subject = $sig.SignerCertificate.Subject
		$thumb = $sig.SignerCertificate.Thumbprint
	}
	[ordered]@{
		status     = [string]$sig.Status
		type       = [string]$sig.SignatureType
		subject    = $subject
		thumbprint = $thumb
	}
}

# Throws unless Windows reports a valid signature whose subject matches the expected publisher
function Confirm-SignedBy {
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [string] $SubjectPattern,
		[Parameter(Mandatory = $true)] [string] $Label
	)
	$info = Get-SignerInfo $Path
	if ($info.status -ne "Valid" -or $info.subject -notmatch $SubjectPattern) {
		throw "$Label at $Path isn't validly signed by the expected publisher (status $($info.status), signer '$($info.subject)')"
	}
	$info
}

# Throws unless the file matches the SHA256 recorded in PinFile. A missing pin explains how to create one.
function Confirm-PinnedHash {
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [string] $PinFile,
		[Parameter(Mandatory = $true)] [string] $Label
	)
	$actual = Get-FileSha256 $Path
	if (-not (Test-Path -LiteralPath $PinFile)) {
		throw @"
$Label has no pinned hash yet ($PinFile).
Its SHA256 right now is
    $actual
Only pin it if you downloaded it yourself from the official release page. Then run
    Set-Content -Encoding ASCII -LiteralPath "$PinFile" -Value $actual
and commit the pin file. See docs\VERIFYING.md.
"@
	}
	$expected = @((Get-Content -LiteralPath $PinFile -Raw) -split '\s+' | Where-Object { $_ -match '^[0-9A-Fa-f]{64}$' })
	if ($expected.Count -eq 0) { throw "$PinFile doesn't contain a SHA256 hash" }
	if ($expected[0].ToUpperInvariant() -ne $actual) {
		throw "$Label doesn't match its pinned hash. Pinned $($expected[0].ToUpperInvariant()), found $actual at $Path"
	}
	$actual
}

function Get-GitProvenance {
	param([Parameter(Mandatory = $true)] [string] $Root)
	$ErrorActionPreference = "Continue"
	$git = Get-Command git -ErrorAction SilentlyContinue
	if ($null -eq $git) { return [ordered]@{ available = $false } }
	$commit = [string](& git -C $Root rev-parse HEAD 2>$null)
	# Untracked files count too, because apply_patches.ps1 picks up every .patch under patches\
	$changes = @(& git -C $Root status --porcelain=v1 --untracked-files=all -- patches installer tools mpml 2>$null)
	[ordered]@{
		available     = $true
		commit        = $commit.Trim()
		dirty         = ($changes.Count -gt 0)
		changed_paths = @($changes | ForEach-Object { ([string]$_).Substring(3) })
		git_version   = ([string](& git --version 2>$null)).Trim()
		git_path      = $git.Source
		git_signer    = Get-SignerInfo $git.Source
	}
}

# -- Patch vetting ---------------------------------------------------------

# Throws unless the patch is a plain text edit of exactly one file, the one its own name says.
# git apply supports creating, deleting, renaming, symlinking and binary-patching files. None of
# those have any business in this repo, so a patch that tries them is rejected before git sees it.
function Confirm-SafePatch {
	param(
		[Parameter(Mandatory = $true)] [string] $PatchPath,
		[Parameter(Mandatory = $true)] [string] $Target
	)
	if ($Target -match '(^|/)\.\.(/|$)' -or $Target -match '^[A-Za-z]:' -or $Target.StartsWith('/') -or $Target.Contains('\')) {
		throw "Unsafe patch target path '$Target' for $PatchPath"
	}
	$text = [System.IO.File]::ReadAllText($PatchPath, $script:Utf8NoBom)
	if ($text.Contains("`r")) { throw "$PatchPath contains CR characters. Patches must be LF only" }
	$lines = $text -split "`n"
	$seen = @{ diff = 0; old = 0; new = 0 }
	$inBody = $false
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$l = $lines[$i]
		if (-not $inBody) {
			if ($l.StartsWith("@@ ")) { $inBody = $true; continue }
			if ($l -eq "diff --git a/$Target b/$Target") { $seen.diff++; continue }
			if ($l -eq "--- a/$Target") { $seen.old++; continue }
			if ($l -eq "+++ b/$Target") { $seen.new++; continue }
			if ($l -match '^index [0-9a-f]{7,64}\.\.[0-9a-f]{7,64}( 100644)?$') { continue }
			throw "$PatchPath line $($i + 1) is not an allowed header for $Target -> $l"
		}
		if ($l.Length -eq 0) { continue }
		$c = $l[0]
		if ($c -eq ' ' -or $c -eq '+' -or $c -eq '-' -or $c -eq '\') { continue }
		if ($l.StartsWith("@@ ")) { continue }
		throw "$PatchPath line $($i + 1) is not part of a hunk -> $l"
	}
	if ($seen.diff -ne 1 -or $seen.old -ne 1 -or $seen.new -ne 1 -or -not $inBody) {
		throw "$PatchPath must hold exactly one diff for $Target (diff=$($seen.diff) ---=$($seen.old) +++=$($seen.new))"
	}
}

# -- Read-only exe inspection ----------------------------------------------

function Confirm-DesktopPowerShell {
	if ($PSVersionTable.PSEdition -ne "Desktop") {
		throw "This needs Windows PowerShell 5.1 (powershell.exe). PowerShell 7 can't do reflection-only loads."
	}
}

# Lists an exe's embedded .NET resources with their size and SHA256, and optionally their bytes.
#
# The exe is loaded reflection-only from a byte array inside a separate PowerShell process. The
# runtime parses its metadata, but reflection-only assemblies can't execute code, and nothing from the
# exe stays loaded in this session.
function Get-EmbeddedResources {
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[string[]] $WithContent = @()
	)
	Confirm-DesktopPowerShell
	$full = (Resolve-Path -LiteralPath $Path).Path
	$job = Start-Job -ArgumentList $full, $WithContent -ScriptBlock {
		param($exePath, $wanted)
		$ErrorActionPreference = "Stop"
		$asm = [System.Reflection.Assembly]::ReflectionOnlyLoad([System.IO.File]::ReadAllBytes($exePath))
		if (-not $asm.ReflectionOnly) { throw "Refusing to continue, assembly was not loaded reflection-only" }
		$sha = [System.Security.Cryptography.SHA256]::Create()
		foreach ($name in $asm.GetManifestResourceNames()) {
			$s = $asm.GetManifestResourceStream($name)
			$ms = New-Object System.IO.MemoryStream
			$s.CopyTo($ms)
			$s.Dispose()
			$bytes = $ms.ToArray()
			$b64 = ""
			if ($wanted -contains $name) { $b64 = [Convert]::ToBase64String($bytes) }
			New-Object psobject -Property @{
				name   = $name
				size   = $bytes.Length
				sha256 = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
				base64 = $b64
			}
		}
	}
	try { $items = @(Receive-Job -Job $job -Wait -ErrorAction Stop) }
	finally { Remove-Job -Job $job -Force }
	$map = @{}
	foreach ($it in $items) {
		$map[[string]$it.name] = [ordered]@{
			size    = [int]$it.size
			sha256  = [string]$it.sha256
			content = $(if ($it.base64) { [Convert]::FromBase64String([string]$it.base64) } else { $null })
		}
	}
	$map
}

function Clear-ByteRange {
	param([byte[]] $Bytes, [long] $Offset, [long] $Count)
	if ($Offset -lt 0 -or $Count -lt 0 -or $Offset + $Count -gt $Bytes.Length) { throw "PE field outside the file" }
	[Array]::Clear($Bytes, [int]$Offset, [int]$Count)
}

function ConvertTo-FileOffset {
	param([byte[]] $Bytes, [int] $SectionTable, [int] $SectionCount, [uint32] $Rva)
	for ($s = 0; $s -lt $SectionCount; $s++) {
		$h = $SectionTable + 40 * $s
		$vsize = [BitConverter]::ToUInt32($Bytes, $h + 8)
		$va = [BitConverter]::ToUInt32($Bytes, $h + 12)
		$rawSize = [BitConverter]::ToUInt32($Bytes, $h + 16)
		$rawPtr = [BitConverter]::ToUInt32($Bytes, $h + 20)
		$span = [Math]::Max($vsize, $rawSize)
		if ($Rva -ge $va -and $Rva -lt $va + $span) { return [long]($Rva - $va + $rawPtr) }
	}
	throw ("RVA 0x{0:X} isn't inside any section" -f $Rva)
}

# SHA256 of a .NET PE file with its build-specific noise blanked out, so two compiles of identical
# inputs can be compared. Cleared fields are the COFF timestamp, the PE checksum, debug directory
# timestamps and payloads, the metadata #GUID heap (the random module version id), and any
# Authenticode certificate table, so a signed copy still compares equal to an unsigned build.
function Get-NormalizedPeSha256 {
	param([Parameter(Mandatory = $true)] [string] $Path)
	$b = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)
	if ($b.Length -lt 0x40) { throw "$Path is too small to be a PE file" }
	$pe = [BitConverter]::ToInt32($b, 0x3C)
	if ($pe -lt 0 -or $pe + 24 -gt $b.Length -or [BitConverter]::ToUInt32($b, $pe) -ne 0x00004550) { throw "$Path isn't a PE file" }
	$coff = $pe + 4
	$sectionCount = [BitConverter]::ToUInt16($b, $coff + 2)
	$optSize = [BitConverter]::ToUInt16($b, $coff + 16)
	$opt = $coff + 20
	$magic = [BitConverter]::ToUInt16($b, $opt)
	if ($magic -eq 0x10B) { $dirs = $opt + 96 } elseif ($magic -eq 0x20B) { $dirs = $opt + 112 } else { throw "$Path has an unknown PE optional header" }
	$sectionTable = $opt + $optSize

	Clear-ByteRange $b ($coff + 4) 4
	Clear-ByteRange $b ($opt + 64) 4

	$length = $b.Length
	$certOffset = [BitConverter]::ToUInt32($b, $dirs + 4 * 8)
	$certSize = [BitConverter]::ToUInt32($b, $dirs + 4 * 8 + 4)
	if ($certSize -gt 0) {
		if ([long]$certOffset + $certSize -ne $b.Length) { throw "$Path has a certificate table that isn't at the end of the file" }
		$length = [long]$certOffset
		Clear-ByteRange $b ($dirs + 4 * 8) 8
	}

	$dbgRva = [BitConverter]::ToUInt32($b, $dirs + 6 * 8)
	$dbgSize = [BitConverter]::ToUInt32($b, $dirs + 6 * 8 + 4)
	if ($dbgSize -gt 0) {
		$dbg = ConvertTo-FileOffset $b $sectionTable $sectionCount $dbgRva
		for ($e = 0; $e -lt [Math]::Floor($dbgSize / 28); $e++) {
			$entry = $dbg + 28 * $e
			Clear-ByteRange $b ($entry + 4) 4
			$dataSize = [BitConverter]::ToUInt32($b, $entry + 16)
			$dataPtr = [BitConverter]::ToUInt32($b, $entry + 24)
			if ($dataSize -gt 0 -and $dataPtr -gt 0) { Clear-ByteRange $b $dataPtr $dataSize }
		}
	}

	$clrRva = [BitConverter]::ToUInt32($b, $dirs + 14 * 8)
	if ($clrRva -eq 0) { throw "$Path isn't a .NET assembly" }
	$cli = ConvertTo-FileOffset $b $sectionTable $sectionCount $clrRva
	$md = ConvertTo-FileOffset $b $sectionTable $sectionCount ([BitConverter]::ToUInt32($b, $cli + 8))
	if ([BitConverter]::ToUInt32($b, $md) -ne 0x424A5342) { throw "$Path has no metadata root" }
	$p = $md + 16 + [BitConverter]::ToUInt32($b, $md + 12)
	$streams = [BitConverter]::ToUInt16($b, $p + 2)
	$p += 4
	$guidCleared = $false
	for ($s = 0; $s -lt $streams; $s++) {
		$off = [BitConverter]::ToUInt32($b, $p)
		$size = [BitConverter]::ToUInt32($b, $p + 4)
		$nameStart = $p + 8
		$end = [Array]::IndexOf($b, [byte]0, $nameStart)
		$name = [System.Text.Encoding]::ASCII.GetString($b, $nameStart, $end - $nameStart)
		if ($name -eq "#GUID") {
			Clear-ByteRange $b ($md + $off) $size
			$guidCleared = $true
		}
		$p = $nameStart + [int]([Math]::Ceiling(($end - $nameStart + 1) / 4.0) * 4)
	}
	if (-not $guidCleared) { throw "$Path has no #GUID metadata stream" }

	$sha = [System.Security.Cryptography.SHA256]::Create()
	try { ([BitConverter]::ToString($sha.ComputeHash($b, 0, [int]$length))).Replace("-", "") }
	finally { $sha.Dispose() }
}

Export-ModuleMember -Function Get-FileSha256, Get-BytesSha256, Write-JsonFile, Read-JsonFile, Get-TreeHashes,
	ConvertTo-Lookup, Get-SignerInfo, Confirm-SignedBy, Confirm-PinnedHash, Get-GitProvenance, Confirm-SafePatch,
	Get-EmbeddedResources, Get-NormalizedPeSha256
