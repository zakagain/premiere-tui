# premiere-tui

Create a new Adobe Premiere Pro project from a master template without leaving the terminal.

`premiere-tui` copies your template folder, renames the project file, updates its internal paths, and opens the finished project in Premiere Pro. It ships with a bundled starter template, but you can point it at any template folder you like.

```
╭──────────────────────────────────────────────────────────────────────────╮
│  premiere-tui                                                            │
│                                                                          │
│  Enter project name:                                                     │
│  ❯ My amazing Premiere project▌                                          │
│  ──────────────────────────────────────────────────────────────────────  │
│                                                                          │
│  → C:\Users\you\Documents\Adobe\Premiere Pro\26.0\Projects\My amazing…   │
╰──────────────────────────────────────────────────────────────────────────╯
  enter to create • esc to quit
```

## Features

- Interactive project-name prompt with a path preview.
- One command creates the folder, copies the template, renames the `.prproj`, and opens it.
- Bundled template works out of the box.
- Custom template folder and projects folder.
- A proper config screen: `premiere-tui config setup`.
- Clean uninstall: `premiere-tui uninstall`.
- `ptui` alias for `premiere-tui`.
- Per-run overrides for scripts and testing.
- Does not need to know where Premiere is installed; it opens the `.prproj` with its registered handler.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 or PowerShell 7+
- Adobe Premiere Pro installed and associated with `.prproj` files

## Install

Run this in PowerShell:

```powershell
iex (irm https://raw.githubusercontent.com/zakagain/premiere-tui/main/install.ps1)
```

The installer:

1. Downloads the repository.
2. Copies the app and bundled template to `%LOCALAPPDATA%\premiere-tui`.
3. Adds a `premiere-tui` function and the `ptui` alias to your PowerShell profile.
4. Backs up your profile first.

Restart PowerShell when it finishes, then run `premiere-tui` or `ptui`.

> The installer updates the profile for the shell you run it in. If you use both Windows PowerShell and PowerShell 7, run it in the one you use for Premiere projects, or run it in both.

## First run

```powershell
premiere-tui
```

On the first run, `premiere-tui` creates:

```
%APPDATA%\premiere-tui\config.json
```

It uses the bundled template and tries to detect your Premiere Pro projects folder (for example `Documents\Adobe\Premiere Pro\26.0\Projects`). If it cannot find one, it opens the config screen so you can choose.

## Usage

```powershell
premiere-tui                              # interactive name prompt
ptui                                      # same thing (alias)
premiere-tui "My project"                 # create directly
premiere-tui new-project "My project"     # same, explicit
premiere-tui config setup                 # edit settings in the config TUI
premiere-tui config                       # print current settings
premiere-tui uninstall                    # remove the app, config, and profile entry
premiere-tui -NoLaunch "Test"             # create without opening Premiere
premiere-tui -Ascii                       # use ASCII borders
premiere-tui -Help
```

Project names are validated before anything is copied. A project folder is never overwritten.

## Configuration

Settings live in:

```
%APPDATA%\premiere-tui\config.json
```

Example:

```json
{
  "version": 1,
  "templateFolder": "",
  "templateProjectFile": "Master_Template.prproj",
  "projectsParentFolder": "C:\\Users\\you\\Documents\\Adobe\\Premiere Pro\\26.0\\Projects"
}
```

| Field | Meaning |
| --- | --- |
| `templateFolder` | Folder copied for each new project. Leave empty to use the bundled template. |
| `templateProjectFile` | Preferred `.prproj` inside the template. If empty, `Master_Template.prproj` is preferred, then the first `.prproj` found. |
| `projectsParentFolder` | New project folders are created here. |

### Config screen

```powershell
premiere-tui config setup
```

```
╭──────────────────────────────────────────────────────────────────────────╮
│  premiere-tui config                                                     │
│                                                                          │
│  Template folder                                                         │
│  ❯ (bundled) C:\Users\you\AppData\Local\premiere-tui\template            │
│    Leave empty to use the bundled template.                              │
│                                                                          │
│  Projects folder                                                         │
│    C:\Users\you\Documents\Adobe\Premiere Pro\26.0\Projects               │
│    New project folders are created here.                                 │
│                                                                          │
│  Config: …\AppData\Roaming\premiere-tui\config.json                      │
│                                                                          │
│  ↑↓ select • enter edit • ctrl+s save • esc cancel                       │
╰──────────────────────────────────────────────────────────────────────────╯
```

- `↑` / `↓` select a field
- `Enter` edit
- `Ctrl+S` save
- `Esc` cancel

The projects folder is created if it does not exist. The template folder must exist and contain at least one `.prproj`.

You can also set both paths without opening the TUI:

