#Requires -Version 5.1
<#
  One-shot: copy Setup Server Stack over SSH and run setup-server-stack.sh as root.
  Password auth: prompted once at start (or -RootPassword / -SshIdentityFile).

  Requires ssh, scp, ssh-keygen (OpenSSH Client on Windows).

  Host: DOMAIN in .env or -RemoteHost. Remote path: SETUP_SERVER_STACK_ROOT in .env or /opt/setup-server-stack.
  Options: -SkipInstall, -ForceSecrets, -SshIdentityFile path\to\key, -RootPassword (SecureString)
  After install: downloads server .secrets to LocalStackPath\secrets\<timestamp>, downloads exported TLS certs to certs\<host>, then applies SSH hardening on the server.
#>

[CmdletBinding()]
param(
    [string]$RemoteHost = "",
    [string]$RemotePath = "",
    [string]$LocalStackPath = "",
    [ValidateRange(0, 65535)]
    [int]$SshPort = 0,
    [string]$SshIdentityFile = "",
    [SecureString]$RootPassword,
    [switch]$SkipInstall,
    [switch]$ForceSecrets
)

$ErrorActionPreference = "Stop"
$script:DeploySshConfigTemp = $null
$script:DeployStagingPath = $null
$script:DeployAskPassCmd = $null
$script:DeployControlPath = $null
$script:DeployPasswordPlain = $null
$script:SshExe = "ssh"
$script:ScpExe = "scp"
# Windows OpenSSH: ControlMaster/ControlPath → "getsockname failed: Not a socket"
$script:DeployUseMultiplex = $false

