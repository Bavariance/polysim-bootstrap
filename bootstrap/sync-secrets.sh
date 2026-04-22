#!/usr/bin/env bash
# sync-secrets.sh — pull polysimulator secrets from Bitwarden Secrets Manager
# and write them to <polysimulator-repo>/.env, layered with env-specific defaults.
#
# Layering (last assignment wins for duplicate keys, per docker-compose semantics):
#   1. <polysim-repo>/.env.defaults              (env-agnostic, optional)
#   2. <polysim-repo>/.env.defaults.<env>        (env-specific, optional)
#   3. bws secret list -o env                    (secrets, always — highest precedence)
#
# SSH key routing (multi-line values that would break direnv's .env parser):
#   SSH_KEY_<name>  →  ~/.ssh/<name>      (chmod 600, private key)
#   SSH_PUB_<name>  →  ~/.ssh/<name>.pub  (chmod 644, public key)
# <name> is lowercased for the filename. These secrets are excluded from .env
# and consumed by ssh-agent (auto-loaded via keychain in shell-init.sh).
#
# Usage:
#   ./bootstrap/sync-secrets.sh                  # default: --env dev
#   ./bootstrap/sync-secrets.sh --env prod
#   ./bootstrap/sync-secrets.sh --env staging-api
#   ./bootstrap/sync-secrets.sh -e dev
#
# Replaces the legacy bw (personal vault) flow. Secret keys in bws must match
# the env var names the app expects — no prefix translation.
#
# Prerequisites (handled by ./bootstrap/install.sh):
#   - bws CLI on PATH
#
# Auth resolution (in order):
#   - $BWS_ACCESS_TOKEN env var
#   - ~/.config/polysim/bws-token (chmod 600)
#
# Project resolution (in order):
#   - $BWS_PROJECT_ID env var
#   - ~/.config/polysim/bws-project-id
#   - if neither: lists available projects and exits non-zero
#
# Output:
#   <polysimulator-repo>/.env (chmod 600, gitignored)
#
# Override polysimulator location with POLYSIM_REPO_DIR.

set -euo pipefail

log()  { printf '\033[1;34m[sync]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- parse args -----------------------------------------------------------

ENV_NAME="dev"
while [ $# -gt 0 ]; do
  case "$1" in
    --env|-e)  [ $# -ge 2 ] || die "--env requires a value (e.g. --env prod)"
               ENV_NAME="$2"; shift 2 ;;
    --env=*)   ENV_NAME="${1#*=}"; shift ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

case "$ENV_NAME" in
  ''|*[!a-zA-Z0-9_-]*) die "Invalid --env value: '$ENV_NAME' (alphanumeric, dash, underscore only)" ;;
esac

CFG_DIR="$HOME/.config/polysim"
TOKEN_FILE="$CFG_DIR/bws-token"
PROJECT_FILE="$CFG_DIR/bws-project-id"
SERVER_URL_FILE="$CFG_DIR/bws-server-url"

# Strip surrounding whitespace + a single leading `<` / trailing `>` (common
# copy-paste mistake when users paste the README's `<placeholder>` literally).
sanitize() {
  local v="$1"
  v="${v#<}"; v="${v%>}"
  printf '%s' "$v" | tr -d '[:space:]'
}

# ---- resolve auth ---------------------------------------------------------

if [ -z "${BWS_ACCESS_TOKEN:-}" ] && [ -r "$TOKEN_FILE" ]; then
  BWS_ACCESS_TOKEN="$(cat "$TOKEN_FILE")"
  export BWS_ACCESS_TOKEN
fi
BWS_ACCESS_TOKEN="$(sanitize "${BWS_ACCESS_TOKEN:-}")"
export BWS_ACCESS_TOKEN

# ---- resolve server URL (default US, EU users override) -------------------

if [ -z "${BWS_SERVER_URL:-}" ] && [ -r "$SERVER_URL_FILE" ]; then
  BWS_SERVER_URL="$(cat "$SERVER_URL_FILE")"
fi
BWS_SERVER_URL="$(sanitize "${BWS_SERVER_URL:-}")"
[ -n "$BWS_SERVER_URL" ] && export BWS_SERVER_URL

if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
  die "BWS_ACCESS_TOKEN not set and $TOKEN_FILE not found.
Get a machine-account token from sm.bitwarden.com, then either:
  export BWS_ACCESS_TOKEN=<token>
