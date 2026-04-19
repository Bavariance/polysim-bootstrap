# polysim-bootstrap

One-command dev-environment setup for [Polysimulator](https://github.com/Bavariance/polysimulator)
on Fedora and Ubuntu/Debian. Installs the deterministic toolchain, links shell
+ tmux + direnv configs, and pulls per-machine secrets from **Bitwarden Secrets
Manager** via the `bws` CLI.

**No secrets live in this repo.** It is safe to be public. See
[Security model](#security-model) below.

---

## What it sets up

- **Packages**: `zsh`, `bash`, `tmux`, `git`, `curl`, `direnv`, `jq`, `ripgrep`, `fd`, build tools
- **Languages / tooling**: Node 22 (via [`fnm`](https://github.com/Schniz/fnm)), [`uv`](https://github.com/astral-sh/uv) for Python, Docker CLI
- **CLIs**: `gh` (GitHub), `bws` (Bitwarden Secrets Manager), `claude` (Claude Code)
- **VS Code**: Remote-SSH server prerequisites (so opening the host in VS Code "just works")
- **Configs**: minimal `.zshrc`, `.zshenv`, `.bashrc`, `.bash_profile`, `.tmux.conf`, `direnvrc`
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
    shell-init.sh                     ← symlink → bootstrap/configs/polysim/shell-init.sh
  .ssh/
  .bashrc, .bash_profile              ← symlinks → bootstrap/configs/bash/*
  .zshrc, .zshenv                     ← symlinks → bootstrap/configs/zsh/*
  .tmux.conf                          ← symlink → bootstrap/configs/tmux/tmux.conf
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
mkdir -p ~/.config/polysim
printf '%s\n' '<machine-account-token>' > ~/.config/polysim/bws-token
printf '%s\n' '<polysimulator-project-uuid>' > ~/.config/polysim/bws-project-id
chmod 600 ~/.config/polysim/bws-token ~/.config/polysim/bws-project-id

# 5. open a new shell so PATH and BWS_* env vars pick up
exec $SHELL

# 6. clone the app
gh auth login
gh repo clone Bavariance/polysimulator ~/projects/polysimulator

# 7. pull secrets into <polysim-repo>/.env
./bootstrap/sync-secrets.sh

# 8. (optional) make zsh the login shell
chsh -s "$(command -v zsh)"
```

After step 5, `bws secret list` and `bws project list` work without any
manual `export`. After step 7, `cd ~/projects/polysimulator && docker compose
up --build` Just Works.

To find your project UUID before step 4:
```bash
BWS_ACCESS_TOKEN=<token> bws project list
```

---

## Re-running

All scripts are **idempotent**:

- `install.sh`        — re-checks each tool, installs only what's missing
- `link-configs.sh`   — leaves correct symlinks alone, backs up real files to `*.bak-<timestamp>`
- `sync-secrets.sh`   — re-pulls latest secrets, atomically replaces `<polysim-repo>/.env`

Run `sync-secrets.sh` whenever a secret rotates in Bitwarden Secrets Manager.

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

Architectures: `x86_64` and `aarch64` (bws install handles both).

---

## License

MIT — see [LICENSE](LICENSE).
