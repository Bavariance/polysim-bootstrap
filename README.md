# polysim-bootstrap

One-command dev-environment setup for Polysimulator on Fedora and Ubuntu.
Installs the deterministic toolchain, links shell + tmux + direnv configs,
and pulls per-machine secrets from Bitwarden.

**No secrets live in this repo.** It is safe to be public. See
[Security model](#security-model) below.

---

## What it sets up

- **Packages**: `zsh`, `tmux`, `git`, `curl`, `direnv`, `jq`, `ripgrep`, `fd`, build tools
- **Languages / tooling**: Node 22 (via [`fnm`](https://github.com/Schniz/fnm)), [`uv`](https://github.com/astral-sh/uv) for Python, Docker CLI
- **CLIs**: `gh` (GitHub), `bw` (Bitwarden), `claude` (Claude Code)
- **VS Code**: Remote-SSH server prerequisites (so opening the host in VS Code "just works")
- **Configs**: minimal `.zshrc`, `.zshenv`, `.tmux.conf`, `direnvrc`
- **Secrets**: pulled from Bitwarden into `~/.config/polysim/` with `chmod 600`

---

## Layout on a target machine

```
$HOME/
  bootstrap/                      ← this repo, cloned here
    install.sh
    restore-secrets.sh
    link-configs.sh
  .config/polysim/                ← created by restore-secrets.sh (chmod 700)
    env.sh                        ← chmod 600, gitignored
    mcp-secrets.sh                ← chmod 600, gitignored
    gh-token                      ← chmod 600, gitignored
  .ssh/
  .tmux.conf                      ← symlink → bootstrap/configs/tmux/tmux.conf
  .zshrc                          ← symlink → bootstrap/configs/zsh/zshrc
  projects/
    polysimulator/
```

---

## First-run on a fresh box

```bash
# 1. clone (use ssh once you've added a key, https for the very first run)
git clone https://github.com/ErikEremenko/polysim-bootstrap.git ~/bootstrap
cd ~/bootstrap

# 2. install deterministic tooling (apt or dnf, autodetected)
./bootstrap/install.sh
# open a new shell so PATH picks up fnm / npm / uv

# 3. link shell + tmux + direnv configs
./bootstrap/link-configs.sh

# 4. set Bitwarden API key in this shell ONLY (never write to disk)
export BW_CLIENTID=user.xxxxxxxx
export BW_CLIENTSECRET=xxxxxxxxxxxxxxxxxxxxxxxx
export BW_PASSWORD='your-vault-master-password'

# 5. pull secrets into ~/.config/polysim/
./bootstrap/restore-secrets.sh

# 6. (optional) make zsh the login shell
chsh -s "$(command -v zsh)"

# 7. clone the app
gh repo clone Bavariance/polysimulator ~/projects/polysimulator
```

Open a new shell. `echo $DATABASE_URL` should now be set, `claude --version`
should print, `gh auth status` should report logged in.

---

## Re-running

All three scripts are **idempotent**:

- `install.sh`        — re-checks each tool, installs only what's missing
- `link-configs.sh`   — leaves correct symlinks alone, backs up real files to `*.bak-<timestamp>`
- `restore-secrets.sh` — re-pulls latest secrets, overwrites the `~/.config/polysim/*` files

Run `restore-secrets.sh` whenever a credential rotates.

---

## Security model

This repo is intentionally **public** — for that to be safe, these rules hold:

1. **Nothing in `~/.config/polysim/`** is committed. The `.gitignore` blocks
   `*.env`, `*.secret`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`,
   `configs/polysim/env.sh`, `configs/polysim/mcp-secrets.sh`, and similar.
2. **Bitwarden API key never touches disk.** `BW_CLIENTID` / `BW_CLIENTSECRET` /
   `BW_PASSWORD` live only in the shell that runs `restore-secrets.sh`.
   The session token (`.bw-session`) is the only thing persisted, `chmod 600`.
3. **Secret files are `chmod 600`** and the directory `chmod 700`.
4. The example files (`*.example`) are placeholders only. The real
   `env.sh` / `mcp-secrets.sh` are written by `restore-secrets.sh`, never by hand.
5. If you ever paste a secret into a shell-history-recording terminal,
   prefix the command with a space (`HISTCONTROL=ignorespace` is on in zsh by default).

If you accidentally commit a secret: rotate it in Bitwarden first, then
`git rm` and force-push only after the rotation is live.

---

## Customisation

- Override Bitwarden item names by setting `POLYSIM_BW_*_ITEM` env vars
  before running `restore-secrets.sh` — see the top of that script.
- Override the secrets directory with `POLYSIM_CFG_DIR`.
- Add machine-local zsh tweaks in `~/.zshrc.local` (sourced last, gitignored).

---

## Supported OSes

- **Fedora** 40+ (uses `dnf`)
- **Ubuntu** 22.04+, **Debian** 12+ (uses `apt`)

Everything else falls back to manual install.

---

## License

MIT — see [LICENSE](LICENSE).
