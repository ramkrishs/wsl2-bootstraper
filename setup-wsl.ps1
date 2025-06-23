# Requires -RunAsAdministrator
<#
  setup-wsl.ps1 — Idempotent WSL2 + Ubuntu-24.04 + Python + Docker + Zsh
  PowerShell 5.1 compatible, ASCII only
#>

# ────────── Console helpers ─────────────────────────────────────────────
$Cyan   = [ConsoleColor]::Cyan
$Green  = [ConsoleColor]::Green
$Yellow = [ConsoleColor]::Yellow
$Red    = [ConsoleColor]::Red

function Step { param([string]$m) Write-Host "`n[*] $m" -Foreground $Cyan }
function Ok   { param([string]$m) Write-Host "[OK]  $m"   -Foreground $Green }
function Skip { param([string]$m) Write-Host "[SKIP] $m"   -Foreground $Yellow }
function Fail { param([string]$m) Write-Host "[ERR]  $m"   -Foreground $Red }

# ────────── Y/N prompt ────────────────────────────────────────────────────
function Ask-YesNo {
    param([string]$Prompt,[bool]$Default=$true)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $r = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
        switch ($r.ToLower()) { 'y'{return $true}; 'n'{return $false}; default{Write-Host 'Enter Y or N.' -Foreground $Yellow} }
    }
}

# ────────── Elevation check ──────────────────────────────────────────────
if (-not (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Fail 'Please rerun in an elevated PowerShell window.'; exit 1
}

# ────────── Helpers ─────────────────────────────────────────────────────
function Has-Ubuntu24 { (& wsl --list --quiet 2>$null) -contains 'Ubuntu-24.04' }

function Ensure-WslAndUbuntu {
    Step 'Checking for WSL'
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        Step 'Installing WSL base'
        wsl --install --no-launch
        Ok    'WSL installed'
    } else { Skip 'WSL already present' }

    if (Has-Ubuntu24) {
        if (Ask-YesNo 'Ubuntu-24.04 exists. Re-install (wipe data)?' $false) {
            Step 'Removing Ubuntu-24.04'
            wsl --terminate Ubuntu-24.04 2>$null
            wsl --unregister Ubuntu-24.04
            Step 'Installing fresh Ubuntu-24.04'
            wsl --install -d Ubuntu-24.04 --no-launch
            Ok    'Fresh Ubuntu-24.04 installed'
        } else { Skip 'Keeping Ubuntu-24.04' }
    } else {
        Step 'Installing Ubuntu-24.04 LTS'
        wsl --install -d Ubuntu-24.04 --no-launch
        Ok    'Ubuntu-24.04 installed'
    }

    Step 'Ensuring WSL2 for Ubuntu'
    $ver = (& wsl --list --verbose) -match 'Ubuntu-24.04' | ForEach-Object { ($_ -split '\s+')[2] }
    if ($ver -ne '2') {
        wsl --set-version Ubuntu-24.04 2
        Ok    'Converted to WSL2'
    } else { Skip 'Already on WSL2' }

    Step 'Updating WSL kernel'
    wsl --update
    $st = wsl --status 2>$null
    if ($st -match 'Kernel version') { Ok "Kernel status:`n$st" } else { Skip 'Kernel up to date' }
}

function Enable-Systemd([bool]$on) {
    if ($on) {
        Step 'Enabling systemd'
        wsl -d Ubuntu-24.04 -- bash -c "echo -e '[boot]\nsystemd=true' | sudo tee /etc/wsl.conf"
        Ok    'systemd enabled'
    } else { Skip 'systemd not requested' }
}

