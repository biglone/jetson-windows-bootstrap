param(
    [string]$HostAlias = "jetson",
    [string]$JetsonUser = "Biglone",
    [string]$SshKeyName = "id_ed25519_jetson",
    [string]$InstallDir = "C:\tools\frp",
    [string]$FrpVersion = "latest",
    [string]$FrpServerAddr = "",
    [int]$FrpServerPort = 7000,
    [string]$FrpToken = "",
    [string]$FrpVisitorName = "company_ssh",
    [string]$FrpSecretKey = "",
    [string]$BindAddr = "127.0.0.1",
    [int]$BindPort = 6000,
    [switch]$SkipDownload,
    [switch]$SkipStartupRegistration,
    [switch]$SkipLaunch
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ManagedBlockStart = "# >>> jetson bootstrap >>>"
$ManagedBlockEnd = "# <<< jetson bootstrap <<<"
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LocalConfigPath = Join-Path $RepoRoot "config.local.ps1"

if (Test-Path -LiteralPath $LocalConfigPath) {
    . $LocalConfigPath
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Require-Value {
    param(
        [string]$Name,
        [string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Missing required value: $Name. Set it via parameters or config.local.ps1."
    }
}

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Get-FrpArch {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    switch ($arch.ToString().ToLowerInvariant()) {
        "x64" { return "amd64" }
        "arm64" { return "arm64" }
        default { throw "Unsupported Windows architecture: $arch" }
    }
}

function Get-FrpRelease {
    param(
        [string]$Version,
        [string]$Arch
    )

    $repoApi = "https://api.github.com/repos/fatedier/frp/releases"
    if ($Version -eq "latest") {
        $release = Invoke-RestMethod -Uri "$repoApi/latest"
    } else {
        $tag = if ($Version.StartsWith("v")) { $Version } else { "v$Version" }
        $release = Invoke-RestMethod -Uri "$repoApi/tags/$tag"
    }

    $normalizedVersion = $release.tag_name.TrimStart("v")
    $assetName = "frp_${normalizedVersion}_windows_${Arch}.zip"
    $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if (-not $asset) {
        throw "Could not find FRP asset $assetName in release $($release.tag_name)"
    }

    return @{
        Version = $normalizedVersion
        AssetName = $asset.name
        DownloadUrl = $asset.browser_download_url
    }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Set-ManagedBlock {
    param(
        [string]$Path,
        [string]$StartMarker,
        [string]$EndMarker,
        [string]$BlockContent
    )

    $existing = ""
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw
    }

    $escapedStart = [regex]::Escape($StartMarker)
    $escapedEnd = [regex]::Escape($EndMarker)
    $pattern = "(?ms)^$escapedStart.*?^$escapedEnd\s*"
    if ($existing -match $pattern) {
        $updated = [regex]::Replace($existing, $pattern, $BlockContent + [Environment]::NewLine)
    } elseif ([string]::IsNullOrWhiteSpace($existing)) {
        $updated = $BlockContent + [Environment]::NewLine
    } else {
        $trimmed = $existing.TrimEnd()
        $updated = $trimmed + [Environment]::NewLine + [Environment]::NewLine + $BlockContent + [Environment]::NewLine
    }

    Set-Content -LiteralPath $Path -Value $updated -NoNewline
}

function Install-Frpc {
    param(
        [string]$TargetDir,
        [string]$Version
    )

    $arch = Get-FrpArch
    $release = Get-FrpRelease -Version $Version -Arch $arch
    $zipPath = Join-Path $env:TEMP $release.AssetName
    $extractRoot = Join-Path $env:TEMP ("frp_extract_" + [guid]::NewGuid().ToString("N"))

    Write-Step "Downloading FRP $($release.Version) ($arch)"
    Invoke-WebRequest -Uri $release.DownloadUrl -OutFile $zipPath

    Write-Step "Extracting FRP"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

    $frpcSource = Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter "frpc.exe" | Select-Object -First 1
    if (-not $frpcSource) {
        throw "frpc.exe was not found after extracting $($release.AssetName)"
    }

    Ensure-Directory -Path $TargetDir
    Copy-Item -LiteralPath $frpcSource.FullName -Destination (Join-Path $TargetDir "frpc.exe") -Force

    $licenseSource = Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter "LICENSE" | Select-Object -First 1
    if ($licenseSource) {
        Copy-Item -LiteralPath $licenseSource.FullName -Destination (Join-Path $TargetDir "LICENSE.frp") -Force
    }

    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Ensure-SshKey {
    param(
        [string]$SshDir,
        [string]$KeyName
    )

    $privateKeyPath = Join-Path $SshDir $KeyName
    $publicKeyPath = "$privateKeyPath.pub"

    if (-not (Test-Path -LiteralPath $privateKeyPath)) {
        Write-Step "Generating SSH key $KeyName"
        $comment = "windows-jetson@$env:COMPUTERNAME"
        & ssh-keygen -t ed25519 -f $privateKeyPath -C $comment -N ""
    } else {
        Write-Step "Reusing existing SSH key $KeyName"
    }

    return @{
        PrivateKey = $privateKeyPath
        PublicKey = $publicKeyPath
    }
}

function Write-FrpcConfig {
    param([string]$Path)

    $content = @"
[common]
server_addr = $FrpServerAddr
server_port = $FrpServerPort
token = $FrpToken

[$($FrpVisitorName)_visitor]
type = stcp
role = visitor
server_name = $FrpVisitorName
sk = $FrpSecretKey
bind_addr = $BindAddr
bind_port = $BindPort
"@

    Set-Content -LiteralPath $Path -Value $content
}

function Write-StartupScript {
    param(
        [string]$StartupDir,
        [string]$TargetDir
    )

    $scriptPath = Join-Path $StartupDir "start-frpc-company-ssh.bat"
    $content = @"
@echo off
cd /d "$TargetDir"
start "" /min cmd /c "frpc.exe -c frpc-visitor-company-ssh.ini >> frpc-company-ssh.log 2>&1"
"@

    Set-Content -LiteralPath $scriptPath -Value $content
    return $scriptPath
}

function Write-SshConfig {
    param(
        [string]$ConfigPath,
        [string]$KeyPath
    )

    $normalizedKeyPath = $KeyPath -replace "\\", "/"
    $sshBlock = @"
$ManagedBlockStart
Host $HostAlias
    HostName $BindAddr
    Port $BindPort
    User $JetsonUser
    IdentityFile $normalizedKeyPath
    IdentitiesOnly yes
    ProxyCommand none
$ManagedBlockEnd
"@

    Set-ManagedBlock -Path $ConfigPath -StartMarker $ManagedBlockStart -EndMarker $ManagedBlockEnd -BlockContent $sshBlock
}

function Start-Frpc {
    param([string]$ScriptPath)

    Write-Step "Starting frpc via startup script"
    Start-Process -FilePath $ScriptPath -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

Require-Command -Name "ssh"
Require-Command -Name "ssh-keygen"
Require-Value -Name "FrpServerAddr" -Value $FrpServerAddr
Require-Value -Name "FrpToken" -Value $FrpToken
Require-Value -Name "FrpSecretKey" -Value $FrpSecretKey

$sshDir = Join-Path $HOME ".ssh"
$sshConfigPath = Join-Path $sshDir "config"
$frpcExePath = Join-Path $InstallDir "frpc.exe"
$frpcConfigPath = Join-Path $InstallDir "frpc-visitor-company-ssh.ini"
$startupDir = [Environment]::GetFolderPath("Startup")

Write-Step "Preparing directories"
Ensure-Directory -Path $sshDir
Ensure-Directory -Path $InstallDir

if (-not $SkipDownload) {
    Install-Frpc -TargetDir $InstallDir -Version $FrpVersion
} elseif (-not (Test-Path -LiteralPath $frpcExePath)) {
    throw "SkipDownload was specified, but $frpcExePath does not exist."
}

$keys = Ensure-SshKey -SshDir $sshDir -KeyName $SshKeyName

Write-Step "Writing FRP config"
Write-FrpcConfig -Path $frpcConfigPath

Write-Step "Writing SSH config block"
Write-SshConfig -ConfigPath $sshConfigPath -KeyPath $keys.PrivateKey

$startupScriptPath = $null
if (-not $SkipStartupRegistration) {
    Write-Step "Registering startup script"
    $startupScriptPath = Write-StartupScript -StartupDir $startupDir -TargetDir $InstallDir
}

if (-not $SkipLaunch) {
    if (-not $startupScriptPath) {
        $startupScriptPath = Write-StartupScript -StartupDir $startupDir -TargetDir $InstallDir
    }
    Start-Frpc -ScriptPath $startupScriptPath
}

$publicKey = Get-Content -LiteralPath $keys.PublicKey -Raw
if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
    $publicKey.Trim() | Set-Clipboard
}

Write-Step "Done"
Write-Host "Public key path: $($keys.PublicKey)"
Write-Host "Public key copied to clipboard: $([bool](Get-Command Set-Clipboard -ErrorAction SilentlyContinue))"
Write-Host ""
Write-Host "Add this public key to Jetson ~/.ssh/authorized_keys before first SSH from this device:"
Write-Host $publicKey.Trim()
Write-Host ""
Write-Host "Files written:"
Write-Host "  SSH config: $sshConfigPath"
Write-Host "  FRP config: $frpcConfigPath"
if ($startupScriptPath) {
    Write-Host "  Startup script: $startupScriptPath"
}
Write-Host ""
Write-Host "Next checks:"
Write-Host "  1. netstat -ano | findstr $BindPort"
Write-Host "  2. ssh -vvv $HostAlias"
