# Requires -RunAsAdministrator
<#
  setup-wsl.ps1  v2.0.0
  Idempotent WSL2 + Ubuntu (selectable) + Python + Docker + Zsh + NVM + GitHub CLI
  PowerShell 5.1 compatible

  USAGE
    .\setup-wsl.ps1                          # interactive first run
    .\setup-wsl.ps1 -DryRun                  # preview without changes
    .\setup-wsl.ps1 -NonInteractive          # re-run using saved wsl-config.json
    .\setup-wsl.ps1 -Help                    # show this message
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NonInteractive,
    [switch]$Help,
    [string]$ConfigFile = "$PSScriptRoot\wsl-config.json",
    [string]$LogFile    = "$env:USERPROFILE\wsl-setup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

Set-StrictMode -Off   # PS5.1 strict mode is too noisy for interactive scripts
$ErrorActionPreference = 'Continue'

$Script:VERSION    = 'v2.0.0'
$Script:StartTime  = [datetime]::Now
$Script:StepTotal   = 0
$Script:StepCurrent = 0
$Script:Results    = [ordered]@{}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — EARLY EXIT: HELP
# ─────────────────────────────────────────────────────────────────────────────
if ($Help) {
    Write-Host @"

  setup-wsl.ps1  $Script:VERSION
  Idempotent WSL2 bootstrapper — Ubuntu + Python + Docker + Zsh + NVM + GitHub CLI

  USAGE
    .\setup-wsl.ps1 [flags]

  FLAGS
    -DryRun           Print every action without executing it
    -NonInteractive   Skip all prompts; load choices from wsl-config.json
    -ConfigFile       Path to config JSON  (default: .\wsl-config.json)
    -LogFile          Path for transcript  (default: ~\wsl-setup-<ts>.log)
    -Help             Show this message

  EXAMPLES
    .\setup-wsl.ps1                           # guided first run
    .\setup-wsl.ps1 -DryRun                   # safe preview
    .\setup-wsl.ps1 -NonInteractive           # repeat last run

"@
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — TRANSCRIPT + ELEVATION
# ─────────────────────────────────────────────────────────────────────────────
Start-Transcript -Path $LogFile -Append | Out-Null
Write-Host "Log : $LogFile" -ForegroundColor DarkGray
if ($DryRun)          { Write-Host "`n  *** DRY-RUN — no changes will be made ***`n" -ForegroundColor Magenta }
if ($NonInteractive)  { Write-Host "  *** NON-INTERACTIVE — loading $ConfigFile ***`n" -ForegroundColor Cyan }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host '[ERR] Please rerun in an elevated PowerShell window.' -ForegroundColor Red
    Stop-Transcript; exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — CONSOLE HELPERS
# ─────────────────────────────────────────────────────────────────────────────
function Ok   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green  }
function Skip { param([string]$m) Write-Host "  [SKIP] $m" -ForegroundColor Yellow }
function Fail { param([string]$m) Write-Host "  [ERR]  $m" -ForegroundColor Red    }
function Info { param([string]$m) Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

function Write-StepHeader {
    param([string]$Name)
    $Script:StepCurrent++
    $pad = '-' * [Math]::Max(2, 60 - $Name.Length)
    Write-Host "`n  [$($Script:StepCurrent)/$($Script:StepTotal)] $Name $pad" -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 — PROGRESS / RESULT TRACKING
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action,
        [switch]$Critical,
        [switch]$SkipWhen
    )
    Write-StepHeader $Name
    if ($SkipWhen) {
        $Script:Results[$Name] = @{ Status = 'SKIP'; Ms = 0; Detail = '' }
        Skip $Name; return
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $sw.Stop()
        $Script:Results[$Name] = @{ Status = 'OK'; Ms = $sw.ElapsedMilliseconds; Detail = '' }
    } catch {
        $sw.Stop()
        $msg = $_.Exception.Message
        $Script:Results[$Name] = @{ Status = 'FAIL'; Ms = $sw.ElapsedMilliseconds; Detail = $msg }
        Fail "$Name : $msg"
        if ($Critical) { Stop-Transcript; throw }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 — UTILITY HELPERS
# ─────────────────────────────────────────────────────────────────────────────
# PS5.1-compatible null-coalescing: returns $a if non-null/non-empty, else $b
function Coalesce { param($a, $b) if ($null -ne $a -and "$a" -ne '') { $a } else { $b } }

function Invoke-WithRetry {
    param([scriptblock]$Action, [int]$Attempts = 3, [int]$DelaySec = 5, [string]$Label = 'operation')
    for ($i = 1; $i -le $Attempts; $i++) {
        try { & $Action; return } catch {
            if ($i -eq $Attempts) { throw }
            Info "$Label : attempt $i/$Attempts failed - retrying in ${DelaySec}s..."
            Start-Sleep $DelaySec
        }
    }
}

function ConvertTo-Hashtable {
    param([object]$Obj)
    if ($null -eq $Obj) { return @{} }
    $ht = @{}
    $Obj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
    return $ht
}

function Ask-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $r = Read-Host "  $Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
        switch ($r.Trim().ToLower()) {
            'y' { return $true }  'n' { return $false }
            default { Write-Host "  Enter Y or N." -ForegroundColor Yellow }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 — CONFIG LOAD / SAVE
# ─────────────────────────────────────────────────────────────────────────────
function Import-WslConfig {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $json = Get-Content $Path -Raw | ConvertFrom-Json
        return ConvertTo-Hashtable $json
    } catch {
        Write-Host "  [WARN] Could not parse $Path - ignoring." -ForegroundColor Yellow
        return $null
    }
}

function Export-WslConfig {
    param([hashtable]$Cfg, [string]$Path)
    $Cfg['savedAt'] = (Get-Date -Format 'o')
    $Cfg | ConvertTo-Json -Depth 3 | Set-Content $Path -Encoding UTF8
    Info "Config saved: $Path"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 — SELECTION PROMPTS
# ─────────────────────────────────────────────────────────────────────────────
function Select-WslDistro {
    param([string]$Default = 'Ubuntu-24.04')
    Write-Host "`n  Fetching available WSL distributions..." -ForegroundColor DarkGray
    $fallback = @('Ubuntu-22.04', 'Ubuntu-24.04', 'Ubuntu-24.10', 'Debian', 'kali-linux', 'openSUSE-Tumbleweed')
    try {
        # wsl outputs UTF-16 LE; set console encoding to Unicode so PowerShell
        # captures it correctly, then restore the original encoding afterwards.
        $prevEnc = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        $raw = & wsl --list --online 2>&1
        [Console]::OutputEncoding = $prevEnc

        # Strip null bytes that can survive encoding transitions, then parse
        # the first token of lines that look like distro names (start with a
        # word char, not "NAME" header or prose description lines).
        $parsed = $raw |
            ForEach-Object { ($_ -replace '\x00', '').Trim() } |
            Where-Object   { $_ -ne '' } |
            ForEach-Object { ($_ -split '\s+', 2)[0].Trim() } |
            Where-Object   { $_ -match '^[A-Za-z0-9]' -and $_ -notmatch '^NAME$' -and $_.Length -gt 2 }
        $versions = if ($parsed -and $parsed.Count -gt 0) { $parsed } else { $fallback }
    } catch { $versions = $fallback }

    Write-Host "`n  Select WSL distro:" -ForegroundColor Cyan
    # Show friendly names alongside distro IDs
    $friendly = @{
        'Ubuntu'               = 'Ubuntu (latest)'
        'Ubuntu-22.04'         = 'Ubuntu 22.04 LTS'
        'Ubuntu-24.04'         = 'Ubuntu 24.04 LTS'
        'Ubuntu-24.10'         = 'Ubuntu 24.10'
        'Debian'               = 'Debian GNU/Linux'
        'kali-linux'           = 'Kali Linux Rolling'
        'openSUSE-Tumbleweed'  = 'openSUSE Tumbleweed'
        'openSUSE-Leap-15.6'   = 'openSUSE Leap 15.6'
        'OracleLinux_9_1'      = 'Oracle Linux 9.1'
        'AlmaLinux-9'          = 'AlmaLinux 9'
    }
    for ($i = 0; $i -lt $versions.Count; $i++) {
        $name = $versions[$i]
        $label = if ($friendly.ContainsKey($name)) { " ($($friendly[$name]))" } else { '' }
        $tag   = if ($name -eq $Default) { ' [default]' } else { '' }
        Write-Host "    [$($i+1)] $name$label$tag"
    }
    $defIdx = [Array]::IndexOf($versions, $Default)
    if ($defIdx -lt 0) { $defIdx = 0 }
    while ($true) {
        $r = Read-Host "  Choice [1-$($versions.Count)] (default: $($defIdx+1))"
        if ([string]::IsNullOrWhiteSpace($r)) { return $versions[$defIdx] }
        if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $versions.Count) {
            return $versions[[int]$r - 1]
        }
        Write-Host "  Enter 1-$($versions.Count)." -ForegroundColor Yellow
    }
}

function Select-InstallDrive {
    param([string]$Default = 'C')
    $drives = Get-WmiObject -Class Win32_LogicalDisk |
              Where-Object { $_.DriveType -eq 3 -and $_.Size -gt 0 } |
              ForEach-Object {
                  [PSCustomObject]@{
                      Letter = $_.DeviceID.TrimEnd(':')
                      FreeGB = [math]::Round($_.FreeSpace / 1GB, 1)
                      TotalGB = [math]::Round($_.Size / 1GB, 1)
                  }
              }

    Write-Host "`n  Select drive for WSL distro storage:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $drives.Count; $i++) {
        $d   = $drives[$i]
        $tag = if ($d.Letter -ieq $Default) { ' [default]' } else { '' }
        $warn = if ($d.FreeGB -lt 10) { '  (!low space)' } else { '' }
        Write-Host "    [$($i+1)] $($d.Letter): — $($d.FreeGB) GB free / $($d.TotalGB) GB total${tag}${warn}"
    }
    $defIdx = 0
    for ($i = 0; $i -lt $drives.Count; $i++) { if ($drives[$i].Letter -ieq $Default) { $defIdx = $i } }
    while ($true) {
        $r = Read-Host "  Choice [1-$($drives.Count)] (default: $($defIdx+1))"
        if ([string]::IsNullOrWhiteSpace($r)) { return $drives[$defIdx].Letter }
        if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $drives.Count) {
            return $drives[[int]$r - 1].Letter
        }
        Write-Host "  Enter 1-$($drives.Count)." -ForegroundColor Yellow
    }
}

