# AGENTS.md

Windows-only PowerShell 5.1 app for creating Adobe Premiere Pro projects from a template.
`premiere.ps1` is the whole app (CLI, TUI, config, project creation, path patching, uninstall).
`install.ps1` is the installer. `template/` is the bundled starter. No build system, tests, or CI.
The installed command is `premiere-tui`; `ptui` is a profile alias for it.

## Critical constraints

- Keep `premiere.ps1` and `install.ps1` pure ASCII (0 bytes > 127). TUI glyphs are built with `[string][char]0x...`; `-Ascii` selects the plain fallback. Do not paste box-drawing characters or emoji into `.ps1` files.
- Stay compatible with Windows PowerShell 5.1 (`#Requires -Version 5.1`). Do not add PS7-only syntax.
- Keep the outer `& { ... } -Ref ... -InstallDir ...` wrapper in `install.ps1`. The documented install is `iex (irm ...)`; without the child scope, `Set-StrictMode`, preferences, helper functions, and `return`/`exit` leak into or close the user's session.
- `premiere.ps1` uses `exit` and is meant to be invoked as a file/function (`& path`). Do not document or use `iex (irm .../premiere.ps1)`; only `install.ps1` is `iex`-safe.
- `.gitattributes` forces CRLF for `*.ps1` and binary for `*.prproj`. Git's "LF will be replaced by CRLF" warnings are expected; do not change the attributes.
- `template/01_Project Files/Master_Template.prproj` is a sanitized, gzip-compressed XML project with no personal paths. Decompress it to inspect; never commit a real user project or personal paths. Keep `template/**/.gitkeep` (it preserves empty folders).

## Verify

There is no test runner, linter, or CI. Run from the repo root with `powershell.exe` (and `pwsh` if available).

```powershell
# Parse both scripts
foreach ($f in 'premiere.ps1','install.ps1') {
    $e = $null; $t = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$t, [ref]$e) | Out-Null
    if ($e) { $e | ForEach-Object Message } else { "$f parse OK" }
}

# Must print 0 for both files
foreach ($f in 'premiere.ps1','install.ps1') {
    "$f non-ASCII bytes: " + (([IO.File]::ReadAllBytes((Resolve-Path $f))) | Where-Object { $_ -gt 127 }).Count
}

# Project smoke test: temp config/projects, never launches Premiere
$root = Join-Path $env:TEMP ('ptui-test-' + [guid]::NewGuid().ToString('N'))
.\premiere.ps1 -ConfigPath "$root\config.json" -ProjectsParentFolder "$root\Projects" -NoLaunch 'Smoke Test'
Test-Path "$root\Projects\Smoke Test\01_Project Files\Smoke Test.prproj"   # True

# Installer without touching the real profile; re-run to check idempotency
.\install.ps1 -SourcePath . -InstallDir "$root\app" -ProfilePath "$root\profile.ps1"
Get-Content "$root\profile.ps1" -Raw   # exactly one marked block, includes ptui alias
.\install.ps1 -SourcePath . -InstallDir "$root\app" -ProfilePath "$root\profile.ps1"

# Uninstall against temp targets; -Force is required when non-interactive
.\premiere.ps1 uninstall -Force -NoProfile -InstallDir "$root\app" -ConfigPath "$root\config.json"
```

- Always use `-NoLaunch` in automation. GUI launch and `.prproj` file association cannot be verified headlessly; the project is still created if launch fails.
- Non-interactive `config setup` without overrides only prints guidance. Pass `-TemplateFolder`/`-ProjectsParentFolder`, or run the TUI in a real terminal.
- Never point tests at the real `$PROFILE`, `%APPDATA%\premiere-tui`, or Premiere projects folder. Use `-ProfilePath`, `-ConfigPath`, and `-InstallDir` temp paths.
- `-NoProfile` skips profile cleanup. To test marked-block removal, omit it and add `-ProfilePath "$root\profile.ps1"`; that also removes the command/alias from the current session.

## Wiring and invariants

