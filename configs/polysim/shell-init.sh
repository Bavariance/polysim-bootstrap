# shell-init.sh — sourced by both bash and zsh on shell startup.
#
# POSIX-compatible. Do not use bash- or zsh-specific syntax here.
#
# Linked to ~/.config/polysim/shell-init.sh by link-configs.sh.

# Auto-export BWS_ACCESS_TOKEN so `bws` works without re-exporting per shell.
_polysim_token_file="$HOME/.config/polysim/bws-token"
if [ -r "$_polysim_token_file" ]; then
  BWS_ACCESS_TOKEN="$(cat "$_polysim_token_file")"
  export BWS_ACCESS_TOKEN
fi
unset _polysim_token_file

# Auto-export BWS_PROJECT_ID for ergonomic `bws secret list` etc.
_polysim_project_file="$HOME/.config/polysim/bws-project-id"
if [ -r "$_polysim_project_file" ]; then
  BWS_PROJECT_ID="$(cat "$_polysim_project_file")"
  export BWS_PROJECT_ID
fi
unset _polysim_project_file