function Select-PythonVersion {
    param([string]$Default = '3\.14')
    $opts = @(
        @{ Label = 'Python 3.14 (latest stable)';       Pattern = '3\.14' }
        @{ Label = 'Python 3.13 (previous stable)';     Pattern = '3\.13' }
        @{ Label = 'Python 3.12 (security fixes only)'; Pattern = '3\.12' }
    )
    Write-Host "`n  Select Python version:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $opts.Count; $i++) {
        $tag = if ($opts[$i].Pattern -eq $Default) { ' (default)' } else { '' }
        Write-Host "    [$($i+1)] $($opts[$i].Label)$tag"
    }
    $defIdx = 0
    for ($i = 0; $i -lt $opts.Count; $i++) { if ($opts[$i].Pattern -eq $Default) { $defIdx = $i } }
    while ($true) {
        $r = Read-Host "  Choice [1-$($opts.Count)] (default: $($defIdx+1))"
        if ([string]::IsNullOrWhiteSpace($r)) { return $opts[$defIdx].Pattern }
        if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $opts.Count) {
            return $opts[[int]$r - 1].Pattern
        }
        Write-Host "  Enter 1–$($opts.Count)." -ForegroundColor Yellow
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8 — COLLECT PHASE (all prompts upfront)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-CollectPhase {
    param([hashtable]$Defaults)
    $d = if ($Defaults) { $Defaults } else { @{} }

    $cfg = @{}

    # Distro + Python (network calls — do first while user reads)
    $cfg['distro']        = Select-WslDistro -Default (Coalesce $d['distro'] 'Ubuntu-24.04')
    $cfg['pythonPattern'] = Select-PythonVersion -Default (Coalesce $d['pythonPattern'] '3\.14')
    $cfg['installDrive']  = Select-InstallDrive -Default (Coalesce $d['installDrive'] 'C')

    Write-Host ''
    # UNIX identity
    $defUser = Coalesce $d['unixUser'] ''
    $cfg['unixUser'] = (Read-Host "  UNIX username          [$defUser]").Trim()
    if ([string]::IsNullOrWhiteSpace($cfg['unixUser'])) { $cfg['unixUser'] = $defUser }
    if ([string]::IsNullOrWhiteSpace($cfg['unixUser'])) { throw 'UNIX username is required.' }

    $cfg['_securePwd'] = Read-Host '  UNIX password' -AsSecureString

    # Git identity
    $defGitName  = Coalesce $d['gitName']  ''
    $defGitEmail = Coalesce $d['gitEmail'] ''
    $cfg['gitName']  = (Read-Host "  Git user.name          [$defGitName]").Trim()
    if ([string]::IsNullOrWhiteSpace($cfg['gitName']))  { $cfg['gitName']  = $defGitName }
    $cfg['gitEmail'] = (Read-Host "  Git user.email         [$defGitEmail]").Trim()
    if ([string]::IsNullOrWhiteSpace($cfg['gitEmail'])) { $cfg['gitEmail'] = $defGitEmail }

    Write-Host "`n  --- Components ---"
    $cfg['enableSystemd']  = Ask-YesNo 'Enable systemd?'               (Coalesce $d['enableSystemd']  $true)
    $cfg['installDocker']  = Ask-YesNo 'Install Docker Engine?'        (Coalesce $d['installDocker']  $true)
    $cfg['installGhCli']   = Ask-YesNo 'Install GitHub CLI (gh)?'      (Coalesce $d['installGhCli']   $true)
    $cfg['installZsh']     = Ask-YesNo 'Install Zsh + Oh-My-Zsh?'      (Coalesce $d['installZsh']     $true)
    $cfg['installNvm']     = Ask-YesNo 'Install NVM + Node.js LTS?'    (Coalesce $d['installNvm']     $false)
    $cfg['installCuda']    = Ask-YesNo 'Install NVIDIA CUDA toolkit?'  (Coalesce $d['installCuda']    $false)

    Write-Host "`n  --- SSH Key ---"
    $defComment = Coalesce $d['sshKeyComment'] "$($cfg['unixUser'])@wsl"
    $cfg['sshKeyComment'] = (Read-Host "  SSH key comment        [$defComment]").Trim()
    if ([string]::IsNullOrWhiteSpace($cfg['sshKeyComment'])) { $cfg['sshKeyComment'] = $defComment }

    Write-Host "`n  --- Dotfiles ---"
    $defUrl = Coalesce $d['dotfilesUrl'] ''
    $rawUrl = (Read-Host "  Dotfiles HTTPS repo URL (blank to skip) [$defUrl]").Trim()
    if ([string]::IsNullOrWhiteSpace($rawUrl)) { $rawUrl = $defUrl }
    if ($rawUrl -and $rawUrl -notmatch '^https?://') {
        Write-Host "  [WARN] URL must start with https:// - skipping dotfiles." -ForegroundColor Yellow
        $rawUrl = ''
    }
    $cfg['dotfilesUrl'] = $rawUrl

    Write-Host "`n  --- Windows Terminal ---"
    $defScheme = Coalesce $d['wtColorScheme'] 'One Half Dark'
    $cfg['wtColorScheme'] = (Read-Host "  Color scheme           [$defScheme]").Trim()
    if ([string]::IsNullOrWhiteSpace($cfg['wtColorScheme'])) { $cfg['wtColorScheme'] = $defScheme }

    return $cfg
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 9 — RECAP SCREEN
# ─────────────────────────────────────────────────────────────────────────────
function Show-Recap {
    param([hashtable]$Cfg)
    $yn = { param($v) if ($v) { 'YES' } else { 'NO' } }
    Write-Host "`n" + ('=' * 62) -ForegroundColor Cyan
    Write-Host '  CONFIGURATION RECAP' -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor Cyan
    Write-Host "  Distro          : $($Cfg['distro'])"
    Write-Host "  Install drive   : $($Cfg['installDrive']):"
    Write-Host "  Python          : $($Cfg['pythonPattern'] -replace '\\','').x (latest patch via pyenv)"
    Write-Host "  UNIX user       : $($Cfg['unixUser'])"
    Write-Host "  Git name        : $($Cfg['gitName'])"
    Write-Host "  Git email       : $($Cfg['gitEmail'])"
    Write-Host "  Systemd         : $(& $yn $Cfg['enableSystemd'])"
    Write-Host "  Docker CE       : $(& $yn $Cfg['installDocker'])"
    Write-Host "  GitHub CLI      : $(& $yn $Cfg['installGhCli'])"
    Write-Host "  Zsh + OMZ       : $(& $yn $Cfg['installZsh'])"
    Write-Host "  NVM + Node LTS  : $(& $yn $Cfg['installNvm'])"
    Write-Host "  CUDA toolkit    : $(& $yn $Cfg['installCuda'])"
    Write-Host "  SSH key comment : $($Cfg['sshKeyComment'])"
    $dfu = if ($Cfg['dotfilesUrl']) { $Cfg['dotfilesUrl'] } else { '(skip)' }
    Write-Host "  Dotfiles        : $dfu"
    Write-Host "  WT color scheme : $($Cfg['wtColorScheme'])"
    Write-Host ('=' * 62) -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 10 — WSL INFRASTRUCTURE
# ─────────────────────────────────────────────────────────────────────────────
function Has-UbuntuDistro {
    param([string]$Distro)
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    $list = & wsl --list --quiet 2>$null
    [Console]::OutputEncoding = $prevEnc
    ($list | ForEach-Object { ($_ -replace '\x00','').Trim() }) -contains $Distro
}

function Invoke-Wsl {
    # Thin wrapper: in DryRun, prints intent; otherwise executes
    if ($DryRun) { Write-Host "  [DRYRUN] wsl $args" -ForegroundColor Magenta }
    else         { & wsl @args }
}

function Wait-WslReady {
    param([string]$Distro, [int]$TimeoutSec = 90)
    Info "Waiting for $Distro..."
    if ($DryRun) { Ok "[DRYRUN] skipped wait"; return }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        & wsl -d $Distro -- true 2>$null
        if ($LASTEXITCODE -eq 0) { Ok "$Distro is ready"; return }
        Start-Sleep 2
    }
    throw "Timed out (${TimeoutSec}s) waiting for $Distro"
}

function Ensure-WslAndUbuntu {
    param([string]$Distro)
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        Info 'Installing WSL base'
        Invoke-Wsl --install --no-launch
        Ok 'WSL installed'
    } else { Skip 'WSL already present' }

    if (Has-UbuntuDistro $Distro) {
        if (Ask-YesNo "$Distro already exists. Re-install (wipes all data)?" $false) {
            Info "Removing $Distro"
            Invoke-Wsl --terminate $Distro
            Invoke-Wsl --unregister $Distro
            Info "Installing fresh $Distro"
            Invoke-Wsl --install -d $Distro --no-launch
            Ok "Fresh $Distro installed"
        } else { Skip "Keeping existing $Distro" }
    } else {
        Info "Installing $Distro"
        Invoke-Wsl --install -d $Distro --no-launch
        Ok "$Distro installed"
    }

    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    $wslVerbose = & wsl --list --verbose 2>$null
    [Console]::OutputEncoding = $prevEnc
    $ver = ($wslVerbose | ForEach-Object { ($_ -replace '\x00','').Trim() }) -match $Distro |
           ForEach-Object { ($_ -split '\s+' | Where-Object { $_ })[2] }
    if ($ver -ne '2') {
        Info "Converting to WSL2"
        Invoke-Wsl --set-version $Distro 2
        Ok 'Converted to WSL2'
    } else { Skip 'Already WSL2' }

    if (-not $DryRun) {
        wsl --update | Out-Null
    } else { Info '[DRYRUN] would run: wsl --update' }
}

