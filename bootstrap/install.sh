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
  python3 python3-pip python3-venv
  pkg-config
  ripgrep fd-find
  postgresql-client                # psql, for talking to Supabase
  redis-tools                      # redis-cli, for inspecting Redis
  btop                             # system monitor (used by zellij layout)
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
    postgresql                     # provides psql on Fedora
    redis                          # provides redis-cli
    btop
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

# ---------------------------- zellij ----------------------------------------
#
# Installs the static musl Linux binary from GitHub releases — same version
# across Fedora and Ubuntu, no distro-package lag.

install_zellij() {
  local dest="${1:-/usr/local/bin}"
  local tmp
  tmp="$(mktemp -d)"

  local arch
  case "$(uname -m)" in
    x86_64)  arch="x86_64-unknown-linux-musl" ;;
    aarch64) arch="aarch64-unknown-linux-musl" ;;
    *)       warn "Unsupported arch for zellij: $(uname -m)"; rm -rf "$tmp"; return 1 ;;
  esac

  local url="https://github.com/zellij-org/zellij/releases/latest/download/zellij-${arch}.tar.gz"
  log "Downloading zellij (${arch})…"
  curl -fsSL "$url" -o "$tmp/zellij.tar.gz" \
    || { warn "zellij download failed"; rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/zellij.tar.gz" -C "$tmp" \
    || { warn "zellij extract failed"; rm -rf "$tmp"; return 1; }
  install -m 0755 "$tmp/zellij" "$dest/zellij" \
    || { warn "zellij install to $dest failed"; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  log "zellij installed to ${dest}/zellij"
}

if ! have zellij; then
  log "Installing zellij (terminal multiplexer)…"
  if [ -w /usr/local/bin ] || { [ -n "$SUDO" ] && $SUDO test -w /usr/local/bin 2>/dev/null; }; then
    TMP_DEST="$(mktemp -d)"
    install_zellij "$TMP_DEST" && { $SUDO install -m 0755 "$TMP_DEST/zellij" /usr/local/bin/zellij || true; rm -rf "$TMP_DEST"; }
    have zellij || install_zellij "$HOME/.local/bin"
  else
    mkdir -p "$HOME/.local/bin"
    install_zellij "$HOME/.local/bin"
  fi
fi

# ---------------------------- bun (JS runtime) -------------------------------
#
# Used by the polysimulator zellij layout (`bunx ccusage`) and as a faster
# Next.js dev runtime than npm. Official installer drops binary at ~/.bun/bin.

if ! have bun; then
  log "Installing bun…"
  curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 \
    || warn "bun install failed — install manually if needed"
fi
export PATH="$HOME/.bun/bin:$PATH"

# ---------------------------- stripe-cli -------------------------------------
#
# Polysimulator integrates Stripe; stripe-cli is needed for local webhook
# forwarding (`stripe listen --forward-to localhost:8000/api/stripe/webhook`).
# Released as .deb (apt) and .rpm (dnf) from GitHub.

install_stripe_cli() {
  local tmp version arch ext
  tmp="$(mktemp -d)"

  version="$(curl -fsSL https://api.github.com/repos/stripe/stripe-cli/releases/latest \
             | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")" \
    || { warn "could not resolve stripe-cli version"; rm -rf "$tmp"; return 1; }

  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *)       warn "unsupported arch for stripe-cli: $(uname -m)"; rm -rf "$tmp"; return 1 ;;
  esac

  case "$PKG" in apt) ext="deb" ;; dnf) ext="rpm" ;; esac

  local url="https://github.com/stripe/stripe-cli/releases/download/v${version}/stripe_${version}_linux_${arch}.${ext}"
  log "Downloading stripe-cli ${version} (${arch}.${ext})…"
  curl -fsSL "$url" -o "$tmp/stripe.${ext}" \
    || { warn "stripe-cli download failed"; rm -rf "$tmp"; return 1; }

  if [ "$ext" = "deb" ]; then
    $SUDO apt-get install -y "$tmp/stripe.deb" \
      || { warn "stripe-cli install failed"; rm -rf "$tmp"; return 1; }
  else
    $SUDO dnf install -y "$tmp/stripe.rpm" \
      || { warn "stripe-cli install failed"; rm -rf "$tmp"; return 1; }
  fi
  rm -rf "$tmp"
  log "stripe-cli ${version} installed"
}

if ! have stripe; then
  log "Installing stripe-cli…"
  install_stripe_cli || warn "stripe-cli not installed — install manually if you need webhook forwarding"
fi

# ---------------------------- mcp-grafana ------------------------------------
#
# Stdio MCP server referenced by polysimulator's .mcp.json. Without this
# binary, the grafana MCP server in Claude Code shows as failed.

install_mcp_grafana() {
  local dest="${1:-/usr/local/bin}"
  local tmp version arch
  tmp="$(mktemp -d)"

  version="$(curl -fsSL https://api.github.com/repos/grafana/mcp-grafana/releases/latest \
             | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")" \
    || { warn "could not resolve mcp-grafana version"; rm -rf "$tmp"; return 1; }

  case "$(uname -m)" in
    x86_64)  arch="x86_64" ;;
    aarch64) arch="arm64" ;;
    *)       warn "unsupported arch for mcp-grafana: $(uname -m)"; rm -rf "$tmp"; return 1 ;;
  esac

  local url="https://github.com/grafana/mcp-grafana/releases/download/v${version}/mcp-grafana_Linux_${arch}.tar.gz"
  log "Downloading mcp-grafana ${version} (${arch})…"
  curl -fsSL "$url" -o "$tmp/mcp-grafana.tar.gz" \
    || { warn "mcp-grafana download failed"; rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/mcp-grafana.tar.gz" -C "$tmp" \
    || { warn "mcp-grafana extract failed"; rm -rf "$tmp"; return 1; }
  install -m 0755 "$tmp/mcp-grafana" "$dest/mcp-grafana" \
    || { warn "mcp-grafana install to $dest failed"; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  log "mcp-grafana ${version} installed to ${dest}/mcp-grafana"
}

if ! have mcp-grafana; then
  log "Installing mcp-grafana (Grafana MCP server)…"
  if [ -w /usr/local/bin ] || { [ -n "$SUDO" ] && $SUDO test -w /usr/local/bin 2>/dev/null; }; then
    TMP_DEST="$(mktemp -d)"
    install_mcp_grafana "$TMP_DEST" && { $SUDO install -m 0755 "$TMP_DEST/mcp-grafana" /usr/local/bin/mcp-grafana || true; rm -rf "$TMP_DEST"; }
    have mcp-grafana || install_mcp_grafana "$HOME/.local/bin"
  else
    mkdir -p "$HOME/.local/bin"
    install_mcp_grafana "$HOME/.local/bin"
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
for c in git zsh tmux direnv gh node npm uv bun bws zellij claude docker stripe psql redis-cli btop mcp-grafana; do
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
