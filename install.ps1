#Requires -Version 5.1
<#
.SYNOPSIS
    Install premiere-tui for the current user.

.DESCRIPTION
    Downloads the premiere-tui repository, copies the script and bundled
    template to %LOCALAPPDATA%\premiere-tui, and adds a premiere-tui function
    to the current PowerShell profile.

.PARAMETER Ref
    Branch or tag to install. Defaults to main.

.PARAMETER InstallDir
    Install directory. Defaults to %LOCALAPPDATA%\premiere-tui.

.PARAMETER ProfilePath
    PowerShell profile to update. Defaults to $PROFILE.

.PARAMETER SourcePath
    Install from a local repository instead of downloading. Intended for
    development and testing.

.PARAMETER NoProfile
    Skip the profile update.

.EXAMPLE
    iex (irm https://raw.githubusercontent.com/zakagain/premiere-tui/main/install.ps1)

.EXAMPLE
    .\install.ps1 -SourcePath . -NoProfile
#>
[CmdletBinding()]
param(
    [string]$Ref = 'main',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'premiere-tui'),
    [string]$ProfilePath = $PROFILE,
    [string]$SourcePath,
    [switch]$NoProfile
)

# The result is reported through $global:LASTEXITCODE because this file is
# commonly run with iex (irm ...), where exit would close the user's session.
# The installer itself only sets it to 0 once it has finished successfully.
$global:LASTEXITCODE = 1