function Get-WslDistroRegKey {
    param([string]$Distro)
    Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
        Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DistributionName -eq $Distro }
}

function Move-WslDistro {
    param([string]$Distro, [string]$TargetDrive)
    if ($DryRun) { Info "[DRYRUN] would move $Distro to ${TargetDrive}:"; return }

    # Find current drive from registry BasePath
    $regKey = Get-WslDistroRegKey $Distro
    if (-not $regKey) { throw "Distro '$Distro' not found in registry" }
    $basePath = (Get-ItemProperty $regKey.PSPath).BasePath

    # BasePath may be \\?\D:\... or C:\Users\...
    $currentDrive = if ($basePath -match '[A-Za-z]:') { $Matches[0].TrimEnd(':') } else { 'C' }

    if ($currentDrive -ieq $TargetDrive) {
        Skip "Distro already on ${TargetDrive}: — no move needed"
        return
    }

    $targetDir = "${TargetDrive}:\wsl\$Distro"
    $tempTar   = "${TargetDrive}:\wsl\_${Distro}-move.tar"
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

    Info "Exporting $Distro from ${currentDrive}: (this takes a few minutes)..."
    wsl --terminate $Distro 2>$null
    & wsl --export $Distro $tempTar
    if (-not (Test-Path $tempTar)) { throw "Export failed — tar not found at $tempTar" }

    & wsl --unregister $Distro
    Info "Importing $Distro to $targetDir..."
    & wsl --import $Distro $targetDir $tempTar --version 2

    # Restore default user (import resets to root / UID 0)
    $newKey = Get-WslDistroRegKey $Distro
    if ($newKey) {
        Set-ItemProperty -Path $newKey.PSPath -Name DefaultUid -Value 1000
    }

    Remove-Item $tempTar -Force -ErrorAction SilentlyContinue
    Ok "Moved $Distro to ${TargetDrive}:"
}

