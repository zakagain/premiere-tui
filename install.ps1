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
            Write-Host "    function premiere-tui { & '$installScript' @args }" -ForegroundColor ([ConsoleColor]::Gray)
            Write-Host "    Set-Alias -Name ptui -Value premiere-tui -Scope Global -Force" -ForegroundColor ([ConsoleColor]::Gray)
            Write-Host ''
            return
        }

        if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
            Write-Fail 'Could not determine the PowerShell profile path.'
            Write-Host '  Add this to your profile manually:' -ForegroundColor ([ConsoleColor]::DarkGray)
            Write-Host "    function premiere-tui { & '$installScript' @args }" -ForegroundColor ([ConsoleColor]::Gray)
            Write-Host "    Set-Alias -Name ptui -Value premiere-tui -Scope Global -Force" -ForegroundColor ([ConsoleColor]::Gray)
            Write-Host ''
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

        # Remove every previous marked block.
        $markedPattern = [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker) + '\r?\n?'
        while ($true) {
            $stripped = [regex]::Replace(
                $content,
                $markedPattern,
                '',
                [System.Text.RegularExpressions.RegexOptions]::Singleline
            )
            if ($stripped -eq $content) {
                break
            }
            $content = $stripped
        }

        # Remove the old hand-written function, with or without its comment.
        $legacyPatterns = @(
            '(?ms)^[ \t]*#\s*premiere-tui\s*\r?\n[ \t]*function\s+(?:global:|script:)?premiere-tui\s*\{.*?^\}[ \t]*\r?\n?',
            '(?ms)^[ \t]*function\s+(?:global:|script:)?premiere-tui\s*\{.*?^\}[ \t]*\r?\n?'
        )
        foreach ($legacyPattern in $legacyPatterns) {
            $content = [regex]::Replace($content, $legacyPattern, '')
        }

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
    } catch {
        Write-Fail $_.Exception.Message
        Write-Host ''
    } finally {
        if ($null -ne $downloadRoot -and (Test-Path -LiteralPath $downloadRoot)) {
            try { Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
} -Ref $Ref -InstallDir $InstallDir -ProfilePath $ProfilePath -SourcePath $SourcePath -NoProfile:$NoProfile
