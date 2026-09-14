<#
.SYNOPSIS
    Makes the Copy Signature entry of GH SigMaker v2.0 put nothing but the
    wildcard array of bytes on the clipboard.

.DESCRIPTION
    GH SigMaker copies three lines. An address line, the escaped byte string
    with its mask, and the wildcard pattern. This script changes twelve bytes
    in your own copy of GH-CE-SigMaker.dll so that only the wildcard pattern
    is copied, for example

        48 8B ? ? ? 66 C1 E8 ? 66 8B

    The script carries no part of the plugin. It knows the SHA-256 of the
    unmodified v2.0 build and of the patched result, and it only touches a
    file whose hash is one of those two. Anything else is left alone.

    Without a path it reads the plugin list Cheat Engine stores in the
    registry, which holds every plugin added under Settings and Plugins. It
    also looks in the plugins and autorun\plugins folders of every Cheat
    Engine installation under Program Files, if they exist. A copy anywhere
    else has to be passed as a path.

    Before the first patch the untouched file is saved next to it as
    GH-CE-SigMaker.dll.original. Restore does not need that copy though. The
    original bytes are known, so they are simply written back.

    Cheat Engine has to be closed while the file is changed. A plugin that is
    loaded cannot be written to.

    This is an unofficial patch. It is not made, endorsed or supported by
    Guided Hacking.

.PARAMETER Path
    One or more DLL files or folders. A folder is searched for DLLs that match
    a known build. Leave it out to search the usual places.

.PARAMETER Restore
    Turns a patched file back into the original v2.0 build.

.PARAMETER Check
    Only reports what was found. Nothing is written. Wins over Restore.

.PARAMETER NoBackup
    Skips the .original copy before patching.

.PARAMETER NoElevate
    Does not ask for administrator rights when a file cannot be written.

.PARAMETER PauseAtEnd
    Waits for a key before the window closes, so the result can be read. It
    only waits when the window belongs to this run, as after a double click,
    a drop or the elevated relaunch. The .cmd launcher passes this.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\GH-SigMaker-Patch.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\GH-SigMaker-Patch.ps1 -Check

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\GH-SigMaker-Patch.ps1 "D:\CE Plugins\GH-CE-SigMaker.dll"

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\GH-SigMaker-Patch.ps1 -Restore
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Path,
    [switch] $Restore,
    [switch] $Check,
    [switch] $NoBackup,
    [switch] $NoElevate,
    [switch] $PauseAtEnd
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.3.0'
$DllName = 'GH-CE-SigMaker.dll'
$FileLength = 36864

# The whole file is compared, not just the bytes that change. A build that
# differs anywhere else might lay its code out differently, and then the same
# offsets would land in the middle of something unrelated.
$OriginalSha256 = 'A357E57BAAD6846A1B25A8514441147F2685A3771AD64F6E6455188E9957C99A'
$PatchedSha256 = '8706CC979A690D8B6ECF3FD9FE3A5D220DC2459F87D8F43346AD4A89D0EA4674'

# The plugin builds its output in two string streams inside one function.
# The first holds the escaped bytes, the mask, a line break and then the
# wildcard pattern. The second holds the address line and then the first
# stream wrapped in quotes. The second one is what lands on the clipboard.
#
# The first two edits turn the start of each stream into a jump over the parts
# that are not wanted. The last two leave the quote calls in place and point
# them at an empty string instead. Only the lowest byte of each of those two
# displacements changes. Nothing is inserted or moved, so every address in the
# file stays valid.
$Edits = @(
    @{
        Offset   = 0x0ACC
        Original = [byte[]](0x45, 0x8B, 0xE5, 0x4C, 0x39)
        Patched  = [byte[]](0xE9, 0xE1, 0x00, 0x00, 0x00)
        What     = 'jump over the escaped bytes and the mask'
    },
    @{
        Offset   = 0x0D50
        Original = [byte[]](0x48, 0x8D, 0x4D, 0xF0, 0x48)
        Patched  = [byte[]](0xE9, 0xB7, 0x00, 0x00, 0x00)
        What     = 'jump over the address line'
    },
    @{
        Offset   = 0x0E22
        Original = [byte[]](0xC2)
        Patched  = [byte[]](0xBD)
        What     = 'opening quote becomes an empty string'
    },
    @{
        Offset   = 0x0E40
        Original = [byte[]](0xA4)
        Patched  = [byte[]](0x9F)
        What     = 'closing quote becomes an empty string'
    }
)

