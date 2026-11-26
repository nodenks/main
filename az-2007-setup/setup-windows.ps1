<#
.SYNOPSIS
    Installs and verifies everything needed for the AZ-2007 GitHub Copilot labs on Windows.

.DESCRIPTION
    Covers every lab in MicrosoftLearning/mslearn-github-copilot-dev (LAB_AK_00 to LAB_AK_16):
      Git, PowerShell 7, VS Code + C# Dev Kit + Python extension, .NET 8 and .NET 9 SDKs,
      Python 3.13 + pytest, uv + Specify CLI (Spec Kit), GitHub Copilot CLI, SQL Server LocalDB.

    Safe to re-run: installed tools are skipped or upgraded.

    Run from an elevated PowerShell ("Run as administrator") under YOUR OWN Windows account:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
        .\setup-windows.ps1

.PARAMETER CheckOnly
    Only verify the environment; install nothing. Does not need admin rights.

.PARAMETER SkipLocalDB
    Skip SQL Server LocalDB (only needed for LAB_AK_13/14, the Spec Kit labs).

.PARAMETER SkipSmokeTest
    Skip cloning the lab repo and building/testing one C# and one Python lab project.
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$SkipLocalDB,
    [switch]$SkipSmokeTest
)

# 'Continue' on purpose: in Windows PowerShell 5.1, 'Stop' turns any stderr output of a
# native command (git, dotnet, uv...) into a terminating error.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest much faster on 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$LabRepoUrl     = 'https://github.com/MicrosoftLearning/mslearn-github-copilot-dev.git'
$SpecKitSource  = 'git+https://github.com/github/spec-kit.git'
$LocalDbSseiUrl = 'https://go.microsoft.com/fwlink/?LinkID=866658'   # SQL Server 2019 Express bootstrapper (same link as the lab)
$WorkDir        = Join-Path $env:ProgramData 'az2007-setup'

# winget exit codes that mean "already installed / nothing to upgrade"
$WingetOkCodes = @(0, -1978335189, -1978335135)

$WingetPackages = @(
    @{ Id = 'Microsoft.PowerShell';       Name = 'PowerShell 7 (required by Copilot CLI on Windows)' },
    @{ Id = 'Git.Git';                    Name = 'Git' },
    @{ Id = 'Microsoft.VisualStudioCode'; Name = 'Visual Studio Code'; Extra = @('--scope', 'machine'); SkipIfVersion = @('code', '1.116') },
    @{ Id = 'Microsoft.DotNet.SDK.9';     Name = '.NET 9 SDK (labs 01-12 target net9.0)' },
    @{ Id = 'Microsoft.DotNet.SDK.8';     Name = '.NET 8 SDK (labs 13-16 starter apps target net8.0)' },
    @{ Id = 'Python.Python.3.13';         Name = 'Python 3.13' },
    @{ Id = 'astral-sh.uv';               Name = 'uv package manager' },
    @{ Id = 'GitHub.Copilot';             Name = 'GitHub Copilot CLI' }
)

$VsCodeExtensions = @('ms-dotnettools.csdevkit', 'ms-python.python')

# ----------------------------------------------------------------------------- helpers

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $uvBin   = Join-Path $env:USERPROFILE '.local\bin'
    $env:Path = "$machine;$user;$uvBin"
}

function Add-ToUserPath([string[]]$Dirs) {
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if ($current) { $parts = @($current -split ';' | Where-Object { $_ }) }
    $changed = $false
    for ($i = $Dirs.Count - 1; $i -ge 0; $i--) {
        $d = $Dirs[$i]
        if ($parts -notcontains $d) { $parts = @($d) + $parts; $changed = $true }
    }
    if ($changed) {
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
        Write-Host "  Added to user PATH: $($Dirs -join ', ')"
    }
}

# Runs a native command, returns @{ExitCode; Output} or $null when the command doesn't exist.
function Invoke-Native([string]$Exe, [string[]]$Arguments = @()) {
    $cmd = Get-Command $Exe -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cmd) { return $null }
    try {
        $out = & $cmd.Source @Arguments 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($out -join "`n").Trim()) }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = "$_" }
    }
}