or persist it:
  mkdir -p $CFG_DIR && printf '%s\n' '<token>' > $TOKEN_FILE && chmod 600 $TOKEN_FILE"
fi

# ---- check tools ----------------------------------------------------------

command -v bws >/dev/null 2>&1 \
  || die "bws not installed — run ./bootstrap/install.sh first"
command -v jq >/dev/null 2>&1 \
  || die "jq not installed — run ./bootstrap/install.sh first (or apt-get install jq)"

# ---- resolve project id ---------------------------------------------------

if [ -z "${BWS_PROJECT_ID:-}" ] && [ -r "$PROJECT_FILE" ]; then
  BWS_PROJECT_ID="$(cat "$PROJECT_FILE")"
fi
BWS_PROJECT_ID="$(sanitize "${BWS_PROJECT_ID:-}")"

if [ -z "$BWS_PROJECT_ID" ]; then
  warn "BWS_PROJECT_ID not set. Available projects:"
  bws project list >&2 || true
  die "Set BWS_PROJECT_ID to your project UUID, or persist it:
  mkdir -p $CFG_DIR && printf '%s\n' 'YOUR_PROJECT_UUID' > $PROJECT_FILE"
fi

if ! printf '%s' "$BWS_PROJECT_ID" \
     | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
  die "BWS_PROJECT_ID is not a valid UUID: '$BWS_PROJECT_ID'
Likely causes:
  - You copy-pasted '<polysimulator-project-uuid>' literally into $PROJECT_FILE
    instead of your actual UUID. Fix:
        printf '%s\n' 'YOUR_ACTUAL_UUID' > $PROJECT_FILE
  - A stale BWS_PROJECT_ID is exported in this shell. Fix:
        unset BWS_PROJECT_ID && exec \$SHELL
  - Find your UUID with: BWS_ACCESS_TOKEN=<token> bws project list"
fi
export BWS_PROJECT_ID

# ---- locate target repo ---------------------------------------------------

REPO_DIR="${POLYSIM_REPO_DIR:-$HOME/projects/polysimulator}"
[ -d "$REPO_DIR" ] \
  || die "polysimulator repo not found at $REPO_DIR
Clone it first:
  gh repo clone Bavariance/polysimulator $REPO_DIR
Or override with POLYSIM_REPO_DIR=/path/to/polysimulator $0"

DEFAULTS_FILE="$REPO_DIR/.env.defaults"
ENV_DEFAULTS_FILE="$REPO_DIR/.env.defaults.$ENV_NAME"
OUT_FILE="$REPO_DIR/.env"

# ---- fetch secrets --------------------------------------------------------

log "Environment: $ENV_NAME"
log "Server URL:  ${BWS_SERVER_URL:-https://vault.bitwarden.com (default)}"
log "Fetching secrets from bws (project $BWS_PROJECT_ID)…"
SECRETS_JSON="$(bws secret list -o json "$BWS_PROJECT_ID" 2>&1)" \
  || die "bws fetch failed:
$SECRETS_JSON"

printf '%s' "$SECRETS_JSON" | jq empty >/dev/null 2>&1 \
  || die "bws returned non-JSON output:
$SECRETS_JSON"

TOTAL_COUNT="$(printf '%s' "$SECRETS_JSON" | jq 'length')"
[ "$TOTAL_COUNT" -gt 0 ] \
  || die "bws returned 0 secrets — check the project ID and machine-account access"

ENV_COUNT="$(printf '%s' "$SECRETS_JSON" \
  | jq '[.[] | select(.key | test("^SSH_(KEY|PUB)_") | not)] | length')"
SSH_COUNT="$(printf '%s' "$SECRETS_JSON" \
  | jq '[.[] | select(.key | test("^SSH_(KEY|PUB)_"))] | length')"

# Warn on multi-line non-SSH secrets — they'll break direnv's .env parser.
MULTILINE_KEYS="$(printf '%s' "$SECRETS_JSON" \
  | jq -r '.[] | select(.key | test("^SSH_(KEY|PUB)_") | not)
                | select(.value | contains("\n")) | .key')"
if [ -n "$MULTILINE_KEYS" ]; then
  warn "Multi-line non-SSH secrets detected — direnv will fail to load .env:"
  printf '%s\n' "$MULTILINE_KEYS" | sed 's/^/  - /' >&2
  warn "Rename them to SSH_KEY_<name> or SSH_PUB_<name> to route them to ~/.ssh/ instead."
