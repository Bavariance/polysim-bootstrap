# polysim-bootstrap

One-command dev-environment setup for [Polysimulator](https://github.com/Bavariance/polysimulator)
on Fedora, Ubuntu/Debian, and **Windows 11 via WSL2**. Installs the deterministic
toolchain, links shell + tmux + direnv configs, and pulls per-machine secrets
from **Bitwarden Secrets Manager** via the `bws` CLI.

**No secrets live in this repo.** It is safe to be public. See
[Security model](#security-model) below.

---

## What it sets up

- **Packages**: `zsh`, `bash`, `tmux`, `git`, `curl`, `direnv`, `jq`, `ripgrep`, `fd`, `btop`, build tools
- **Languages / runtimes**: Node 22 (via [`fnm`](https://github.com/Schniz/fnm)), [`uv`](https://github.com/astral-sh/uv) for Python, [`bun`](https://bun.sh) for fast JS/TS, Docker CLI
- **Database CLIs**: `psql` (Postgres / Supabase), `redis-cli` (Redis inspection)
- **Service CLIs**: `gh` (GitHub), `bws` (Bitwarden Secrets Manager), `stripe` (Stripe webhook forwarding), `claude` (Claude Code), `zellij` (terminal multiplexer)
- **MCP server binaries**: `mcp-grafana` (the Grafana MCP server referenced by polysimulator's `.mcp.json`); `dokploy` MCP runs via `npx -y` with no install needed; `supabase`, `cloudflare`, `polymarket-docs` are HTTP MCPs with no binary needed
- **VS Code**: Remote-SSH server prerequisites (so opening the host in VS Code "just works")
- **Configs**: minimal `.zshrc`, `.zshenv`, `.bashrc`, `.bash_profile`, `.tmux.conf`, `direnvrc`, zellij config + polysimulator layout
- **Secrets**: pulled from Bitwarden Secrets Manager into `<polysim-repo>/.env` with `chmod 600`

---

## Layout on a target machine

```
$HOME/
  bootstrap/                          ← this repo, cloned here
    bootstrap/install.sh
    bootstrap/link-configs.sh
    bootstrap/sync-secrets.sh
    configs/{bash,zsh,tmux,direnv,polysim}/
  .config/polysim/                    ← chmod 700
    bws-token                         ← chmod 600, gitignored (machine account token)
    bws-project-id                    ← chmod 600, gitignored (UUID of the bws project)
    bws-server-url                    ← chmod 600, gitignored (only if on Bitwarden EU)
    shell-init.sh                     ← symlink → bootstrap/configs/polysim/shell-init.sh
  .ssh/
  .bashrc, .bash_profile              ← symlinks → bootstrap/configs/bash/*
  .zshrc, .zshenv                     ← symlinks → bootstrap/configs/zsh/*
  .tmux.conf                          ← symlink → bootstrap/configs/tmux/tmux.conf
  .config/zellij/
    config.kdl                        ← symlink → bootstrap/configs/zellij/config.kdl
    layouts/polysimulator.kdl         ← symlink → bootstrap/configs/zellij/layouts/polysimulator.kdl
  projects/
    polysimulator/
      .env                            ← written by sync-secrets.sh, chmod 600, gitignored
```

---

## First-run on a fresh box

```bash
# 1. clone (use ssh once you've added a key, https for the very first run)
git clone https://github.com/Bavariance/polysim-bootstrap.git ~/bootstrap
cd ~/bootstrap

# 2. install deterministic tooling (apt or dnf, autodetected)
./bootstrap/install.sh

# 3. link shell + tmux + direnv + polysim configs
./bootstrap/link-configs.sh

# 4. persist your bws machine-account token + project ID
#    Replace the right-hand side of each printf with your actual values —
#    do NOT include the angle brackets, they're just placeholders here.
mkdir -p ~/.config/polysim
TOKEN='paste-your-machine-account-token-here'
UUID='paste-your-polysimulator-project-uuid-here'
printf '%s\n' "$TOKEN" > ~/.config/polysim/bws-token
printf '%s\n' "$UUID"  > ~/.config/polysim/bws-project-id
chmod 600 ~/.config/polysim/bws-token ~/.config/polysim/bws-project-id
unset TOKEN UUID

# 4b. ONLY if your Bitwarden account is on the EU instance (Bavariance is):
#     Skip this if you log in at vault.bitwarden.com (US default).
echo 'https://vault.bitwarden.eu' > ~/.config/polysim/bws-server-url
chmod 600 ~/.config/polysim/bws-server-url

# 5. open a new shell so PATH and BWS_* env vars pick up
exec $SHELL

# 6. clone the app
gh auth login
gh repo clone Bavariance/polysimulator ~/projects/polysimulator

# 7. pull secrets into <polysim-repo>/.env
./bootstrap/sync-secrets.sh

# 8. trust the polysimulator .envrc so direnv loads the new .env into your shell
#    (one-time per machine per repo — direnv refuses to source untrusted files
#    by default, which is good security; you're vouching that .envrc only does
#    `dotenv_if_exists .env` and isn't running anything malicious).
cd ~/projects/polysimulator && direnv allow .

# 9. (optional) make zsh the login shell
chsh -s "$(command -v zsh)"
```

After step 5, `bws secret list` and `bws project list` work without any
manual `export`. After step 7, `docker compose up --build` from inside the
polysimulator directory Just Works (compose reads `.env` directly via
`env_file:`). After step 8, `claude` and VSCode launched from inside the
repo see all the MCP secrets in their environment — without it, Claude Code
will report `supabase`, `grafana`, and `dokploy` MCP servers as failed.

To find your project UUID before step 4:
```bash
BWS_ACCESS_TOKEN=<token> bws project list
```

---

## Windows 11 (WSL2)

The bootstrap is bash-only and targets Linux. On Windows, you run it inside
**WSL2 / Ubuntu 22.04+** — WSL2 is a real Linux kernel, so every step in
"First-run on a fresh box" works identically once you're in the Ubuntu shell.

### 1. Install WSL2 + Ubuntu

In **PowerShell as Administrator**, once per machine:

```powershell
wsl --install -d Ubuntu-22.04
```

Reboot if prompted. On first launch, Ubuntu asks you to set a UNIX username +
password — use a sensible name (e.g. `wladimir`). The user gets `sudo`
automatically. Then update packages:

```bash
sudo apt update && sudo apt upgrade -y
```

### 2. Install [Windows Terminal](https://aka.ms/terminal) and use it as your default

Windows Terminal supports tabs, true colour, GPU rendering, and works correctly
with `zellij`. The default `conhost.exe` does not.

### 3. Install Docker

Pick **one**:

- **Docker Desktop for Windows** (recommended for most). Download the installer,
  enable "Use the WSL 2 based engine" and "Enable integration with Ubuntu-22.04"
  in Settings → Resources → WSL integration. `docker` and `docker compose`
  become available inside WSL automatically. Free for organisations with <250
  employees and <$10M revenue (covers Bavariance).
- **Native Docker inside WSL**: `sudo apt install docker.io && sudo usermod -aG docker $USER`,
  then `sudo service docker start` (no systemd autostart in WSL by default).
  No Windows-side install, but you have to remember to start the daemon.

### 4. Run the standard bootstrap

Inside the Ubuntu shell, follow [First-run on a fresh box](#first-run-on-a-fresh-box)
exactly as written. The bootstrap auto-detects Ubuntu and uses `apt` paths.

### 5. VSCode + WSL

Install VSCode **on Windows** (not inside WSL), then add these extensions:

- `ms-vscode-remote.remote-wsl` — opens any folder inside WSL as if local
- `ms-vscode-remote.remote-ssh` — for connecting to the shared Hetzner VM

To open the polysimulator repo:

```bash
# inside the WSL Ubuntu shell
cd ~/projects/polysimulator && code .
```

VSCode launches on Windows, but the language server, terminal, and Claude Code
extension all run inside WSL.

### 6. SSH key for GitHub

Generate a separate key inside WSL — don't try to share the Windows-side
Bitwarden Desktop SSH agent (the bridge requires `npiperelay` + `socat` and
breaks more than it helps for a dev VM):

```bash
ssh-keygen -t ed25519 -C "wladimir-wsl@bavariance"
gh ssh-key add ~/.ssh/id_ed25519.pub --title "wladimir-wsl"
```

Then `gh repo clone …` works for the polysimulator clone in step 6 of the
standard flow.

### Critical WSL2 gotchas

- **Keep all work inside `~/`, not `/mnt/c/`**. The cross-OS filesystem bridge
  is ~10–100× slower for small-file operations. `git status` on a polysimulator
  clone in `/mnt/c/Users/.../projects/` takes seconds; in `~/projects/` it's
  instant.
- **`localhost` is shared**. A backend on `localhost:8000` inside WSL is reachable
  from a browser on Windows — no port forwarding needed.
- **No systemd autostart** unless you've enabled it. Add `[boot] systemd=true`
  to `/etc/wsl.conf` and `wsl --shutdown` from PowerShell to enable. Otherwise
  services like Docker (native, not Desktop) need manual `sudo service docker start`.
- **Time drift**: WSL2's clock can drift after Windows sleep. If `git`/`docker`
  complain about timestamps, run `sudo hwclock -s` inside WSL.

---

## bws on Windows / WSL2

`bws` is **only installed inside WSL**, not on Windows. The bootstrap's
`install.sh` puts the Linux musl binary at `/usr/local/bin/bws` (or
`~/.local/bin/bws`), and the rest of the flow — `~/.config/polysim/bws-token`,
`sync-secrets.sh`, the auto-export from `shell-init.sh` — works identically to
native Linux.

You don't need the Windows-native `bws.exe` for our setup. If you ever want it
in PowerShell separately, Bitwarden ships a `bws-x86_64-pc-windows-msvc-*.zip`
in the same GitHub releases.

### Where the BWS_ACCESS_TOKEN lives on Wladimir's machine

Two places, both safe:

1. **Personal Bitwarden vault on Windows** (the desktop app, not Secrets
   Manager): store the machine-account token as a secure note named e.g.
   `polysim/bws-machine-token-wsl-<hostname>`. Copy it into WSL during
   bootstrap step 4. This is the long-term home — if the laptop dies, you
   can re-bootstrap a new one from any device that has access to the vault.
2. **Inside WSL at `~/.config/polysim/bws-token`** (chmod 600): the working
   copy. Lives on the WSL ext4 filesystem (`\\wsl$\Ubuntu-22.04\home\<user>\…`),
   so it's isolated from Windows-side processes by default and never crosses
   the OS boundary.

### One machine-account token per developer-machine

Best practice: each developer creates **their own** machine account in
`sm.bitwarden.com` (one machine account per laptop, not one shared across the
team). Reasons:

- If Wladimir's laptop is lost or compromised, you revoke just his token in the
  bws web UI without affecting yours.
- Audit log shows who pulled secrets when.
- Token rotation is per-machine, no team coordination needed.

Both machine accounts get **read-only** access to the same `polysimulator`
project — they pull identical secrets, just authenticate as different
principals.

### Rotating the token on WSL

Same flow as Linux:

```bash
# After generating a new machine-account token in sm.bitwarden.com:
printf '%s\n' '<new-token>' > ~/.config/polysim/bws-token
chmod 600 ~/.config/polysim/bws-token
exec $SHELL                     # picks up the new token via shell-init.sh
bws secret list                 # verify it works
~/bootstrap/bootstrap/sync-secrets.sh   # refresh ~/projects/polysimulator/.env
```

---

## Re-running

All scripts are **idempotent**:

- `install.sh`        — re-checks each tool, installs only what's missing
- `link-configs.sh`   — leaves correct symlinks alone, backs up real files to `*.bak-<timestamp>`
- `sync-secrets.sh`   — re-pulls latest secrets, atomically replaces `<polysim-repo>/.env`

Run `sync-secrets.sh` whenever a secret rotates in Bitwarden Secrets Manager.
You do **not** need to re-run `direnv allow .` — direnv stays trusting the
same `.envrc` until its content changes (then it asks you to re-allow once).

---

## Security model

This repo is intentionally **public** — for that to be safe, these rules hold:

1. **Nothing in `~/.config/polysim/`** is committed. The `.gitignore` blocks
   `*.env`, `bws-token`, `bws-project-id`, `*.secret`, `*.pem`, `*.key`,
   `id_rsa*`, `id_ed25519*`, and similar.
2. **Only one credential needs to live on the machine**: the bws machine-account
   token at `~/.config/polysim/bws-token`. Treat it like an SSH key. Revoke per
   machine in `sm.bitwarden.com` if a host is lost or decommissioned.
3. **Secret files are `chmod 600`** and the directory `chmod 700`.
4. The generated `<polysim-repo>/.env` is `chmod 600` and gitignored.
5. If you ever paste a secret into a shell-history-recording terminal,
   prefix the command with a space (`HISTCONTROL=ignorespace` is on in zsh
   and bash by default in our configs).

If you accidentally commit a secret: rotate it in Bitwarden Secrets Manager
first, then `git rm` and force-push only after the rotation is live.

---

## Polysimulator zellij workflow

Two shell functions are provisioned in both `~/.bashrc` and `~/.zshrc`:

- `zpoly` — `cd ~/projects/polysimulator && zellij attach polysimulator` (auto-creates
  the session with the layout if it doesn't exist).
- `zpoly_reset` — kill the session and recreate it from scratch with the layout.

The layout `configs/zellij/layouts/polysimulator.kdl` defines five tabs: `core`
(Claude + ops shells), `server` (SSH to your remote VM), `github` (gh issue/pr
status), `monitor` (ccusage + git status), `backtests`.

The `server` tab SSHes to `${POLYSIM_SERVER_HOST:-hetzner-ashburn1}`. Override
in `~/.bashrc.local`:

```bash
export POLYSIM_SERVER_HOST=my-vm-alias
```

The alias must exist in `~/.ssh/config`.

---

## Customisation

- Override the polysimulator clone location with `POLYSIM_REPO_DIR=/path/to/polysim ./bootstrap/sync-secrets.sh`.
- Override `BWS_ACCESS_TOKEN` / `BWS_PROJECT_ID` per-shell to use a different
  bws project (e.g. `polysimulator-staging` vs `polysimulator-prod`).
- Add machine-local zsh tweaks in `~/.zshrc.local` (sourced last, gitignored);
  bash equivalent is `~/.bashrc.local`.

---

## Supported OSes

- **Fedora** 40+ (uses `dnf`)
- **Ubuntu** 22.04+, **Debian** 12+ (uses `apt`)
- **Windows 11** via [WSL2 / Ubuntu 22.04+](#windows-11-wsl2)

Architectures: `x86_64` and `aarch64` (bws + zellij installs handle both).

---

## License

MIT — see [LICENSE](LICENSE).