function Set-WslConfKey {
    # Merges a single key=value under [section] without overwriting other settings
    param([string]$Distro, [string]$Section, [string]$Key, [string]$Value)
    if ($DryRun) { Info "[DRYRUN] would set [$Section] $Key=$Value in /etc/wsl.conf"; return }
    # Use single-quoted here-string + placeholder substitution so no PS variable
    # expansion happens inside the bash script, then base64-encode to avoid all
    # shell quoting issues at the wsl-boundary.
    $script = @'
set -eu
CONF=/etc/wsl.conf
SECTION="__SECTION__"
KEY="__KEY__"
VAL="__VAL__"
sudo touch "$CONF"
if grep -q "^\[${SECTION}\]" "$CONF" 2>/dev/null; then
  if grep -q "^${KEY}=" "$CONF"; then
    sudo sed -i "s|^${KEY}=.*|${KEY}=${VAL}|" "$CONF"
  else
    sudo sed -i "/^\[${SECTION}\]/a ${KEY}=${VAL}" "$CONF"
  fi
else
  printf '\n[%s]\n%s=%s\n' "$SECTION" "$KEY" "$VAL" | sudo tee -a "$CONF" >/dev/null
fi
'@ -replace '__SECTION__', $Section -replace '__KEY__', $Key -replace '__VAL__', $Value
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
    & wsl -d $Distro -- bash -c "printf '%s' '$b64' | base64 -d | bash"
}

function Ensure-UnixUser {
    param([string]$Distro, [string]$User, [System.Security.SecureString]$SecurePwd)
    if ($DryRun) { Info "[DRYRUN] would create/verify user '$User'"; return }
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                 [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePwd))
    $tmp = [IO.Path]::GetTempFileName()
    try {
        # Write user:pass to temp file for chpasswd (avoids shell quoting issues)
        "${User}:${plain}" | Out-File $tmp -Encoding ASCII -NoNewline
        $exists = & wsl -d $Distro -u root -- bash -c "id -u $User 2>/dev/null || echo __missing__"
        if ($exists -match '__missing__') {
            wsl -d $Distro -u root -- useradd -m -s /bin/bash $User
            Ok "User '$User' created"
        } else {
            Info "User '$User' already exists - updating password and group membership"
        }
        # Always apply password and sudo group regardless of whether user is new or existing.
        # This handles the common case where Ubuntu first-boot already created the account.
        Get-Content $tmp | wsl -d $Distro -u root -- chpasswd
        wsl -d $Distro -u root -- usermod -aG sudo $User
        Ok "Password set and sudo group confirmed for '$User'"
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        $plain = $null
    }
}

