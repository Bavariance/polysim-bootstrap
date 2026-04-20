# shell-init.sh — sourced by both bash and zsh on shell startup.
#
# POSIX-compatible. Do not use bash- or zsh-specific syntax here.
#
# Linked to ~/.config/polysim/shell-init.sh by link-configs.sh.

# Strip a single leading `<` / trailing `>` plus all whitespace — defends
# against the README's `<placeholder>` syntax being copy-pasted literally.
_polysim_clean() {
  v="$1"
  v="${v#<}"; v="${v%>}"
  printf '%s' "$v" | tr -d '[:space:]'
}

# Auto-export BWS_ACCESS_TOKEN so `bws` works without re-exporting per shell.
_polysim_token_file="$HOME/.config/polysim/bws-token"
if [ -r "$_polysim_token_file" ]; then
  BWS_ACCESS_TOKEN="$(_polysim_clean "$(cat "$_polysim_token_file")")"
  [ -n "$BWS_ACCESS_TOKEN" ] && export BWS_ACCESS_TOKEN
fi
unset _polysim_token_file

# Auto-export BWS_PROJECT_ID for ergonomic `bws secret list` etc.
_polysim_project_file="$HOME/.config/polysim/bws-project-id"
if [ -r "$_polysim_project_file" ]; then
  BWS_PROJECT_ID="$(_polysim_clean "$(cat "$_polysim_project_file")")"
  [ -n "$BWS_PROJECT_ID" ] && export BWS_PROJECT_ID
fi
unset _polysim_project_file

# Auto-export BWS_SERVER_URL for non-US Bitwarden instances (e.g. EU).
# Defaults to https://vault.bitwarden.com if the file is absent.
_polysim_server_file="$HOME/.config/polysim/bws-server-url"
if [ -r "$_polysim_server_file" ]; then
  BWS_SERVER_URL="$(_polysim_clean "$(cat "$_polysim_server_file")")"
  [ -n "$BWS_SERVER_URL" ] && export BWS_SERVER_URL
fi
unset _polysim_server_file

unset -f _polysim_clean 2>/dev/null || true

# Persistent ssh-agent via keychain — prompts once per machine-uptime for any
# passphrase-protected key, then caches for all future shells. Silent when
# keychain isn't installed so this file stays safe on minimal systems.
# Auto-discovers all key pairs in ~/.ssh/ (anything with a matching .pub).
if command -v keychain >/dev/null 2>&1 && [ -d "$HOME/.ssh" ]; then
  _polysim_keys=""
  for _pub in "$HOME/.ssh"/*.pub; do
    [ -r "$_pub" ] || continue
    _priv="${_pub%.pub}"
    [ -r "$_priv" ] && _polysim_keys="$_polysim_keys $_priv"
  done
  if [ -n "$_polysim_keys" ]; then
    eval "$(keychain --quiet --eval --agents ssh $_polysim_keys)"
  fi
  unset _polysim_keys _pub _priv
fi
