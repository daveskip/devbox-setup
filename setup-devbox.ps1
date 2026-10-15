<#
.SYNOPSIS
    Sets up a Windows PC for .NET + React development.

.DESCRIPTION
    Installs the toolchain with winget, then configures Git, .NET, Node/npm, VS Code and the GitHub CLI.
    Safe to re-run: anything already installed is skipped (or upgraded with -Upgrade).

    Run it from the developer's own Windows account, elevated with "Run as administrator".
    Git config, VS Code extensions, .NET tools and the HTTPS dev certificate are per-user,
    so running it under a separate admin account would configure the wrong profile.

    To change what every machine gets, edit the parameter defaults below.
    To customise one machine, pass parameters on the command line.

.EXAMPLE
    .\setup-devbox.ps1 -WhatIf
    Dry run: shows what's already installed and what would change, without changing anything.

.EXAMPLE
    .\setup-devbox.ps1 -GitUserName "Jane Doe" -GitUserEmail jane@contoso.com -GitHubLogin

.EXAMPLE
    .\setup-devbox.ps1 -IncludeVisualStudio -IncludeWsl -IncludeDocker -DotNetSdks 10,8 -NpmGlobalPackages pnpm -ExtraPackages Microsoft.AzureCLI,Bruno.Bruno
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # .NET SDK major versions to install. 10 is the current LTS; add 8 or 9 for older apps.
    [string[]]$DotNetSdks = @('10'),

    # .NET global tools to install.
    [string[]]$DotNetTools = @('dotnet-ef'),

    # Install nvm-windows (switch Node versions per project) instead of the plain Node.js LTS installer.
    [switch]$UseNvm,

    # npm packages to install globally, e.g. pnpm or yarn.
    [string[]]$NpmGlobalPackages = @(),

    [string[]]$VSCodeExtensions = @(
        'ms-dotnettools.csdevkit',            # C# Dev Kit (pulls in the C# extension)
        'dbaeumer.vscode-eslint',             # ESLint
        'esbenp.prettier-vscode',             # Prettier
        'editorconfig.editorconfig',          # EditorConfig
        'github.vscode-pull-request-github'   # GitHub Pull Requests
    ),

    # Also install Visual Studio 2026 with the "ASP.NET and web development" workload.
    [switch]$IncludeVisualStudio,

    [ValidateSet('Community', 'Professional', 'Enterprise')]
    [string]$VisualStudioEdition = 'Community',

    # Also install WSL 2 with a Linux distro (Ubuntu by default). Needs a restart if WSL wasn't already on.
    [switch]$IncludeWsl,

    # Distro for -IncludeWsl, as listed by 'wsl --list --online'. 'Ubuntu' is always the latest Ubuntu LTS.
    [string]$WslDistro = 'Ubuntu',

    # Also install Docker Desktop (and WSL 2, which it runs on). Usually needs a restart afterwards.
    [switch]$IncludeDocker,

    # Any other winget package IDs, e.g. Microsoft.AzureCLI, Bruno.Bruno, JetBrains.Rider.
    [string[]]$ExtraPackages = @(),

    # Git identity. If omitted and not already set, you'll be prompted at the start.
    [string]$GitUserName,
    [string]$GitUserEmail,

    # Run 'gh auth login' at the end (opens a browser).
    [switch]$GitHubLogin,

    # Upgrade packages that are already installed instead of skipping them.
    [switch]$Upgrade
)

$script:Cmdlet = $PSCmdlet
$script:Results = New-Object System.Collections.Generic.List[object]
$script:RestartNeeded = $false
$script:AfterRestart = New-Object System.Collections.Generic.List[string]   # things that can only install after a restart
$env:DOTNET_NOLOGO = '1'
$env:WSL_UTF8 = '1'   # otherwise wsl.exe prints UTF-16, which Windows PowerShell garbles

# winget exit codes that aren't failures.
$script:WingetOk = @{
    0          = 'Installed'
    0x8A15002B = 'Up to date'                     # no applicable upgrade
    0x8A150061 = 'Already installed'
    0x8A150109 = 'Installed, restart required'
}