$script:Failures = 0
$script:ResolvedForElevation = @()

function Write-Line {
    param([string] $Tag, [string] $Text, [ConsoleColor] $Color = 'Gray')
    $label = if ($Tag) { "[$Tag]" } else { '' }
    Write-Host ('  {0,-11}' -f $label) -ForegroundColor $Color -NoNewline
    Write-Host " $Text"
}

function Get-Sha256Hex {
    param([byte[]] $Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function Get-State {
    param([byte[]] $Bytes)
    if ($Bytes.Length -ne $FileLength) { return 'Unknown' }
    $hash = Get-Sha256Hex $Bytes
    if ($hash -eq $OriginalSha256) { return 'Original' }
    if ($hash -eq $PatchedSha256) { return 'Patched' }
    return 'Unknown'
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# PowerShell wraps exceptions from .NET calls. The interesting one is at the
# bottom of the chain.
function Get-InnerException {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($exception.InnerException) { $exception = $exception.InnerException }
    return $exception
}

# Cheat Engine lists every plugin the user ever added here, not only this
# one. Only a file that could be GH SigMaker is kept, going by its name or its
# exact length. An entry whose file is gone is skipped quietly.
function Get-RegistryPluginPaths {
    $found = @()
    foreach ($keyName in 'Plugins64', 'Plugins') {
        $keyPath = "HKCU:\Software\Cheat Engine\$keyName"
        if (-not (Test-Path -LiteralPath $keyPath)) { continue }
        $key = Get-Item -LiteralPath $keyPath
        foreach ($valueName in $key.GetValueNames()) {
            # Cheat Engine writes one pair per plugin. The value ending in A
            # holds the path and the one ending in B says whether it is on.
            if ($valueName -notmatch ' A$') { continue }
            $value = [string] $key.GetValue($valueName)
            if (-not $value) { continue }
            try {
                if (-not (Test-Path -LiteralPath $value -PathType Leaf)) { continue }
                $file = Get-Item -LiteralPath $value -Force
            }
            catch {
                continue
            }
            if ($file.Name -ieq $DllName -or $file.Length -eq $FileLength) { $found += $file.FullName }
        }
    }
    return $found
}

function Get-DefaultCandidates {
    $candidates = @(Get-RegistryPluginPaths)
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) |
        Where-Object { $_ } | Select-Object -Unique
    foreach ($root in $roots) {
        $installs = Get-ChildItem -LiteralPath $root -Directory -Filter 'Cheat Engine*' -ErrorAction SilentlyContinue
        foreach ($install in $installs) {
            # Cheat Engine itself does not load plugins from a folder. These are
            # just the two places people tend to put them.
            foreach ($sub in 'plugins', 'autorun\plugins') {
                $folder = Join-Path $install.FullName $sub
                if (Test-Path -LiteralPath $folder -PathType Container) { $candidates += $folder }
            }
        }
    }
    return $candidates
}

function New-Target {
    param([string] $TargetPath, [bool] $Explicit, [bool] $Missing = $false, [string] $Reason = $null)
    return [pscustomobject]@{ Path = $TargetPath; Explicit = $Explicit; Missing = $Missing; Reason = $Reason }
}

# Expands the given paths into DLL files. A file the user named is always
# reported, even when it turns out not to be a known build. Inside a folder,
# and for anything found on its own, only a file with the plugin name or with
# the exact length of the build is looked at. So an unrelated DLL does not
# show up as unknown.
function Resolve-Targets {
    param([string[]] $Inputs, [switch] $Discovered)
    $seen = @{}
    $targets = @()
    foreach ($item in $Inputs) {
        if (-not $item) { continue }
        $trimmed = $item.Trim().Trim('"')
        if (-not $trimmed) { continue }
        try {
            if ($trimmed.Contains('"')) {
                throw 'A quoted folder that ends in a backslash swallows everything after it. Leave out the trailing backslash.'
            }
            if ($trimmed.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) {
                throw 'This contains characters a path cannot hold.'
            }
            if (Test-Path -LiteralPath $trimmed -PathType Leaf) {
                $file = Get-Item -LiteralPath $trimmed -Force
                $key = $file.FullName.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { continue }
                $named = $file.Name -ieq $DllName
                if ($Discovered -and -not $named -and $file.Length -ne $FileLength) { continue }
                $seen[$key] = $true
                $targets += New-Target $file.FullName ($named -or -not $Discovered)
            }
            elseif (Test-Path -LiteralPath $trimmed -PathType Container) {
                # A folder the user named has to be readable and has to hold a
                # candidate. Otherwise the run would quietly go on without it.
                $listing = if ($Discovered) { 'SilentlyContinue' } else { 'Stop' }
                try {
                    $files = @(Get-ChildItem -LiteralPath $trimmed -File -Force -Filter '*.dll' -ErrorAction $listing |
                        Where-Object { $_.Name -ieq $DllName -or $_.Length -eq $FileLength })
                }
                catch [UnauthorizedAccessException] {
                    throw "This folder cannot be listed. Name the $DllName inside it instead, or check the folder permissions."
                }
                if ($files.Count -eq 0 -and -not $Discovered) {
                    throw "This folder holds no $DllName."
                }
                foreach ($file in $files) {
                    $key = $file.FullName.ToLowerInvariant()
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    $targets += New-Target $file.FullName ($file.Name -ieq $DllName)
                }
            }
            elseif (-not $Discovered) {
                $targets += New-Target $trimmed $true $true
            }
        }
        catch {
            if (-not $Discovered) {
                $targets += New-Target $trimmed $true $true (Get-InnerException $_).Message
            }
        }
    }
    return $targets
}

function Read-Shared {
    param([string] $FilePath)
    $stream = New-Object IO.FileStream($FilePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $buffer = New-Object byte[] $stream.Length
        $read = 0
        while ($read -lt $buffer.Length) {
            $count = $stream.Read($buffer, $read, $buffer.Length - $read)
            if ($count -le 0) { break }
            $read += $count
        }
        return , $buffer
    }
    finally {
        $stream.Dispose()
    }
}

# A file with the temporary backup name can only be left over from an earlier
# run, so it goes. A folder of that name, or a file that will not go away,
# blocks the name and the caller moves on to the next number.
function Remove-LeftoverPartial {
    param([string] $PartialPath)
    if (Test-Path -LiteralPath $PartialPath -PathType Container) { return $false }
    if (Test-Path -LiteralPath $PartialPath -PathType Leaf) {
        try { Remove-Item -LiteralPath $PartialPath -Force } catch { return $false }
    }
    return $true
}

function Save-Backup {
    param([string] $FilePath, [byte[]] $Bytes)
    $backup = "$FilePath.original"
    $number = 1
    while ((Test-Path -LiteralPath $backup) -or -not (Remove-LeftoverPartial "$backup.partial")) {
        # A copy that already holds the original build is exactly what we
        # would write, so it is kept and nothing new is made. A folder, a
        # different file or one that cannot be read is never touched.
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            $existing = $null
            try { $existing = Read-Shared $backup } catch { }
            if ($null -ne $existing -and (Get-State $existing) -eq 'Original') { return $backup }
        }
        $backup = "$FilePath.original.$number"
        $number++
    }
    # Written under a temporary name first. A backup that was cut short by a
    # full disk must never sit there looking like the real one.
    $partial = "$backup.partial"
    [IO.File]::WriteAllBytes($partial, $Bytes)
    if ((Get-State (Read-Shared $partial)) -ne 'Original') {
        Remove-Item -LiteralPath $partial -Force
        throw 'It did not read back as the original build.'
    }
    Move-Item -LiteralPath $partial -Destination $backup
    return $backup
}

# Changes one file from one known build into the other. The file is opened
# once with nobody else allowed in, read, checked, written and read back
# through that same handle. So nothing can swap the file between the check
# and the write, and a plugin Cheat Engine has loaded refuses to open at all.
function Convert-Dll {
    param([string] $FilePath, [string] $From, [string] $To, [bool] $Backup)

    $stream = New-Object IO.FileStream($FilePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        if ($stream.Length -ne $FileLength) { return 'Unknown' }
        $buffer = New-Object byte[] $FileLength
        $read = 0
        while ($read -lt $FileLength) {
            $count = $stream.Read($buffer, $read, $FileLength - $read)
            if ($count -le 0) { break }
            $read += $count
        }
        $state = Get-State $buffer
        if ($state -eq $To) { return 'Already' }
        if ($state -ne $From) { return $state }

        # The hash already vouches for these bytes. Checking them again costs
        # nothing and keeps a mistake in the table above from writing blind.
        foreach ($edit in $Edits) {
            for ($i = 0; $i -lt $edit[$From].Length; $i++) {
                if ($buffer[$edit.Offset + $i] -ne $edit[$From][$i]) {
                    throw ('Offset 0x{0:X5} does not hold the expected bytes.' -f $edit.Offset)
                }
            }
        }

        # Build the result in memory first and only write it when it hashes to
        # exactly the build we expect.
        $result = [byte[]] $buffer.Clone()
        foreach ($edit in $Edits) {
            [Array]::Copy($edit[$To], 0, $result, $edit.Offset, $edit[$To].Length)
        }
        $expected = if ($To -eq 'Original') { $OriginalSha256 } else { $PatchedSha256 }
        if ((Get-Sha256Hex $result) -ne $expected) {
            throw 'The edited bytes do not produce the expected build. Nothing was written.'
        }

        $backupPath = $null
        if ($Backup) {
            # Whatever goes wrong here is about the backup and not about the
            # DLL. A folder that only administrators may add files to is the
            # one case where elevation helps. That failure keeps its type and
            # is marked as a backup problem for the main loop.
            try {
                $backupPath = Save-Backup $FilePath $buffer
            }
            catch {
                $inner = Get-InnerException $_
                if ($inner -is [UnauthorizedAccessException]) {
                    $denied = New-Object UnauthorizedAccessException 'The backup next to it cannot be created in this folder.'
                    $denied.Data['Backup'] = $true
                    throw $denied
                }
                throw "The backup next to it could not be written. $($inner.Message) Nothing was changed. Run it again with -NoBackup to patch without a copy."
            }
        }

        foreach ($edit in $Edits) {
            $stream.Position = $edit.Offset
            $stream.Write($edit[$To], 0, $edit[$To].Length)
        }
        $stream.Flush($true)

        $stream.Position = 0
        $check = New-Object byte[] $FileLength
        $read = 0
        while ($read -lt $FileLength) {
            $count = $stream.Read($check, $read, $FileLength - $read)
            if ($count -le 0) { break }
            $read += $count
        }
        if ((Get-Sha256Hex $check) -ne $expected) {
            throw 'The file does not read back as the expected build after writing.'
        }
        if ($backupPath) { return "Done|$backupPath" }
        return 'Done'
    }
    finally {
        $stream.Dispose()
    }
}

# After a double click, a drop or the elevated relaunch the console belongs to
# this run alone and closes with it. Started from an open console the window
# stays, and waiting for a key only gets in the way.
function Test-OwnConsole {
    try {
        if (-not ('GHSigMakerPatch.ConsoleInfo' -as [type])) {
            Add-Type -Namespace GHSigMakerPatch -Name ConsoleInfo -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] list, uint count);'
        }
        $list = New-Object uint32[] 16
        $count = [GHSigMakerPatch.ConsoleInfo]::GetConsoleProcessList($list, 16)
        if ($count -eq 1) { return $true }
        if ($count -ne 2) { return $false }
        # Two processes are this one and the cmd.exe running the launcher.
        # Explorer starts that cmd.exe with /c for a double click or a drop,
        # and the window closes with it. A cmd window someone typed into has
        # no /c and stays open.
        $self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($self.ParentProcessId)"
        if ($null -eq $parent -or $parent.Name -ne 'cmd.exe') { return $false }
        return ([string] $parent.CommandLine -match '^\s*(?:"[^"]*"|\S+)(?:\s+/[a-bd-jl-z]\S*)*\s+/c(?:\s|"|$)')
    }
    catch {
        return $true
    }
}