```powershell
premiere-tui config setup -TemplateFolder "D:\Templates\Master" -ProjectsParentFolder "D:\Projects"
```

In an interactive terminal, those overrides pre-fill the config screen.

## Bundled template

The repository includes a starter template:

```
template/
  01_Project Files/
    Master_Template.prproj
  02_Footage/
  03_Audio/
  04_Exports/
```

When a project is created:

- The whole template folder is copied to `<projectsParentFolder>\<project name>`.
- The preferred `.prproj` is renamed to `<project name>.prproj`.
- `.gitkeep` placeholder files are removed.
- The `.prproj`'s internal recent-path settings are updated to the new location.

To use your own template, set `templateFolder` to it in `premiere-tui config setup`. A custom template can contain any folder structure; it just needs at least one `.prproj`.

## How it works

1. Loads `config.json` (or creates it with sensible defaults).
2. Uses the configured template, or the bundled one.
3. Prompts for a project name unless you supplied one.
4. Copies the template into the projects folder.
5. Renames the preferred `.prproj`.
6. Opens the `.prproj` with its registered handler, which is Adobe Premiere Pro.

No Premiere installation path is stored or required.

## Troubleshooting

### `premiere-tui` or `ptui` is not recognized

Restart PowerShell, then check:

```powershell
$PROFILE
Get-Command premiere-tui
Get-Alias ptui
```

If the command is missing, re-run the installer or add this to your profile manually:

```powershell
function premiere-tui {
    & "$env:LOCALAPPDATA\premiere-tui\premiere.ps1" @args
}
Set-Alias -Name ptui -Value premiere-tui -Scope Global -Force
```

### Premiere does not open the project

The project is still created. Open the `.prproj` manually, or check the file association:

1. Right-click a `.prproj` file.
2. Choose **Open with**.
3. Select Adobe Premiere Pro and enable **Always use this app**.

### Template not found

Run:

```powershell
premiere-tui config setup
```

Either keep the template field empty to use the bundled template, or choose a folder that contains a `.prproj`.

### Projects folder not found

Run `premiere-tui config setup` and save; the folder is created for you.

### The config file is broken

Delete it and run `premiere-tui` again:

```powershell
Remove-Item "$env:APPDATA\premiere-tui\config.json"
premiere-tui
```

Or run `premiere-tui config setup`.

### Very long project paths

Enable Windows long paths if you use very long names:

```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1
```

This requires an elevated PowerShell and a restart.

## Uninstall

```powershell
premiere-tui uninstall
```

It removes:

- the app in `%LOCALAPPDATA%\premiere-tui`
- the config in `%APPDATA%\premiere-tui`
- the `premiere-tui` function and `ptui` alias from your PowerShell profile
- the command and alias from the current session

Your Premiere projects are not touched.

Options:

```powershell
premiere-tui uninstall -Force           # skip the confirmation
premiere-tui uninstall -NoProfile       # leave the PowerShell profile alone
premiere-tui uninstall -RemoveBackups   # also delete profile.ps1.bak-* files
```

`-NoProfile` leaves the `# >>> premiere-tui >>>` block in your profile, so remove it yourself if you delete the app. Profile backups are kept by default. Running the uninstall from the source checkout only removes the installed copy in `%LOCALAPPDATA%`; the checkout itself stays.

`-InstallDir`, `-ProfilePath`, and `-ConfigPath` override the uninstall targets; they are mainly useful for testing.

If the command is already gone, remove the folders manually and delete the `# >>> premiere-tui >>>` block from your profile (`$PROFILE`):

```powershell
Remove-Item "$env:LOCALAPPDATA\premiere-tui" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:APPDATA\premiere-tui" -Recurse -Force -ErrorAction SilentlyContinue
```

## Development

Run the script directly from the repository:

```powershell
.\premiere.ps1 -NoLaunch "Test project"
```

Test the installer without touching your real profile:

```powershell
.\install.ps1 -SourcePath . -InstallDir "$env:TEMP\premiere-tui-test" -NoProfile
```

Use a temporary config and projects folder:

```powershell
.\premiere.ps1 `
    -ConfigPath "$env:TEMP\premiere-tui-test\config.json" `
    -ProjectsParentFolder "$env:TEMP\premiere-tui-test\Projects" `
    -NoLaunch "Test project"
```

Test the uninstall against temporary paths:

```powershell
.\premiere.ps1 uninstall -Force -NoProfile `
    -InstallDir "$env:TEMP\premiere-tui-test" `
    -ConfigPath "$env:TEMP\premiere-tui-test\config.json"
```

`premiere.ps1` is intentionally ASCII-only so Windows PowerShell 5.1 reads it correctly. The TUI glyphs are created at runtime from character codes.

## License

MIT. See [LICENSE](LICENSE).
