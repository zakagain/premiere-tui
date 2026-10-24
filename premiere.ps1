#Requires -Version 5.1
<#
.SYNOPSIS
    premiere-tui - create a new Adobe Premiere Pro project from a master template.

.DESCRIPTION
    Copies a master template folder to a new project folder, renames the copied
    .prproj to match the project name, then opens the project in Adobe Premiere Pro.

    Settings live in %APPDATA%\premiere-tui\config.json. If no template folder is
    configured, the template bundled next to this script is used.

    With no project name the script renders an interactive terminal prompt.
    A project name can also be supplied directly from the command line.

    The commands are "new-project", "config", "config setup", "uninstall" and
    "help". Every flag is written with one dash followed by the name, for
    example -NoLaunch. -Help prints the full list, it is the only help flag.

.PARAMETER CommandOrName
    Optional subcommand ("new-project", "config", "uninstall", "help"),
    or the project name itself.

.PARAMETER ProjectName
    The project name when using the "new-project" form, or "setup" when using the
    "config" form.

.PARAMETER TemplateFolder
    Optional one-run override for the template folder.

.PARAMETER TemplateProjectFile
    Optional one-run override for the preferred .prproj inside the template.

.PARAMETER ProjectsParentFolder
    Optional one-run override for the folder that receives new project folders.

.PARAMETER ConfigPath
    Optional one-run override for the config file path.

.PARAMETER InstallDir
    Install directory to remove during uninstall. Defaults to %LOCALAPPDATA%\premiere-tui.

.PARAMETER ProfilePath
    PowerShell profile to clean during uninstall. Defaults to $PROFILE.

.PARAMETER NoProfile
    Skip PowerShell profile changes during uninstall.

.PARAMETER RemoveBackups
    Remove profile backups created by the installer during uninstall.

.PARAMETER Force
    Skip the uninstall confirmation prompt.

.PARAMETER Ascii
    Use plain ASCII borders instead of Unicode box drawing characters.

.PARAMETER NoLaunch
    Create the project but do not open it in Premiere Pro.

.EXAMPLE
    .\premiere.ps1 -Help

.EXAMPLE
    .\premiere.ps1

.EXAMPLE
    .\premiere.ps1 "My amazing Premiere project"

.EXAMPLE
    .\premiere.ps1 new-project "My amazing Premiere project"

.EXAMPLE
    .\premiere.ps1 config setup

.EXAMPLE
    .\premiere.ps1 uninstall

.EXAMPLE
    .\premiere.ps1 uninstall -Force -NoProfile

.EXAMPLE
    .\premiere.ps1 -NoLaunch "Test project"
#>
param(
    [string]$CommandOrName,
    [string]$ProjectName,

    # Optional one-run overrides. Normal settings live in config.json.
    [string]$TemplateFolder,
    [string]$TemplateProjectFile,
    [string]$ProjectsParentFolder,
    [string]$ConfigPath,

    # Uninstall options.
    [string]$InstallDir,
    [string]$ProfilePath = $PROFILE,
    [switch]$NoProfile,
    [switch]$RemoveBackups,
    [switch]$Force,

    # Use plain ASCII borders if your terminal font cannot render box drawing.
    [switch]$Ascii,

    # Create the project but do not open it (useful for testing).
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ScriptName = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { 'premiere.ps1' }
$script:ScriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} else {
    (Get-Location).Path
}
$script:IsInteractive = $true
try {
    $script:IsInteractive = -not ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)
} catch {
    $script:IsInteractive = $false
}

# Make box-drawing characters render correctly in Windows PowerShell 5.1.
$script:UseAscii = [bool]$Ascii
if (-not $script:UseAscii) {
    try {
        if ([Console]::OutputEncoding.CodePage -ne 65001) {
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        }
        if ([Console]::OutputEncoding.CodePage -ne 65001) {
            $script:UseAscii = $true
        }
    } catch {
        $script:UseAscii = $true
    }
}

if ($script:UseAscii) {
    $script:Glyphs = @{
        TopLeft     = '+'
        TopRight    = '+'
        BottomLeft  = '+'
        BottomRight = '+'
        Horizontal  = '-'
        Vertical    = '|'
        Prompt      = '>'
        Bullet      = '-'
        Check       = 'OK'
        Cross       = 'x'
        Arrow       = '>'
        Caret       = '_'
        Ellipsis    = '~'
        UpArrow     = '^'
        DownArrow   = 'v'
    }
} else {
    $script:Glyphs = @{
        TopLeft     = [string][char]0x256D # rounded corner
        TopRight    = [string][char]0x256E
        BottomLeft  = [string][char]0x2570
        BottomRight = [string][char]0x256F
        Horizontal  = [string][char]0x2500
        Vertical    = [string][char]0x2502
        Prompt      = [string][char]0x276F
        Bullet      = [string][char]0x2022
        Check       = [string][char]0x2713
        Cross       = [string][char]0x2717
        Arrow       = [string][char]0x2192
        Caret       = [string][char]0x258C
        Ellipsis    = [string][char]0x2026
        UpArrow     = [string][char]0x2191
        DownArrow   = [string][char]0x2193
    }
}

# =========================================================================
#  Small text / console helpers
# =========================================================================

function Repeat-Text {
    param(
        [string]$Text,
        [int]$Count
    )

    if ($Count -le 0 -or [string]::IsNullOrEmpty($Text)) {
        return ''
    }

    return (($Text * $Count) -join '')
}

function Get-TruncatedText {
    param(
        [string]$Text,
        [int]$MaxLength
    )

    $value = [string]$Text
    if ($MaxLength -le 0) {
        return ''
    }
    if ($value.Length -le $MaxLength) {
        return $value
    }

    $ellipsis = $script:Glyphs.Ellipsis
    if ($MaxLength -le $ellipsis.Length) {
        return $ellipsis.Substring(0, $MaxLength)
    }

    return $value.Substring(0, $MaxLength - $ellipsis.Length) + $ellipsis
}