# ────────── Bootstrap function ────────────────────────────────────────────
function Start-UbuntuBootstrap {
    param($Docker, $CUDA, $ZSH, $GitName, $GitEmail)

    $raw = @'
#!/usr/bin/env bash
set -e

# Load existing shell configs
source ~/.bashrc 2>/dev/null || true

DOCKER="$1"; CUDA="$2"; ZSH="$3"; GITNAME="$4"; GITEMAIL="$5"
log(){ echo -e "\e[1;36m[*] $*\e[0m"; }
ok(){ echo -e "\e[1;32m[OK] $*\e[0m"; }
skip(){ echo -e "\e[1;33m[SKIP] $*\e[0m"; }
export DEBIAN_FRONTEND=noninteractive

# 1. Core tools
if ! command -v gcc >/dev/null; then
  log "Installing build-essential, git, curl, wget, unzip, zip"
  sudo apt-get update -y
  sudo apt-get install -y build-essential git curl wget unzip zip
  ok "Core tools"
else skip "Core tools present"; fi

# 2. Git config
if ! git config --global user.name >/dev/null; then
  log "Setting Git user.name/email"
  git config --global user.name "$GITNAME"
  git config --global user.email "$GITEMAIL"
  git config --global init.defaultBranch main
  ok "Git configured"
else skip "Git already configured"; fi

# 3. Docker
if [ "$DOCKER" = "true" ]; then
  if ! command -v docker >/dev/null; then
    log "Installing Docker & containerd"
    sudo apt-get install -y docker.io containerd
    sudo systemctl enable --now docker
    ok "Docker installed"
  else skip "Docker present"; fi
fi

# 4. pyenv & Python
if ! command -v pyenv >/dev/null; then
  log "Installing pyenv dependencies"
  sudo apt-get update -y
  sudo apt-get install -y make build-essential libssl-dev libbz2-dev libffi-dev libreadline-dev libsqlite3-dev libncurses-dev zlib1g-dev libgdbm-dev liblzma-dev uuid-dev tcl-dev tk-dev libx11-dev
  curl -fsSL https://pyenv.run | bash
  export PYENV_ROOT="$HOME/.pyenv"; export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
  eval "$(pyenv init --path)" >/dev/null 2>&1 || true
  eval "$(pyenv init -)"     >/dev/null 2>&1 || true
  ok "pyenv installed"
else skip "pyenv present"; fi

LATEST=$(pyenv install --list | grep -E '^[[:space:]]*3\.12\.[0-9]+$' | tail -1 | tr -d '[:space:]')
if ! pyenv versions --bare | grep -qx "$LATEST"; then
  log "Installing Python $LATEST"
  PYTHON_CONFIGURE_OPTS="--without-ensurepip" pyenv install -s "$LATEST"
  pyenv global "$LATEST"; ok "Python $LATEST"
else skip "Python $LATEST present"; fi

# pip, poetry, pipx, uv
if ! python -m pip --version >/dev/null 2>&1; then
  log "Installing pip"
  curl -sS https://bootstrap.pypa.io/get-pip.py | python
  ok "pip installed"
else skip "pip present"; fi

if ! command -v poetry >/dev/null; then
  log "Installing Poetry"
  curl -sSL https://install.python-poetry.org | python -
  ok "Poetry installed"
else skip "Poetry present"; fi

if ! command -v pipx >/dev/null; then
  log "Installing pipx"
  python -m pip install --user pipx
  export PATH="$HOME/.local/bin:$PATH"; ok "pipx installed"
else skip "pipx present"; fi

if ! command -v uv >/dev/null; then
  log "Installing uv"
  pipx install uv; ok "uv installed"
else skip "uv present"; fi

# 7. CUDA
if [ "$CUDA" = "true" ]; then
  if ! command -v nvcc >/dev/null; then
    log "Installing NVIDIA CUDA toolkit"
    sudo apt-get install -y nvidia-cuda-toolkit
    ok "CUDA installed"
  else skip "CUDA present"; fi
fi

# 8. Zsh & Oh-My-Zsh
if [ "$ZSH" = "true" ]; then
  if ! command -v zsh >/dev/null; then
    log "Installing Zsh & Oh-My-Zsh"
    sudo apt-get install -y zsh fonts-powerline
    RUNZSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="agnoster"/' ~/.zshrc
    rm -rf ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
    sed -i 's/ZSH_THEME="agnoster"/ZSH_THEME="powerlevel10k\/powerlevel10k"/' ~/.zshrc
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
    sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/g' ~/.zshrc
    chsh -s $(which zsh) $USER
    echo 'if [ -n "$PS1" ] && [ -z "$ZSH_VERSION" ]; then exec zsh; fi' >> ~/.bashrc
    ok "Zsh & plugins installed, default shell set to zsh"
  else
    skip "Zsh already installed"
  fi
fi
'@

    # Strip CRs, encode & run under bash
    $clean = $raw -replace "`r", ""
    $b64   = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($clean))
    $cmd   = @"
printf '%s' '$b64' | base64 -d > /tmp/bs.sh && \
chmod +x /tmp/bs.sh && \
bash /tmp/bs.sh '$Docker' '$CUDA' '$ZSH' '$GitName' '$GitEmail'
"@

    Step 'Running Ubuntu bootstrap…'
    wsl -d Ubuntu-24.04 bash -c "$cmd"
    Ok 'Ubuntu bootstrap complete'
}

# ────────── MAIN FLOW ─────────────────────────────────────────────────────
Step 'Starting Setup'
Ensure-WslAndUbuntu

# UNIX user prompt
$UnixUser  = Read-Host 'Enter UNIX username to create/use'
$SecurePwd = Read-Host 'Enter UNIX password' -AsSecureString
$PlainPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePwd))

Step "Ensuring UNIX user '$UnixUser' exists"
$userExists = wsl -d Ubuntu-24.04 -u root -- bash -c "id -u $UnixUser 2>/dev/null || echo not-exists"
if ($userExists -eq 'not-exists') {
    $passFile = [IO.Path]::GetTempFileName()
    "$UnixUser`:$PlainPass" | Out-File $passFile -Encoding ASCII -NoNewline
    wsl -d Ubuntu-24.04 -u root -- useradd -m -s /bin/bash $UnixUser
    Get-Content $passFile | wsl -d Ubuntu-24.04 -u root -- chpasswd
    wsl -d Ubuntu-24.04 -u root -- usermod -aG sudo $UnixUser
    Remove-Item $passFile -Force
    Ok "User '$UnixUser' created & sudo-enabled"
} else {
    Skip "User '$UnixUser' already exists"
}

