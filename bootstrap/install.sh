#!/usr/bin/env bash
# install.sh — deterministic dev-machine setup for Fedora and Ubuntu.
#
# Idempotent. Safe to re-run. Does NOT touch secrets — see sync-secrets.sh.
#
# Usage:
#   ./bootstrap/install.sh                 # full install
#   SKIP_DOCKER=1 ./bootstrap/install.sh   # skip Docker CLI
#   ASSUME_YES=1 ./bootstrap/install.sh    # non-interactive

set -euo pipefail

# ---------------------------- helpers ----------------------------------------

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n'    "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n'    "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------- OS detect --------------------------------------

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"
else
  die "/etc/os-release not found — unsupported OS"
fi

case "$OS_ID" in
  fedora|rhel|centos|rocky|almalinux) PKG="dnf" ;;
  ubuntu|debian|linuxmint|pop)        PKG="apt" ;;
  *)
    case "$OS_LIKE" in
      *fedora*|*rhel*) PKG="dnf" ;;
      *debian*|*ubuntu*) PKG="apt" ;;
      *) die "Unsupported OS: $OS_ID ($OS_LIKE)" ;;
    esac
    ;;
esac

log "Detected OS: $OS_ID (pkg: $PKG)"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  have sudo || die "sudo is required for install"
  SUDO="sudo"
fi

YES_FLAG=""
[ "${ASSUME_YES:-0}" = "1" ] && YES_FLAG="-y"

# ---------------------------- package install --------------------------------

apt_install() {
  $SUDO apt-get update -qq
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends "$@"
}

dnf_install() {
  $SUDO dnf install -y "$@"
}

pkg_install() {
  if [ "$PKG" = "apt" ]; then apt_install "$@"; else dnf_install "$@"; fi
}

log "Installing base packages…"
COMMON_PKGS=(
  curl wget git ca-certificates gnupg
  zsh tmux jq unzip xz-utils
  build-essential
  python3 python3-pip
  pkg-config
  ripgrep fd-find
)

# Translate apt names → dnf names where they differ.
if [ "$PKG" = "dnf" ]; then
  COMMON_PKGS=(
    curl wget git ca-certificates gnupg2
    zsh tmux jq unzip xz
    @development-tools
    python3 python3-pip
    pkgconf-pkg-config
    ripgrep fd-find
  )
fi

pkg_install "${COMMON_PKGS[@]}" || warn "Some base packages failed — continuing"

# ---------------------------- direnv -----------------------------------------

if ! have direnv; then
  log "Installing direnv…"
  pkg_install direnv || {
    warn "Falling back to direnv install script"
    curl -sfL https://direnv.net/install.sh | $SUDO bash
  }
fi

# ---------------------------- GitHub CLI -------------------------------------

if ! have gh; then
  log "Installing GitHub CLI…"
  if [ "$PKG" = "apt" ]; then
    type -p curl >/dev/null
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | $SUDO dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    $SUDO chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    apt_install gh
  else
    $SUDO dnf install -y 'dnf-command(config-manager)' || true
    $SUDO dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null \
      || $SUDO dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
    $SUDO dnf install -y gh
  fi
fi

# ---------------------------- Node.js via fnm --------------------------------

if ! have fnm; then
  log "Installing fnm (Node version manager)…"
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$HOME/.local/share/fnm" --skip-shell
fi

export PATH="$HOME/.local/share/fnm:$PATH"
if have fnm; then
  eval "$(fnm env --shell bash)"
  if ! fnm list | grep -q 'v22'; then
    log "Installing Node 22 (LTS)…"
    fnm install 22
    fnm default 22
  fi
fi

# ---------------------------- uv (Python) ------------------------------------

if ! have uv; then
  log "Installing uv (Python package manager)…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# ---------------------------- Docker CLI -------------------------------------

if [ "${SKIP_DOCKER:-0}" != "1" ] && ! have docker; then
  log "Installing Docker CLI…"
  if [ "$PKG" = "apt" ]; then
    pkg_install docker.io || warn "docker.io install failed — install Docker Engine manually if needed"
  else
    pkg_install docker-cli || pkg_install moby-engine || warn "docker install failed — install manually if needed"
  fi
fi