function Get-TruncatedPath {
    param(
        [string]$Path,
        [int]$MaxLength
    )

    $value = [string]$Path
    if ($MaxLength -le 0) {
        return ''
    }
    if ($value.Length -le $MaxLength) {
        return $value
    }

    $ellipsis = $script:Glyphs.Ellipsis
    if ($MaxLength -le $ellipsis.Length) {
        return $ellipsis.Substring(0, $MaxLength)
    }

    $tailLength = $MaxLength - $ellipsis.Length
    $tail = $value.Substring($value.Length - $tailLength)

    # Prefer to resume at a path separator so the preview does not start
    # in the middle of a folder name.
    $separatorIndex = $tail.IndexOf('\')
    if ($separatorIndex -gt 0 -and $separatorIndex -lt ($tail.Length - 1)) {
        $tail = $tail.Substring($separatorIndex)
    }

    return $ellipsis + $tail
}

function Get-ConsoleDimensions {
    try {
        $width = [Console]::WindowWidth
        $height = [Console]::WindowHeight
        if ($width -gt 0 -and $height -gt 0) {
            return @{ Width = $width; Height = $height }
        }
    } catch {
        # Fall through to the default size.
    }

    return @{ Width = 100; Height = 30 }
}

function Get-DestinationPath {
    param([string]$Name)

    return (Join-Path -Path $ProjectsParentFolder -ChildPath $Name)
}

# =========================================================================
#  TUI layout
# =========================================================================

function New-Segment {
    param(
        [string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    return [pscustomobject]@{
        Text  = [string]$Text
        Color = $Color
    }
}

function New-Line {
    param(
        [object[]]$Segments,
        [int]$Width
    )

    return [pscustomobject]@{
        Segments = @($Segments)
        Width    = $Width
    }
}

function New-BorderedLine {
    param(
        [object[]]$Segments = @(),
        [int]$BoxWidth,
        [int]$TextWidth,
        [ConsoleColor]$BorderColor = [ConsoleColor]::DarkGray
    )

    $content = @($Segments)
    $line = @()
    $line += New-Segment -Text $script:Glyphs.Vertical -Color $BorderColor
    $line += New-Segment -Text '  ' -Color $BorderColor

    $remaining = $TextWidth
    foreach ($segment in $content) {
        if ($remaining -le 0) {
            break
        }

        $segmentText = [string]$segment.Text
        if ($segmentText.Length -gt $remaining) {
            $segmentText = $segmentText.Substring(0, $remaining)
        }
        if ($segmentText.Length -gt 0) {
            $line += New-Segment -Text $segmentText -Color $segment.Color
            $remaining -= $segmentText.Length
        }
    }

    if ($remaining -gt 0) {
        $line += New-Segment -Text (Repeat-Text ' ' $remaining) -Color $BorderColor
    }
    $line += New-Segment -Text '  ' -Color $BorderColor
    $line += New-Segment -Text $script:Glyphs.Vertical -Color $BorderColor

    return New-Line -Segments $line -Width $BoxWidth
}

function New-TuiFrame {
    param(
        [string]$Text = '',
        [int]$Cursor = 0,
        [string]$ErrorMessage = ''
    )

    $value = [string]$Text
    $errorText = [string]$ErrorMessage
    $cursorPosition = [Math]::Max(0, [Math]::Min($Cursor, $value.Length))

    $dimensions = Get-ConsoleDimensions
    $windowWidth = [Math]::Max(16, [int]$dimensions.Width)
    $boxWidth = [Math]::Min(76, [Math]::Max(18, $windowWidth - 2))
    $margin = 0
    $textWidth = [Math]::Max(4, $boxWidth - 6)

    # The label and the input share one line so the prompt stays compact.
    $label = 'Enter project name:'
    $inputWidth = [Math]::Max(2, $textWidth - $label.Length - 4)

    $borderColor = [ConsoleColor]::DarkGray
    $g = $script:Glyphs

    $topBorder = New-Line -Width $boxWidth -Segments @(
        (New-Segment -Text $g.TopLeft -Color $borderColor),
        (New-Segment -Text (Repeat-Text $g.Horizontal ([Math]::Max(0, $boxWidth - 2))) -Color $borderColor),
        (New-Segment -Text $g.TopRight -Color $borderColor)
    )

    $bottomBorder = New-Line -Width $boxWidth -Segments @(
        (New-Segment -Text $g.BottomLeft -Color $borderColor),
        (New-Segment -Text (Repeat-Text $g.Horizontal ([Math]::Max(0, $boxWidth - 2))) -Color $borderColor),
        (New-Segment -Text $g.BottomRight -Color $borderColor)
    )

    # Build the input field: caret + placeholder, or text split at the caret.
    $inputSegments = @()
    if ($value.Length -eq 0) {
        $placeholder = Get-TruncatedText 'My amazing Premiere project' ([Math]::Max(0, $inputWidth - 1))
        $inputSegments += New-Segment -Text $g.Caret -Color ([ConsoleColor]::Cyan)
        if ($placeholder.Length -gt 0) {
            $inputSegments += New-Segment -Text $placeholder -Color ([ConsoleColor]::DarkGray)
        }
    } else {
        $maxText = [Math]::Max(0, $inputWidth - 1)
        $start = 0
        if ($value.Length -gt $maxText) {
            $start = [Math]::Max(0, $cursorPosition - [int]([Math]::Floor($maxText / 2)))
            $start = [Math]::Min($start, $value.Length - $maxText)
        }

        $visibleLength = [Math]::Min($maxText, $value.Length - $start)
        $visible = $value.Substring($start, [Math]::Max(0, $visibleLength))
        $relativeCursor = [Math]::Max(0, [Math]::Min($cursorPosition - $start, $visible.Length))
        $before = $visible.Substring(0, $relativeCursor)
        $after = $visible.Substring($relativeCursor)

        if ($before.Length -gt 0) {
            $inputSegments += New-Segment -Text $before -Color ([ConsoleColor]::White)
        }
        $inputSegments += New-Segment -Text $g.Caret -Color ([ConsoleColor]::Cyan)
        if ($after.Length -gt 0) {
            $inputSegments += New-Segment -Text $after -Color ([ConsoleColor]::White)
        }
    }

    $inputContent = @(
        (New-Segment -Text $label -Color ([ConsoleColor]::White)),
        (New-Segment -Text ' ' -Color ([ConsoleColor]::White)),
        (New-Segment -Text $g.Prompt -Color ([ConsoleColor]::Cyan)),
        (New-Segment -Text ' ' -Color ([ConsoleColor]::Gray))
    )
    $inputContent += $inputSegments

    $inputLine = New-BorderedLine -BoxWidth $boxWidth -TextWidth $textWidth -BorderColor $borderColor -Segments $inputContent

    if ($errorText.Length -gt 0) {
        $statusLine = New-BorderedLine -BoxWidth $boxWidth -TextWidth $textWidth -BorderColor $borderColor -Segments @(
            (New-Segment -Text ($g.Cross + ' ') -Color ([ConsoleColor]::Red)),
            (New-Segment -Text (Get-TruncatedText $errorText ([Math]::Max(0, $textWidth - 2))) -Color ([ConsoleColor]::Red))
        )
    } elseif ($value.Trim().Length -gt 0) {
        $previewPath = $ProjectsParentFolder.TrimEnd('\') + '\' + $value.Trim()
        $statusLine = New-BorderedLine -BoxWidth $boxWidth -TextWidth $textWidth -BorderColor $borderColor -Segments @(
            (New-Segment -Text ($g.Arrow + ' ') -Color ([ConsoleColor]::DarkGray)),
            (New-Segment -Text (Get-TruncatedPath $previewPath ([Math]::Max(0, $textWidth - 2))) -Color ([ConsoleColor]::DarkGray))
        )
    } else {
        $hint = 'New folder in ' + $ProjectsParentFolder
        $statusLine = New-BorderedLine -BoxWidth $boxWidth -TextWidth $textWidth -BorderColor $borderColor -Segments @(
            (New-Segment -Text (Get-TruncatedText $hint $textWidth) -Color ([ConsoleColor]::DarkGray))
        )
    }

    $footer = '  enter to create ' + $g.Bullet + ' esc to quit'
    $footerLine = New-Line -Width $boxWidth -Segments @(
        (New-Segment -Text (Get-TruncatedText $footer $boxWidth) -Color ([ConsoleColor]::DarkGray))
    )

    return [pscustomobject]@{
        Margin = $margin
        Width  = $boxWidth
        Lines  = @(
            $topBorder,
            $inputLine,
            $statusLine,
            $bottomBorder,
            $footerLine
        )
    }
}

function Write-TuiFrame {
    param([object]$Frame)

    $margin = [int]$Frame.Margin
    $row = 0

    foreach ($line in $Frame.Lines) {
        try {
            [Console]::SetCursorPosition($margin, $row)
        } catch {
            return
        }

        $used = 0
        foreach ($segment in $line.Segments) {
            $remaining = $line.Width - $used
            if ($remaining -le 0) {
                break
            }

            $segmentText = [string]$segment.Text
            if ($segmentText.Length -eq 0) {
                continue
            }
            if ($segmentText.Length -gt $remaining) {
                $segmentText = $segmentText.Substring(0, $remaining)
            }

            [Console]::ForegroundColor = [ConsoleColor]$segment.Color
            [Console]::Write($segmentText)
            $used += $segmentText.Length
        }

        if ($used -lt $line.Width) {
            [Console]::ForegroundColor = [ConsoleColor]::DarkGray
            [Console]::Write((Repeat-Text ' ' ($line.Width - $used)))
        }

        $row++
    }
}

function Get-CursorRow {
    # The row the cursor sits on, or -1 when the console cannot report it.
    try {
        return [int][Console]::CursorTop
    } catch {
        return -1
    }
}

function Test-ConsoleCursor {
    # True when the console supports moving the cursor, which is what an
    # inline prompt needs to redraw itself in place.
    try {
        $null = [Console]::CursorTop
        return $true
    } catch {
        return $false
    }
}

function Write-InlineFrame {
    # Draws a frame at the current cursor position and leaves the cursor on the
    # line below it. Nothing above the frame is touched, so the output of the
    # shell keeps the place it had.
    param([object]$Frame)

    foreach ($line in $Frame.Lines) {
        $used = 0
        foreach ($segment in $line.Segments) {
            $remaining = $line.Width - $used
            if ($remaining -le 0) {
                break
            }

            $segmentText = [string]$segment.Text
            if ($segmentText.Length -eq 0) {
                continue
            }
            if ($segmentText.Length -gt $remaining) {
                $segmentText = $segmentText.Substring(0, $remaining)
            }

            [Console]::ForegroundColor = [ConsoleColor]$segment.Color
            [Console]::Write($segmentText)
            $used += $segmentText.Length
        }

        if ($used -lt $line.Width) {
            [Console]::ForegroundColor = [ConsoleColor]::DarkGray
            [Console]::Write((Repeat-Text ' ' ($line.Width - $used)))
        }

        [Console]::Write("`r`n")
    }
}

function Clear-InlineFrame {
    # Blanks a frame that was drawn before, used when the terminal changed size
    # and the frame has to be drawn again with a different width.
    param(
        [int]$Top,
        [int]$Rows,
        [int]$Width
    )

    if ($Top -lt 0 -or $Rows -le 0 -or $Width -le 0) {
        return
    }

    for ($row = 0; $row -lt $Rows; $row++) {
        try {
            [Console]::SetCursorPosition(0, $Top + $row)
        } catch {
            return
        }
        [Console]::ForegroundColor = [ConsoleColor]::DarkGray
        [Console]::Write((Repeat-Text ' ' $Width))
    }

    try {
        [Console]::SetCursorPosition(0, $Top + $Rows)
    } catch { }
}

# =========================================================================
#  Config
# =========================================================================

function Get-BundledTemplateFolder {
    return (Join-Path -Path $script:ScriptRoot -ChildPath 'template')
}

function Get-ConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        return $ConfigPath
    }

    $root = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path -Path $env:USERPROFILE -ChildPath 'AppData\Roaming'
    }
    return (Join-Path -Path $root -ChildPath 'premiere-tui\config.json')
}

function Get-DefaultProjectsParentFolder {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documents)) {
        $documents = Join-Path -Path $env:USERPROFILE -ChildPath 'Documents'
    }

    $adobeRoot = Join-Path -Path $documents -ChildPath 'Adobe\Premiere Pro'
    if (Test-Path -LiteralPath $adobeRoot -PathType Container) {
        $versionFolders = @(
            Get-ChildItem -LiteralPath $adobeRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+(\.\d+)*$' } |
                Sort-Object -Descending -Property @{
                    Expression = {
                        try { [version]$_.Name } catch { [version]'0.0' }
                    }
                }
        )

        foreach ($folder in $versionFolders) {
            $candidate = Join-Path -Path $folder.FullName -ChildPath 'Projects'
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                return $candidate
            }
        }
    }

    return (Join-Path -Path $adobeRoot -ChildPath 'Projects')
}

function New-DefaultConfig {
    return [pscustomobject]@{
        version             = 1
        templateFolder      = ''
        templateProjectFile = ''
        projectsParentFolder = (Get-DefaultProjectsParentFolder)
    }
}

function Read-Config {
    $path = Get-ConfigPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data -or $data -is [System.Array]) {
            return $null
        }

        $config = New-DefaultConfig
        $names = @($data.PSObject.Properties.Name)
        if ($names -contains 'version') {
            try { $config.version = [int]$data.version } catch { }
        }
        if ($names -contains 'templateFolder') {
            $config.templateFolder = [string]$data.templateFolder
        }
        if ($names -contains 'templateProjectFile') {
            $config.templateProjectFile = [string]$data.templateProjectFile
        }
        if ($names -contains 'projectsParentFolder') {
            $config.projectsParentFolder = [string]$data.projectsParentFolder
        }
        return $config
    } catch {
        Write-Warning "Could not read config '$path': $($_.Exception.Message)"
        return $null
    }
}

function Save-Config {
    param([object]$Config)

    $path = Get-ConfigPath
    $directory = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }

    $json = $Config | ConvertTo-Json -Depth 5
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $json + [Environment]::NewLine, $encoding)

    return $path
}

function Expand-PathVariables {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    # Expand %VAR% (cmd-style)
    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)

    # Expand $env:VAR (PowerShell-style) - Environment.ExpandEnvironmentVariables
    # does not handle $env:VAR, so we do it manually
    $expanded = [regex]::Replace($expanded, '\$env:([A-Za-z_][A-Za-z0-9_]*)', {
        param($match)
        $varName = $match.Groups[1].Value
        if (Test-Path "Env:$varName") {
            return (Get-Item "Env:$varName").Value
        }
        return $match.Value
    })

    return $expanded
}