function Set-PasswordlessSudo {
    param([string]$Distro, [string]$User)
    if ($DryRun) { Info "[DRYRUN] would configure passwordless sudo for '$User'"; return }
    $bash = @"
set -euo pipefail
echo '${User} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/99_wsl_nopasswd > /dev/null
sudo chmod 0440 /etc/sudoers.d/99_wsl_nopasswd
if ! sudo visudo -c -f /etc/sudoers.d/99_wsl_nopasswd >/dev/null 2>&1; then
  echo '[ERR] sudoers syntax check failed — removing bad file' >&2
  sudo rm -f /etc/sudoers.d/99_wsl_nopasswd
  exit 1
fi
"@
    wsl -d $Distro -u root -- bash -c $bash
    Ok "Passwordless sudo enabled for '$User' (visudo validated)"
}

function Set-DefaultWslUser {
    param([string]$Distro, [string]$User)
    if ($DryRun) { Info "[DRYRUN] would set DefaultUid for '$User' in registry"; return }
    $uid = wsl -d $Distro -u root -- bash -lc "id -u $User" |
           ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    Get-ChildItem $key | ForEach-Object {
        if ((Get-ItemProperty $_.PSPath).DistributionName -eq $Distro) {
            Set-ItemProperty -Path $_.PSPath -Name DefaultUid -Value ([int]$uid)
            Ok "Default user for $Distro = '$User' (uid $uid)"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 11 — FEATURE FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
function Set-WslSshKey {
    param([string]$Distro, [string]$User, [string]$Comment)
    if ($DryRun) { Info "[DRYRUN] would generate ed25519 SSH key (comment: $Comment)"; return }
    $bash = @'
set -euo pipefail
mkdir -p ~/.ssh && chmod 700 ~/.ssh
KEY="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -C "$1" -f "$KEY" -N "" -q
fi
cat "${KEY}.pub"
'@
    $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bash))
    $cmd  = "printf '%s' '$b64' | base64 -d | bash -s -- '$Comment'"
    $pubKey = & wsl -d $Distro -u $User -- bash -c $cmd
    if ($pubKey) {
        Write-Host "`n  +-- SSH PUBLIC KEY (add to GitHub -> Settings -> SSH Keys) ---" -ForegroundColor Cyan
        Write-Host "  |   $pubKey" -ForegroundColor White
        Write-Host "  +-------------------------------------------------------------" -ForegroundColor Cyan
        Ok 'SSH key ready'
    }
}

function Install-Dotfiles {
    param([string]$Distro, [string]$User, [string]$RepoUrl)
    if ([string]::IsNullOrWhiteSpace($RepoUrl)) { Skip 'Dotfiles not requested'; return }
    if ($DryRun) { Info "[DRYRUN] would clone dotfiles from $RepoUrl"; return }
    $bash = @'
set -euo pipefail
REPO="$1"
DIR="$HOME/dotfiles"
if [ ! -d "$DIR/.git" ]; then
  git clone "$REPO" "$DIR"
else
  git -C "$DIR" pull --ff-only || true
fi
if [ -f "$DIR/install.sh" ]; then
  chmod +x "$DIR/install.sh"
  bash "$DIR/install.sh"
  echo "[OK] install.sh executed"
else
  echo "[INFO] No install.sh found — files cloned to ~/dotfiles"
fi
'@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bash))
    $cmd = "printf '%s' '$b64' | base64 -d | bash -s -- '$RepoUrl'"
    & wsl -d $Distro -u $User -- bash -c $cmd
    Ok 'Dotfiles done'
}

function Update-WindowsTerminalProfile {
    param([string]$Distro, [string]$User, [string]$ColorScheme)
    if ($DryRun) { Info "[DRYRUN] would configure Windows Terminal profile for $Distro"; return }

    $candidates = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )
    $settingsPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $settingsPath) { Skip 'Windows Terminal not found — skipping profile'; return }

    # Back up before modifying
    Copy-Item $settingsPath "$settingsPath.bak" -Force
    Info "Backed up WT settings to $settingsPath.bak"

    try {
        $json     = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $startDir = "//wsl$/$Distro/home/$User"

        $existing = $json.profiles.list | Where-Object {
            ($_.name -and $_.name -like "*$Distro*") -or ($_.source -and $_.source -like '*Wsl*' -and $_.name -like "*$Distro*")
        } | Select-Object -First 1

        if ($existing) {
            $existing | Add-Member -NotePropertyName 'startingDirectory' -NotePropertyValue $startDir   -Force
            $existing | Add-Member -NotePropertyName 'colorScheme'       -NotePropertyValue $ColorScheme -Force
            Ok "Updated existing Windows Terminal profile for $Distro"
        } else {
            $newProfile = [PSCustomObject]@{
                guid              = [guid]::NewGuid().ToString('B')
                name              = $Distro
                source            = 'Windows.Terminal.Wsl'
                startingDirectory = $startDir
                colorScheme       = $ColorScheme
            }
            # PS5.1: array concat since arrays are fixed-size
            $json.profiles.list = $json.profiles.list + @($newProfile)
            Ok "Added new Windows Terminal profile for $Distro"
        }

        $json | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
    } catch {
        Write-Host "  [WARN] WT profile update failed: $_  (backup at $settingsPath.bak)" -ForegroundColor Yellow
        throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 12 — UBUNTU BOOTSTRAP (bash, base64-encoded)
# ─────────────────────────────────────────────────────────────────────────────
function Start-UbuntuBootstrap {
    param(
        [string]$Distro,
        [string]$User,
        [hashtable]$Cfg
    )

    $raw = @'
#!/usr/bin/env bash
# Bootstrap runs inside WSL as the target user

source ~/.bashrc  2>/dev/null || true
source ~/.profile 2>/dev/null || true

set -euo pipefail

DOCKER="$1"; CUDA="$2"; ZSH="$3"; NVM="$4"; GH="$5"
GITNAME="$6"; GITEMAIL="$7"; PYPATTERN="$8"

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo -e "\n\e[1;36m[*] $*\e[0m"; }
ok()   { echo -e "\e[1;32m[OK] $*\e[0m"; }
skip() { echo -e "\e[1;33m[SKIP] $*\e[0m"; }

CURRENT_STEP="init"
on_error() {
    echo -e "\n\e[1;31m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
    echo -e "\e[1;31m  BOOTSTRAP FAILED at step: $CURRENT_STEP\e[0m"
    echo -e "\e[1;31m  Re-run setup-wsl.ps1 to resume (it is idempotent).\e[0m"
    echo -e "\e[1;31m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
}
trap on_error ERR

retry() {
    local n=0 max=3 delay=5
    until [ $n -ge $max ]; do
        "$@" && return 0
        n=$((n+1))
        # Recover interrupted dpkg before retrying any apt/dpkg command
        case "$*" in *apt-get*|*dpkg*)
            sudo dpkg --configure -a 2>/dev/null || true ;;
        esac
        echo "  [retry $n/$max] waiting ${delay}s..." >&2
        sleep $delay
    done
    echo "  [FAIL] command failed after $max attempts: $*" >&2
    return 1
}