function Get-VersionFromText([string]$Text) {
    if ($Text -and $Text -match '(\d+)\.(\d+)(?:\.(\d+))?') {
        $patch = '0'
        if ($Matches[3]) { $patch = $Matches[3] }
        return [version]"$($Matches[1]).$($Matches[2]).$patch"
    }
    return $null
}

function Find-PythonExe {
    $candidates = @()
    $py = Get-Command py -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($py) {
        $exe = & $py.Source -3.13 -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe) { $candidates += "$exe".Trim() }
    }
    $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe')
    $candidates += (Join-Path $env:ProgramFiles 'Python313\python.exe')
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Find-SqlLocalDb {
    $cmd = Get-Command SqlLocalDB -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $hit = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'Microsoft SQL Server\*\Tools\Binn\SqlLocalDB.exe') `
        -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

# ----------------------------------------------------------------------------- install steps

function Install-WingetPackages {
    Write-Step 'Installing / upgrading tools with winget'
    foreach ($p in $WingetPackages) {
        Write-Host "  - $($p.Name)  [$($p.Id)]"
        if ($p.SkipIfVersion) {
            $r = Invoke-Native $p.SkipIfVersion[0] @('--version')
            $v = $null
            if ($r) { $v = Get-VersionFromText (($r.Output -split "`n")[0]) }
            if ($v -and $v -ge [version]$p.SkipIfVersion[1]) { Write-Host "    already installed ($v), skipping."; continue }
            if ($v) { Write-Warning "    $($p.Id) $v is older than $($p.SkipIfVersion[1]); update it from inside the app (Help > Check for Updates)."; continue }
        }
        $wingetArgs = @('install', '--id', $p.Id, '--exact', '--source', 'winget',
                        '--accept-package-agreements', '--accept-source-agreements', '--silent')
        if ($p.Extra) { $wingetArgs += $p.Extra }
        & winget @wingetArgs | Out-Host
        if ($WingetOkCodes -notcontains $LASTEXITCODE) {
            Write-Warning "winget exit code $LASTEXITCODE for $($p.Id). The final check shows whether it is usable."
        }
    }
    Update-SessionPath
}

function Install-PythonBits {
    Write-Step 'Python: PATH and pytest'
    $pythonExe = Find-PythonExe
    if (-not $pythonExe) {
        Write-Warning 'Python 3.13 not found after install. Install it from https://www.python.org/downloads/ and tick "Add python.exe to PATH".'
        return
    }
    $dir = Split-Path $pythonExe
    Add-ToUserPath @($dir, (Join-Path $dir 'Scripts'))
    Update-SessionPath
    & $pythonExe -m pip install --upgrade --quiet --disable-pip-version-check pytest | Out-Host
}

function Set-NuGetSource {
    Write-Step 'NuGet: ensure nuget.org is a package source'
    $r = Invoke-Native dotnet @('nuget', 'list', 'source')
    if (-not $r) { Write-Warning 'dotnet not found; skipping.'; return }
    if ($r.Output -match 'api\.nuget\.org/v3/index\.json') {
        Write-Host '  nuget.org already configured.'
    } else {
        & dotnet nuget add source 'https://api.nuget.org/v3/index.json' -n nuget.org | Out-Host
    }
}

function Install-VsCodeExtensions {
    Write-Step 'VS Code extensions'
    if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
        Write-Warning "'code' is not on PATH. Open a new terminal and re-run, or install the extensions from the Extensions view."
        return
    }
    foreach ($ext in $VsCodeExtensions) {
        Write-Host "  - $ext"
        & code --install-extension $ext --force | Out-Host
    }
}

function Install-SpecifyCli {
    Write-Step 'Spec Kit: Specify CLI (via uv)'
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        Write-Warning 'uv not found; skipping Specify CLI.'
        return
    }
    & uv tool install specify-cli --force --from $SpecKitSource | Out-Host
    & uv tool update-shell | Out-Host
    Update-SessionPath
}

