# Dev box setup (.NET + React)

Sets up a Windows 10/11 PC for .NET and React development using winget. Safe to re-run: anything already installed is skipped.

## Run it

**Easiest:** copy this folder to the PC and double-click `setup.cmd`. It asks for admin rights, asks for your Git name/email, then installs everything unattended.

**With options:** open PowerShell as administrator in this folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup-devbox.ps1 -WhatIf     # preview only, changes nothing
.\setup-devbox.ps1 -GitUserName "Jane Doe" -GitUserEmail jane@contoso.com -GitHubLogin
.\setup-devbox.ps1 -IncludeVisualStudio -IncludeWsl -IncludeDocker -GitHubLogin   # everything except the Dev Drive
```

Run it as the developer who will use the PC (elevating through the UAC prompt), not under a separate admin account. Git config, VS Code extensions, .NET tools and the HTTPS dev certificate are all per-user.

## What it sets up

| Area | Default | Opt-in |
|---|---|---|
| Source control | Git, GitHub CLI | `-GitHubLogin` runs `gh auth login` at the end |
| .NET | .NET 10 SDK (LTS), `dotnet-ef`, .NET Aspire templates, trusted HTTPS dev certificate | `-DotNetSdks 10,8` for more SDKs; `-IncludeVisualStudio` for VS 2026 with the ASP.NET workload (`-VisualStudioEdition Professional` etc.) |
| Node / React | Node.js LTS | `-UseNvm` for nvm-windows instead; `-NpmGlobalPackages pnpm` |
| Editor | VS Code + C# Dev Kit, ESLint, Prettier, EditorConfig, GitHub Pull Requests, Azure Resources, Bicep, AWS Toolkit | |
| Shell | PowerShell 7, Windows Terminal | |
| Cloud | Azure CLI, Azure Developer CLI (`azd`), AWS CLI, Terraform | |
| ARM64 PCs | Detected automatically: Visual Studio Build Tools with the ARM64 C++ toolset and Windows 11 SDK, for Native AOT and native dependencies | `-SkipArmTools` to leave them out |
| Linux | | `-IncludeWsl` turns on the Virtual Machine Platform Windows feature and installs WSL 2 + Ubuntu (latest LTS) as the default distro, with Git, GitHub CLI, the same .NET SDKs and Node.js major version as Windows, and build tools installed inside it. Git in Ubuntu uses your Windows sign-in for pushes. Also adds the VS Code WSL extension; `-WslDistro Ubuntu-24.04` picks another distro. Open Ubuntu once afterwards to create your Linux user |
| Containers | | `-IncludeDocker` for Docker Desktop and the WSL 2 it runs on |
| Windows | Long paths enabled; PowerShell execution policy `RemoteSigned` for the current user, so `npm`/`pnpm` work in PowerShell | |
| Dev Drive | | `-IncludeDevDrive` (Windows 11) creates a 200 GB dynamically expanding [Dev Drive](https://learn.microsoft.com/windows/dev-drive/) (ReFS, antivirus tuned for builds) in `C:\DevDrive\DevDrive.vhdx`, on the first free letter from D, with a `repos` folder. A startup task re-attaches it after each restart. `-DevDriveSizeGB`, `-DevDriveLetter`, `-DevDriveVhdPath` change it |
| Git | `init.defaultBranch=main`, `core.longpaths=true`, your name and email | |
| Anything else | | `-ExtraPackages Bruno.Bruno,JetBrains.Rider` (any ID from `winget search`) |

**WSL and Docker on a PC that hasn't used WSL before:** Windows has to restart before WSL can run, and Ubuntu and Docker Desktop can't be installed until it does. The first run turns on WSL and tells you to restart. After restarting, run setup again with the same options: everything else is skipped and Ubuntu and Docker are installed. Also make sure CPU virtualization (Intel VT-x / AMD SVM) is on in the BIOS/UEFI; the script checks this and flags it, but can't change it.

To change what **every** machine gets, edit the `param(...)` defaults at the top of `setup-devbox.ps1`.

Add `-Upgrade` to update already-installed packages instead of skipping them. Each run writes a log to `%TEMP%\devbox-setup-*.log`.

## Licensing notes

- Visual Studio **Community** is free for individuals and small teams; larger organizations need Professional or Enterprise.
- Docker Desktop needs a paid subscription for larger companies (over 250 employees or $10M revenue). The script accepts package agreements on your behalf, so check this before using `-IncludeDocker`.

## Getting it onto a new PC

**Easiest:** on [github.com/daveskip/devbox-setup](https://github.com/daveskip/devbox-setup), click **Code > Download ZIP**, extract it, and double-click `setup.cmd`. If Windows warns that the file came from the internet, choose **Run**.

**One command:** paste into any PowerShell window; it asks for admin rights itself. Default options:

```powershell
irm https://raw.githubusercontent.com/daveskip/devbox-setup/main/setup-devbox.ps1 -OutFile $env:TEMP\setup-devbox.ps1; Start-Process powershell -Verb RunAs -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$env:TEMP\setup-devbox.ps1`""
```

Everything except the Dev Drive (Visual Studio, WSL + Ubuntu, Docker, GitHub sign-in):

```powershell
irm https://raw.githubusercontent.com/daveskip/devbox-setup/main/setup-devbox.ps1 -OutFile $env:TEMP\setup-devbox.ps1; Start-Process powershell -Verb RunAs -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$env:TEMP\setup-devbox.ps1`" -IncludeVisualStudio -IncludeWsl -IncludeDocker -GitHubLogin"
```