# Check available disk space in KB; warn and skip if below threshold
check_disk() {
    local need_kb="$1" label="$2"
    local free_kb
    free_kb=$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ')
    if [ -z "$free_kb" ] || [ "$free_kb" -lt "$need_kb" ]; then
        local free_mb=$(( ${free_kb:-0} / 1024 ))
        local need_mb=$(( need_kb / 1024 ))
        warn "Skipping ${label}: only ${free_mb}MB free, need ${need_mb}MB"
        return 1
    fi
    return 0
}

export DEBIAN_FRONTEND=noninteractive

# ── 1. Core tools ─────────────────────────────────────────────────────────────
CURRENT_STEP="Core tools"
if ! command -v gcc >/dev/null 2>&1; then
  log "Installing core tools"
  retry sudo apt-get update -y
  retry sudo apt-get install -y build-essential git curl wget unzip zip ca-certificates gnupg
  ok "Core tools installed"
else skip "Core tools already present"; fi

# ── 2. Git config ─────────────────────────────────────────────────────────────
CURRENT_STEP="Git config"
if [ -z "$(git config --global user.name 2>/dev/null || true)" ]; then
  log "Configuring Git"
  git config --global user.name  "$GITNAME"
  git config --global user.email "$GITEMAIL"
  git config --global init.defaultBranch main
  ok "Git configured"
else skip "Git already configured"; fi