function Install-LocalDB {
    Write-Step 'SQL Server LocalDB (LAB_AK_13/14)'
    $sqlLocalDb = Find-SqlLocalDb
    if (-not $sqlLocalDb) {
        try {
            New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
            $mediaDir = Join-Path $WorkDir 'localdb-media'
            New-Item -ItemType Directory -Force -Path $mediaDir | Out-Null
            $ssei = Join-Path $WorkDir 'SQL2019-SSEI-Expr.exe'
            Write-Host '  Downloading SQL Server Express bootstrapper...'
            Invoke-WebRequest -Uri $LocalDbSseiUrl -OutFile $ssei -UseBasicParsing
            Write-Host '  Downloading the LocalDB package (this can take a few minutes)...'
            $p = Start-Process -FilePath $ssei -Wait -PassThru -ArgumentList @(
                '/ACTION=Download', "/MEDIAPATH=$mediaDir", '/MEDIATYPE=LocalDB', '/QUIET')
            $msi = Get-ChildItem -Path $mediaDir -Recurse -Filter 'SqlLocalDB.msi' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $msi) { throw "SqlLocalDB.msi was not downloaded (bootstrapper exit code $($p.ExitCode))." }
            Write-Host "  Installing $($msi.FullName)..."
            $p = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru -ArgumentList @(
                '/i', "`"$($msi.FullName)`"", '/qn', 'IACCEPTSQLLOCALDBLICENSETERMS=YES')
            if (@(0, 3010) -notcontains $p.ExitCode) { throw "msiexec exit code $($p.ExitCode)." }
            Update-SessionPath
            $sqlLocalDb = Find-SqlLocalDb
        } catch {
            Write-Warning "LocalDB install failed: $_"
            Write-Warning 'Manual fallback: https://go.microsoft.com/fwlink/?LinkID=866658 -> Download Media -> LocalDB -> run SqlLocalDB.msi'
            return
        }
    }
    if ($sqlLocalDb) {
        $info = & $sqlLocalDb info MSSQLLocalDB 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $info -notmatch 'State') {
            & $sqlLocalDb create MSSQLLocalDB | Out-Host
        }
        & $sqlLocalDb start MSSQLLocalDB | Out-Host
    }
}

function Set-GitIdentity {
    Write-Step 'Git identity'
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Warning 'git not found; skipping.'; return }
    $name  = & git config --global user.name
    $email = & git config --global user.email
    if (-not $name) {
        $name = Read-Host '  Git user.name (e.g. Jane Doe)'
        if ($name) { & git config --global user.name "$name" }
    }
    if (-not $email) {
        $email = Read-Host '  Git user.email (use the email of your GitHub account, or its noreply address)'
        if ($email) { & git config --global user.email "$email" }
    }
    Write-Host "  user.name=$(& git config --global user.name)  user.email=$(& git config --global user.email)"
}

function Invoke-SmokeTest {
    Write-Step 'Smoke test: clone lab repo, build a C# lab, run a Python lab''s tests'
    foreach ($tool in 'git', 'dotnet', 'python') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Write-Warning "$tool not on PATH; smoke test skipped."; return $false }
    }
    $dir = Join-Path $env:TEMP 'az2007-smoketest'
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    & git clone --depth 1 --quiet $LabRepoUrl $dir 2>&1 | ForEach-Object { "$_" } | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Warning 'git clone failed (network/proxy?).'; return $false }

    $ok = $true
    $csproj = Join-Path $dir 'LabFiles\02-analyze-document-code\AccelerateDevGHCopilot\src\Library.Console\Library.Console.csproj'
    & dotnet build $csproj --nologo -v quiet | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Warning 'C# lab build FAILED.'; $ok = $false } else { Write-Host '  C# lab builds.' -ForegroundColor Green }

    $pyDir = Join-Path $dir 'LabFiles\02-python-analyze-document-code\AccelerateDevGHCopilot\library'
    Push-Location $pyDir
    & python -m unittest discover tests 2>&1 | ForEach-Object { "$_" } | Select-Object -Last 3 | Out-Host
    $pyExit = $LASTEXITCODE
    Pop-Location
    if ($pyExit -ne 0) { Write-Warning 'Python lab tests FAILED.'; $ok = $false } else { Write-Host '  Python lab tests pass.' -ForegroundColor Green }

    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    return $ok
}

# ----------------------------------------------------------------------------- verification

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Status, [string]$Item, [string]$Detail) {
    $script:Results.Add([pscustomobject]@{ Status = $Status; Item = $Item; Detail = $Detail })
}

function Test-MinVersion([string]$Item, [string]$Exe, [string[]]$Arguments, [string]$Min) {
    $r = Invoke-Native $Exe $Arguments
    if (-not $r) { Add-Result 'FAIL' $Item 'not found on PATH'; return }
    $first = ($r.Output -split "`n")[0]
    $v = Get-VersionFromText $first
    if ($r.ExitCode -eq 0 -and $v -and $v -ge [version]$Min) { Add-Result 'OK' $Item $first }
    else { Add-Result 'FAIL' $Item "found: $first" }
}

function Test-Environment {
    $script:Results.Clear()
    Update-SessionPath

    Test-MinVersion 'Git >= 2.48'             git    @('--version') '2.48'
    $gName  = Invoke-Native git @('config', '--global', 'user.name')
    $gEmail = Invoke-Native git @('config', '--global', 'user.email')
    if ($gName -and $gName.Output -and $gEmail -and $gEmail.Output) { Add-Result 'OK' 'Git user.name / user.email' "$($gName.Output) <$($gEmail.Output)>" }
    else { Add-Result 'FAIL' 'Git user.name / user.email' 'not set (git config --global user.name / user.email)' }

    Test-MinVersion 'PowerShell 7 (pwsh)'     pwsh   @('--version') '7.0'
    Test-MinVersion 'VS Code >= 1.116'        code   @('--version') '1.116'

    $ext = Invoke-Native code @('--list-extensions')
    foreach ($e in $VsCodeExtensions) {
        if ($ext -and (($ext.Output -split "`n") | ForEach-Object { $_.Trim().ToLower() }) -contains $e) { Add-Result 'OK' "VS Code ext $e" 'installed' }
        else { Add-Result 'FAIL' "VS Code ext $e" 'not installed' }
    }

    $sdks = Invoke-Native dotnet @('--list-sdks')
    $sdkVersions = @()
    if ($sdks) { $sdkVersions = @(($sdks.Output -split "`n") | ForEach-Object { Get-VersionFromText $_ } | Where-Object { $_ }) }
    $sdk9 = @($sdkVersions | Where-Object { $_.Major -ge 9 })
    if ($sdk9.Count) { Add-Result 'OK' '.NET SDK >= 9' (($sdk9 | ForEach-Object { "$_" }) -join ', ') }
    else { Add-Result 'FAIL' '.NET SDK >= 9' "found: $(($sdkVersions | ForEach-Object { "$_" }) -join ', ')" }

    $rt = Invoke-Native dotnet @('--list-runtimes')
    $rtText = ''
    if ($rt) { $rtText = $rt.Output }
    foreach ($major in 8, 9) {
        $core = $rtText -match "(?m)^Microsoft\.NETCore\.App $major\."
        $asp  = $rtText -match "(?m)^Microsoft\.AspNetCore\.App $major\."
        if ($core -and $asp) { Add-Result 'OK' ".NET $major runtime (+ASP.NET Core)" 'installed' }
        else { Add-Result 'FAIL' ".NET $major runtime (+ASP.NET Core)" "missing; install Microsoft.DotNet.SDK.$major" }
    }

    $src = Invoke-Native dotnet @('nuget', 'list', 'source')
    if ($src -and $src.Output -match 'api\.nuget\.org/v3/index\.json') { Add-Result 'OK' 'NuGet source nuget.org' 'configured' }
    else { Add-Result 'FAIL' 'NuGet source nuget.org' 'missing' }

    Test-MinVersion 'Python >= 3.11'          python @('--version') '3.11'
    $pt = Invoke-Native python @('-m', 'pytest', '--version')
    if ($pt -and $pt.ExitCode -eq 0) { Add-Result 'OK' 'pytest' $pt.Output } else { Add-Result 'WARN' 'pytest' 'not importable from "python" (only LAB_AK_04/05 Python need it)' }

    Test-MinVersion 'uv'                      uv     @('--version') '0.1'
    if (Get-Command specify -ErrorAction SilentlyContinue) { Add-Result 'OK' 'Specify CLI (Spec Kit)' (Get-Command specify).Source }
    else { Add-Result 'FAIL' 'Specify CLI (Spec Kit)' 'not on PATH (open a new terminal, or: uv tool list)' }

    Test-MinVersion 'GitHub Copilot CLI'      copilot @('--version') '0.0'

    if ($SkipLocalDB) {
        Add-Result 'SKIP' 'SQL Server LocalDB' 'skipped (-SkipLocalDB)'
    } else {
        $sql = Find-SqlLocalDb
        if ($sql) {
            $info = & $sql info MSSQLLocalDB 2>&1 | Out-String
            if ($info -match 'State:\s*(\w+)') { Add-Result 'OK' 'SQL Server LocalDB (MSSQLLocalDB)' "state: $($Matches[1])" }
            else { Add-Result 'WARN' 'SQL Server LocalDB (MSSQLLocalDB)' 'installed, instance missing: SqlLocalDB create MSSQLLocalDB -s' }
        } else { Add-Result 'FAIL' 'SQL Server LocalDB' 'not installed (needed for LAB_AK_13/14)' }
    }
}

function Show-Results {
    Write-Step 'Environment check'
    foreach ($r in $script:Results) {
        $color = switch ($r.Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'SKIP' { 'DarkGray' } default { 'Red' } }
        Write-Host ('  [{0,-4}] {1,-38} {2}' -f $r.Status, $r.Item, $r.Detail) -ForegroundColor $color
    }
}

function Show-ManualSteps {
    Write-Step 'Manual steps (need your GitHub login, cannot be scripted)'
    Write-Host @'
  1. Close and reopen all terminals and VS Code windows (PATH changed).
  2. Check your Copilot plan: https://github.com/settings/copilot
     (Free plan has tight monthly limits; the Spec Kit / agent labs use a lot of requests.)
  3. VS Code: click the Copilot icon in the Status Bar -> "Set up Copilot" / Sign in
     -> authorize in the browser. Then View -> Chat should open the Copilot Chat view.
  4. Terminal:  copilot login     (browser sign-in; needed for LAB_AK_00 SDK and LAB_AK_16)
     Then run:  copilot           and send a short prompt to confirm it answers.
  5. Labs 11, 12, 14, 15, 16 create repos in YOUR GitHub account from templates;
     make sure you can sign in at https://github.com.
'@
}

# ----------------------------------------------------------------------------- main

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Write-Error 'This script is for Windows. Use setup-macos.sh on macOS.'
    exit 2
}

if (-not $CheckOnly) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error 'Run this script from an elevated PowerShell (Run as administrator), or use -CheckOnly.'
        exit 1
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Error 'winget not found. Install "App Installer" from the Microsoft Store, then re-run.'
        exit 1
    }

    Install-WingetPackages
    Install-PythonBits
    Set-NuGetSource
    Install-VsCodeExtensions
    Install-SpecifyCli
    if (-not $SkipLocalDB) { Install-LocalDB }
    Set-GitIdentity
}

$smokeOk = $true
if (-not $SkipSmokeTest) { $smokeOk = [bool](Invoke-SmokeTest | Select-Object -Last 1) }

Test-Environment
if (-not $SkipSmokeTest) {
    if ($smokeOk) { Add-Result 'OK' 'Smoke test (C# build + Python tests)' 'passed' }
    else { Add-Result 'FAIL' 'Smoke test (C# build + Python tests)' 'see warnings above' }
}
Show-Results
Show-ManualSteps

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($failed) {
    Write-Host "`n$failed check(s) failed. Fix them, open a NEW terminal, and re-run with -CheckOnly." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll automated checks passed. Finish the manual steps above and you're ready." -ForegroundColor Green
exit 0
