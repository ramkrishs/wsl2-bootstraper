## 🐧 WSL2-Bootstraper

**A PowerShell script to provision Ubuntu‑24.04 on WSL2 with Python, Docker, Zsh, and more — idempotent & user‑configurable.**

### ✅ Prerequisites

* Windows 10/11 with WSL enabled (Admin PowerShell, elevated).
* PowerShell 5.1 or later.

### ⚙️ Installation & Usage

#### ⚡ One-Click Installation

> This runs the script from GitHub directly. Make sure you're in an **elevated PowerShell window** (Run as Administrator).

```powershell
irm https://raw.githubusercontent.com/ramkrishs/wsl2-bootstraper/main/setup-wsl.ps1 | iex
```

You’ll be prompted to:

* Choose or create a UNIX username & password
* Provide Git name/email
* Select optional components:

  * ✅ Docker
  * ✅ Zsh + Oh My Zsh
  * ❌ CUDA (optional)
  * ✅ systemd

#### ⚙️ Manual Installation

```powershell
git clone https://github.com/ramkrishs/wsl2-bootstraper.git
cd wsl2-bootstraper
.\setup-wsl.ps1
```

> Make sure you're in an **elevated PowerShell window** (Run as Administrator).

You’ll be prompted for a UNIX username, password, Git identity, and whether to install:

* systemd support
* Docker
* CUDA (optional)
* Zsh + Oh My Zsh

### 🔄 What It Does

1. **Checks/installs WSL & Ubuntu‑24.04**, converts to WSL2 if necessary.
2. **Creates (or skips) a sudo‑enabled UNIX user**, sets default user via registry.
3. **Configures passwordless sudo** for the new user.
4. **Writes `/etc/wsl.conf`** to enable systemd.
5. **Bootstraps Ubuntu** via an embedded Bash script:

   * core dev tools
   * Git config
   * Docker (if chosen)
   * Python via pyenv (latest 3.12.x)
   * pip, Poetry, pipx, uv
   * CUDA toolkit (optional)
   * Zsh + Oh My Zsh with Powerlevel10k & plugins
6. **Appends user `.zshrc`** with:

   ```bash
   export PYENV_ROOT="$HOME/.pyenv"
   export PATH="$PYENV_ROOT/bin:$PATH"
   eval "$(pyenv init --path)"
   eval "$(pyenv init -)"
   eval "$(pyenv virtualenv-init -)"
   export PATH="$HOME/.local/bin:$PATH"
   ```
7. **Validates default user**, ensures root vs user installs are isolated.
8. **Optionally launches** Ubuntu terminal when done.

### ⚠️ Known Issues & Tips

* Ensure your password is correctly passed — check passwordless sudo config.
* Double-check your `$HOME` paths in zshrc to avoid Windows path contamination.
* WSL2 memory may balloon; use `.wslconfig` to cap VM RAM ([github.com][1], [reddit.com][2], [stackoverflow.com][3]).

### ❓ Troubleshooting

* **Default user isn’t being set correctly?**
  Check that registry `DefaultUid` matches your new user's UID.

* **`pyenv` not loading or `$HOME` wrong?**
  Make sure you’re sourcing the appended `.zshrc` under the correct user in WSL.

* **Memory not reclaimed?**
  Use a `.wslconfig` with `memory=...GB`, then `wsl --shutdown` ([stackoverflow.com][3]).

### 🧩 Contribution

PRs welcome! Please:

* Keep ASCII‑only PowerShell.
* Maintain idempotency.
* Add tests around `.zshrc` & path injection.