fi

# ---- write SSH key files ---------------------------------------------------

if [ "$SSH_COUNT" -gt 0 ]; then
  SSH_DIR="$HOME/.ssh"
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"

  SSH_WRITTEN=""
  # Stream one base64-encoded JSON blob per SSH secret so multi-line values
  # survive the shell loop intact.
  while IFS= read -r _row; do
    [ -n "$_row" ] || continue
    _decoded="$(printf '%s' "$_row" | base64 -d)"
    _skey="$(printf '%s' "$_decoded" | jq -r '.key')"
    _sval="$(printf '%s' "$_decoded" | jq -r '.value')"

    case "$_skey" in
      SSH_KEY_*) _suffix="";      _mode=600; _raw="${_skey#SSH_KEY_}" ;;
      SSH_PUB_*) _suffix=".pub";  _mode=644; _raw="${_skey#SSH_PUB_}" ;;
      *)         continue ;;
    esac

    if [ -z "$_raw" ]; then
      warn "Skipping malformed SSH secret (empty name after prefix): $_skey"
      continue
    fi

    _fname="$(printf '%s' "$_raw" | tr '[:upper:]' '[:lower:]')${_suffix}"
    _target="$SSH_DIR/$_fname"
    _tmp_target="$(mktemp "${_target}.sync.XXXXXX")"
    # Strip one trailing newline (if present) and add exactly one — OpenSSH
    # requires the file to end with a newline.
    printf '%s\n' "${_sval%$'\n'}" > "$_tmp_target"
    chmod "$_mode" "$_tmp_target"
    mv "$_tmp_target" "$_target"
    SSH_WRITTEN="$SSH_WRITTEN $_fname"
  done < <(printf '%s' "$SECRETS_JSON" \
    | jq -r '.[] | select(.key | test("^SSH_(KEY|PUB)_")) | @base64')

  log "Wrote $SSH_COUNT ssh key file(s) to $SSH_DIR:$SSH_WRITTEN"
fi

# ---- write .env atomically -------------------------------------------------

umask 077
TMP="$(mktemp "$REPO_DIR/.env.sync.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

{
  printf '# Generated by polysim-bootstrap/bootstrap/sync-secrets.sh\n'
  printf '# DO NOT EDIT MANUALLY — re-run sync-secrets.sh after rotating any secret\n'
  printf '# or changing a defaults file.\n'
  printf '#\n'
  printf '# Layered (last wins for duplicate keys):\n'
  printf '#   1. .env.defaults                  (env-agnostic)\n'
  printf '#   2. .env.defaults.%s               (env-specific)\n' "$ENV_NAME"
  printf '#   3. bws secrets                    (env vars; SSH_KEY_*/SSH_PUB_* → ~/.ssh/)\n'
  printf '#\n'
  printf '# Environment: %s\n' "$ENV_NAME"
  printf '# bws project: %s\n' "$BWS_PROJECT_ID"
  printf '# Generated:   %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ -r "$DEFAULTS_FILE" ]; then
    printf '# ====== %s ======\n' "$(basename "$DEFAULTS_FILE")"
    cat "$DEFAULTS_FILE"
    printf '\n'
  else
    printf '# (no .env.defaults found — skipping env-agnostic defaults layer)\n\n'
  fi

  if [ -r "$ENV_DEFAULTS_FILE" ]; then
    printf '# ====== %s ======\n' "$(basename "$ENV_DEFAULTS_FILE")"
    cat "$ENV_DEFAULTS_FILE"
    printf '\n'
  else
    printf '# (no %s found — skipping env-specific defaults layer)\n\n' "$(basename "$ENV_DEFAULTS_FILE")"
  fi

  printf '# ====== secrets from bws (SSH_KEY_*/SSH_PUB_* routed to ~/.ssh/) ======\n'
  printf '%s' "$SECRETS_JSON" | jq -r '
    [.[] | select(.key | test("^SSH_(KEY|PUB)_") | not)]
    | sort_by(.key) | .[]
    | "\(.key)=\(.value)"
  '
} > "$TMP"

mv "$TMP" "$OUT_FILE"
chmod 600 "$OUT_FILE"
trap - EXIT

log "Wrote $OUT_FILE ($ENV_COUNT env secrets, $(wc -l < "$OUT_FILE") total lines, chmod 600)"
log "Done. 'docker compose up' will pick up the new env; ssh-agent picks up keys on next shell."