# Run in a child scope so preferences and helper functions do not leak into
# the caller's session when this file is executed with iex (irm ...).
& {
    param(
        [string]$Ref,
        [string]$InstallDir,
        [string]$ProfilePath,
        [string]$SourcePath,
        [switch]$NoProfile
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    function Write-Step {
        param([string]$Message)
        Write-Host "  $Message"
    }

    function Write-Ok {
        param([string]$Message)
        Write-Host "  [ok] $Message" -ForegroundColor ([ConsoleColor]::Green)
    }

    function Write-Fail {
        param([string]$Message)
        Write-Host "  [!!] $Message" -ForegroundColor ([ConsoleColor]::Red)
    }

    function Get-LegacyFunctionEnd {
        # Returns the index of the line that closes the function that starts on
        # $Start, or -1 when it is never closed. Braces are counted instead of
        # matched by a regex so an indented function is closed by its own brace
        # and never by an enclosing block.
        param([string[]]$Lines, [int]$Start)

        $depth = 0
        $seenOpen = $false
        for ($i = $Start; $i -lt $Lines.Count; $i++) {
            $opens = ([regex]::Matches($Lines[$i], '\{')).Count
            $closes = ([regex]::Matches($Lines[$i], '\}')).Count
            if (-not $seenOpen) {
                if ($opens -gt 0) {
                    $seenOpen = $true
                } else {
                    continue
                }
            }
            $depth += $opens - $closes
            if ($depth -le 0) {
                return $i
            }
        }
        return -1
    }

    function Remove-LegacyProfileEntries {
        # Removes an unmarked premiere-tui function and its ptui alias. These
        # were written by older installers and by the manual setup snippet, so
        # they are removed line by line instead of by a pattern that could
        # reach past the end of the definition.
        param([string]$Content)

        if ([string]::IsNullOrEmpty($Content)) {
            return $Content
        }

        $newline = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
        $lines = $Content -split "`r?`n"
        $kept = New-Object System.Collections.Generic.List[string]
        $index = 0
        while ($index -lt $lines.Count) {
            $line = $lines[$index]
            if ($line -match '^[ \t]*function\s+(?:global:|script:)?premiere-tui\b') {
                $end = Get-LegacyFunctionEnd -Lines $lines -Start $index
                if ($end -ge $index) {
                    if ($kept.Count -gt 0 -and $kept[$kept.Count - 1] -match '^[ \t]*#\s*premiere-tui\s*$') {
                        $kept.RemoveAt($kept.Count - 1)
                    }
                    $index = $end + 1
                    continue
                }
            }
            $kept.Add($line)
            $index++
        }

        $result = $kept -join $newline

        # A leftover ptui alias points at a function that is being replaced.
        $result = [regex]::Replace($result, '(?im)^[ \t]*(?:Set-Alias|New-Alias)\s+[^\r\n]*\bptui\b[^\r\n]*\r?\n?', '')

        return $result
    }

    function Remove-PremiereProfileEntries {
        # Strips every premiere-tui entry from a PowerShell profile. Only the
        # premiere-tui block and the legacy definition are touched, any other
        # content in the profile is left exactly as it was.
        param([string]$Content)

        if ([string]::IsNullOrEmpty($Content)) {
            return $Content
        }

        $startMarker = '# >>> premiere-tui >>>'
        $endMarker = '# <<< premiere-tui <<<'

        # The tempered dot stops a match from spanning a second start marker, so
        # a half written block can never swallow the content around it.
        $start = [regex]::Escape($startMarker)
        $end = [regex]::Escape($endMarker)
        $markedPattern = $start + '(?:(?!' + $start + ').)*?' + $end + '[ \t]*\r?\n?'
        $stripped = [regex]::Replace(
            $Content,
            $markedPattern,
            '',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )

        $stripped = Remove-LegacyProfileEntries -Content $stripped

        # A marker left over is an orphan. Only the marker line is dropped, never
        # the content around it.
        $stripped = [regex]::Replace($stripped, '(?im)^[ \t]*' + [regex]::Escape($startMarker) + '[ \t]*\r?\n?', '')
        $stripped = [regex]::Replace($stripped, '(?im)^[ \t]*' + [regex]::Escape($endMarker) + '[ \t]*\r?\n?', '')

        return $stripped
    }

    $repoOwner = 'zakagain'
    $repoName = 'premiere-tui'
    $downloadRoot = $null
    $sourceRoot = $null

    try {
        if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
            $sourceRoot = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
            Write-Step "Installing from $sourceRoot"
        } else {
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            } catch { }

            $downloadRoot = Join-Path $env:TEMP ('premiere-tui-install-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
            $zipPath = Join-Path $downloadRoot 'premiere-tui.zip'
            $zipUrl = "https://github.com/$repoOwner/$repoName/archive/$Ref.zip"
            Write-Step "Downloading $zipUrl"
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
            Expand-Archive -LiteralPath $zipPath -DestinationPath $downloadRoot -Force

            $sourceRoot = Get-ChildItem -LiteralPath $downloadRoot -Directory |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'premiere.ps1') -PathType Leaf } |
                Select-Object -First 1 -ExpandProperty FullName

            if ([string]::IsNullOrWhiteSpace($sourceRoot)) {
                throw 'The downloaded archive did not contain premiere.ps1.'
            }
        }

        $sourceScript = Join-Path $sourceRoot 'premiere.ps1'
        $sourceTemplate = Join-Path $sourceRoot 'template'
        if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) {
            throw "premiere.ps1 was not found in $sourceRoot"
        }
        if (-not (Test-Path -LiteralPath $sourceTemplate -PathType Container)) {
            throw "template folder was not found in $sourceRoot"
        }

        if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }

        $installScript = Join-Path $InstallDir 'premiere.ps1'
        Copy-Item -LiteralPath $sourceScript -Destination $installScript -Force

        $installTemplate = Join-Path $InstallDir 'template'
        if (Test-Path -LiteralPath $installTemplate) {
            Remove-Item -LiteralPath $installTemplate -Recurse -Force
        }
        Copy-Item -LiteralPath $sourceTemplate -Destination $installTemplate -Recurse -Force

        foreach ($extra in @('README.md', 'LICENSE')) {
            $extraSource = Join-Path $sourceRoot $extra
            if (Test-Path -LiteralPath $extraSource -PathType Leaf) {
                Copy-Item -LiteralPath $extraSource -Destination (Join-Path $InstallDir $extra) -Force
            }
        }

        Write-Ok "Installed to $InstallDir"

        if ($NoProfile) {
            Write-Step 'Profile not modified (-NoProfile).'
            Write-Host ''
            Write-Host '  To add the command manually, put this in your PowerShell profile:' -ForegroundColor ([ConsoleColor]::DarkGray)
            Write-Host "    # >>> premiere-tui >>>" -ForegroundColor ([ConsoleColor]::Gray)
            Write-Host "    function premiere-tui { & '$installScript' @args }" -ForegroundColor ([ConsoleColor]::Gray)
            Write-Host "    Set-Alias -Name ptui -Value premiere-tui -Scope Global -Force" -ForegroundColor ([ConsoleColor]::Gray)
            Write-Host "    # <<< premiere-tui <<<" -ForegroundColor ([ConsoleColor]::Gray)
            Write-Host ''
            $global:LASTEXITCODE = 0
            return
        }

        if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
            Write-Fail 'Could not determine the PowerShell profile path.'
            Write-Host '  Add this to your profile manually:' -ForegroundColor ([ConsoleColor]::DarkGray)
            Write-Host "    # >>> premiere-tui >>>" -ForegroundColor ([ConsoleColor]::Gray)
            Write-Host "    function premiere-tui { & '$installScript' @args }" -ForegroundColor ([ConsoleColor]::Gray)
            Write-Host "    Set-Alias -Name ptui -Value premiere-tui -Scope Global -Force" -ForegroundColor ([ConsoleColor]::Gray)
            Write-Host "    # <<< premiere-tui <<<" -ForegroundColor ([ConsoleColor]::Gray)
            Write-Host ''
            $global:LASTEXITCODE = 1
            return
        }

        $profileDirectory = Split-Path -Parent $ProfilePath
        if (-not [string]::IsNullOrWhiteSpace($profileDirectory) -and -not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
        }

        $profileExists = Test-Path -LiteralPath $ProfilePath -PathType Leaf
        $content = ''
        if ($profileExists) {
            $content = Get-Content -LiteralPath $ProfilePath -Raw -ErrorAction Stop
            if ($null -eq $content) {
                $content = ''
            }
        }

        $backupPath = $null
        if ($profileExists -and -not [string]::IsNullOrWhiteSpace($content)) {
            $backupPath = $ProfilePath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff')
            Copy-Item -LiteralPath $ProfilePath -Destination $backupPath -Force
        }

        $startMarker = '# >>> premiere-tui >>>'
        $endMarker = '# <<< premiere-tui <<<'

        # Remove every previous premiere-tui entry from the profile. Only the
        # marked block and the legacy definition are touched.
        $content = Remove-PremiereProfileEntries -Content $content

        $escapedInstallScript = $installScript.Replace("'", "''")
        $block = @"