function Invoke-Elevated {
    $quote = [char] 34
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ($quote + $PSCommandPath + $quote))
    foreach ($item in $script:ResolvedForElevation) { $arguments += ($quote + $item + $quote) }
    if ($Restore) { $arguments += '-Restore' }
    if ($NoBackup) { $arguments += '-NoBackup' }
    $arguments += '-NoElevate'
    $arguments += '-PauseAtEnd'
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    return $process.ExitCode
}

# ---------------------------------------------------------------------------

Write-Host ''
Write-Host "GH SigMaker patch $ScriptVersion" -ForegroundColor White
if ($Check) { $action = 'check' } elseif ($Restore) { $action = 'restore' } else { $action = 'patch' }
Write-Host "Wildcard pattern only on Copy Signature. Mode $action." -ForegroundColor DarkGray
Write-Host ''

$exitCode = 0
$needsElevation = @()
$pathGiven = $PSBoundParameters.ContainsKey('Path')
$isAdmin = Test-Administrator
$wanted = if ($Restore) { 'Original' } else { 'Patched' }

try {
    if ($pathGiven) {
        # An empty argument must not quietly turn into a search of the real
        # installation when the caller meant one particular file.
        $given = @($Path | Where-Object { $_ -and $_.Trim().Trim('"') })
        if ($given.Count -eq 0) {
            throw 'The path is empty. Name the DLL or its folder, or leave the path out to search the usual places.'
        }
        $targets = @(Resolve-Targets $given)
    }
    else {
        $targets = @(Resolve-Targets (Get-DefaultCandidates) -Discovered)
    }

    # Every named path has to make sense before anything is written. A typo
    # like -Chek ends up here as a path, and carrying on would patch the rest
    # when the user asked for a dry run.
    $bad = @($targets | Where-Object { $_.Missing })
    if ($bad.Count -gt 0) {
        foreach ($entry in $bad) {
            if ($entry.Reason) { Write-Line 'bad path' "$($entry.Path)  $($entry.Reason)" Red }
            elseif ($entry.Path -match '^[-/]') { Write-Line 'unknown' "$($entry.Path)  is not a switch this script knows." Red }
            else { Write-Line 'missing' $entry.Path Red }
        }
        Write-Host ''
        Write-Host '  Nothing was changed.' -ForegroundColor DarkGray
        $script:Failures += $bad.Count
        $targets = @()
    }

    $known = 0
    foreach ($target in $targets) {
        try {
            $state = Get-State (Read-Shared $target.Path)
        }
        catch {
            Write-Line 'unreadable' "$($target.Path)  $((Get-InnerException $_).Message)" Red
            $script:Failures++
            continue
        }

        if ($state -eq 'Unknown') {
            if ($target.Explicit) {
                Write-Line 'unknown' "$($target.Path)  is not the v2.0 build this script knows. Left alone." Yellow
                $script:Failures++
            }
            continue
        }
        $known++

        if ($Check) {
            if ($state -eq 'Original') { Write-Line 'original' $target.Path Cyan }
            else { Write-Line 'patched' $target.Path Green }
            continue
        }

        if ($Restore) { $from = 'Patched'; $to = 'Original' } else { $from = 'Original'; $to = 'Patched' }

        # A file that is already right needs no write access at all. This keeps
        # a second run quiet under Program Files and with Cheat Engine open.
        if ($state -eq $to) {
            Write-Line $(if ($Restore) { 'original' } else { 'patched' }) "$($target.Path)  already, nothing to do." DarkGray
            continue
        }

        try {
            $outcome = Convert-Dll -FilePath $target.Path -From $from -To $to -Backup (-not $Restore -and -not $NoBackup)
        }
        catch {
            $inner = Get-InnerException $_
            $code = $inner.HResult -band 0xFFFF
            $readOnly = $false
            try { $readOnly = [bool] (Get-Item -LiteralPath $target.Path -Force).IsReadOnly } catch { }
            $backupProblem = $inner -is [UnauthorizedAccessException] -and $inner.Data.Contains('Backup')
            if ($backupProblem -and $isAdmin) {
                Write-Line 'no access' "$($target.Path)  $($inner.Message) Not even administrator rights help. Run it again with -NoBackup to patch without a copy." Red
            }
            elseif ($backupProblem) {
                Write-Line 'no access' "$($target.Path)  $($inner.Message) That needs administrator rights, or -NoBackup to patch without a copy." Red
                $needsElevation += $target.Path
            }
            elseif ($inner -is [UnauthorizedAccessException] -and $readOnly) {
                # Administrator rights do not help against this attribute.
                Write-Line 'read only' "$($target.Path)  has the read only attribute. Clear it in the file properties and run this again." Red
            }
            elseif ($inner -is [UnauthorizedAccessException] -and $isAdmin) {
                Write-Line 'no access' "$($target.Path)  cannot be written, not even with administrator rights." Red
            }
            elseif ($inner -is [UnauthorizedAccessException]) {
                Write-Line 'no access' "$($target.Path)  cannot be written without administrator rights." Red
                $needsElevation += $target.Path
            }
            elseif ($code -eq 32 -or $code -eq 33 -or $code -eq 1224) {
                Write-Line 'in use' "$($target.Path)  is in use, most likely loaded by Cheat Engine. Close it and run this again." Red
            }
            else {
                Write-Line 'failed' "$($target.Path)  $($inner.Message)" Red
            }
            $script:Failures++
            continue
        }

        switch -Wildcard ($outcome) {
            'Done|*' {
                Write-Line $(if ($Restore) { 'restored' } else { 'patched' }) $target.Path Green
                Write-Line '' "backup  $($outcome.Substring(5))" DarkGray
            }
            'Done' { Write-Line $(if ($Restore) { 'restored' } else { 'patched' }) $target.Path Green }
            'Already' {
                Write-Line $(if ($Restore) { 'original' } else { 'patched' }) "$($target.Path)  already, nothing to do." DarkGray
            }
            default {
                Write-Line 'changed' "$($target.Path)  changed while it was being read. Left alone." Yellow
                $script:Failures++
            }
        }
    }

    if ($known -eq 0 -and $script:Failures -eq 0) {
        Write-Line 'not found' "No $DllName v2.0 was found." Yellow
        if (-not $pathGiven) {
            Write-Host ''
            Write-Host '  Pass the DLL or its folder as an argument, or drop it onto the .cmd file.' -ForegroundColor DarkGray
        }
        $exitCode = 2
    }

    # Only a session without administrator rights ever fills this list.
    if ($needsElevation.Count -gt 0) {
        if ($NoElevate) {
            Write-Host ''
            Write-Host '  Run this again as administrator to change the files above.' -ForegroundColor DarkGray
        }
        else {
            Write-Host ''
            Write-Host '  Asking Windows for administrator rights for the files above.' -ForegroundColor DarkGray
            $script:ResolvedForElevation = $needsElevation
            $launched = $false
            try {
                [void] (Invoke-Elevated)
                $launched = $true
            }
            catch {
                Write-Line 'declined' 'Administrator rights were not granted.' Yellow
            }
            if ($launched) {
                # The elevated window can be closed at its pause, and then its
                # exit code means nothing. The files show what it really did.
                foreach ($item in $needsElevation) {
                    $after = 'Unknown'
                    try { $after = Get-State (Read-Shared $item) } catch { }
                    if ($after -eq $wanted) {
                        $script:Failures--
                        Write-Line $(if ($Restore) { 'restored' } else { 'patched' }) "$item  by the elevated run." Green
                    }
                    else {
                        Write-Line 'failed' "$item  was not changed by the elevated run." Red
                    }
                }
            }
        }
    }
}
catch {
    Write-Line 'error' (Get-InnerException $_).Message Red
    $script:Failures++
}

if ($script:Failures -gt 0) { $exitCode = 1 }

Write-Host ''
if ($PauseAtEnd -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected -and (Test-OwnConsole)) {
    # The key is only worth waiting for when someone can see the prompt and
    # answer it. With input or output redirected it would look like a hang.
    try {
        Write-Host 'Press any key to close.' -ForegroundColor DarkGray
        [void] $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    catch { }
}
exit $exitCode