# ── 3. Docker CE ──────────────────────────────────────────────────────────────
CURRENT_STEP="Docker CE"
if [ "$DOCKER" = "true" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker CE (official repo)"
    sudo install -m 0755 -d /etc/apt/keyrings
    retry curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    retry sudo apt-get update -y
    retry sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
    ok "Docker CE installed (re-login or run 'newgrp docker' for group to take effect)"
  else skip "Docker already present"; fi
fi

# ── 4. GitHub CLI ─────────────────────────────────────────────────────────────
CURRENT_STEP="GitHub CLI"
if [ "$GH" = "true" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    log "Installing GitHub CLI"
    type -p wget >/dev/null 2>&1 || (sudo apt-get update -y && sudo apt-get install -y wget)
    sudo mkdir -p -m 755 /etc/apt/keyrings
    tmp_gpg=$(mktemp)
    retry wget -nv -O"$tmp_gpg" https://cli.github.com/packages/githubcli-archive-keyring.gpg
    cat "$tmp_gpg" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
    rm -f "$tmp_gpg"
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    sudo mkdir -p -m 755 /etc/apt/sources.list.d
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    retry sudo apt-get update -y
    retry sudo apt-get install -y gh
    ok "GitHub CLI installed — run 'gh auth login' to authenticate"
  else skip "GitHub CLI already present"; fi
fi

# ── 5. pyenv + Python ─────────────────────────────────────────────────────────
CURRENT_STEP="pyenv"
if [ ! -d "$HOME/.pyenv" ]; then
  log "Installing pyenv dependencies"
  retry sudo apt-get update -y
  retry sudo apt-get install -y \
    make libssl-dev libbz2-dev libffi-dev libreadline-dev \
    libsqlite3-dev libncurses-dev zlib1g-dev libgdbm-dev \
    liblzma-dev uuid-dev tcl-dev tk-dev libx11-dev
  log "Installing pyenv"
  retry bash -c 'curl -fsSL https://pyenv.run | bash'
  export PYENV_ROOT="$HOME/.pyenv"
  export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
  eval "$(pyenv init --path)" 2>/dev/null || true
  eval "$(pyenv init -)"      2>/dev/null || true
  ok "pyenv installed"
else skip "pyenv already present"; fi

export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
eval "$(pyenv init --path)" 2>/dev/null || true
eval "$(pyenv init -)"      2>/dev/null || true

CURRENT_STEP="Python"
LATEST=$(pyenv install --list 2>/dev/null \
  | grep -E "^[[:space:]]*${PYPATTERN}\.[0-9]+$" | tail -1 | tr -d '[:space:]')
if [ -z "$LATEST" ]; then
  echo "[WARN] No Python matching ${PYPATTERN}.x found — falling back to 3.14" >&2
  LATEST=$(pyenv install --list 2>/dev/null \
    | grep -E '^[[:space:]]*3\.14\.[0-9]+$' | tail -1 | tr -d '[:space:]')
fi
if ! pyenv versions --bare 2>/dev/null | grep -qx "$LATEST"; then
  log "Installing Python $LATEST"
  PYTHON_CONFIGURE_OPTS="--without-ensurepip" pyenv install -s "$LATEST"
  ok "Python $LATEST installed"
else skip "Python $LATEST already present"; fi
pyenv global "$LATEST"

# pip, poetry, pipx, uv
CURRENT_STEP="pip/poetry/pipx/uv"
if ! python -m pip --version >/dev/null 2>&1; then
  log "Installing pip"
  retry bash -c 'curl -sS https://bootstrap.pypa.io/get-pip.py | python'
  ok "pip installed"
else skip "pip present"; fi

if ! command -v poetry >/dev/null 2>&1; then
  log "Installing Poetry"
  retry bash -c 'curl -sSL https://install.python-poetry.org | python -'
  ok "Poetry installed"
else skip "Poetry present"; fi

if ! command -v pipx >/dev/null 2>&1; then
  log "Installing pipx"
  python -m pip install --user pipx
  export PATH="$HOME/.local/bin:$PATH"
  ok "pipx installed"
else skip "pipx present"; fi

if ! command -v uv >/dev/null 2>&1; then
  log "Installing uv"
  pipx install uv
  ok "uv installed"
else skip "uv present"; fi

# ── 6. NVM + Node.js LTS ──────────────────────────────────────────────────────
CURRENT_STEP="NVM"
if [ "$NVM" = "true" ]; then
  if [ ! -d "$HOME/.nvm" ]; then
    log "Installing NVM"
    retry bash -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh | bash'
    # Run NVM operations in a subshell with set -u disabled; nvm.sh internally
    # uses variables that may be unset, which crashes under strict mode.
    (
      set +u
      export NVM_DIR="$HOME/.nvm"
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
      nvm install --lts
      nvm use --lts
    )
    ok "NVM + Node.js LTS installed"
  else skip "NVM already present"; fi
fi

# ── 7. CUDA ───────────────────────────────────────────────────────────────────
CURRENT_STEP="CUDA"
if [ "$CUDA" = "true" ]; then
  if [ -d /usr/lib/nvidia-cuda-toolkit ] || command -v nvcc >/dev/null 2>&1; then
    skip "CUDA present"
  # CUDA toolkit unpacks ~4 GB; check free space first (require 5 GB headroom)
  elif check_disk 5120000 "CUDA"; then
    log "Installing NVIDIA CUDA toolkit (~4 GB, this takes a while)"
    # Run in a subshell so a failure does NOT trigger the ERR trap and kill the
    # rest of the bootstrap (Zsh, SSH key, etc. must still run).
    if ( retry sudo apt-get install -y nvidia-cuda-toolkit ); then
      ok "CUDA installed"
    else
      warn "CUDA install failed — filesystem may be full or read-only."
      warn "Fix manually: sudo dpkg --configure -a && sudo apt-get install -y nvidia-cuda-toolkit"
    fi
  fi
fi

# ── 8. Zsh + Oh-My-Zsh ───────────────────────────────────────────────────────
CURRENT_STEP="Zsh"
if [ "$ZSH" = "true" ]; then
  # Check both zsh binary and Oh-My-Zsh directory so we re-run if only zsh was
  # manually installed (e.g. by the user) but OMZ setup never completed.
  if ! command -v zsh >/dev/null 2>&1 || [ ! -d "$HOME/.oh-my-zsh" ]; then
    log "Installing Zsh"
    retry sudo apt-get install -y zsh fonts-powerline
    log "Installing Oh-My-Zsh"
    RUNZSH=no KEEP_ZSHRC=yes retry bash -c \
      'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
    ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    log "Installing Powerlevel10k"
    rm -rf "$ZSH_CUSTOM/themes/powerlevel10k"
    retry git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
      "$ZSH_CUSTOM/themes/powerlevel10k"
    log "Installing zsh plugins"
    retry git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git \
      "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
    retry git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git \
      "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
    sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="powerlevel10k\/powerlevel10k"/' ~/.zshrc 2>/dev/null || true
    sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc 2>/dev/null || true
    sudo usermod -s "$(which zsh)" "$USER"
    echo 'if [ -n "$PS1" ] && [ -z "$ZSH_VERSION" ]; then exec zsh; fi' >> ~/.bashrc
    ok "Zsh + Oh-My-Zsh installed, default shell set to zsh"
  else skip "Zsh + Oh-My-Zsh already installed"; fi
fi

echo -e "\n\e[1;32m━━━ Bootstrap complete ━━━\e[0m"
'@

    $d = if ($Cfg['installDocker']) { 'true' } else { 'false' }
    $c = if ($Cfg['installCuda'])   { 'true' } else { 'false' }
    $z = if ($Cfg['installZsh'])    { 'true' } else { 'false' }
    $n = if ($Cfg['installNvm'])    { 'true' } else { 'false' }
    $g = if ($Cfg['installGhCli'])  { 'true' } else { 'false' }
    $gn = $Cfg['gitName']   -replace "'", "'"
    $ge = $Cfg['gitEmail']  -replace "'", "'"
    $py = $Cfg['pythonPattern']

    $clean = $raw -replace "`r", ""
    $b64   = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($clean))
    $cmd   = "printf '%s' '$b64' | base64 -d > /tmp/_bs.sh && chmod +x /tmp/_bs.sh && bash /tmp/_bs.sh '$d' '$c' '$z' '$n' '$g' '$gn' '$ge' '$py'"

    if ($DryRun) {
        Info "[DRYRUN] would run bootstrap: Docker=$d CUDA=$c ZSH=$z NVM=$n GH=$g Python=$py"
        return
    }
    & wsl -d $Distro -u $User bash -c $cmd
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 13 — ZSHRC ADDITIONS
# ─────────────────────────────────────────────────────────────────────────────
function Write-ZshConfig {
    param([string]$Distro, [string]$User)
    if ($DryRun) { Info '[DRYRUN] would append shell config to ~/.zshrc'; return }
    $content = @'

# ── Oh My Zsh ───────────────────────────────────────────────────────────────
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git docker docker-compose zsh-autosuggestions zsh-syntax-highlighting)
[ -f "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"

# ── pyenv ────────────────────────────────────────────────────────────────────
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init --path)"
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)" 2>/dev/null || true

# ── NVM ──────────────────────────────────────────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

# ── Poetry / pipx / uv ───────────────────────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"

# ── Aliases ───────────────────────────────────────────────────────────────────
alias zshconfig="nano ~/.zshrc"
alias zshreload="source ~/.zshrc"