Step "Granting passwordless sudo to '$UnixUser'…"

# inside WSL as root, create a sudoers file
wsl -d Ubuntu-24.04 -u root -- bash -lc "
  echo '$UnixUser ALL=(ALL) NOPASSWD:ALL' \
    | sudo tee /etc/sudoers.d/99_wsl_config > /dev/null
  sudo chmod 0440 /etc/sudoers.d/99_wsl_config
"

Ok "Passwordless sudo enabled for '$UnixUser'"

# ──────────────────────────────────────────────────────────────────────────────
# 4) SYSTEMD + DEFAULT USER + VALIDATION
# ──────────────────────────────────────────────────────────────────────────────

Step "Writing /etc/wsl.conf for systemd…"
$wslConf = @'
[boot]
systemd=true
'@
# write as root inside Ubuntu
wsl -d Ubuntu-24.04 -- bash -lc "echo `$wslConf | sudo tee /etc/wsl.conf > /dev/null"
Ok "/etc/wsl.conf updated"

Step "Setting default WSL user to '$UnixUser'…"
# get the Linux uid of our user
$uid = wsl -d Ubuntu-24.04 -u root -- bash -lc "id -u $UnixUser" | ForEach-Object { $_.Trim() }

# patch the registry DefaultUid for Ubuntu-24.04
$baseKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
Get-ChildItem $baseKey | ForEach-Object {
  $props = Get-ItemProperty $_.PSPath
  if ($props.DistributionName -eq 'Ubuntu-24.04') {
    Set-ItemProperty -Path $_.PSPath -Name DefaultUid -Value ([int]$uid)
    Ok "Default user for Ubuntu-24.04 set to '$UnixUser' (uid $uid)"
  }
}

Step "Restarting WSL to pick up changes…"
wsl --shutdown
Ok "WSL will now start as '$UnixUser' on next launch"

# ──────────────────────────────────────────────────────────────────────────────
# 5) VALIDATION
# ──────────────────────────────────────────────────────────────────────────────

Step "Validating default WSL user & sample installs…"



# a) whoami
wsl -d Ubuntu-24.04 -- bash -lc 'echo "Default WSL user is: $(whoami)"'

# b) root-level apt install
wsl -d Ubuntu-24.04 -u $UnixUser -- bash -lc 'echo "Default WSL user is: $(whoami)"'

Ok "If step 5a shows '$UnixUser' and you see /usr/bin/cowsay plus ~/.local/bin/lolcat, root vs. user installs are correctly scoped."


# Git & component choices
$GitName  = Read-Host 'Enter Git user.name'
$GitEmail = Read-Host 'Enter Git user.email'
Write-Host "`nAbout to install components…" -Foreground $Cyan
if (-not (Ask-YesNo 'Proceed?' $true)) { Fail 'Aborted.'; exit 1 }

$sysd   = Ask-YesNo 'Enable systemd?'              $true
$docker = Ask-YesNo 'Install Docker Engine?'       $true
$cuda   = Ask-YesNo 'Install NVIDIA CUDA toolkit?' $false
$zsh    = Ask-YesNo 'Install Zsh & Oh-My-Zsh?'     $true

Enable-Systemd $sysd
Step 'Restarting WSL…'
wsl --shutdown; Start-Sleep 3

$d = if ($docker) { 'true' } else { 'false' }
$c = if ($cuda)   { 'true' } else { 'false' }
$z = if ($zsh)    { 'true' } else { 'false' }

Start-UbuntuBootstrap $d $c $z $GitName $GitEmail

Step 'Configuring ~/.bashrc and ~/.zshrc in Ubuntu…'



# Define zshrc content with Oh-My-Zsh configuration
$zshrcContent = @'

# === Oh My Zsh settings ===
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git docker docker-compose zsh-autosuggestions zsh-syntax-highlighting)

# Pyenv settings
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init --path)"
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"

# === Poetry & pipx & uv settings ===
export PATH="$HOME/.local/bin:$PATH"


# === Aliases ===
alias zshconfig="nano ~/.zshrc"
alias zshreload="source ~/.zshrc"

'@

# Convert to base64 to avoid any interpretation issues
$zshrcBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($zshrcContent))

# Write .zshrc content using base64
wsl -d Ubuntu-24.04 -u $UnixUser -- bash -c "echo '$zshrcBase64' | base64 -d >> ~/.zshrc"
Ok '~/.zshrc updated'

Ok "Setup complete! Launch Ubuntu-24.04 now."
if (Ask-YesNo 'Launch?' $true) { wsl -d Ubuntu-24.04 } else { Ok 'You can launch later with `wsl -d Ubuntu-24.04`' }