function Get-EffectiveConfig {
    param([object]$Config)

    $effective = New-DefaultConfig
    if ($null -ne $Config) {
        $names = @($Config.PSObject.Properties.Name)
        if ($names -contains 'version') {
            try { $effective.version = [int]$Config.version } catch { }
        }
        if ($names -contains 'templateFolder') {
            $effective.templateFolder = Expand-PathVariables ([string]$Config.templateFolder)
        }
        if ($names -contains 'templateProjectFile') {
            $effective.templateProjectFile = [string]$Config.templateProjectFile
        }
        if ($names -contains 'projectsParentFolder') {
            $effective.projectsParentFolder = Expand-PathVariables ([string]$Config.projectsParentFolder)
        }
    }

    if ([string]::IsNullOrWhiteSpace($effective.projectsParentFolder)) {
        $effective.projectsParentFolder = Get-DefaultProjectsParentFolder
    }

    return $effective
}

function Resolve-TemplateFolder {
    param([string]$ConfiguredFolder)

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredFolder)) {
        return $ConfiguredFolder.Trim()
    }
    return (Get-BundledTemplateFolder)
}

function Get-TemplateProjectPath {
    param(
        [string]$TemplateFolder,
        [string]$PreferredFile
    )

    if ([string]::IsNullOrWhiteSpace($TemplateFolder) -or -not (Test-Path -LiteralPath $TemplateFolder -PathType Container)) {
        return $null
    }

    $projects = @(Get-ChildItem -LiteralPath $TemplateFolder -Recurse -Filter '*.prproj' -File -Force -ErrorAction SilentlyContinue)
    if ($projects.Count -eq 0) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredFile)) {
        $preferredName = [System.IO.Path]::GetFileName($PreferredFile)
        if (-not [string]::IsNullOrWhiteSpace($preferredName)) {
            $match = $projects | Where-Object { $_.Name -eq $preferredName } | Select-Object -First 1
            if ($null -ne $match) {
                return $match.FullName
            }
        }
    }

    $master = $projects | Where-Object { $_.Name -eq 'Master_Template.prproj' } | Select-Object -First 1
    if ($null -ne $master) {
        return $master.FullName
    }

    return $projects[0].FullName
}

function Get-ConfigError {
    param([object]$Config)

    if ($null -eq $Config) {
        return 'Config is empty.'
    }

    $template = Resolve-TemplateFolder -ConfiguredFolder ([string]$Config.templateFolder)
    if (-not (Test-Path -LiteralPath $template -PathType Container)) {
        return "Template folder not found: $template"
    }

    $project = Get-TemplateProjectPath -TemplateFolder $template -PreferredFile ([string]$Config.templateProjectFile)
    if ($null -eq $project) {
        return "No .prproj file was found inside the template: $template"
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.projectsParentFolder)) {
        return 'Projects folder is not configured.'
    }

    return $null
}