function Test-Cmd([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

foreach ($cmd in @("ssh", "scp", "ssh-keygen")) {
    if (-not (Test-Cmd $cmd)) {
        Write-Error "Command $cmd is required. Enable OpenSSH Client in Windows optional features."
    }
}

if ([string]::IsNullOrWhiteSpace($LocalStackPath)) { $LocalStackPath = $PSScriptRoot }
$LocalStackPath = (Resolve-Path -LiteralPath $LocalStackPath).Path

foreach ($f in @(
        "docker-compose.yml", "setup-server-stack.sh", "install.sh",
        "lib/setup-server-stack-lib.sh", "lib/docker-install.inc.sh", ".env.example"
    )) {
    if (-not (Test-Path -LiteralPath (Join-Path $LocalStackPath $f))) {
        Write-Error "Missing $f in $LocalStackPath"
    }
}

$envFile = Join-Path $LocalStackPath ".env"
$stackRootFromEnv = ""
$domainFromEnv = ""
$enableDeployer = $false
$deployerImageFromEnv = ""

if (Test-Path -LiteralPath $envFile) {
    foreach ($raw in Get-Content -LiteralPath $envFile -Encoding UTF8 -ErrorAction SilentlyContinue) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        if ($SshPort -eq 0 -and $line -match '^\s*SSH_PORT\s*=\s*"?(\d+)"?\s*$') { $SshPort = [int]$Matches[1] }
        if ($line -match '^\s*ENABLE_DEPLOYER\s*=\s*"?1"?\s*$') { $enableDeployer = $true }
        if ($line -match '^\s*DEPLOYER_IMAGE\s*=') {
            $v = ($line -replace '^\s*DEPLOYER_IMAGE\s*=\s*', '').Split('#')[0].Trim().Trim('"')
            if ($v) { $deployerImageFromEnv = $v }
        }
        if (-not $PSBoundParameters.ContainsKey('RemotePath') -and $line -match '^\s*SETUP_SERVER_STACK_ROOT\s*=') {
            $v = ($line -replace '^\s*SETUP_SERVER_STACK_ROOT\s*=\s*', '').Split('#')[0].Trim().Trim('"')
            if ($v) { $stackRootFromEnv = $v }
        }
        if (-not $PSBoundParameters.ContainsKey('RemotePath') -and [string]::IsNullOrWhiteSpace($stackRootFromEnv) -and $line -match '^\s*STACK_ROOT\s*=') {
            $v = ($line -replace '^\s*STACK_ROOT\s*=\s*', '').Split('#')[0].Trim().Trim('"')
            if ($v -and $v.StartsWith('/')) { $stackRootFromEnv = $v }
        }
        if ($line -match '^\s*DOMAIN\s*=') {
            $v = ($line -replace '^\s*DOMAIN\s*=\s*', '').Split('#')[0].Trim().Trim('"')
            if ($v) { $domainFromEnv = $v }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RemoteHost)) {
    if ($domainFromEnv) { $RemoteHost = $domainFromEnv }
}
if ($SshPort -eq 0) { $SshPort = 22 }
if ([string]::IsNullOrWhiteSpace($RemotePath)) {
    $RemotePath = if ($stackRootFromEnv) { $stackRootFromEnv } else { "/opt/setup-server-stack" }
}
if ([string]::IsNullOrWhiteSpace($RemoteHost)) {
    Write-Error "Set DOMAIN in .env (FQDN for SSH/TLS) or pass -RemoteHost with the server IP."
}

function Get-DeployConnectIPv4([string]$Name) {
    if ($Name -match '^(?:\d{1,3}\.){3}\d{1,3}$') { return $Name }
    try {
        $ip = [System.Net.Dns]::GetHostAddresses($Name) |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            Select-Object -First 1
        if ($ip) { return $ip.IPAddressToString }
    } catch { }
    return $Name
}

$RemoteHostName = $RemoteHost
$DeployConnectHost = Get-DeployConnectIPv4 $RemoteHost

$RemotePath = $RemotePath.TrimEnd("/")
if ($RemotePath -notmatch "^/") { Write-Error "SETUP_SERVER_STACK_ROOT / RemotePath must be absolute, e.g. /opt/setup-server-stack" }
$lastSlash = $RemotePath.LastIndexOf("/")
$remoteParent = if ($lastSlash -le 0) { "/" } else { $RemotePath.Substring(0, $lastSlash) }
$remoteLeaf = Split-Path -Leaf $RemotePath

$CopySourcePath = $null
if (-not (Test-Cmd "robocopy")) {
    Write-Error "robocopy is required to create a safe upload staging folder on Windows."
}
$stRoot = Join-Path $env:TEMP ("sss-deploy-{0}" -f $PID)
$st = Join-Path $stRoot $remoteLeaf
if (Test-Path -LiteralPath $stRoot) { Remove-Item -LiteralPath $stRoot -Recurse -Force }
New-Item -ItemType Directory -Path $st -Force | Out-Null
$excludeDirs = @(".git", ".ssh-bootstrap", ".cursor", "secrets", "traefik", "filebrowser", "certs", "registry", "portainer", "semaphore", "duplicati", "gocron", "kuma", "pgadmin", "postgres", "mongo", "mariadb", "mysql")
$excludeFiles = @(
    ".secrets", ".setup-server-stack-secrets", ".env.stack",
    "*.secrets", "*.secrets-backup", "secrets-backup.txt",
    "acme.json", "*.pem", "auth_config.yml", "config.json",
    "htpasswd", "htpasswd-doku", "docker-compose.override.yml"
)
& robocopy.exe $LocalStackPath $st /E /XD @excludeDirs /XF @excludeFiles /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-Error "robocopy staging failed with exit code $LASTEXITCODE."
}
$localCerts = Join-Path $LocalStackPath "certs"
if (Test-Path -LiteralPath $localCerts) {
    $certsTarget = Join-Path $st "certs"
    New-Item -ItemType Directory -Path $certsTarget -Force | Out-Null
    Get-ChildItem -LiteralPath $localCerts -Directory | ForEach-Object {
        $targetDir = Join-Path $certsTarget $_.Name
        & robocopy.exe $_.FullName $targetDir /E /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
        if ($LASTEXITCODE -ge 8) {
            Write-Error "robocopy TLS certificates failed for $($_.Name) with exit code $LASTEXITCODE."
        }
    }
}
$CopySourcePath = $st
$script:DeployStagingPath = $stRoot
$localLeaf = Split-Path -Leaf $CopySourcePath

if ($enableDeployer -and [string]::IsNullOrWhiteSpace($deployerImageFromEnv)) {
    $deployerImageFromEnv = "commercedeployer/deployer:latest"
}

$useIdentity = -not [string]::IsNullOrWhiteSpace($SshIdentityFile)
if (-not $useIdentity -and -not $RootPassword) {
    try {
        if ([Console]::IsInputRedirected) {
            Write-Error "Interactive terminal required for root password (or use -SshIdentityFile / -RootPassword)."
        }
    } catch { }
}

$wSsh = Join-Path $env:SystemRoot "System32\OpenSSH\ssh.exe"
$wScp = Join-Path $env:SystemRoot "System32\OpenSSH\scp.exe"
if ((Test-Path -LiteralPath $wSsh) -and (Test-Path -LiteralPath $wScp)) {
    $script:SshExe = $wSsh; $script:ScpExe = $wScp
} else { $script:SshExe = "ssh"; $script:ScpExe = "scp" }

$kg = (Get-Command ssh-keygen -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($kg)) { $kg = "ssh-keygen" }
$tOut = [System.IO.Path]::GetTempFileName(); $tErr = [System.IO.Path]::GetTempFileName()
$khRemove = if ($SshPort -ne 22) { '[' + $DeployConnectHost + ']:' + [string]$SshPort } else { $DeployConnectHost }
$null = Start-Process -FilePath $kg -ArgumentList @("-R", $khRemove) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tOut -RedirectStandardError $tErr
Remove-Item -LiteralPath $tOut, $tErr -Force -ErrorAction SilentlyContinue

$sshTarget = "root@${DeployConnectHost}"
$aa = [string][char]38 + [char]38
$sedLf = 'for f in setup-server-stack.sh install.sh lib/setup-server-stack-lib.sh lib/docker-install.inc.sh; do sed -i ''s/\r$//'' "$f" 2>/dev/null; done'
$installFlag = if ($ForceSecrets) { " --force-secrets" } else { "" }
$remoteInstallCmd = (('cd ''{0}'' ' + $aa + ' ' + $sedLf + ' ' + $aa + ' chmod +x setup-server-stack.sh install.sh ' + $aa + ' bash ./setup-server-stack.sh --skip-ssh-hardening{1}') -f $RemotePath, $installFlag)
$remoteHardenCmd = (('cd ''{0}'' ' + $aa + ' bash ./setup-server-stack.sh --ssh-hardening-only') -f $RemotePath)
$remoteStateDir = "/tmp/setup-server-stack-preserve-$PID"
$runtimePaths = @(".secrets", ".env.stack", "traefik", "certs", "config", "filebrowser", "nginx", "secrets", "docker-compose.override.yml", "registry", "portainer", "semaphore", "duplicati", "gocron", "kuma", "pgadmin", "postgres", "mongo", "mariadb", "mysql")
$runtimeList = ($runtimePaths | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join " "
$remotePrepare = @"
set -eu
rm -rf '$remoteStateDir'
mkdir -p '$remoteStateDir' '$remoteParent'
if [ -d '$RemotePath' ]; then
  for p in $runtimeList; do
    if [ -e '$RemotePath'/"`$p" ]; then
      mv '$RemotePath'/"`$p" '$remoteStateDir'/
    fi
  done
  rm -rf '$RemotePath'
fi
"@ -replace "`r`n", "`n" -replace "`r", ""
$remoteRestore = @"
set -eu
mkdir -p '$RemotePath'
if [ -d '$remoteStateDir' ]; then
  for p in $runtimeList; do
    if [ -e '$remoteStateDir'/"`$p" ]; then
      rm -rf '$RemotePath'/"`$p"
      mv '$remoteStateDir'/"`$p" '$RemotePath'/
    fi
  done
  rmdir '$remoteStateDir' 2>/dev/null || true
fi
"@ -replace "`r`n", "`n" -replace "`r", ""

function ConvertTo-PlainText([Security.SecureString]$Secure) {
    if (-not $Secure) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Clear-DeployPassword {
    if ($script:DeployPasswordPlain) {
        $script:DeployPasswordPlain = $null
    }
    [Environment]::SetEnvironmentVariable("SSH_ASKPASS_PASSWORD", $null, "Process")
    [Environment]::SetEnvironmentVariable("SSH_ASKPASS", $null, "Process")
    [Environment]::SetEnvironmentVariable("SSH_ASKPASS_REQUIRE", $null, "Process")
}

function Remove-DeployArtifacts {
    Stop-DeploySshMaster -ErrorAction SilentlyContinue
    Clear-DeployPassword
    if ($script:DeployAskPassCmd -and (Test-Path -LiteralPath $script:DeployAskPassCmd)) {
        Remove-Item -LiteralPath $script:DeployAskPassCmd -Force -ErrorAction SilentlyContinue
    }
    $script:DeployAskPassCmd = $null
    if ($script:DeploySshConfigTemp -and (Test-Path -LiteralPath $script:DeploySshConfigTemp)) {
        Remove-Item -LiteralPath $script:DeploySshConfigTemp -Force -ErrorAction SilentlyContinue
    }
    $script:DeploySshConfigTemp = $null
    if ($script:DeployStagingPath -and (Test-Path -LiteralPath $script:DeployStagingPath)) {
        Remove-Item -LiteralPath $script:DeployStagingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:DeployStagingPath = $null
    if ($script:DeployControlPath -and (Test-Path -LiteralPath $script:DeployControlPath)) {
        Remove-Item -LiteralPath $script:DeployControlPath -Force -ErrorAction SilentlyContinue
    }
    $script:DeployControlPath = $null
}

function Get-DeployControlPath {
    if (-not $script:DeployControlPath) {
        $dir = Join-Path $env:TEMP ("sss-ssh-ctrl-{0}" -f $PID)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $script:DeployControlPath = (Join-Path $dir "socket.sock") -replace '\\', '/'
    }
    return $script:DeployControlPath
}

function Get-SshMultiplexOpts {
    if ($useIdentity -or -not $script:DeployUseMultiplex) { return @() }
    return @(
        "-o", "ControlMaster=no",
        "-o", "ControlPath=$(Get-DeployControlPath)",
        "-o", "ControlPersist=600"
    )
}

function Initialize-DeployPasswordAuth {
    if ($useIdentity) { return }
    if ($RootPassword) {
        $script:DeployPasswordPlain = ConvertTo-PlainText $RootPassword
    } else {
        Write-Host ""
        $sec = Read-Host "root@${DeployConnectHost} password (entered once for this run)" -AsSecureString
        if (-not $sec -or $sec.Length -eq 0) { Write-Error "Empty password." }
        $script:DeployPasswordPlain = ConvertTo-PlainText $sec
    }
    $script:DeployAskPassCmd = Join-Path $env:TEMP ("sss-askpass-{0}.cmd" -f $PID)
    '@echo off' + "`r`n" + 'echo %SSH_ASKPASS_PASSWORD%' | Set-Content -LiteralPath $script:DeployAskPassCmd -Encoding ASCII
    [Environment]::SetEnvironmentVariable("SSH_ASKPASS_PASSWORD", $script:DeployPasswordPlain, "Process")
    [Environment]::SetEnvironmentVariable("SSH_ASKPASS", $script:DeployAskPassCmd, "Process")
    [Environment]::SetEnvironmentVariable("SSH_ASKPASS_REQUIRE", "force", "Process")
}

function Invoke-DeploySsh {
    param(
        [string[]]$BaseArgs,
        [string[]]$ExtraArgs = @(),
        [switch]$RequestTty
    )
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $saved = @{}
    if ($useIdentity) {
        foreach ($k in @('SSH_AUTH_SOCK', 'SSH_ASKPASS', 'SSH_ASKPASS_REQUIRE', 'SSH_ASKPASS_PASSWORD')) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
            [Environment]::SetEnvironmentVariable($k, $null, 'Process')
        }
    }
    $argLine = [System.Collections.Generic.List[string]]::new()
    foreach ($x in $BaseArgs) { $argLine.Add($x) }
    foreach ($x in (Get-SshMultiplexOpts)) { $argLine.Add($x) }
    if ($RequestTty) { $argLine.Add("-t") }
    foreach ($x in $ExtraArgs) { $argLine.Add($x) }
    try { & $script:SshExe @($argLine.ToArray()) } finally {
        if ($useIdentity) {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
        }
        $ErrorActionPreference = $prev
    }
}

function Invoke-DeployScp {
    param(
        [string[]]$BaseArgs,
        [string[]]$ExtraArgs
    )
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $saved = @{}
    if ($useIdentity) {
        foreach ($k in @('SSH_AUTH_SOCK', 'SSH_ASKPASS', 'SSH_ASKPASS_REQUIRE', 'SSH_ASKPASS_PASSWORD')) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
            [Environment]::SetEnvironmentVariable($k, $null, 'Process')
        }
    }
    $argLine = [System.Collections.Generic.List[string]]::new()
    foreach ($x in $BaseArgs) { $argLine.Add($x) }
    foreach ($x in (Get-SshMultiplexOpts)) { $argLine.Add($x) }
    foreach ($x in $ExtraArgs) { $argLine.Add($x) }
    try { & $script:ScpExe @($argLine.ToArray()) } finally {
        if ($useIdentity) {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
        }
        $ErrorActionPreference = $prev
    }
}

function Start-DeploySshMaster {
    if ($useIdentity -or -not $script:DeployUseMultiplex) { return }
    $ctrl = Get-DeployControlPath
    Write-Host "Opening SSH session (password used once)..." -ForegroundColor DarkGray
    $masterArgs = @(
        "-4",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=25",
        "-o", "PubkeyAuthentication=no",
        "-o", "PreferredAuthentications=password,keyboard-interactive",
        "-o", "KbdInteractiveAuthentication=yes",
        "-o", "PasswordAuthentication=yes",
        "-o", "GSSAPIAuthentication=no",
        "-o", "IdentityAgent=none",
        "-o", "ControlMaster=yes",
        "-o", "ControlPath=$ctrl",
        "-o", "ControlPersist=600",
        "-f", "-N"
    )
    if ($SshPort -ne 22) { $masterArgs = @("-p", "$SshPort") + $masterArgs }
    if ($script:DeploySshConfigTemp) {
        $cfgPathForSsh = ($script:DeploySshConfigTemp -replace '\\', '/')
        $masterArgs = @("-F", $cfgPathForSsh) + $masterArgs
    }
    if ($useIdentity) {
        $idPath = (Resolve-Path -LiteralPath $SshIdentityFile).Path
        $masterArgs = @("-i", $idPath) + $masterArgs
    }
    Invoke-DeploySsh -BaseArgs $masterArgs -ExtraArgs @($sshTarget)
    if ($LASTEXITCODE -ne 0) {
        Write-Error "SSH master connection failed (exit $LASTEXITCODE). Check host, port, and password."
    }
}

function Stop-DeploySshMaster {
    if ($useIdentity -or -not $script:DeployUseMultiplex -or -not $script:DeployControlPath) { return }
    $exitArgs = @(
        "-4",
        "-o", "ControlPath=$(Get-DeployControlPath)",
        "-O", "exit",
        $sshTarget
    )
    if ($SshPort -ne 22) { $exitArgs = @("-p", "$SshPort") + $exitArgs }
    if ($script:DeploySshConfigTemp) {
        $cfgPathForSsh = ($script:DeploySshConfigTemp -replace '\\', '/')
        $exitArgs = @("-F", $cfgPathForSsh) + $exitArgs
    }
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & $script:SshExe @exitArgs 2>$null | Out-Null } finally { $ErrorActionPreference = $prev }
}

if ($useIdentity) {
    $idPath = (Resolve-Path -LiteralPath $SshIdentityFile).Path
    $baseSsh = [System.Collections.Generic.List[string]]::new()
    $baseScp = [System.Collections.Generic.List[string]]::new()
    $baseSsh.Add("-4"); $baseScp.Add("-4")
    $baseSsh.Add("-o"); $baseSsh.Add("StrictHostKeyChecking=accept-new")
    $baseScp.Add("-o"); $baseScp.Add("StrictHostKeyChecking=accept-new")
    $baseSsh.Add("-i"); $baseSsh.Add($idPath)
    $baseScp.Add("-i"); $baseScp.Add($idPath)
    if ($SshPort -ne 22) { $baseSsh.Add("-p"); $baseSsh.Add("$SshPort"); $baseScp.Add("-P"); $baseScp.Add("$SshPort") }
    $sa = $baseSsh.ToArray(); $ca = $baseScp.ToArray()
} else {
    $script:DeploySshConfigTemp = Join-Path $env:TEMP ("setup-server-stack-ssh-{0}.conf" -f $PID)
    $cfgLines = @(
        "Host *",
        "    AddressFamily inet",
        "    StrictHostKeyChecking accept-new",
        "    ConnectTimeout 30",
        "    PubkeyAuthentication no",
        "    PreferredAuthentications password,keyboard-interactive",
        "    KbdInteractiveAuthentication yes",
        "    PasswordAuthentication yes",
        "    GSSAPIAuthentication no",
        "    IdentityAgent none"
    )
    $cfgBody = ($cfgLines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($script:DeploySshConfigTemp, $cfgBody, [System.Text.UTF8Encoding]::new($false))
    $cfgPathForSsh = ($script:DeploySshConfigTemp -replace '\\', '/')
    $sshArgs = [System.Collections.Generic.List[string]]::new()
    $scpArgs = [System.Collections.Generic.List[string]]::new()
    $sshArgs.Add("-4"); $scpArgs.Add("-4")
    $sshArgs.Add("-F"); $sshArgs.Add($cfgPathForSsh)
    $scpArgs.Add("-F"); $scpArgs.Add($cfgPathForSsh)
    if ($SshPort -ne 22) { $sshArgs.Add("-p"); $sshArgs.Add("$SshPort"); $scpArgs.Add("-P"); $scpArgs.Add("$SshPort") }
    foreach ($x in @("-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "KbdInteractiveAuthentication=yes", "-o", "IdentityAgent=none")) {
        $sshArgs.Add($x); $scpArgs.Add($x)
    }
    $sa = $sshArgs.ToArray(); $ca = $scpArgs.ToArray()
}

Write-Host ""
Write-Host "=== Setup Server Stack: copy and setup-server-stack.sh ===" -ForegroundColor Cyan
if ($RemoteHostName -ne $DeployConnectHost) {
    Write-Host "  SSH via IPv4 $DeployConnectHost (resolved from $RemoteHostName)" -ForegroundColor White
} else {
    Write-Host "  SSH via $DeployConnectHost" -ForegroundColor White
}
Write-Host "  $sshTarget port $SshPort -> $RemotePath" -ForegroundColor White
$preflight = Test-NetConnection -ComputerName $DeployConnectHost -Port $SshPort -WarningAction SilentlyContinue
if (-not $preflight.TcpTestSucceeded) {
    Write-Error "TCP port $SshPort is not reachable on $DeployConnectHost. Open SSH in the VPS firewall and verify the server is running."
}
if ($enableDeployer) { Write-Host "  Deployer: enabled (image: $deployerImageFromEnv)" -ForegroundColor White }
if ($useIdentity) { Write-Host "  SSH key: $SshIdentityFile" -ForegroundColor Yellow }
else { Write-Host "  Password: entered once (SSH_ASKPASS for each step on Windows)." -ForegroundColor Yellow }
Write-Host ""

try {
    if (-not $useIdentity) {
        Initialize-DeployPasswordAuth
        Start-DeploySshMaster
    }

    Write-Host "1/5 Preparing remote directory..." -ForegroundColor Green
    Invoke-DeploySsh -BaseArgs $sa -ExtraArgs @($sshTarget, $remotePrepare)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "SSH failed. Check password/key and DNS for DOMAIN." -ForegroundColor Yellow
        exit $LASTEXITCODE
    }

    $scpTarget = if ($remoteParent -eq "/") { "${sshTarget}:/" } else { "${sshTarget}:$remoteParent/" }
    Write-Host "2/5 Copying files..." -ForegroundColor Green
    Invoke-DeployScp -BaseArgs $ca -ExtraArgs @("-r", "$CopySourcePath", $scpTarget)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Invoke-DeploySsh -BaseArgs $sa -ExtraArgs @($sshTarget, $remoteRestore)
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to restore preserved runtime files on the server."
    }

    if ($localLeaf -ne $remoteLeaf) {
        Write-Error "Local folder name ($localLeaf) does not match $remoteLeaf. Set SETUP_SERVER_STACK_ROOT in .env or enable robocopy staging."
    }

    if ($SkipInstall) {
        Write-Host ('Skipped install (-SkipInstall). On server: cd ' + $RemotePath + ' && sudo bash ./setup-server-stack.sh') -ForegroundColor Yellow
        exit 0
    }

    Write-Host "3/5 setup-server-stack.sh (install, SSH hardening deferred)..." -ForegroundColor Green
    Invoke-DeploySsh -BaseArgs $sa -ExtraArgs @($sshTarget, $remoteInstallCmd) -RequestTty
    $exitInstall = $LASTEXITCODE
    if ($exitInstall -ne 0) { exit $exitInstall }

    $localSecretsDir = Join-Path $LocalStackPath "secrets"
    New-Item -ItemType Directory -Path $localSecretsDir -Force | Out-Null
    $localSecretsName = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $localSecrets = Join-Path $localSecretsDir $localSecretsName
    $remoteSecrets = "${sshTarget}:${RemotePath}/.secrets"
    Write-Host "4/5 Downloading .secrets to $localSecrets ..." -ForegroundColor Green
    Invoke-DeployScp -BaseArgs $ca -ExtraArgs @($remoteSecrets, $localSecrets)
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to download .secrets from the server."
    }
    if (-not (Test-Path -LiteralPath $localSecrets)) {
        Write-Error "Secrets file missing after download: $localSecrets"
    }
    Write-Host "Secrets saved locally (do not commit)." -ForegroundColor DarkGray

    if (Test-Cmd "tar") {
        $remoteCertArchive = "/tmp/setup-server-stack-certs-$PID.tgz"
        $localCertArchive = Join-Path $env:TEMP ("setup-server-stack-certs-{0}.tgz" -f $PID)
        $localCertExtract = Join-Path $env:TEMP ("setup-server-stack-certs-{0}" -f $PID)
        if (Test-Path -LiteralPath $localCertExtract) { Remove-Item -LiteralPath $localCertExtract -Recurse -Force }
        New-Item -ItemType Directory -Path $localCertExtract -Force | Out-Null
        $remoteCertArchiveCmd = "cd '$RemotePath' && if [ -d certs ]; then find certs -mindepth 2 -maxdepth 2 -type f \( -name fullchain.pem -o -name privkey.pem \) | tar -czf '$remoteCertArchive' -T -; else tar -czf '$remoteCertArchive' --files-from /dev/null; fi"
        Write-Host "Downloading exported TLS certificates to local certs\\<host> ..." -ForegroundColor Green
        Invoke-DeploySsh -BaseArgs $sa -ExtraArgs @($sshTarget, $remoteCertArchiveCmd)
        if ($LASTEXITCODE -eq 0) {
            Invoke-DeployScp -BaseArgs $ca -ExtraArgs @("${sshTarget}:$remoteCertArchive", $localCertArchive)
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $localCertArchive)) {
                & tar.exe -xzf $localCertArchive -C $localCertExtract
                $downloaded = 0
                $extractedCerts = Join-Path $localCertExtract "certs"
                if (Test-Path -LiteralPath $extractedCerts) {
                    Get-ChildItem -LiteralPath $extractedCerts -Recurse -File | Where-Object { $_.Name -in @("fullchain.pem", "privkey.pem") } | ForEach-Object {
                        $rel = $_.FullName.Substring($localCertExtract.Length).TrimStart([char[]]@('\', '/'))
                        $target = Join-Path $LocalStackPath $rel
                        if (-not (Test-Path -LiteralPath $target)) {
                            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                            Copy-Item -LiteralPath $_.FullName -Destination $target
                            $downloaded++
                        }
                    }
                }
                if ($downloaded -gt 0) {
                    Write-Host "Saved $downloaded TLS certificate files locally under certs\\<host>." -ForegroundColor Green
                } else {
                    Write-Host "No new TLS certificate files to save locally." -ForegroundColor DarkGray
                }
            }
        }
        Invoke-DeploySsh -BaseArgs $sa -ExtraArgs @($sshTarget, "rm -f '$remoteCertArchive'") | Out-Null
        Remove-Item -LiteralPath $localCertArchive, $localCertExtract -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Skipping TLS certificate download: local tar command was not found." -ForegroundColor Yellow
    }

    Write-Host "5/5 SSH hardening on server..." -ForegroundColor Green
    Invoke-DeploySsh -BaseArgs $sa -ExtraArgs @($sshTarget, $remoteHardenCmd)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host "Done. Passwords: $localSecrets" -ForegroundColor Green
} finally {
    Remove-DeployArtifacts
}