- Config path: `%APPDATA%\premiere-tui\config.json` (`-ConfigPath` overrides). Fields: `version`, `templateFolder`, `templateProjectFile`, `projectsParentFolder`. Empty `templateFolder` means the bundled `<script root>\template`; `Save-ConfigFromValues` normalizes the bundled path back to `""`.
- Adding a config field means updating `New-DefaultConfig`, `Read-Config`, `Get-EffectiveConfig`, `Save-ConfigFromValues`, and the README table; if it is editable in the TUI, also `New-ConfigFrame` and `Read-ConfigInteractive`. `Save-ConfigFromValues` expects the TUI values positionally as `[templateFolder, projectsParentFolder]`.
- First run creates the config from `Documents\Adobe\Premiere Pro\<version>\Projects`. If that folder cannot be created, it opens the config TUI when interactive and exits when not.
- `New-PremiereProject`: copy template -> delete copied `.gitkeep` files -> select the configured preferred `.prproj` (default `Master_Template.prproj`) -> rename to `<project name>.prproj` -> patch paths -> launch. If a later step fails, the destination created by this run is rolled back.
- Project names: max 120 chars; reject `< > : " / \ | ? *`, control chars, trailing dot/space, and Windows reserved device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9). Never overwrite an existing project folder.
- `Set-PremiereProjectPaths` is best-effort: it decompresses the gzip XML, rewrites only `project.settings.lastknowngoodprojectpath` and `project.settings.lastknownparentdirectorypathaboveprojectpath` (with a `\\?\` prefix), verifies the new gzip, then replaces the file. It does not rewrite media paths; failures are swallowed so creation still succeeds.
- The TUI uses raw `[Console]::ReadKey($true)` and temporarily changes `TreatControlCAsInput`, cursor visibility, and foreground color. Restore them in `finally`. `$script:IsInteractive` is false when stdin/stdout is redirected. The project-name prompt is inline: it is drawn at the current cursor position and redrawn in place, it never calls `Clear-Host`, and it falls back to `Read-Host` when the console cannot report the cursor row (`Test-ConsoleCursor`). The config screen is still a full-screen form.
- Installer: copies `premiere.ps1`, `template/`, `README.md`, and `LICENSE` to `%LOCALAPPDATA%\premiere-tui`; downloads `https://github.com/zakagain/premiere-tui/archive/$Ref.zip` unless `-SourcePath` is given.
- Profile block markers: `# >>> premiere-tui >>>` / `# <<< premiere-tui <<<`. The installer removes prior marked blocks, the legacy unmarked `function premiere-tui`, and a legacy `ptui` alias, backs up the profile, writes UTF-8 with BOM, and adds the function plus `ptui` alias. Uninstall mirrors this. The removal must never touch content that is not ours: the marked block is matched with a tempered dot so it cannot span a second start marker, the legacy function is closed by counting braces instead of by a regex, and a rewritten profile is parsed before it is written. Change the block format in both scripts and the README together.
- Uninstall safety is deliberate: confirmation unless `-Force`; `-Force` required non-interactively; always refuses a git repo (never waived by `-Force`); always refuses drive roots, the user profile, AppData, Program Files, Windows, and an install folder that is an ancestor of the running script. The exact-match protected folders (drive root, `%USERPROFILE%`, `%LOCALAPPDATA%`, `%APPDATA%`, Program Files, Windows) are refused, and anything under the user profile or a system folder is refused too, except paths under `%LOCALAPPDATA%`/`%APPDATA%` where the app itself lives. `-NoProfile` leaves the profile block; `-RemoveBackups` deletes `profile.ps1.bak-*`; user projects are never touched.
- Exit codes: 0 success; 1 runtime/config error or uninstall cancellation/refusal; 2 bad arguments. `premiere.ps1` signals this with `exit`. `install.ps1` must never call `exit`: it runs inside `iex (irm ...)`, where `exit` closes the user's session. It reports failure with `$global:LASTEXITCODE = 1` instead.
- CLI changes need updates in three places: comment-based help, `Show-Usage`, and `README.md`. Subcommands are matched before the project-name fallback; add new ones before `$projectNameFromCli` is resolved.
- Flags are standardized: one dash, then the name, for example `-NoLaunch`. There is exactly one help flag, `-Help`; `-h`, `--help` and `/?` are not accepted. `-Help` is not a real parameter, it is matched by hand out of `$Remaining` so the PowerShell binder cannot accept a short form of it. The commands are `new-project`, `config`, `config setup`, `uninstall` and `help`; the old spellings `new`, `setup` and `config edit` are refused with a pointer to the current one.

## Repo notes

- Remote: `https://github.com/zakagain/premiere-tui.git`. The install one-liner and zip URL assume `main` and `zakagain/premiere-tui`; if the repo moves, update `install.ps1` (`$repoOwner`, `$repoName`) and the README together.
- No package manifest, lockfile, CI, linter, or test runner. Do not invent npm/pip/pytest commands.
- `.gitignore` ignores `config.json`, logs, and Premiere auto-save/backup files. Test configs belong in `%TEMP%`.
- This machine may already have a real config in `%APPDATA%\premiere-tui` and an old unmarked `premiere-tui` function in the real profile. Both install and uninstall are designed to migrate/remove that function; do not edit `$PROFILE` manually during tests.