function Save-ConfigFromValues {
    param(
        [string[]]$Values,
        [object]$BaseConfig
    )

    $templateValue = Expand-PathVariables (([string]$Values[0]).Trim())
    $projectsValue = Expand-PathVariables (([string]$Values[1]).Trim())
    $bundled = Get-BundledTemplateFolder

    $effectiveTemplate = if ([string]::IsNullOrWhiteSpace($templateValue)) { $bundled } else { $templateValue }
    if (-not (Test-Path -LiteralPath $effectiveTemplate -PathType Container)) {
        return [pscustomobject]@{ Error = "Template folder not found: $effectiveTemplate"; Config = $null; Path = $null }
    }

    $preferred = if ($null -ne $BaseConfig) { [string]$BaseConfig.templateProjectFile } else { '' }
    $templateProject = Get-TemplateProjectPath -TemplateFolder $effectiveTemplate -PreferredFile $preferred
    if ($null -eq $templateProject) {
        return [pscustomobject]@{ Error = "No .prproj file was found inside the template: $effectiveTemplate"; Config = $null; Path = $null }
    }

    if ([string]::IsNullOrWhiteSpace($projectsValue)) {
        return [pscustomobject]@{ Error = 'Projects folder cannot be empty.'; Config = $null; Path = $null }
    }

    try {
        $projectsFull = [System.IO.Path]::GetFullPath($projectsValue)
    } catch {
        return [pscustomobject]@{ Error = "Projects folder is not a valid path: $projectsValue"; Config = $null; Path = $null }
    }

    if (Test-Path -LiteralPath $projectsFull -PathType Leaf) {
        return [pscustomobject]@{ Error = "Projects folder is a file: $projectsFull"; Config = $null; Path = $null }
    }

    if (-not (Test-Path -LiteralPath $projectsFull -PathType Container)) {
        try {
            New-Item -ItemType Directory -Path $projectsFull -Force -ErrorAction Stop | Out-Null
        } catch {
            return [pscustomobject]@{ Error = "Could not create projects folder: $($_.Exception.Message)"; Config = $null; Path = $null }
        }
    }

    # Keep the bundled template portable: store an empty templateFolder when
    # the configured folder is the bundled one.
    $templateSetting = $templateValue
    if ([string]::IsNullOrWhiteSpace($templateSetting)) {
        $templateSetting = ''
    } elseif ([string]::Equals($templateSetting.TrimEnd('\'), $bundled.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        $templateSetting = ''
    } else {
        try { $templateSetting = [System.IO.Path]::GetFullPath($templateSetting) } catch { }
    }

    $config = [pscustomobject]@{
        version              = 1
        templateFolder       = $templateSetting
        templateProjectFile  = [System.IO.Path]::GetFileName($templateProject)
        projectsParentFolder = $projectsFull
    }

    try {
        $path = Save-Config -Config $config
    } catch {
        return [pscustomobject]@{ Error = "Could not save config: $($_.Exception.Message)"; Config = $null; Path = $null }
    }

    return [pscustomobject]@{ Error = $null; Config = $config; Path = $path }
}

# =========================================================================
#  Config TUI
# =========================================================================

function New-ConfigFrame {
    param(
        [string[]]$Values,
        [int]$Selected = 0,
        [bool]$Editing = $false,
        [string]$EditText = '',
        [int]$EditCursor = 0,
        [string]$ErrorMessage = ''
    )

    $dimensions = Get-ConsoleDimensions
    $windowWidth = [Math]::Max(16, [int]$dimensions.Width)
    $boxWidth = [Math]::Min(76, [Math]::Max(24, $windowWidth - 2))
    $margin = [Math]::Max(0, [int]([Math]::Floor(($windowWidth - $boxWidth) / 2)))
    $textWidth = [Math]::Max(10, $boxWidth - 6)
    $inputWidth = [Math]::Max(4, $textWidth - 2)
    $borderColor = [ConsoleColor]::DarkGray
    $g = $script:Glyphs

    $topBorder = New-Line -Width $boxWidth -Segments @(
        (New-Segment -Text $g.TopLeft -Color $borderColor),
        (New-Segment -Text (Repeat-Text $g.Horizontal ([Math]::Max(0, $boxWidth - 2))) -Color $borderColor),
        (New-Segment -Text $g.TopRight -Color $borderColor)
    )

    $bottomBorder = New-Line -Width $boxWidth -Segments @(
        (New-Segment -Text $g.BottomLeft -Color $borderColor),
        (New-Segment -Text (Repeat-Text $g.Horizontal ([Math]::Max(0, $boxWidth - 2))) -Color $borderColor),
        (New-Segment -Text $g.BottomRight -Color $borderColor)
    )

    $titleLine = New-BorderedLine -BoxWidth $boxWidth -TextWidth $textWidth -BorderColor $borderColor -Segments @(
        (New-Segment -Text 'premiere-tui config' -Color ([ConsoleColor]::Cyan))
    )

    $blankLine = New-BorderedLine -BoxWidth $boxWidth -TextWidth $textWidth -BorderColor $borderColor -Segments @()
    $lines = @($topBorder, $titleLine, $blankLine)

    $bundled = Get-BundledTemplateFolder
    for ($i = 0; $i -lt 2; $i++) {
        $isSelected = ($i -eq $Selected)
        $label = if ($i -eq 0) { 'Template folder' } else { 'Projects folder' }
        $hint = if ($i -eq 0) { 'Leave empty to use the bundled template.' } else { 'New project folders are created here.' }

        $labelColor = if ($isSelected) { [ConsoleColor]::Cyan } else { [ConsoleColor]::White }
        $labelLine = New-BorderedLine -BoxWidth $boxWidth -TextWidth $textWidth -BorderColor $borderColor -Segments @(
            (New-Segment -Text $label -Color $labelColor)
        )

        $prefix = if ($isSelected) { $g.Prompt + ' ' } else { '  ' }
        $prefixColor = if ($isSelected) { [ConsoleColor]::Cyan } else { [ConsoleColor]::DarkGray }
        $valueColor = if ($isSelected) { [ConsoleColor]::White } else { [ConsoleColor]::Gray }

        if ($Editing -and $isSelected) {
            $editValue = [string]$EditText
            $cursorPosition = [Math]::Max(0, [Math]::Min($EditCursor, $editValue.Length))
            $maxText = [Math]::Max(0, $inputWidth - 1)
            $start = 0
            if ($editValue.Length -gt $maxText) {
                $start = [Math]::Max(0, $cursorPosition - [int]([Math]::Floor($maxText / 2)))
                $start = [Math]::Min($start, $editValue.Length - $maxText)
            }

            $visibleLength = [Math]::Min($maxText, $editValue.Length - $start)
            $visible = $editValue.Substring($start, [Math]::Max(0, $visibleLength))
            $relativeCursor = [Math]::Max(0, [Math]::Min($cursorPosition - $start, $visible.Length))
            $before = $visible.Substring(0, $relativeCursor)
            $after = $visible.Substring($relativeCursor)

            $valueSegments = @(
                (New-Segment -Text $prefix -Color $prefixColor)
            )
            if ($before.Length -gt 0) {
                $valueSegments += New-Segment -Text $before -Color ([ConsoleColor]::White)
            }
            $valueSegments += New-Segment -Text $g.Caret -Color ([ConsoleColor]::Cyan)
            if ($after.Length -gt 0) {
                $valueSegments += New-Segment -Text $after -Color ([ConsoleColor]::White)
            }
        } else {
            $value = [string]$Values[$i]
            $valueSegments = @(
                (New-Segment -Text $prefix -Color $prefixColor)
            )

            if ($i -eq 0 -and [string]::IsNullOrWhiteSpace($value)) {
                $valueSegments += New-Segment -Text '(bundled) ' -Color ([ConsoleColor]::DarkGray)
                $valueSegments += New-Segment -Text (Get-TruncatedPath $bundled ([Math]::Max(0, $textWidth - 12))) -Color $valueColor
            } elseif ([string]::IsNullOrWhiteSpace($value)) {
                $valueSegments += New-Segment -Text '(not set)' -Color ([ConsoleColor]::DarkGray)
            } else {
                $valueSegments += New-Segment -Text (Get-TruncatedPath $value ([Math]::Max(0, $textWidth - 2))) -Color $valueColor
            }
        }

        $valueLine = New-BorderedLine -BoxWidth $boxWidth -TextWidth $textWidth -BorderColor $borderColor -Segments $valueSegments
        $hintLine = New-BorderedLine -BoxWidth $boxWidth -TextWidth $textWidth -BorderColor $borderColor -Segments @(
            (New-Segment -Text '  ' -Color $borderColor),
            (New-Segment -Text (Get-TruncatedText $hint ([Math]::Max(0, $textWidth - 2))) -Color ([ConsoleColor]::DarkGray))
        )

        $lines += $labelLine
        $lines += $valueLine
        $lines += $hintLine
        if ($i -eq 0) {
            $lines += $blankLine
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        $statusLine = New-BorderedLine -BoxWidth $boxWidth -TextWidth $textWidth -BorderColor $borderColor -Segments @(
            (New-Segment -Text ($g.Cross + ' ') -Color ([ConsoleColor]::Red)),
            (New-Segment -Text (Get-TruncatedText $ErrorMessage ([Math]::Max(0, $textWidth - 2))) -Color ([ConsoleColor]::Red))
        )
    } else {
        $configLabel = 'Config: '
        $configPath = Get-ConfigPath
        $statusLine = New-BorderedLine -BoxWidth $boxWidth -TextWidth $textWidth -BorderColor $borderColor -Segments @(
            (New-Segment -Text $configLabel -Color ([ConsoleColor]::DarkGray)),
            (New-Segment -Text (Get-TruncatedPath $configPath ([Math]::Max(0, $textWidth - $configLabel.Length))) -Color ([ConsoleColor]::DarkGray))
        )
    }

    $footer = $g.UpArrow + $g.DownArrow + ' select ' + $g.Bullet + ' enter edit ' + $g.Bullet + ' ctrl+s save ' + $g.Bullet + ' esc cancel'
    $footerLine = New-BorderedLine -BoxWidth $boxWidth -TextWidth $textWidth -BorderColor $borderColor -Segments @(
        (New-Segment -Text (Get-TruncatedText $footer $textWidth) -Color ([ConsoleColor]::DarkGray))
    )

    $lines += $blankLine
    $lines += $statusLine
    $lines += $blankLine
    $lines += $footerLine
    $lines += $bottomBorder

    return [pscustomobject]@{
        Margin = $margin
        Width  = $boxWidth
        Lines  = $lines
    }
}

function Read-ConfigInteractive {
    param([object]$Config)

    $values = @(
        [string]$Config.templateFolder,
        [string]$Config.projectsParentFolder
    )
    $selected = 0
    $editing = $false
    $editText = ''
    $editCursor = 0
    $errorText = ''

    $originalCursorVisible = $true
    $originalTitle = $null
    $originalForeground = [Console]::ForegroundColor
    $originalTreatControlCAsInput = $false
    $lastDimensions = ''

    try {
        try { $originalCursorVisible = [Console]::CursorVisible } catch { }
        try {
            $originalTreatControlCAsInput = [Console]::TreatControlCAsInput
            [Console]::TreatControlCAsInput = $true
        } catch { }
        try {
            $originalTitle = $Host.UI.RawUI.WindowTitle
            $Host.UI.RawUI.WindowTitle = 'premiere-tui config'
        } catch { }
        try { [Console]::CursorVisible = $false } catch { }

        Clear-Host
        $initialDimensions = Get-ConsoleDimensions
        $lastDimensions = "$($initialDimensions.Width)x$($initialDimensions.Height)"

        while ($true) {
            $dimensions = Get-ConsoleDimensions
            $dimensionKey = "$($dimensions.Width)x$($dimensions.Height)"
            if ($dimensionKey -ne $lastDimensions) {
                Clear-Host
                $lastDimensions = $dimensionKey
            }

            $frame = New-ConfigFrame -Values $values -Selected $selected -Editing $editing -EditText $editText -EditCursor $editCursor -ErrorMessage $errorText
            Write-TuiFrame -Frame $frame

            $key = [Console]::ReadKey($true)
            $isControl = (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)

            if ($editing) {
                if ($key.Key -eq [ConsoleKey]::Escape) {
                    $editing = $false
                    $errorText = ''
                    continue
                }
                if ($key.Key -eq [ConsoleKey]::Enter) {
                    $values[$selected] = $editText.Trim()
                    $editing = $false
                    $errorText = ''
                    continue
                }
                if ($isControl) {
                    if ($key.Key -eq [ConsoleKey]::C) {
                        $editing = $false
                        $editText = [string]$values[$selected]
                        $errorText = ''
                    } elseif ($key.Key -eq [ConsoleKey]::U) {
                        $editText = ''
                        $editCursor = 0
                        $errorText = ''
                    } elseif ($key.Key -eq [ConsoleKey]::A) {
                        $editCursor = 0
                    } elseif ($key.Key -eq [ConsoleKey]::E) {
                        $editCursor = $editText.Length
                    }
                    continue
                }
                if ($key.Key -eq [ConsoleKey]::Backspace) {
                    if ($editCursor -gt 0) {
                        $editText = $editText.Remove($editCursor - 1, 1)
                        $editCursor--
                        $errorText = ''
                    }
                } elseif ($key.Key -eq [ConsoleKey]::Delete) {
                    if ($editCursor -lt $editText.Length) {
                        $editText = $editText.Remove($editCursor, 1)
                        $errorText = ''
                    }
                } elseif ($key.Key -eq [ConsoleKey]::LeftArrow) {
                    if ($editCursor -gt 0) {
                        $editCursor--
                    }
                } elseif ($key.Key -eq [ConsoleKey]::RightArrow) {
                    if ($editCursor -lt $editText.Length) {
                        $editCursor++
                    }
                } elseif ($key.Key -eq [ConsoleKey]::Home) {
                    $editCursor = 0
                } elseif ($key.Key -eq [ConsoleKey]::End) {
                    $editCursor = $editText.Length
                } else {
                    $character = $key.KeyChar
                    if ($character -ne [char]::MinValue -and -not [char]::IsControl($character)) {
                        if ($editText.Length -lt 500) {
                            $editText = $editText.Insert($editCursor, [string]$character)
                            $editCursor++
                            $errorText = ''
                        }
                    }
                }
                continue
            }

            if ($key.Key -eq [ConsoleKey]::Escape) {
                return $null
            }

            if ($isControl) {
                if ($key.Key -eq [ConsoleKey]::C) {
                    return $null
                }
                if ($key.Key -eq [ConsoleKey]::S) {
                    $result = Save-ConfigFromValues -Values $values -BaseConfig $Config
                    if (-not [string]::IsNullOrWhiteSpace([string]$result.Error)) {
                        $errorText = [string]$result.Error
                        continue
                    }
                    return $result.Config
                }
                continue
            }

            if ($key.Key -eq [ConsoleKey]::UpArrow) {
                $selected = [Math]::Max(0, $selected - 1)
                $errorText = ''
                continue
            }
            if ($key.Key -eq [ConsoleKey]::DownArrow) {
                $selected = [Math]::Min(1, $selected + 1)
                $errorText = ''
                continue
            }
            if ($key.Key -eq [ConsoleKey]::Tab) {
                $selected = ($selected + 1) % 2
                $errorText = ''
                continue
            }
            if ($key.Key -eq [ConsoleKey]::Enter) {
                $editing = $true
                $editText = [string]$values[$selected]
                if ($selected -eq 0 -and [string]::IsNullOrWhiteSpace($editText)) {
                    $editText = Get-BundledTemplateFolder
                }
                $editCursor = $editText.Length
                $errorText = ''
                continue
            }
        }
    } finally {
        try { Clear-Host } catch { }
        try { [Console]::CursorVisible = $originalCursorVisible } catch { }
        try { [Console]::ForegroundColor = $originalForeground } catch { }
        try { [Console]::TreatControlCAsInput = $originalTreatControlCAsInput } catch { }
        try {
            if (-not [string]::IsNullOrEmpty($originalTitle)) {
                $Host.UI.RawUI.WindowTitle = $originalTitle
            }
        } catch { }
    }
}

function Invoke-ConfigCommand {
    param([string]$Action = 'show')

    $script:ConfigCommandError = $null
    $existing = Read-Config
    $config = Get-EffectiveConfig -Config $existing
    $configPath = Get-ConfigPath
    $g = $script:Glyphs

    if ($Action -eq 'setup') {
        $templateValue = if (-not [string]::IsNullOrWhiteSpace($TemplateFolder)) {
            $TemplateFolder
        } else {
            [string]$config.templateFolder
        }
        $projectsValue = if (-not [string]::IsNullOrWhiteSpace($ProjectsParentFolder)) {
            $ProjectsParentFolder
        } else {
            [string]$config.projectsParentFolder
        }

        $setupConfig = [pscustomobject]@{
            version              = $config.version
            templateFolder       = $templateValue
            templateProjectFile  = [string]$config.templateProjectFile
            projectsParentFolder = $projectsValue
        }

        if (-not $script:IsInteractive) {
            $hasOverrides = (-not [string]::IsNullOrWhiteSpace($TemplateFolder)) -or (-not [string]::IsNullOrWhiteSpace($ProjectsParentFolder))
            if (-not $hasOverrides) {
                $currentTemplate = if ([string]::IsNullOrWhiteSpace([string]$config.templateFolder)) {
                    (Get-BundledTemplateFolder) + ' (bundled)'
                } else {
                    [string]$config.templateFolder
                }
                Write-Host ''
                Write-Host '  Config setup needs an interactive terminal.' -ForegroundColor ([ConsoleColor]::Yellow)
                Write-Host "    File:     $configPath" -ForegroundColor ([ConsoleColor]::DarkGray)
                Write-Host "    Template: $currentTemplate" -ForegroundColor ([ConsoleColor]::DarkGray)
                Write-Host "    Projects: $($config.projectsParentFolder)" -ForegroundColor ([ConsoleColor]::DarkGray)
                Write-Host ''
                Write-Host '  Run it in Windows Terminal, or edit the config file directly.' -ForegroundColor ([ConsoleColor]::DarkGray)
                Write-Host ''
                return
            }

            $result = Save-ConfigFromValues -Values @($templateValue, $projectsValue) -BaseConfig $config
            if (-not [string]::IsNullOrWhiteSpace([string]$result.Error)) {
                $script:ConfigCommandError = [string]$result.Error
                Write-ErrorMessage ([string]$result.Error)
                return
            }
            $saved = $result.Config
        } else {
            $saved = Read-ConfigInteractive -Config $setupConfig
        }

        if ($null -eq $saved) {
            Write-Host ''
            Write-Host '  Config unchanged.' -ForegroundColor ([ConsoleColor]::DarkGray)
            Write-Host ''
            return
        }

        $templateDisplay = if ([string]::IsNullOrWhiteSpace([string]$saved.templateFolder)) {
            (Get-BundledTemplateFolder) + ' (bundled)'
        } else {
            [string]$saved.templateFolder
        }

        Write-Host ''
        Write-Host "  $($g.Check) Config saved" -ForegroundColor ([ConsoleColor]::Green)
        Write-Host "    File:     $configPath" -ForegroundColor ([ConsoleColor]::DarkGray)
        Write-Host "    Template: $templateDisplay" -ForegroundColor ([ConsoleColor]::DarkGray)
        Write-Host "    Projects: $($saved.projectsParentFolder)" -ForegroundColor ([ConsoleColor]::DarkGray)
        Write-Host ''
        return
    }

    $templateDisplay = if ([string]::IsNullOrWhiteSpace([string]$config.templateFolder)) {
        (Get-BundledTemplateFolder) + ' (bundled)'
    } else {
        [string]$config.templateFolder
    }

    Write-Host ''
    Write-Host '  premiere-tui config' -ForegroundColor ([ConsoleColor]::Cyan)
    Write-Host "    File:     $configPath" -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host "    Template: $templateDisplay" -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host "    Projects: $($config.projectsParentFolder)" -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host ''
    Write-Host "  $($g.Bullet) Run '.\$($script:ScriptName) config setup' to change these settings." -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host ''
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
    # Removes an unmarked premiere-tui function and its ptui alias. These were
    # written by older installers and by the manual setup snippet, so they are
    # removed line by line instead of by a pattern that could reach past the
    # end of the definition.
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

    # A leftover ptui alias points at a function that is being removed.
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

    # The tempered dot stops a match from spanning a second start marker, so a
    # half written block can never swallow the content around it.
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

function Invoke-UninstallCommand {
    $g = $script:Glyphs
    $localAppData = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = Join-Path $env:USERPROFILE 'AppData\Local'
    }
    $installDir = if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        Join-Path $localAppData 'premiere-tui'
    } else {
        $InstallDir
    }
    $configPath = Get-ConfigPath
    $profilePath = $ProfilePath
    $appData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $appData = Join-Path $env:USERPROFILE 'AppData\Roaming'
    }
    $defaultConfigDir = Join-Path $appData 'premiere-tui'

    Write-Host ''
    Write-Host '  premiere-tui uninstall' -ForegroundColor ([ConsoleColor]::Cyan)
    Write-Host ''
    Write-Host '  This will remove:' -ForegroundColor ([ConsoleColor]::White)
    Write-Host "    App:     $installDir" -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host "    Config:  $configPath" -ForegroundColor ([ConsoleColor]::DarkGray)
    if ($NoProfile) {
        Write-Host '    Profile: skipped (-NoProfile)' -ForegroundColor ([ConsoleColor]::DarkGray)
    } elseif ([string]::IsNullOrWhiteSpace($profilePath)) {
        Write-Host '    Profile: (not detected)' -ForegroundColor ([ConsoleColor]::DarkGray)
    } else {
        Write-Host "    Profile: $profilePath" -ForegroundColor ([ConsoleColor]::DarkGray)
    }
    if ($RemoveBackups) {
        Write-Host '    Profile backups: yes' -ForegroundColor ([ConsoleColor]::DarkGray)
    }
    Write-Host ''
    Write-Host '  Your Premiere projects are not touched.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host ''

    try {
        $fullInstallDir = [System.IO.Path]::GetFullPath($installDir).TrimEnd('\')
    } catch {
        Write-ErrorMessage "Invalid install path: $installDir"
        Write-Host ''
        return $false
    }

    # Never remove a drive root or a well-known user/system folder.
    $protectedPaths = @(
        [System.IO.Path]::GetPathRoot($fullInstallDir),
        $env:USERPROFILE,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:WINDIR
    )
    foreach ($protectedPath in $protectedPaths) {
        if (-not [string]::IsNullOrWhiteSpace($protectedPath) -and
            [string]::Equals($fullInstallDir, $protectedPath.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            Write-ErrorMessage "Refusing to remove a protected folder: $installDir"
            Write-Host ''
            return $false
        }
    }

    # Refuse to remove anything that lives inside the user profile or a system
    # folder, not just the folder itself. The app itself is installed under
    # %LOCALAPPDATA% or %APPDATA%, so those two are only protected exactly.
    $appDataRoots = @()
    foreach ($appDataRoot in @($env:LOCALAPPDATA, $env:APPDATA)) {
        if (-not [string]::IsNullOrWhiteSpace($appDataRoot)) {
            $appDataRoots += $appDataRoot.TrimEnd('\')
        }
    }
    $containerRoots = @($env:USERPROFILE, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:WINDIR)
    foreach ($containerRoot in $containerRoots) {
        if ([string]::IsNullOrWhiteSpace($containerRoot)) {
            continue
        }
        $normalizedRoot = $containerRoot.TrimEnd('\')
        if (-not $fullInstallDir.StartsWith($normalizedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $underAppData = $false
        foreach ($appDataRoot in $appDataRoots) {
            if ($fullInstallDir.StartsWith($appDataRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $underAppData = $true
                break
            }
        }
        if (-not $underAppData) {
            Write-ErrorMessage "Refusing to remove a protected folder: $installDir"
            Write-Host ''
            return $false
        }
    }

    $installDir = $fullInstallDir
    $scriptRoot = if ([string]::IsNullOrWhiteSpace($script:ScriptRoot)) {
        ''
    } else {
        $script:ScriptRoot.TrimEnd('\')
    }
    $installPrefix = $installDir + '\'
    if (-not [string]::Equals($scriptRoot, $installDir, [StringComparison]::OrdinalIgnoreCase) -and
        $scriptRoot.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Write-ErrorMessage "Refusing to remove a folder that contains this script: $installDir"
        Write-Host ''
        return $false
    }

    # Do not remove a source checkout by accident. The installed app is not a
    # git repository, so this only triggers for an explicit -InstallDir. This
    # refusal is never waived by -Force, a mistyped path must not be able to
    # delete a working copy.
    if (Test-Path -LiteralPath (Join-Path $installDir '.git') -PathType Container) {
        Write-ErrorMessage "Refusing to remove a git repository: $installDir"
        Write-Host '  The installed app is never a repository, so this path is probably a mistake.' -ForegroundColor ([ConsoleColor]::DarkGray)
        Write-Host '  Delete it by hand if that is really what you want.' -ForegroundColor ([ConsoleColor]::DarkGray)
        Write-Host ''
        return $false
    }

    if (-not $Force) {
        if (-not $script:IsInteractive) {
            Write-ErrorMessage 'Uninstall needs -Force in a non-interactive shell.'
            Write-Host ''
            return $false
        }
        $answer = Read-Host '  Continue? [y/N]'
        if (([string]$answer).Trim() -notmatch '^(?i)y(es)?$') {
            Write-Host '  Cancelled.' -ForegroundColor ([ConsoleColor]::DarkGray)
            Write-Host ''
            return $false
        }
    }

    $installRemoved = $false
    $installError = $null
    if (Test-Path -LiteralPath $installDir -PathType Container) {
        $currentLocation = (Get-Location).Path
        $installPrefix = $installDir.TrimEnd('\') + '\'
        if ([string]::Equals($currentLocation.TrimEnd('\'), $installDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
            $currentLocation.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            try {
                Set-Location -LiteralPath $env:USERPROFILE
            } catch {
                Set-Location -LiteralPath $env:TEMP
            }
        }
        try {
            Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction Stop
            $installRemoved = $true
        } catch {
            $installError = $_.Exception.Message
        }
    }

    $configRemoved = $false
    $configError = $null
    $configParent = if ([string]::IsNullOrWhiteSpace($configPath)) { $null } else { Split-Path -Parent $configPath }
    if (-not [string]::IsNullOrWhiteSpace($configPath) -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        try {
            Remove-Item -LiteralPath $configPath -Force -ErrorAction Stop
            $configRemoved = $true
        } catch {
            $configError = $_.Exception.Message
        }
    }
    if ($null -ne $configParent -and
        [string]::Equals($configParent.TrimEnd('\'), $defaultConfigDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $defaultConfigDir -PathType Container)) {
        try {
            Remove-Item -LiteralPath $defaultConfigDir -Recurse -Force -ErrorAction Stop
            $configRemoved = $true
        } catch {
            if ($null -eq $configError) {
                $configError = $_.Exception.Message
            }
        }
    }

    $profileChanged = $false
    $profileBackup = $null
    $profileError = $null
    if (-not $NoProfile -and
        -not [string]::IsNullOrWhiteSpace($profilePath) -and
        (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        try {
            $profileContent = Get-Content -LiteralPath $profilePath -Raw -ErrorAction Stop
            if ($null -eq $profileContent) {
                $profileContent = ''
            }
            $originalProfile = $profileContent
            $profileContent = Remove-PremiereProfileEntries -Content $profileContent

            if ($profileContent -ne $originalProfile) {
                $candidate = $profileContent.Trim()
                $parseErrors = $null
                $parseTokens = $null
                [System.Management.Automation.Language.Parser]::ParseInput($candidate, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
                if (@($parseErrors).Count -gt 0) {
                    throw "Refusing to rewrite the profile, the result would not parse: $($parseErrors[0].Message)"
                }
                $profileBackup = $profilePath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff')
                Copy-Item -LiteralPath $profilePath -Destination $profileBackup -Force
                $utf8Bom = New-Object System.Text.UTF8Encoding($true)
                [System.IO.File]::WriteAllText($profilePath, $candidate, $utf8Bom)
                $profileChanged = $true
            }
        } catch {
            $profileError = $_.Exception.Message
        }
    }

    $backupsRemoved = 0
    if ($RemoveBackups -and -not [string]::IsNullOrWhiteSpace($profilePath)) {
        $profileDirectory = Split-Path -Parent $profilePath
        $profileLeaf = Split-Path -Leaf $profilePath
        if (-not [string]::IsNullOrWhiteSpace($profileDirectory) -and
            (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
            $backups = @(Get-ChildItem -LiteralPath $profileDirectory -Filter ($profileLeaf + '.bak-*') -File -ErrorAction SilentlyContinue)
            foreach ($backup in $backups) {
                try {
                    Remove-Item -LiteralPath $backup.FullName -Force -ErrorAction Stop
                    $backupsRemoved++
                } catch { }
            }
        }
    }

    # Remove the command and alias from the current session as well.
    try {
        $currentAlias = Get-Alias -Name ptui -ErrorAction SilentlyContinue
        if ($null -ne $currentAlias -and $currentAlias.Definition -eq 'premiere-tui') {
            Remove-Item -Path 'Alias:ptui' -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -Path 'Function:premiere-tui' -Force -ErrorAction SilentlyContinue
    } catch { }

    $succeeded = (($null -eq $installError) -and ($null -eq $configError) -and ($null -eq $profileError))
    Write-Host ''
    if ($succeeded) {
        Write-Host "  $($g.Check) premiere-tui uninstalled" -ForegroundColor ([ConsoleColor]::Green)
    } else {
        Write-Host "  $($g.Cross) premiere-tui uninstall finished with errors" -ForegroundColor ([ConsoleColor]::Yellow)
    }
    if ($installRemoved) {
        Write-Host "    Removed app:    $installDir" -ForegroundColor ([ConsoleColor]::DarkGray)
    } elseif ($null -ne $installError) {
        Write-Host "    App not removed: $installDir" -ForegroundColor ([ConsoleColor]::Yellow)
        Write-Host "      $installError" -ForegroundColor ([ConsoleColor]::DarkGray)
        Write-Host '      Close this PowerShell window and delete the folder manually.' -ForegroundColor ([ConsoleColor]::DarkGray)
    } else {
        Write-Host "    App not found:  $installDir" -ForegroundColor ([ConsoleColor]::DarkGray)
    }

    if ($configRemoved) {
        Write-Host "    Removed config: $configPath" -ForegroundColor ([ConsoleColor]::DarkGray)
    } elseif ($null -ne $configError) {
        Write-Host "    Config not removed: $configPath" -ForegroundColor ([ConsoleColor]::Yellow)
        Write-Host "      $configError" -ForegroundColor ([ConsoleColor]::DarkGray)
    } else {
        Write-Host "    Config not found: $configPath" -ForegroundColor ([ConsoleColor]::DarkGray)
    }

    if ($NoProfile) {
        Write-Host '    Profile: skipped (-NoProfile).' -ForegroundColor ([ConsoleColor]::DarkGray)
        Write-Host '      The profile block was left in place.' -ForegroundColor ([ConsoleColor]::DarkGray)
    } elseif ([string]::IsNullOrWhiteSpace($profilePath)) {
        Write-Host '    Profile: not detected.' -ForegroundColor ([ConsoleColor]::DarkGray)
    } elseif ($null -ne $profileError) {
        Write-Host "    Profile not updated: $profilePath" -ForegroundColor ([ConsoleColor]::Yellow)
        Write-Host "      $profileError" -ForegroundColor ([ConsoleColor]::DarkGray)
    } elseif ($profileChanged) {
        Write-Host "    Updated profile: $profilePath" -ForegroundColor ([ConsoleColor]::DarkGray)
        if ($null -ne $profileBackup) {
            Write-Host "    Backup: $profileBackup" -ForegroundColor ([ConsoleColor]::DarkGray)
        }
    } else {
        Write-Host "    Profile: nothing to remove ($profilePath)" -ForegroundColor ([ConsoleColor]::DarkGray)
    }

    if ($RemoveBackups) {
        Write-Host "    Removed profile backups: $backupsRemoved" -ForegroundColor ([ConsoleColor]::DarkGray)
    }

    Write-Host ''
    Write-Host '  Your Premiere projects were not touched.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host '  Restart PowerShell if the command is still available.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host ''

    return $succeeded
}

# =========================================================================
#  Validation
# =========================================================================

function Get-ProjectNameError {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return 'Project name cannot be empty.'
    }
    if ($Name.Length -gt 120) {
        return 'Project name can be at most 120 characters.'
    }
    if ($Name -match '[<>:"/\\|?*\x00-\x1F]') {
        return 'Name contains an invalid character: < > : " / \ | ? *'
    }
    if ($Name.EndsWith('.') -or $Name.EndsWith(' ')) {
        return 'Project name cannot end with a period or space.'
    }
    if ($Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') {
        return 'That name is reserved by Windows.'
    }

    return $null
}

function Get-EnvironmentError {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($TemplateFolder)) {
        return 'TemplateFolder is not configured.'
    }
    if ([string]::IsNullOrWhiteSpace($ProjectsParentFolder)) {
        return 'ProjectsParentFolder is not configured.'
    }
    if (-not (Test-Path -LiteralPath $TemplateFolder -PathType Container)) {
        return "Master template folder not found: $TemplateFolder"
    }

    $destination = Get-DestinationPath -Name $Name
    if (Test-Path -LiteralPath $destination) {
        return "A project folder already exists at: $destination"
    }

    if (-not (Test-Path -LiteralPath $ProjectsParentFolder -PathType Container)) {
        return "Projects parent folder not found: $ProjectsParentFolder"
    }

    return $null
}

function Get-PrerequisiteError {
    param([string]$Name)

    $environmentError = Get-EnvironmentError -Name $Name
    if ($null -ne $environmentError) {
        return $environmentError
    }

    $templateProjects = @(Get-ChildItem -LiteralPath $TemplateFolder -Recurse -Filter '*.prproj' -File -Force -ErrorAction SilentlyContinue)
    if ($templateProjects.Count -eq 0) {
        return "No .prproj file was found inside the master template: $TemplateFolder"
    }

    return $null
}

# =========================================================================
#  Project creation
# =========================================================================

function Set-PremiereProjectPaths {
    param([string]$ProjectFile)

    if ([string]::IsNullOrWhiteSpace($ProjectFile) -or -not (Test-Path -LiteralPath $ProjectFile -PathType Leaf)) {
        return
    }

    $tempPath = $ProjectFile + '.premiere-tui.tmp'
    try {
        $input = [System.IO.File]::OpenRead($ProjectFile)
        try {
            $gzip = New-Object System.IO.Compression.GZipStream($input, [System.IO.Compression.CompressionMode]::Decompress)
            try {
                $reader = New-Object System.IO.StreamReader($gzip, [System.Text.Encoding]::UTF8)
                try { $xml = $reader.ReadToEnd() } finally { $reader.Close() }
            } finally { $gzip.Close() }
        } finally { $input.Close() }

        if ([string]::IsNullOrWhiteSpace($xml) -or $xml -notmatch '<PremiereData') {
            return
        }

        $fullPath = [System.IO.Path]::GetFullPath($ProjectFile)
        $parentPath = [System.IO.Path]::GetDirectoryName($fullPath)
        if ([string]::IsNullOrWhiteSpace($parentPath)) {
            return
        }

        $encodedProject = [System.Security.SecurityElement]::Escape('\\?\' + $fullPath).Replace('$', '$$')
        $encodedParent = [System.Security.SecurityElement]::Escape($parentPath).Replace('$', '$$')

        $newXml = [regex]::Replace(
            $xml,
            '(?s)<project\.settings\.lastknowngoodprojectpath>.*?</project\.settings\.lastknowngoodprojectpath>',
            '<project.settings.lastknowngoodprojectpath>' + $encodedProject + '</project.settings.lastknowngoodprojectpath>'
        )
        $newXml = [regex]::Replace(
            $newXml,
            '(?s)<project\.settings\.lastknownparentdirectorypathaboveprojectpath>.*?</project\.settings\.lastknownparentdirectorypathaboveprojectpath>',
            '<project.settings.lastknownparentdirectorypathaboveprojectpath>' + $encodedParent + '</project.settings.lastknownparentdirectorypathaboveprojectpath>'
        )

        if ($newXml -eq $xml) {
            return
        }

        $output = [System.IO.File]::Create($tempPath)
        try {
            $gzipOut = New-Object System.IO.Compression.GZipStream($output, [System.IO.Compression.CompressionLevel]::Optimal)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($newXml)
                $gzipOut.Write($bytes, 0, $bytes.Length)
            } finally { $gzipOut.Close() }
        } finally { $output.Close() }

        # Verify the rewritten file before replacing the original.
        $verifyInput = [System.IO.File]::OpenRead($tempPath)
        try {
            $verifyGzip = New-Object System.IO.Compression.GZipStream($verifyInput, [System.IO.Compression.CompressionMode]::Decompress)
            try {
                $verifyReader = New-Object System.IO.StreamReader($verifyGzip, [System.Text.Encoding]::UTF8)
                try { $verify = $verifyReader.ReadToEnd() } finally { $verifyReader.Close() }
            } finally { $verifyGzip.Close() }
        } finally { $verifyInput.Close() }

        if ([string]::IsNullOrWhiteSpace($verify) -or $verify -notmatch '<PremiereData') {
            return
        }

        Move-Item -LiteralPath $tempPath -Destination $ProjectFile -Force -ErrorAction Stop
    } catch {
        # Path patching is best-effort; the copied project is still valid.
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            try { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function New-PremiereProject {
    param([string]$Name)

    $destination = Get-DestinationPath -Name $Name
    $createdDestination = $false

    try {
        New-Item -ItemType Directory -Path $destination -ErrorAction Stop | Out-Null
        $createdDestination = $true

        $templateItems = @(Get-ChildItem -LiteralPath $TemplateFolder -Force -ErrorAction Stop)
        if ($templateItems.Count -eq 0) {
            throw "The master template folder is empty: $TemplateFolder"
        }

        foreach ($item in $templateItems) {
            Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force -ErrorAction Stop
        }

        # .gitkeep files keep empty folders in git; they are not part of a project.
        $keepFiles = @(Get-ChildItem -LiteralPath $destination -Recurse -Filter '.gitkeep' -File -Force -ErrorAction SilentlyContinue)
        foreach ($keepFile in $keepFiles) {
            Remove-Item -LiteralPath $keepFile.FullName -Force -ErrorAction SilentlyContinue
        }

        $projectFiles = @(Get-ChildItem -LiteralPath $destination -Recurse -Filter '*.prproj' -File -Force -ErrorAction Stop)
        if ($projectFiles.Count -eq 0) {
            throw 'No .prproj file was copied from the master template.'
        }

        # Prefer Master_Template.prproj, then any configured preferred file.
        $projectFile = $null
        $preferredName = if ([string]::IsNullOrWhiteSpace($TemplateProjectFile)) {
            'Master_Template.prproj'
        } else {
            [System.IO.Path]::GetFileName($TemplateProjectFile)
        }
        if (-not [string]::IsNullOrWhiteSpace($preferredName)) {
            $projectFile = $projectFiles | Where-Object { $_.Name -eq $preferredName } | Select-Object -First 1
        }
        if ($null -eq $projectFile) {
            $projectFile = $projectFiles[0]
        }

        $targetProjectPath = Join-Path -Path $projectFile.Directory.FullName -ChildPath ($Name + '.prproj')
        if (-not [string]::Equals($projectFile.FullName, $targetProjectPath, [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $targetProjectPath) {
                throw "A project file with that name already exists: $targetProjectPath"
            }
            Move-Item -LiteralPath $projectFile.FullName -Destination $targetProjectPath -ErrorAction Stop
        }

        Set-PremiereProjectPaths -ProjectFile $targetProjectPath

        return [pscustomobject]@{
            Destination = $destination
            ProjectFile = $targetProjectPath
        }
    } catch {
        # The destination did not exist before this invocation, so it is safe
        # to roll back a partial copy and leave the Projects folder clean.
        if ($createdDestination -and (Test-Path -LiteralPath $destination)) {
            try {
                Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction Stop
            } catch {
                # Keep the original error; a failed rollback is reported below.
            }
        }
        throw
    }
}

# =========================================================================
#  Interactive prompt
# =========================================================================

function Read-ProjectNameInteractive {
    $text = ''
    $cursor = 0
    $errorText = ''

    $originalCursorVisible = $true
    $originalTitle = $null
    $originalForeground = [Console]::ForegroundColor
    $originalTreatControlCAsInput = $false
    $frameTop = -1
    $frameWidth = 0

    try {
        try { $originalCursorVisible = [Console]::CursorVisible } catch { }
        try {
            $originalTreatControlCAsInput = [Console]::TreatControlCAsInput
            [Console]::TreatControlCAsInput = $true
        } catch { }
        try {
            $originalTitle = $Host.UI.RawUI.WindowTitle
            $Host.UI.RawUI.WindowTitle = 'premiere-tui'
        } catch { }
        try { [Console]::CursorVisible = $false } catch { }

        while ($true) {
            $frame = New-TuiFrame -Text $text -Cursor $cursor -ErrorMessage $errorText
            $frameRows = @($frame.Lines).Count

            # Redraw the frame where it already is, so the prompt keeps its
            # place in the scrollback instead of taking over the screen.
            if ($frameTop -ge 0) {
                if ($frame.Width -ne $frameWidth) {
                    Clear-InlineFrame -Top $frameTop -Rows $frameRows -Width $frameWidth
                    $frameTop = -1
                } else {
                    try {
                        [Console]::SetCursorPosition(0, $frameTop)
                    } catch {
                        $frameTop = -1
                    }
                }
            }

            Write-InlineFrame -Frame $frame

            $afterRow = Get-CursorRow
            if ($afterRow -ge 0) {
                $frameTop = $afterRow - $frameRows
            }
            $frameWidth = $frame.Width

            $key = [Console]::ReadKey($true)
            $isControl = (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)

            if ($key.Key -eq [ConsoleKey]::Escape) {
                return $null
            }

            if ($isControl) {
                if ($key.Key -eq [ConsoleKey]::C) {
                    return $null
                }
                if ($key.Key -eq [ConsoleKey]::U) {
                    $text = ''
                    $cursor = 0
                    $errorText = ''
                } elseif ($key.Key -eq [ConsoleKey]::A) {
                    $cursor = 0
                } elseif ($key.Key -eq [ConsoleKey]::E) {
                    $cursor = $text.Length
                }
                continue
            }

            if ($key.Key -eq [ConsoleKey]::Enter) {
                $candidate = $text.Trim()
                $nameError = Get-ProjectNameError -Name $candidate
                if ($null -ne $nameError) {
                    $errorText = $nameError
                    continue
                }

                $prerequisiteError = Get-PrerequisiteError -Name $candidate
                if ($null -ne $prerequisiteError) {
                    $errorText = $prerequisiteError
                    continue
                }

                return $candidate
            }

            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($cursor -gt 0) {
                    $text = $text.Remove($cursor - 1, 1)
                    $cursor--
                    $errorText = ''
                }
            } elseif ($key.Key -eq [ConsoleKey]::Delete) {
                if ($cursor -lt $text.Length) {
                    $text = $text.Remove($cursor, 1)
                    $errorText = ''
                }
            } elseif ($key.Key -eq [ConsoleKey]::LeftArrow) {
                if ($cursor -gt 0) {
                    $cursor--
                }
            } elseif ($key.Key -eq [ConsoleKey]::RightArrow) {
                if ($cursor -lt $text.Length) {
                    $cursor++
                }
            } elseif ($key.Key -eq [ConsoleKey]::Home) {
                $cursor = 0
            } elseif ($key.Key -eq [ConsoleKey]::End) {
                $cursor = $text.Length
            } else {
                $character = $key.KeyChar
                if ($character -ne [char]::MinValue -and -not [char]::IsControl($character)) {
                    if ($text.Length -ge 120) {
                        $errorText = 'Project name can be at most 120 characters.'
                    } else {
                        $text = $text.Insert($cursor, [string]$character)
                        $cursor++
                        $errorText = ''
                    }
                }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $originalCursorVisible } catch { }
        try { [Console]::ForegroundColor = $originalForeground } catch { }
        try { [Console]::TreatControlCAsInput = $originalTreatControlCAsInput } catch { }
        try {
            if (-not [string]::IsNullOrEmpty($originalTitle)) {
                $Host.UI.RawUI.WindowTitle = $originalTitle
            }
        } catch { }
    }
}

function Read-ProjectName {
    if (-not $script:IsInteractive -or -not (Test-ConsoleCursor)) {
        Write-Host ''
        Write-Host '  Enter project name:' -ForegroundColor ([ConsoleColor]::White)
        Write-Host '  > ' -NoNewline -ForegroundColor ([ConsoleColor]::Cyan)
        $value = Read-Host
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $null
        }
        return $value.Trim()
    }

    return Read-ProjectNameInteractive
}

# =========================================================================
#  CLI text
# =========================================================================

function Show-Usage {
    $g = $script:Glyphs
    $config = Read-Config
    $effective = Get-EffectiveConfig -Config $config
    $template = Resolve-TemplateFolder -ConfiguredFolder $effective.templateFolder
    $templateDisplay = if ([string]::IsNullOrWhiteSpace($effective.templateFolder)) {
        $template + ' (bundled)'
    } else {
        $template
    }
    $master = Get-TemplateProjectPath -TemplateFolder $template -PreferredFile $effective.templateProjectFile
    if ($null -eq $master) {
        $master = '(none found)'
    }
    $configPath = Get-ConfigPath

    Write-Host ''
    Write-Host '  premiere-tui' -ForegroundColor ([ConsoleColor]::Cyan)
    Write-Host '  Create a new Premiere Pro project from your master template.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host ''
    Write-Host '  Usage:' -ForegroundColor ([ConsoleColor]::White)
    Write-Host '    premiere-tui                          Ask for the project name.' -ForegroundColor ([ConsoleColor]::Gray)
    Write-Host '    premiere-tui "My project"             Create a project right away.' -ForegroundColor ([ConsoleColor]::Gray)
    Write-Host '    premiere-tui new-project "My project" The same, spelled out.' -ForegroundColor ([ConsoleColor]::Gray)
    Write-Host '    premiere-tui config                   Show the current settings.' -ForegroundColor ([ConsoleColor]::Gray)
    Write-Host '    premiere-tui config setup             Change the settings.' -ForegroundColor ([ConsoleColor]::Gray)
    Write-Host '    premiere-tui uninstall                Remove the app, config and profile entry.' -ForegroundColor ([ConsoleColor]::Gray)
    Write-Host '    premiere-tui help                     Show this help.' -ForegroundColor ([ConsoleColor]::Gray)
    Write-Host ''
    Write-Host '  Options:' -ForegroundColor ([ConsoleColor]::White)
    Write-Host '    -Help                        Show this help.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host '    -Ascii                       Use plain ASCII borders instead of Unicode.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host '    -NoLaunch                    Create the project without opening Premiere.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host '    -ConfigPath                  Use another config file.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host '    -TemplateFolder              Use another template folder for this run.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host '    -TemplateProjectFile         Use another .prproj inside the template.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host '    -ProjectsParentFolder        Put new project folders somewhere else for this run.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host ''
    Write-Host '  Uninstall options:' -ForegroundColor ([ConsoleColor]::White)
    Write-Host '    -Force           Skip the confirmation prompt.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host '    -NoProfile       Leave the PowerShell profile alone.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host '    -RemoveBackups   Delete profile backups made by the installer.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host '    -InstallDir      Folder to remove. Default %LOCALAPPDATA%\premiere-tui.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host '    -ProfilePath     Profile to clean. Default $PROFILE.' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host ''
    Write-Host '  Configuration:' -ForegroundColor ([ConsoleColor]::White)
    Write-Host "    Config:    $configPath" -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host "    Template:  $templateDisplay" -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host "    Master:    $master" -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host "    Projects:  $($effective.projectsParentFolder)" -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host ''
    Write-Host "  $($g.Bullet) Run 'premiere-tui config setup' to change these settings." -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host "  $($g.Bullet) After install, 'ptui' is an alias for 'premiere-tui'." -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host ''
}

function Write-ErrorMessage {
    param([string]$Message)

    $g = $script:Glyphs
    Write-Host ''
    Write-Host "  $($g.Cross) $Message" -ForegroundColor ([ConsoleColor]::Red)
    Write-Host ''
}

# =========================================================================
#  Main
# =========================================================================

if ([string]::IsNullOrWhiteSpace($ProjectName) -and $CommandOrName -eq 'help') {
    Show-Usage
    exit 0
}

# -------------------------------------------------------------------------
#  flags
# -------------------------------------------------------------------------
# -Help is the only help flag and the only way to spell it. Everything the
# binder did not recognize is reported here with the correct spelling.
$helpRequested = $false
$unknownOptions = @()
foreach ($item in @($args)) {
    if ([string]::IsNullOrWhiteSpace($item)) {
        continue
    }
    if ($item -eq '-Help') {
        $helpRequested = $true
    } else {
        $unknownOptions += $item
    }
}

if ($helpRequested) {
    Show-Usage
    exit 0
}

if ($unknownOptions.Count -gt 0) {
    Write-ErrorMessage "Unknown option '$($unknownOptions[0])'. Use: premiere-tui -Help for the list of flags."
    exit 2
}

if ($CommandOrName -eq '/?') {
    Write-ErrorMessage "'/?' is not a flag of this app. Use: premiere-tui -Help"
    exit 2
}

# -------------------------------------------------------------------------
#  config command
# -------------------------------------------------------------------------
if ($CommandOrName -eq 'config') {
    $configAction = 'show'
    if (-not [string]::IsNullOrWhiteSpace($ProjectName)) {
        if ($ProjectName -eq 'setup') {
            $configAction = 'setup'
        } else {
            Write-ErrorMessage "Unknown config action '$ProjectName'. Use: .\$($script:ScriptName) config setup"
            exit 2
        }
    }
    Invoke-ConfigCommand -Action $configAction
    if (-not [string]::IsNullOrWhiteSpace([string]$script:ConfigCommandError)) {
        exit 1
    }
    exit 0
}

# -------------------------------------------------------------------------
#  uninstall command
# -------------------------------------------------------------------------
if ($CommandOrName -eq 'uninstall') {
    if (-not [string]::IsNullOrWhiteSpace($ProjectName)) {
        Write-ErrorMessage "Unexpected argument for uninstall: $ProjectName"
        exit 2
    }
    if (-not (Invoke-UninstallCommand)) {
        exit 1
    }
    exit 0
}

# -------------------------------------------------------------------------
#  config loading / first run
# -------------------------------------------------------------------------
$configPath = Get-ConfigPath
$configExists = Test-Path -LiteralPath $configPath -PathType Leaf
$config = Read-Config

if ($null -eq $config) {
    if ($configExists) {
        Write-ErrorMessage "Could not read config: $configPath"
        Write-Host "  Fix or remove it, then run: .\$($script:ScriptName) config setup" -ForegroundColor ([ConsoleColor]::DarkGray)
        Write-Host ''
        exit 1
    }

    $config = New-DefaultConfig
    $wroteConfig = $false
    if (-not [string]::IsNullOrWhiteSpace($config.projectsParentFolder)) {
        try {
            if (-not (Test-Path -LiteralPath $config.projectsParentFolder -PathType Container)) {
                New-Item -ItemType Directory -Path $config.projectsParentFolder -Force -ErrorAction Stop | Out-Null
            }
            Save-Config -Config $config | Out-Null
            $wroteConfig = $true
        } catch {
            $wroteConfig = $false
        }
    }

    if (-not $wroteConfig) {
        if ($script:IsInteractive) {
            $setupConfig = Get-EffectiveConfig -Config $config
            $savedConfig = Read-ConfigInteractive -Config $setupConfig
            if ($null -eq $savedConfig) {
                Write-Host ''
                Write-Host '  Cancelled.' -ForegroundColor ([ConsoleColor]::DarkGray)
                Write-Host ''
                exit 0
            }
            $config = $savedConfig
        } else {
            Write-ErrorMessage "Could not create the config file: $configPath"
            exit 1
        }
    }
}

$effective = Get-EffectiveConfig -Config $config
$projectsOverrideProvided = -not [string]::IsNullOrWhiteSpace($ProjectsParentFolder)

# One-run overrides win over config values.
if ([string]::IsNullOrWhiteSpace($TemplateFolder)) {
    $TemplateFolder = Resolve-TemplateFolder -ConfiguredFolder $effective.templateFolder
}
if ([string]::IsNullOrWhiteSpace($TemplateProjectFile)) {
    $TemplateProjectFile = $effective.templateProjectFile
}
if ([string]::IsNullOrWhiteSpace($ProjectsParentFolder)) {
    $ProjectsParentFolder = $effective.projectsParentFolder
}

# A one-run projects folder override is allowed to create the folder.
if ($projectsOverrideProvided -and -not (Test-Path -LiteralPath $ProjectsParentFolder -PathType Container)) {
    try {
        New-Item -ItemType Directory -Path $ProjectsParentFolder -Force -ErrorAction Stop | Out-Null
    } catch {
        # Validation below reports the missing folder.
    }
}

$validationConfig = [pscustomobject]@{
    templateFolder       = $TemplateFolder
    templateProjectFile  = $TemplateProjectFile
    projectsParentFolder = $ProjectsParentFolder
}
$configError = Get-ConfigError -Config $validationConfig
if ($null -ne $configError) {
    Write-ErrorMessage $configError
    Write-Host "  Run: .\$($script:ScriptName) config setup" -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host ''
    exit 1
}

# -------------------------------------------------------------------------
#  project name
# -------------------------------------------------------------------------
$projectNameFromCli = $null

# Spellings that used to be commands. They are refused here so a typo never
# turns into a project with a strange name.
$retiredCommands = @{
    'setup' = "premiere-tui config setup"
    'new'   = "premiere-tui new-project 'name'"
    'edit'  = "premiere-tui config setup"
}

if (-not [string]::IsNullOrWhiteSpace($ProjectName)) {
    if (-not [string]::IsNullOrWhiteSpace($CommandOrName) -and $CommandOrName -ne 'new-project') {
        Write-ErrorMessage "Unknown command '$CommandOrName'. Use: .\$($script:ScriptName) new-project 'name'"
        exit 2
    }
    $projectNameFromCli = $ProjectName
} elseif (-not [string]::IsNullOrWhiteSpace($CommandOrName)) {
    if ($CommandOrName -eq 'new-project') {
        $projectNameFromCli = $null
    } elseif ($retiredCommands.ContainsKey($CommandOrName.ToLowerInvariant())) {
        Write-ErrorMessage "'$CommandOrName' is not a command of this app. Use: $($retiredCommands[$CommandOrName.ToLowerInvariant()])"
        exit 2
    } elseif ($CommandOrName.StartsWith('-')) {
        Write-ErrorMessage "Unknown option '$CommandOrName'."
        exit 2
    } else {
        $projectNameFromCli = $CommandOrName
    }
}

if ([string]::IsNullOrWhiteSpace($projectNameFromCli)) {
    $projectNameFromCli = Read-ProjectName
    if ($null -eq $projectNameFromCli) {
        Write-Host ''
        Write-Host '  Cancelled.' -ForegroundColor ([ConsoleColor]::DarkGray)
        Write-Host ''
        exit 0
    }
}

$projectName = $projectNameFromCli.Trim()
$g = $script:Glyphs

$nameError = Get-ProjectNameError -Name $projectName
if ($null -ne $nameError) {
    Write-ErrorMessage $nameError
    exit 1
}

$prerequisiteError = Get-PrerequisiteError -Name $projectName
if ($null -ne $prerequisiteError) {
    Write-ErrorMessage $prerequisiteError
    if (-not (Test-Path -LiteralPath $TemplateFolder -PathType Container)) {
        Write-Host "  Run: .\$($script:ScriptName) config setup" -ForegroundColor ([ConsoleColor]::DarkGray)
    } elseif (-not (Test-Path -LiteralPath $ProjectsParentFolder -PathType Container)) {
        Write-Host "  Run: .\$($script:ScriptName) config setup" -ForegroundColor ([ConsoleColor]::DarkGray)
    }
    Write-Host ''
    exit 1
}

try {
    $result = New-PremiereProject -Name $projectName
} catch {
    Write-ErrorMessage "Could not create the project: $($_.Exception.Message)"
    exit 1
}

Write-Host ''
Write-Host "  $($g.Check) Project created" -ForegroundColor ([ConsoleColor]::Green)
Write-Host "    Folder:  $($result.Destination)" -ForegroundColor ([ConsoleColor]::DarkGray)
Write-Host "    Project: $($result.ProjectFile)" -ForegroundColor ([ConsoleColor]::DarkGray)

if ($NoLaunch) {
    Write-Host '    Premiere launch skipped (-NoLaunch).' -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host ''
    exit 0
}

try {
    if (-not (Test-Path -LiteralPath $result.ProjectFile -PathType Leaf)) {
        throw "Project file not found: $($result.ProjectFile)"
    }

    # Non-blocking: open the .prproj with its registered handler (Premiere).
    # This is the same as double-clicking the project file.
    Start-Process -FilePath $result.ProjectFile -WorkingDirectory (Split-Path -Parent $result.ProjectFile) -ErrorAction Stop | Out-Null
    Write-Host "  $($g.Arrow) Opening in Adobe Premiere Pro..." -ForegroundColor ([ConsoleColor]::DarkGray)
    Write-Host ''
} catch {
    Write-ErrorMessage "Project created, but Premiere could not be opened: $($_.Exception.Message)"
    exit 1
}

exit 0
