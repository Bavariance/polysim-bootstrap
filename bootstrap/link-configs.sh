#!/usr/bin/env bash
# link-configs.sh — symlink shell + tmux + direnv configs from this repo into $HOME.
#
# Idempotent. Existing real files are backed up to <path>.bak-<timestamp>.
# Existing symlinks pointing into this repo are left alone; symlinks elsewhere
# are replaced (after backup).

set -euo pipefail

log()  { printf '\033[1;34m[link]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

link() {
  local src="$1" dst="$2"

  [ -e "$src" ] || { warn "source missing: $src"; return; }

  mkdir -p "$(dirname "$dst")"

  if [ -L "$dst" ]; then
    local current
    current="$(readlink -f "$dst" || true)"
    if [ "$current" = "$(readlink -f "$src")" ]; then
      log "ok    $dst → $src"
      return
    fi
    warn "replacing symlink $dst (was → $current)"
    rm -f "$dst"
  elif [ -e "$dst" ]; then
    log "backup $dst → $dst.bak-$STAMP"
    mv "$dst" "$dst.bak-$STAMP"
  fi

  ln -s "$src" "$dst"
  log "link  $dst → $src"
}

link "$REPO_ROOT/configs/zsh/zshrc"        "$HOME/.zshrc"
link "$REPO_ROOT/configs/zsh/zshenv"       "$HOME/.zshenv"
link "$REPO_ROOT/configs/tmux/tmux.conf"   "$HOME/.tmux.conf"
link "$REPO_ROOT/configs/direnv/direnvrc"  "$HOME/.config/direnv/direnvrc"

log "Done. Open a new shell to pick up the new configs."