$startMarker
function premiere-tui {
    & '$escapedInstallScript' @args
}
Set-Alias -Name ptui -Value premiere-tui -Scope Global -Force
$endMarker
"@

        $newContent = if ([string]::IsNullOrWhiteSpace($content)) {
            $block + [Environment]::NewLine
        } else {
            $content.Trim() + [Environment]::NewLine + [Environment]::NewLine + $block + [Environment]::NewLine
        }

        # Never write a profile that does not parse. The backup is already in
        # place, so a failure here leaves the original profile untouched.
        $parseErrors = $null
        $parseTokens = $null
        [System.Management.Automation.Language.Parser]::ParseInput($newContent, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
        if (@($parseErrors).Count -gt 0) {
            throw "Refusing to rewrite the profile, the result would not parse: $($parseErrors[0].Message)"
        }

        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($ProfilePath, $newContent, $utf8Bom)

        Write-Ok "Updated profile: $ProfilePath"
        if ($null -ne $backupPath) {
            Write-Step "Backup: $backupPath"
        }
        Write-Host ''
        Write-Host '  Restart PowerShell, then run:' -ForegroundColor ([ConsoleColor]::White)
        Write-Host '    premiere-tui' -ForegroundColor ([ConsoleColor]::Cyan)
        Write-Host '    ptui          (alias)' -ForegroundColor ([ConsoleColor]::Cyan)
        Write-Host ''
        Write-Host '  Change settings:' -ForegroundColor ([ConsoleColor]::White)
        Write-Host '    premiere-tui config setup' -ForegroundColor ([ConsoleColor]::Cyan)
        Write-Host ''
        Write-Host '  Uninstall:' -ForegroundColor ([ConsoleColor]::White)
        Write-Host '    premiere-tui uninstall' -ForegroundColor ([ConsoleColor]::Cyan)
        Write-Host ''
        $global:LASTEXITCODE = 0
    } catch {
        Write-Fail $_.Exception.Message
        Write-Host ''
        # The installer never calls exit, that would close the session of a
        # user who ran it with iex (irm ...). The exit code is reported here.
        $global:LASTEXITCODE = 1
    } finally {
        if ($null -ne $downloadRoot -and (Test-Path -LiteralPath $downloadRoot)) {
            try { Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
} -Ref $Ref -InstallDir $InstallDir -ProfilePath $ProfilePath -SourcePath $SourcePath -NoProfile:$NoProfile

# When this file runs as a file the result becomes the exit code of the
# process. Under iex there is no script file, so this is never reached and the
# session of the user is left alone.
if (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    exit $global:LASTEXITCODE
}