'@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
    & wsl -d $Distro -u $User -- bash -c "echo '$b64' | base64 -d >> ~/.zshrc"
    Ok '~/.zshrc updated'
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 14 — FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
function Show-Summary {
    param([string]$Distro, [string]$User)
    $elapsed = [datetime]::Now - $Script:StartTime
    $elStr   = "$($elapsed.Minutes)m $($elapsed.Seconds)s"

    $c1 = 38; $c2 = 7; $c3 = 9
    $border = '+' + ('-' * ($c1+2)) + '+' + ('-' * ($c2+2)) + '+' + ('-' * ($c3+2)) + '+'
    $hdr    = "| $('Step'.PadRight($c1)) | $('Status'.PadRight($c2)) | $('Time'.PadRight($c3)) |"

    Write-Host "`n$border" -ForegroundColor Cyan
    Write-Host $hdr        -ForegroundColor Cyan
    Write-Host $border     -ForegroundColor Cyan

    foreach ($key in $Script:Results.Keys) {
        $r      = $Script:Results[$key]
        $status = $r.Status
        $t      = if ($r.Ms -gt 0) { "$([Math]::Round($r.Ms/1000,1))s" } else { '' }
        $color  = switch ($status) {
            'OK'     { [ConsoleColor]::Green }
            'SKIP'   { [ConsoleColor]::Yellow }
            'FAIL'   { [ConsoleColor]::Red }
            'DRYRUN' { [ConsoleColor]::Magenta }
            default  { [ConsoleColor]::Gray }
        }
        $row = "| $($key.PadRight($c1)) | $($status.PadRight($c2)) | $($t.PadRight($c3)) |"
        Write-Host $row -ForegroundColor $color
    }

    Write-Host $border -ForegroundColor Cyan
    Write-Host "  Total time : $elStr" -ForegroundColor Cyan
    Write-Host $border -ForegroundColor Cyan

    $failed = $Script:Results.Keys | Where-Object { $Script:Results[$_].Status -eq 'FAIL' }
    if ($failed) {
        Write-Host "`n  FAILED STEPS (check log for details):" -ForegroundColor Red
        $failed | ForEach-Object { Write-Host "    - $_ : $($Script:Results[$_].Detail)" -ForegroundColor Red }
    }

    Write-Host "`n  NEXT STEPS" -ForegroundColor Cyan
    Write-Host "  ----------"
    Write-Host "  [1] Add SSH public key to GitHub : https://github.com/settings/ssh/new"
    Write-Host "  [2] Authenticate GitHub CLI      : wsl -d $Distro -- gh auth login"
    Write-Host "  [3] Launch WSL                   : wsl -d $Distro"
    Write-Host "  [4] Configure Zsh theme          : wsl -d $Distro -- p10k configure"
    Write-Host "  [5] Re-run non-interactively     : .\setup-wsl.ps1 -NonInteractive"
    Write-Host "  [6] Log saved to                 : $LogFile"
    Write-Host "  [7] Config saved to              : $ConfigFile"
    Write-Host ''
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN EXECUTION
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n  setup-wsl.ps1  $Script:VERSION" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n" -ForegroundColor DarkGray

# Load saved config (provides defaults for prompts)
$savedCfg = Import-WslConfig -Path $ConfigFile

# Collect all inputs
if ($NonInteractive) {
    if (-not $savedCfg) {
        Write-Host '[ERR] -NonInteractive requires wsl-config.json. Run interactively first.' -ForegroundColor Red
        Stop-Transcript; exit 1
    }
    $cfg = $savedCfg
    # Password is never stored — always prompt
    $cfg['_securePwd'] = Read-Host '  UNIX password (required)' -AsSecureString
    Show-Recap -Cfg $cfg
} else {
    $cfg = Invoke-CollectPhase -Defaults $savedCfg
    Show-Recap -Cfg $cfg
    if (-not (Ask-YesNo 'Proceed with these settings?' $true)) {
        Write-Host '  Aborted.' -ForegroundColor Yellow; Stop-Transcript; exit 0
    }
}

# Save config now (before execution) so a crash still leaves the config on disk
$saveable = @{}
$cfg.Keys | Where-Object { $_ -ne '_securePwd' } | ForEach-Object { $saveable[$_] = $cfg[$_] }
Export-WslConfig -Cfg $saveable -Path $ConfigFile

# Calculate step total for the counter
$Script:StepTotal = 8   # always-on: wsl, move, wait, user, sudo, wslconf, registry, restart, bootstrap, zshrc, summary
if ($cfg['installDocker']) { $Script:StepTotal++ }
if ($cfg['installGhCli'])  { $Script:StepTotal++ }
if ($cfg['installZsh'])    { $Script:StepTotal++ }
if ($cfg['installNvm'])    { $Script:StepTotal++ }
if ($cfg['installCuda'])   { $Script:StepTotal++ }
$Script:StepTotal += 4   # ssh key, dotfiles, wt profile, zshrc

$distro = $cfg['distro']
$user   = $cfg['unixUser']

# ── Execute ───────────────────────────────────────────────────────────────────
Invoke-Step 'WSL + Ubuntu install' -Critical {
    Ensure-WslAndUbuntu -Distro $distro
}

Invoke-Step 'Move distro to drive' -SkipWhen:($cfg['installDrive'] -ieq 'C') {
    Move-WslDistro -Distro $distro -TargetDrive $cfg['installDrive']
}

Invoke-Step 'Wait for WSL ready' -Critical {
    Wait-WslReady -Distro $distro -TimeoutSec 90
}

Invoke-Step 'UNIX user setup' -Critical {
    Ensure-UnixUser -Distro $distro -User $user -SecurePwd $cfg['_securePwd']
}

Invoke-Step 'Passwordless sudo' {
    Set-PasswordlessSudo -Distro $distro -User $user
}

Invoke-Step 'wsl.conf (systemd)' -SkipWhen:(-not $cfg['enableSystemd']) {
    Set-WslConfKey -Distro $distro -Section 'boot' -Key 'systemd' -Value 'true'
}

Invoke-Step 'Set default WSL user' {
    Set-DefaultWslUser -Distro $distro -User $user
}

Invoke-Step 'Restart WSL' -Critical {
    Invoke-Wsl --shutdown
    Wait-WslReady -Distro $distro -TimeoutSec 90
}

Invoke-Step 'Package bootstrap' -Critical {
    Start-UbuntuBootstrap -Distro $distro -User $user -Cfg $cfg
}

Invoke-Step 'SSH key' {
    Set-WslSshKey -Distro $distro -User $user -Comment $cfg['sshKeyComment']
}

Invoke-Step 'Dotfiles' -SkipWhen:([string]::IsNullOrWhiteSpace($cfg['dotfilesUrl'])) {
    Install-Dotfiles -Distro $distro -User $user -RepoUrl $cfg['dotfilesUrl']
}

Invoke-Step 'Windows Terminal profile' {
    Update-WindowsTerminalProfile -Distro $distro -User $user -ColorScheme $cfg['wtColorScheme']
}

Invoke-Step 'Shell config (~/.zshrc)' {
    Write-ZshConfig -Distro $distro -User $user
}

# ── Summary ───────────────────────────────────────────────────────────────────
Show-Summary -Distro $distro -User $user
Stop-Transcript

if (Ask-YesNo "Launch $distro now?" $true) {
    if (-not $DryRun) { & wsl -d $distro }
}