#region Helpers

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Add-Result([string]$Item, [string]$Status, [string]$Detail = '') {
    $script:Results.Add([pscustomobject]@{ Item = $Item; Status = $Status; Detail = $Detail })
    $color = switch -Wildcard ($Status) {
        'FAILED'     { 'Red' }
        'Would*'     { 'Yellow' }
        'Skipped'    { 'Yellow' }
        'Restart*'   { 'Yellow' }
        'Already*'   { 'DarkGray' }
        'Up to date' { 'DarkGray' }
        default      { 'Green' }
    }
    $line = '  {0,-36} {1}' -f $Item, $Status
    if ($Detail) { $line += " ($Detail)" }
    Write-Host $line -ForegroundColor $color
}

function Test-ShouldRun([string]$Target, [string]$Action) {
    # Honors -WhatIf / -Confirm passed to the script.
    $script:Cmdlet.ShouldProcess($Target, $Action)
}

function Test-Command([string]$Name) {
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Update-SessionPath {
    # Re-read variables installers just wrote to the registry so later steps can use the new tools.
    # NVM_* go first because the PATH entries nvm-windows adds reference them.
    foreach ($name in 'NVM_HOME', 'NVM_SYMLINK') {
        $value = [Environment]::GetEnvironmentVariable($name, 'Machine')
        if (-not $value) { $value = [Environment]::GetEnvironmentVariable($name, 'User') }
        if ($value) { [Environment]::SetEnvironmentVariable($name, $value, 'Process') }
    }
    $paths = @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'))
    $env:Path = ($paths | Where-Object { $_ }) -join ';'
}

function Test-RebootPending {
    # Set by Windows while turned-on features or updates are waiting for a restart.
    Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
}

function Get-VmPlatformState {
    # 'Enabled', 'EnablePending' (needs a restart), 'Disabled', ...
    try {
        (Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop).State.ToString()
    }
    catch {
        # Get-WindowsOptionalFeature needs admin, so a non-elevated -WhatIf run lands here.
        switch ((Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'").InstallState) {
            1       { 'Enabled' }
            2       { 'Disabled' }
            default { 'Unknown' }
        }
    }
}

function Test-WslDistro([string]$Name) {
    if (-not (Test-Command wsl.exe)) { return $false }
    $distros = wsl.exe --list --quiet 2> $null | ForEach-Object { ($_ -replace "`0", '').Trim() }
    return ($distros -contains $Name)
}

function Get-WslDefaultDistro {
    # Read from the registry rather than parsing 'wsl --list', whose output is localized.
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $defaultId = (Get-ItemProperty -Path $lxss -ErrorAction SilentlyContinue).DefaultDistribution
    if (-not $defaultId) { return $null }
    (Get-ItemProperty -Path (Join-Path $lxss $defaultId) -ErrorAction SilentlyContinue).DistributionName
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Name = $Id,
        [string[]]$InstallArgs = @(),   # only used for fresh installs, not upgrades
        [switch]$NeedsRestart
    )

    winget list --id $Id --exact --accept-source-agreements --disable-interactivity *> $null
    $isInstalled = ($LASTEXITCODE -eq 0)

    if ($isInstalled -and -not $Upgrade) {
        Add-Result $Name 'Already installed'
        return
    }

    $verb = if ($isInstalled) { 'upgrade' } else { 'install' }
    if (-not (Test-ShouldRun $Name "winget $verb $Id")) {
        Add-Result $Name "Would $verb"
        return
    }

    Write-Host "  $Name - winget $verb..."
    $wingetArgs = @($verb, '--id', $Id, '--exact', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if (-not $isInstalled) { $wingetArgs += $InstallArgs }
    & winget @wingetArgs
    $code = $LASTEXITCODE

    if (-not $script:WingetOk.ContainsKey($code)) {
        Add-Result $Name 'FAILED' ('winget exit code 0x{0:X8}; run "winget --logs" for details' -f $code)
        return
    }
    $status = $script:WingetOk[$code]
    if ($code -eq 0 -and $isInstalled) { $status = 'Upgraded' }
    if ($code -eq 0x8A150109 -or ($NeedsRestart -and $code -eq 0)) { $script:RestartNeeded = $true }
    Add-Result $Name $status
}

function Set-GitConfig([string]$Key, [string]$Value) {
    $current = git config --global --get $Key
    if ($current -eq $Value) {
        Add-Result "git $Key" 'Already set' $Value
    }
    elseif (Test-ShouldRun "git config --global $Key" "Set to '$Value'") {
        git config --global $Key $Value
        Add-Result "git $Key" 'Set' $Value
    }
    else {
        Add-Result "git $Key" 'Would set' $Value
    }
}

#endregion

#region Pre-flight

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIfPreference) {
    Write-Host 'Please run this from an elevated PowerShell ("Run as administrator"), or double-click setup.cmd.' -ForegroundColor Red
    exit 1
}

if (-not (Test-Command winget)) {
    # On a brand-new Windows profile winget can be present but not registered yet.
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { }
}
if (-not (Test-Command winget)) {
    Write-Host 'winget was not found. Install "App Installer" from the Microsoft Store, then re-run this script.' -ForegroundColor Red
    exit 1
}

$logPath = Join-Path $env:TEMP ('devbox-setup-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
Start-Transcript -Path $logPath -WhatIf:$false | Out-Null

# Ask for the Git identity up front so everything after this runs unattended.
if (Test-Command git) {
    if (-not $GitUserName) { $GitUserName = git config --global --get user.name }
    if (-not $GitUserEmail) { $GitUserEmail = git config --global --get user.email }
}
if (-not $WhatIfPreference) {
    try {
        if (-not $GitUserName) { $GitUserName = Read-Host 'Your name for Git commits (Enter to skip)' }
        if (-not $GitUserEmail) { $GitUserEmail = Read-Host 'Your email for Git commits (Enter to skip)' }
    }
    catch { }   # non-interactive session: leave them unset
}

#endregion

#region Windows settings

Write-Section 'Windows settings'

# node_modules and some .NET builds go past the old 260-character path limit.
$fsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
if ((Get-ItemProperty -Path $fsKey -ErrorAction SilentlyContinue).LongPathsEnabled -eq 1) {
    Add-Result 'Long paths' 'Already enabled'
}
elseif (Test-ShouldRun 'Long paths' 'Set LongPathsEnabled = 1') {
    Set-ItemProperty -Path $fsKey -Name LongPathsEnabled -Value 1 -Type DWord
    Add-Result 'Long paths' 'Enabled'
}
else {
    Add-Result 'Long paths' 'Would enable'
}

# Windows PowerShell's default 'Restricted' policy blocks npm.ps1, pnpm.ps1, etc.
$userPolicy = Get-ExecutionPolicy -Scope CurrentUser
$effectivePolicy = if ($userPolicy -ne 'Undefined') { $userPolicy } else { Get-ExecutionPolicy -Scope LocalMachine }
if ($effectivePolicy -in 'RemoteSigned', 'Unrestricted', 'Bypass') {
    Add-Result 'PowerShell execution policy' "Already $effectivePolicy"
}
elseif (Test-ShouldRun 'PowerShell execution policy (CurrentUser)' 'Set to RemoteSigned') {
    # Expect an "overridden by a more specific scope" error when this script runs with -ExecutionPolicy Bypass,
    # so check the result rather than trusting the error.
    $policyError = ''
    try { Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop } catch { $policyError = $_.Exception.Message }
    if ((Get-ExecutionPolicy -Scope CurrentUser) -eq 'RemoteSigned') { Add-Result 'PowerShell execution policy' 'Set to RemoteSigned' }
    else { Add-Result 'PowerShell execution policy' 'FAILED' $policyError }
}
else {
    Add-Result 'PowerShell execution policy' 'Would set to RemoteSigned'
}

#endregion

#region Packages

Write-Section 'Packages'

Install-WingetPackage -Id 'Git.Git' -Name 'Git'
Install-WingetPackage -Id 'GitHub.cli' -Name 'GitHub CLI'
foreach ($version in $DotNetSdks) {
    Install-WingetPackage -Id "Microsoft.DotNet.SDK.$version" -Name ".NET SDK $version"
}
if ($UseNvm) {
    Install-WingetPackage -Id 'CoreyButler.NVMforWindows' -Name 'nvm-windows'
}
else {
    Install-WingetPackage -Id 'OpenJS.NodeJS.LTS' -Name 'Node.js LTS'
}
# Machine-wide, on PATH, with "Open with Code" in Explorer's right-click menu.
Install-WingetPackage -Id 'Microsoft.VisualStudioCode' -Name 'VS Code' -InstallArgs @(
    '--scope', 'machine',
    '--override', '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath')
Install-WingetPackage -Id 'Microsoft.PowerShell' -Name 'PowerShell 7'
Install-WingetPackage -Id 'Microsoft.WindowsTerminal' -Name 'Windows Terminal'

if ($IncludeVisualStudio) {
    Install-WingetPackage -Id "Microsoft.VisualStudio.$VisualStudioEdition" -Name "Visual Studio $VisualStudioEdition" -InstallArgs @(
        '--override', '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.NetWeb --includeRecommended')
}

if ($IncludeWsl -or $IncludeDocker) {
    # WSL 2 needs CPU virtualization switched on in the BIOS/UEFI, which a script can't change.
    $hypervisorRunning = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
    $firmwareVirtualization = @(Get-CimInstance Win32_Processor | Where-Object { $_.VirtualizationFirmwareEnabled }).Count -gt 0
    if (-not $hypervisorRunning -and -not $firmwareVirtualization) {
        Add-Result 'CPU virtualization' 'FAILED' 'turn on Intel VT-x / AMD SVM in the BIOS/UEFI settings'
    }

    # Virtual Machine Platform is the Windows feature WSL 2 runs on. 'wsl --install' usually turns it on,
    # but do it explicitly so it can't be missed. It only takes effect after a restart.
    $vmpState = Get-VmPlatformState
    if ($vmpState -eq 'Enabled') {
        Add-Result 'Virtual Machine Platform' 'Already enabled'
    }
    elseif ($vmpState -eq 'EnablePending') {
        Add-Result 'Virtual Machine Platform' 'Restart needed' 'enabled, takes effect after restart'
    }
    elseif (Test-ShouldRun 'Virtual Machine Platform' 'Enable Windows feature') {
        try {
            $feature = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction Stop
            if ($feature.RestartNeeded) {
                $vmpState = 'EnablePending'
                Add-Result 'Virtual Machine Platform' 'Restart needed' 'enabled, takes effect after restart'
            }
            else {
                $vmpState = 'Enabled'
                Add-Result 'Virtual Machine Platform' 'Enabled'
            }
        }
        catch {
            Add-Result 'Virtual Machine Platform' 'FAILED' $_.Exception.Message
        }
    }
    else {
        Add-Result 'Virtual Machine Platform' 'Would enable'
    }

    # 'wsl --status' succeeds as soon as WSL is installed, even while it can't start yet.
    $wslInstalled = $false
    if (Test-Command wsl.exe) {
        wsl.exe --status *> $null
        $wslInstalled = ($LASTEXITCODE -eq 0)
    }
    $needDistro = $IncludeWsl -and -not (Test-WslDistro $WslDistro)
    $wslName = if ($IncludeWsl) { "WSL 2 + $WslDistro" } else { 'WSL 2' }

    if ($wslInstalled -and -not $needDistro) {
        Add-Result $wslName 'Already installed'
    }
    else {
        # --no-launch skips the distro's first-run username prompt so the script can carry on unattended.
        $wslArgs = if ($IncludeWsl) { @('--install', '--distribution', $WslDistro, '--no-launch') } else { @('--install', '--no-distribution') }
        if (Test-ShouldRun $wslName "wsl $($wslArgs -join ' ')") {
            wsl.exe @wslArgs
            if ($LASTEXITCODE -ne 0) {
                Add-Result $wslName 'FAILED' "wsl exit code $LASTEXITCODE"
            }
            elseif ($IncludeWsl -and -not (Test-WslDistro $WslDistro)) {
                # wsl reports success, but a distro can't be registered until Virtual Machine Platform is running.
                Add-Result $wslName 'Restart needed' "$WslDistro installs on the next run"
                $script:AfterRestart.Add($WslDistro)
            }
            else {
                Add-Result $wslName 'Installed'
            }
        }
        else {
            Add-Result $wslName 'Would install'
        }
    }

    if (Test-RebootPending) { $script:RestartNeeded = $true }
}

if ($IncludeDocker) {
    # Docker Desktop needs WSL 2 actually running: Virtual Machine Platform enabled and Windows restarted
    # since. Until then, leave Docker for the next run of setup.
    $wslRunnable = $false
    if ($vmpState -eq 'Enabled' -and -not (Test-RebootPending) -and (Test-Command wsl.exe)) {
        wsl.exe --status *> $null
        $wslRunnable = ($LASTEXITCODE -eq 0)
    }
    winget list --id Docker.DockerDesktop --exact --disable-interactivity *> $null
    $dockerInstalled = ($LASTEXITCODE -eq 0)

    if ($dockerInstalled -or $wslRunnable -or $WhatIfPreference) {
        Install-WingetPackage -Id 'Docker.DockerDesktop' -Name 'Docker Desktop' -NeedsRestart
    }
    else {
        Add-Result 'Docker Desktop' 'Restart needed' 'installs on the next run, once WSL is running'
        $script:AfterRestart.Add('Docker Desktop')
    }
}

if ($IncludeWsl) {
    # Make the distro the default, so plain 'wsl' and VS Code's WSL extension open it. Otherwise the
    # first distro registered wins, which is often Docker Desktop's internal 'docker-desktop'.
    # Runs after Docker so nothing installed later in this run can take the default back.
    $currentDefault = Get-WslDefaultDistro
    if ($currentDefault -eq $WslDistro) {
        Add-Result 'Default WSL distro' 'Already set' $WslDistro
    }
    elseif (-not (Test-WslDistro $WslDistro)) {
        if ($WhatIfPreference) { Add-Result 'Default WSL distro' 'Would set' $WslDistro }
        # Otherwise the distro is waiting for a restart (reported above) and the next run sets it.
    }
    elseif (Test-ShouldRun 'Default WSL distro' "wsl --set-default $WslDistro") {
        wsl.exe --set-default $WslDistro
        if ($LASTEXITCODE -eq 0) { Add-Result 'Default WSL distro' 'Set' $WslDistro }
        else { Add-Result 'Default WSL distro' 'FAILED' "wsl exit code $LASTEXITCODE" }
    }
    else {
        Add-Result 'Default WSL distro' 'Would set' "$WslDistro, currently $currentDefault"
    }
}

foreach ($id in $ExtraPackages) {
    Install-WingetPackage -Id $id
}

Update-SessionPath

#endregion

#region Git

Write-Section 'Git'

if (-not (Test-Command git)) {
    Add-Result 'Git config' 'Skipped' 'git not on PATH yet'
}
else {
    if ($GitUserName) { Set-GitConfig 'user.name' $GitUserName } else { Add-Result 'git user.name' 'Skipped' 'not provided' }
    if ($GitUserEmail) { Set-GitConfig 'user.email' $GitUserEmail } else { Add-Result 'git user.email' 'Skipped' 'not provided' }
    Set-GitConfig 'init.defaultBranch' 'main'
    Set-GitConfig 'core.longpaths' 'true'
}

#endregion

#region Node.js

if ($UseNvm -or $NpmGlobalPackages.Count -gt 0) {
    Write-Section 'Node.js'
}

if ($UseNvm) {
    if (Test-Command node) {
        Add-Result 'Node.js' 'Already installed' (node --version)
    }
    elseif (-not (Test-Command nvm)) {
        Add-Result 'Node.js via nvm' 'Skipped' 'nvm not on PATH yet'
    }
    elseif (Test-ShouldRun 'Node.js LTS' 'nvm install lts; nvm use lts') {
        nvm install lts
        nvm use lts
        Update-SessionPath
        if (Test-Command node) { Add-Result 'Node.js via nvm' 'Installed' (node --version) }
        else { Add-Result 'Node.js via nvm' 'FAILED' 'node not found after nvm use' }
    }
    else {
        Add-Result 'Node.js via nvm' 'Would install LTS'
    }
}

if ($NpmGlobalPackages.Count -gt 0) {
    $packageList = $NpmGlobalPackages -join ', '
    if (-not (Test-Command npm.cmd)) {
        Add-Result "npm: $packageList" 'Skipped' 'npm not on PATH yet'
    }
    elseif (Test-ShouldRun $packageList 'npm install --global') {
        npm.cmd install --global @NpmGlobalPackages
        if ($LASTEXITCODE -eq 0) { Add-Result "npm: $packageList" 'Installed' }
        else { Add-Result "npm: $packageList" 'FAILED' "npm exit code $LASTEXITCODE" }
    }
    else {
        Add-Result "npm: $packageList" 'Would install'
    }
}

#endregion

#region .NET

Write-Section '.NET'

if (-not (Test-Command dotnet)) {
    Add-Result '.NET setup' 'Skipped' 'dotnet not on PATH yet'
}
else {
    dotnet dev-certs https --check --trust *> $null
    if ($LASTEXITCODE -eq 0) {
        Add-Result 'HTTPS dev certificate' 'Already trusted'
    }
    elseif (Test-ShouldRun 'HTTPS dev certificate' 'dotnet dev-certs https --trust') {
        Write-Host '  Windows will ask you to confirm trusting the localhost certificate.' -ForegroundColor Yellow
        dotnet dev-certs https --trust
        if ($LASTEXITCODE -eq 0) { Add-Result 'HTTPS dev certificate' 'Trusted' }
        else { Add-Result 'HTTPS dev certificate' 'FAILED' "dotnet dev-certs exit code $LASTEXITCODE" }
    }
    else {
        Add-Result 'HTTPS dev certificate' 'Would trust'
    }

    $installedTools = dotnet tool list --global | Out-String
    foreach ($tool in $DotNetTools) {
        $isInstalled = $installedTools -match "(?m)^$([regex]::Escape($tool))\s"
        if ($isInstalled -and -not $Upgrade) {
            Add-Result $tool 'Already installed'
            continue
        }
        $verb = if ($isInstalled) { 'update' } else { 'install' }
        if (Test-ShouldRun $tool "dotnet tool $verb --global") {
            dotnet tool $verb --global $tool
            if ($LASTEXITCODE -ne 0) { Add-Result $tool 'FAILED' "dotnet tool exit code $LASTEXITCODE" }
            elseif ($isInstalled) { Add-Result $tool 'Upgraded' }
            else { Add-Result $tool 'Installed' }
        }
        else {
            Add-Result $tool "Would $verb"
        }
    }
}

#endregion

#region VS Code extensions

Write-Section 'VS Code extensions'

if ($IncludeWsl) { $VSCodeExtensions += 'ms-vscode-remote.remote-wsl' }
if ($IncludeDocker) { $VSCodeExtensions += 'ms-azuretools.vscode-containers' }

if (-not (Test-Command code.cmd)) {
    Add-Result 'VS Code extensions' 'Skipped' 'code not on PATH yet'
}
else {
    $installedExtensions = code.cmd --list-extensions
    foreach ($extension in $VSCodeExtensions) {
        if ($installedExtensions -contains $extension) {
            Add-Result $extension 'Already installed'
        }
        elseif (Test-ShouldRun $extension 'code --install-extension') {
            code.cmd --install-extension $extension
            if ($LASTEXITCODE -eq 0) { Add-Result $extension 'Installed' }
            else { Add-Result $extension 'FAILED' "code exit code $LASTEXITCODE" }
        }
        else {
            Add-Result $extension 'Would install'
        }
    }
}

#endregion

#region Dev tools inside WSL

# Runs inside the distro as root. Kept in this file so the script stays a single download.
$wslToolsScript = @'
# Installs .NET + React dev tools inside WSL Ubuntu. Safe to re-run.
# Settings arrive as environment variables passed through WSLENV by setup-devbox.ps1.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive DOTNET_NOLOGO=1

dotnet_sdks="${DEVBOX_DOTNET_SDKS:-10}"
node_major="${DEVBOX_NODE_MAJOR:-24}"
git_name="${DEVBOX_GIT_NAME:-}"
git_email="${DEVBOX_GIT_EMAIL:-}"
apt="apt-get -y -q -o DPkg::Lock::Timeout=600"

step() { printf '\n--- %s\n' "$*"; }

# Ubuntu runs cloud-init on first boot; let it finish so it isn't holding the apt lock.
if command -v cloud-init > /dev/null; then
    cloud-init status --wait > /dev/null 2>&1 || true
fi

step 'Base packages'
$apt update
$apt install build-essential ca-certificates curl git gnupg software-properties-common unzip zip

step "Package sources: GitHub CLI, Node.js $node_major"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${node_major}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
# Prefer NodeSource's nodejs (which includes npm) over Ubuntu's own package.
printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' > /etc/apt/preferences.d/nodesource
chmod a+r /etc/apt/keyrings/*.gpg
$apt update

# Newer .NET versions reach older Ubuntu releases through Canonical's backports PPA.
dotnet_packages=()
for v in $dotnet_sdks; do
    dotnet_packages+=("dotnet-sdk-$v.0")
done
for p in "${dotnet_packages[@]}"; do
    if ! apt-cache show "$p" > /dev/null 2>&1; then
        step "Adding the .NET backports PPA for $p"
        add-apt-repository -y ppa:dotnet/backports
        $apt update
        break
    fi
done

step 'Installing GitHub CLI, Node.js, .NET SDK'
$apt install gh nodejs "${dotnet_packages[@]}"

step 'Git'
# System-wide, because the Linux user is only created the first time Ubuntu is opened.
git config --system init.defaultBranch main
if [ -n "$git_name" ]; then git config --system user.name "$git_name"; fi
if [ -n "$git_email" ]; then git config --system user.email "$git_email"; fi
# Use Windows' Git Credential Manager, so pushes from Ubuntu use the same sign-in as Windows.
gcm='/mnt/c/Program Files/Git/mingw64/bin/git-credential-manager.exe'
if [ -f "$gcm" ]; then
    git config --system credential.helper "${gcm// /\\ }"
fi

step 'Installed versions'
echo "git     $(git --version)"
echo "gh      $(gh --version | sed -n 1p)"
echo "dotnet  $(dotnet --list-sdks | cut -d' ' -f1 | tr '\n' ' ')"
echo "node    $(node --version)"
echo "npm     $(npm --version)"
'@

if ($IncludeWsl) {
    Write-Section "Dev tools in $WslDistro"
    $toolsName = "$WslDistro dev tools"

    if (-not (Test-WslDistro $WslDistro)) {
        if ($WhatIfPreference) { Add-Result $toolsName 'Would install' }
        else { Add-Result $toolsName 'Restart needed' "installs on the next run, with $WslDistro" }
    }
    else {
        wsl.exe -d $WslDistro -u root -e sh -c 'command -v git && command -v gh && command -v dotnet && command -v node' *> $null
        $haveTools = ($LASTEXITCODE -eq 0)

        if ($haveTools -and -not $Upgrade) {
            Add-Result $toolsName 'Already installed'
        }
        elseif (Test-ShouldRun $toolsName 'Install Git, GitHub CLI, .NET SDK and Node.js with apt') {
            # Settings travel into Linux as environment variables listed in WSLENV.
            # Node matches the major version installed on Windows.
            $env:DEVBOX_DOTNET_SDKS = $DotNetSdks -join ' '
            $env:DEVBOX_NODE_MAJOR = if (Test-Command node) { (node --version) -replace '^v(\d+).*', '$1' } else { '24' }
            $env:DEVBOX_GIT_NAME = $GitUserName
            $env:DEVBOX_GIT_EMAIL = $GitUserEmail
            $env:WSLENV = (@($env:WSLENV, 'DEVBOX_DOTNET_SDKS/u:DEVBOX_NODE_MAJOR/u:DEVBOX_GIT_NAME/u:DEVBOX_GIT_EMAIL/u') | Where-Object { $_ }) -join ':'

            # bash can't run a script with Windows (CRLF) line endings.
            $scriptFile = Join-Path $env:TEMP 'devbox-setup-wsl.sh'
            [IO.File]::WriteAllText($scriptFile, ($wslToolsScript -replace "`r`n", "`n"))

            Write-Host "  Installing in $WslDistro with apt (takes a few minutes)..."
            wsl.exe -d $WslDistro -u root --cd $env:TEMP -e bash ./devbox-setup-wsl.sh
            if ($LASTEXITCODE -ne 0) { Add-Result $toolsName 'FAILED' "exit code $LASTEXITCODE - see the output above" }
            elseif ($haveTools) { Add-Result $toolsName 'Upgraded' }
            else { Add-Result $toolsName 'Installed' 'git, gh, .NET SDK, Node.js' }
        }
        else {
            Add-Result $toolsName 'Would install'
        }
    }
}

#endregion

#region GitHub CLI

Write-Section 'GitHub CLI'

if (-not (Test-Command gh)) {
    Add-Result 'GitHub sign-in' 'Skipped' 'gh not on PATH yet'
}
else {
    gh auth status *> $null
    if ($LASTEXITCODE -eq 0) {
        Add-Result 'GitHub sign-in' 'Already signed in'
    }
    elseif ($GitHubLogin -and (Test-ShouldRun 'GitHub' 'gh auth login')) {
        gh auth login --hostname github.com --git-protocol https --web
        if ($LASTEXITCODE -eq 0) { Add-Result 'GitHub sign-in' 'Signed in' }
        else { Add-Result 'GitHub sign-in' 'FAILED' "gh exit code $LASTEXITCODE" }
    }
    elseif ($GitHubLogin) {
        Add-Result 'GitHub sign-in' 'Would sign in'
    }
    else {
        Add-Result 'GitHub sign-in' 'Skipped' 'run: gh auth login'
    }
}

#endregion

#region Summary

Write-Section 'Summary'
$script:Results | Format-Table -AutoSize -Wrap | Out-Host

Write-Section 'Versions'
Update-SessionPath
$versionChecks = [ordered]@{
    'git'    = @('git', { git --version })
    'gh'     = @('gh', { gh --version | Select-Object -First 1 })
    'dotnet' = @('dotnet', { (dotnet --list-sdks | ForEach-Object { ($_ -split ' ')[0] }) -join ', ' })
    'node'   = @('node', { node --version })
    'npm'    = @('npm.cmd', { npm.cmd --version })
    'code'   = @('code.cmd', { code.cmd --version | Select-Object -First 1 })
}
foreach ($name in $versionChecks.Keys) {
    $exe, $getVersion = $versionChecks[$name]
    $version = if (Test-Command $exe) { & $getVersion } else { 'not found' }
    Write-Host ('  {0,-8} {1}' -f $name, $version)
}

Write-Section 'Next steps'
if ($script:AfterRestart.Count -gt 0) {
    Write-Host "  * Restart Windows, then run setup again to install $($script:AfterRestart -join ' and ') (they need WSL running)." -ForegroundColor Yellow
}
elseif ($script:RestartNeeded) {
    Write-Host '  * Restart Windows to finish installing (WSL / Docker / other packages asked for it).' -ForegroundColor Yellow
}
Write-Host '  * Open a NEW terminal so PATH changes take effect.'
if ($IncludeWsl -and -not $script:AfterRestart.Contains($WslDistro)) {
    Write-Host "  * Open $WslDistro from the Start menu once to create your Linux username and password."
    Write-Host "    Then, inside $WslDistro, run 'gh auth login' to use the GitHub CLI there (git push already uses your Windows sign-in)."
}
Write-Host '  * Sign in to GitHub if you have not:   gh auth login'
Write-Host '  * Start a project:'
Write-Host '      dotnet new webapi -o MyApp.Api'
Write-Host '      npm create vite@latest my-app -- --template react-ts'
Write-Host ''
Write-Host "  Log: $logPath" -ForegroundColor DarkGray

Stop-Transcript | Out-Null

$failedCount = @($script:Results | Where-Object { $_.Status -eq 'FAILED' }).Count
if ($failedCount -gt 0) {
    Write-Host "$failedCount step(s) failed - see above." -ForegroundColor Red
    exit 1
}

#endregion
