# AZ-2007 lab environment setup

One script per OS that installs and verifies everything the AZ-2007 labs need
([MicrosoftLearning/mslearn-github-copilot-dev](https://github.com/MicrosoftLearning/mslearn-github-copilot-dev), LAB_AK_00 to LAB_AK_16).
Re-runnable: installed tools are skipped or upgraded, and every run ends with a pass/fail table.

## Run it

### Windows (recommended: the labs are written for Windows)

Open **Windows PowerShell as administrator** under your own account (not PowerShell 7: the script installs or upgrades it), then:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
cd <folder containing this README>
.\setup-windows.ps1
```

Options: `-CheckOnly` (verify only, no admin), `-SkipLocalDB`, `-SkipSmokeTest`.

### macOS

Needs [Homebrew](https://brew.sh). Asks for your password for the .NET installers.

```bash
./setup-macos.sh
```

Options: `--check-only`, `--skip-smoke-test`.

## What gets installed

| Tool | Why | Labs |
|---|---|---|
| Git ≥ 2.48 | cloning lab repos | all |
| VS Code ≥ 1.116 + **C# Dev Kit** + **Python** extension | IDE (Copilot Chat is built in) | all |
| **.NET 9 SDK** | starter code targets `net9.0` | 01–12 |
| **.NET 8 SDK** | starter apps target `net8.0` (not in the PDF, see below) | 13–16 |
| nuget.org package source | NuGet restore | all C# |
| Python 3.13 + pytest | Python track | 01–05 `_py` |
| uv + Specify CLI | GitHub Spec Kit | 00 Spec Kit, 13, 14 |
| GitHub Copilot CLI (+ PowerShell 7 on Windows) | Copilot SDK uses the CLI engine | 00 SDK, 16 |
| SQL Server LocalDB (Windows) | ContosoDashboard database | 13, 14 |

The smoke test clones the lab repo to a temp folder, builds the LAB_AK_02 C# project, runs the LAB_AK_02 Python tests, then deletes the clone.

## Manual steps (need your GitHub login)

1. Open a **new** terminal and restart VS Code, so the PATH changes apply.
2. Check your plan at <https://github.com/settings/copilot>.
3. VS Code: Copilot icon in the Status Bar → **Set up Copilot** → sign in. **View → Chat** should open.
4. Terminal: `copilot login`, then run `copilot` and send one prompt to confirm it answers.
5. Re-run with `-CheckOnly` / `--check-only` and confirm everything is green.

## Things the PDF doesn't tell you

- **.NET 8 is required, not just 9+.** The starter apps for labs 13–16 (`ContosoDashboard-SSD`, `github-copilot-customization-starter-app`, `github-copilot-sdk-starter-app`) target `net8.0` with no roll-forward. With only .NET 9/10 installed they build, but `dotnet run` fails with "framework 'Microsoft.NETCore.App', version '8.0.0' was not found". .NET 8 and 9 both reached end of support in November 2026. That's fine for a training lab, but don't use them for anything else.
- **Copilot CLI on Windows needs PowerShell 7+**, not the built-in Windows PowerShell 5.1.
- **Copilot Free plan limits.** The agent-heavy labs (06, 13, 14, 15, 16) use many requests. If your employer gives you Copilot Business or Enterprise, use that account. Your org admin must also allow Copilot CLI, or LAB_AK_16 won't work.
- **LocalDB is Windows-only.** On macOS, for LAB_AK_14, ask Copilot to switch `ContosoDashboard` from `UseSqlServer` to SQLite (`Microsoft.EntityFrameworkCore.Sqlite` 8.0.x). The setup page lists SQLite as an accepted alternative. The other option is SQL Server in Docker.
- **Python stub on Windows.** If `python --version` opens the Microsoft Store, turn off `python.exe` / `python3.exe` under *Settings → Apps → Advanced app settings → App execution aliases*. The script also puts the real Python first in your user PATH.
- **Corporate proxy or SSL inspection** can break `uv tool install`, NuGet restore and `copilot login`. If the smoke test fails on network errors, that's the likely cause.
- **LocalDB install** uses the SQL Server 2019 Express bootstrapper in silent "download LocalDB only" mode. If that step fails, the script prints the manual steps from the lab guide.