# ---------------------------- bws (Bitwarden Secrets Manager CLI) ------------
#
# bws is a separate binary from the personal-vault `bw` CLI. Releases use a
# versioned tag (bws-vX.Y.Z) with no /latest/download/ endpoint, so we query
# the GitHub API to resolve the current version.

install_bws() {
  local dest="${1:-/usr/local/bin}"
  local tmp
  tmp="$(mktemp -d)"

  local version
  version="$(curl -fsSL "https://api.github.com/repos/bitwarden/sdk-sm/releases" \
    | python3 -c "
import sys, json
releases = json.load(sys.stdin)
tags = [r['tag_name'] for r in releases if r['tag_name'].startswith('bws-v')]
print(tags[0].replace('bws-v', '')) if tags else sys.exit(1)
")" || { warn "Could not resolve bws version from GitHub API"; rm -rf "$tmp"; return 1; }

  local arch
  case "$(uname -m)" in
    x86_64)  arch="x86_64-unknown-linux-gnu" ;;
    aarch64) arch="aarch64-unknown-linux-gnu" ;;
    *)       warn "Unsupported arch for bws: $(uname -m)"; rm -rf "$tmp"; return 1 ;;
  esac

  local url="https://github.com/bitwarden/sdk-sm/releases/download/bws-v${version}/bws-${arch}-${version}.zip"
  log "Downloading bws ${version} (${arch})…"
  curl -fsSL "$url" -o "$tmp/bws.zip" || { warn "bws download failed"; rm -rf "$tmp"; return 1; }
  unzip -qo "$tmp/bws.zip" bws -d "$tmp" || { warn "bws unzip failed"; rm -rf "$tmp"; return 1; }
  install -m 0755 "$tmp/bws" "$dest/bws" || { warn "bws install to $dest failed"; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  log "bws ${version} installed to ${dest}/bws"
}

if ! have bws; then
  log "Installing bws (Bitwarden Secrets Manager CLI)…"
  if [ -w /usr/local/bin ] || { [ -n "$SUDO" ] && $SUDO test -w /usr/local/bin 2>/dev/null; }; then
    TMP_DEST="$(mktemp -d)"
    install_bws "$TMP_DEST" && { $SUDO install -m 0755 "$TMP_DEST/bws" /usr/local/bin/bws || true; rm -rf "$TMP_DEST"; }
    have bws || install_bws "$HOME/.local/bin"
  else
    mkdir -p "$HOME/.local/bin"
    install_bws "$HOME/.local/bin"
  fi
fi

# ---------------------------- Claude Code CLI --------------------------------

if ! have claude; then
  log "Installing Claude Code CLI…"
  if ! have npm; then
    die "npm not on PATH — re-run after sourcing fnm (open a new shell)"
  fi
  npm install -g @anthropic-ai/claude-code
fi

# ---------------------------- VS Code Remote prereqs -------------------------

# vscode-server unpacks to ~/.vscode-server and needs glibc, gcompat (musl), tar.
log "Ensuring VS Code Remote prerequisites…"
pkg_install tar gzip || true
if [ "$PKG" = "dnf" ]; then
  pkg_install glibc-langpack-en glibcxx-devel 2>/dev/null || pkg_install libstdc++ || true
fi

# ---------------------------- summary ----------------------------------------

log "Install complete. Versions:"
for c in git zsh tmux direnv gh node npm uv bws claude docker; do
  if have "$c"; then
    printf '  %-8s %s\n' "$c" "$("$c" --version 2>&1 | head -1)"
  else
    printf '  %-8s (not installed)\n' "$c"
  fi
done

cat <<EOF

Next steps:
  1. ./bootstrap/link-configs.sh        # symlink shell + tmux + direnv configs
  2. Persist your Bitwarden Secrets Manager machine-account token:
       mkdir -p ~/.config/polysim
       printf '%s\n' '<token>' > ~/.config/polysim/bws-token
       printf '%s\n' '<project-uuid>' > ~/.config/polysim/bws-project-id
       chmod 600 ~/.config/polysim/bws-token ~/.config/polysim/bws-project-id
  3. Clone polysimulator and sync secrets:
       gh auth login
       gh repo clone Bavariance/polysimulator ~/projects/polysimulator
       ./bootstrap/sync-secrets.sh        # writes ~/projects/polysimulator/.env
  4. chsh -s "\$(command -v zsh)"          # optional, switch login shell
  5. Open a new shell.

EOF
