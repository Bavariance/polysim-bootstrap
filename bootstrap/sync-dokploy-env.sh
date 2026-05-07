#!/usr/bin/env bash
# sync-dokploy-env.sh — push the local .env.defaults + .env.defaults.<env>
# layer to the corresponding Dokploy compose's environment-variables panel.
#
# Companion to ./sync-secrets.sh:
#
#   sync-secrets.sh        →  generates a local .env from defaults + bws
#                             (consumed by `docker compose up` locally)
#   sync-dokploy-env.sh    →  pushes the same defaults to Dokploy compose
#                             panel (consumed by Dokploy at deploy time)
#
# bws-managed secrets stay where they are — this script only adds/updates
# the keys present in the .env.defaults* files. Existing Dokploy panel
# entries for keys NOT in the defaults are preserved verbatim.
#
# Layering (last assignment wins, matches sync-secrets.sh):
#   1. <polysim-repo>/.env.defaults
#   2. <polysim-repo>/.env.defaults.<env>
#
# Mapping <env> → composeId (from `dokploy project list` 2026-05-07):
#   prod         → qCKlu4fStE0xLfZRCKUdw   (Production)
#   staging      → nG8qoVvsNNaMyycQ-OVZc   (Staging Frankfurt)
#   staging-api  → D7D0CWyem5CjJi2bTegfZ   (Staging-API US-East)
#   staging3     → 7zxtKuQLxU9Po8GmtMbJh   (Staging3 US-East)
#
# Override the mapping with --compose-id (rare — for new composes).
#
# Usage:
#   sync-dokploy-env.sh --env staging-api
#   sync-dokploy-env.sh --env staging-api --dry-run     # show diff, don't push
#   sync-dokploy-env.sh --env staging-api --redeploy    # also trigger redeploy
#   sync-dokploy-env.sh --env prod --compose-id <other-id>  # override mapping
#
# Auth resolution:
#   - $DOKPLOY_API_KEY env var
#   - ~/.config/polysim/dokploy-api-key (chmod 600)
#
# Server URL:
#   - $DOKPLOY_URL env var
#   - ~/.config/polysim/dokploy-url
#   - default: https://hosting.wladefant.de/api
#
# Override polysimulator location with POLYSIM_REPO_DIR.

set -euo pipefail

log()  { printf '\033[1;34m[dok-sync]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- parse args -----------------------------------------------------------

ENV_NAME=""
DRY_RUN=0
REDEPLOY=0
COMPOSE_ID_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --env|-e)        [ $# -ge 2 ] || die "--env requires a value"
                     ENV_NAME="$2"; shift 2 ;;
    --env=*)         ENV_NAME="${1#*=}"; shift ;;
    --compose-id)    [ $# -ge 2 ] || die "--compose-id requires a value"
                     COMPOSE_ID_OVERRIDE="$2"; shift 2 ;;
    --compose-id=*)  COMPOSE_ID_OVERRIDE="${1#*=}"; shift ;;
    --dry-run|-n)    DRY_RUN=1; shift ;;
    --redeploy)      REDEPLOY=1; shift ;;
    -h|--help)       sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "Unknown argument: $1 (use --help)" ;;
  esac
done

[ -n "$ENV_NAME" ] || die "--env is required (e.g. --env staging-api). See --help."
case "$ENV_NAME" in
  ''|*[!a-zA-Z0-9_-]*) die "Invalid --env value: '$ENV_NAME'" ;;
esac

# ---- resolve composeId from env name --------------------------------------

if [ -n "$COMPOSE_ID_OVERRIDE" ]; then
  COMPOSE_ID="$COMPOSE_ID_OVERRIDE"
else
  case "$ENV_NAME" in
    prod)        COMPOSE_ID="qCKlu4fStE0xLfZRCKUdw" ;;
    staging)     COMPOSE_ID="nG8qoVvsNNaMyycQ-OVZc" ;;
    staging-api) COMPOSE_ID="D7D0CWyem5CjJi2bTegfZ" ;;
    staging3)    COMPOSE_ID="7zxtKuQLxU9Po8GmtMbJh" ;;
    *)           die "No composeId mapping for env '$ENV_NAME'.
Either:
  - Pick one of: prod, staging, staging-api, staging3
  - Override with --compose-id <id>
List Dokploy composes:
  curl -s -H \"x-api-key: \$DOKPLOY_API_KEY\" \"\$DOKPLOY_URL/project.all\" | jq" ;;
  esac
fi

# ---- resolve auth + URL ---------------------------------------------------

CFG_DIR="$HOME/.config/polysim"
KEY_FILE="$CFG_DIR/dokploy-api-key"
URL_FILE="$CFG_DIR/dokploy-url"

if [ -z "${DOKPLOY_API_KEY:-}" ] && [ -r "$KEY_FILE" ]; then
  DOKPLOY_API_KEY="$(<"$KEY_FILE")"
fi
DOKPLOY_API_KEY="$(printf '%s' "${DOKPLOY_API_KEY:-}" | tr -d '[:space:]')"
[ -n "$DOKPLOY_API_KEY" ] || die "DOKPLOY_API_KEY not set, and $KEY_FILE not found.
Persist your key:
  mkdir -p $CFG_DIR && printf '%s\n' '<token>' > $KEY_FILE && chmod 600 $KEY_FILE"

if [ -z "${DOKPLOY_URL:-}" ] && [ -r "$URL_FILE" ]; then
  DOKPLOY_URL="$(<"$URL_FILE")"
fi
DOKPLOY_URL="${DOKPLOY_URL:-https://hosting.wladefant.de/api}"
DOKPLOY_URL="${DOKPLOY_URL%/}"  # strip trailing slash

# ---- check tools ----------------------------------------------------------

command -v curl >/dev/null 2>&1 || die "curl not installed"
command -v jq   >/dev/null 2>&1 || die "jq not installed"

# ---- locate target repo ---------------------------------------------------

REPO_DIR="${POLYSIM_REPO_DIR:-$HOME/projects/polysimulator}"
[ -d "$REPO_DIR" ] || die "polysimulator repo not found at $REPO_DIR
Override with POLYSIM_REPO_DIR=/path/to/polysimulator $0"

DEFAULTS_FILE="$REPO_DIR/.env.defaults"
ENV_DEFAULTS_FILE="$REPO_DIR/.env.defaults.$ENV_NAME"

[ -r "$DEFAULTS_FILE" ] || warn "$DEFAULTS_FILE not found — env-agnostic defaults skipped"
[ -r "$ENV_DEFAULTS_FILE" ] || die "$ENV_DEFAULTS_FILE not found.
Did you typo --env? Available defaults files:
  ls $REPO_DIR/.env.defaults.*"

# ---- helpers --------------------------------------------------------------

# Read a .env-style file, output one KEY=VALUE per line.
# Skip blank lines, comments, and malformed lines without an '='. Keep the
# RAW value (no quote stripping) so what we send matches docker-compose's
# variable substitution semantics.
parse_env_file() {
  local f="$1"
  [ -r "$f" ] || return 0
  awk '
    /^[[:space:]]*#/    { next }
    /^[[:space:]]*$/    { next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
      # Strip leading whitespace but keep the value intact.
      sub(/^[[:space:]]+/, "")
      print
      next
    }
  ' "$f"
}

# Stable join of env-var lines, with later values winning duplicate keys.
# Stdin: KEY=VALUE per line. Stdout: KEY=VALUE per line, sorted by key.
merge_env_layers() {
  awk -F= '
    {
      key = $1
      sub(/^[^=]*=/, "")
      val[key] = $0
    }
    END {
      n = asorti(val, sorted)
      for (i = 1; i <= n; i++) print sorted[i] "=" val[sorted[i]]
    }
  '
}

# ---- build the merged defaults layer --------------------------------------

DEFAULTS_LINES="$( { parse_env_file "$DEFAULTS_FILE"; parse_env_file "$ENV_DEFAULTS_FILE"; } | merge_env_layers )"
DEFAULTS_KEYS="$(printf '%s\n' "$DEFAULTS_LINES" | awk -F= 'NF>0{print $1}')"
DEFAULTS_COUNT="$(printf '%s\n' "$DEFAULTS_LINES" | grep -c . || true)"

[ "$DEFAULTS_COUNT" -gt 0 ] \
  || die "0 keys parsed from defaults files — refusing to push an empty env."

log "Loaded $DEFAULTS_COUNT keys from defaults layer ($DEFAULTS_FILE + $ENV_DEFAULTS_FILE)"
log "Target compose: $COMPOSE_ID (env=$ENV_NAME)"
log "Dokploy URL:    $DOKPLOY_URL"

# ---- fetch current compose env --------------------------------------------

log "Fetching current compose env from Dokploy…"
COMPOSE_JSON="$(curl -fsS -H "x-api-key: $DOKPLOY_API_KEY" \
  "$DOKPLOY_URL/compose.one?composeId=$COMPOSE_ID")" \
  || die "Failed to fetch compose.one — check the composeId, API key, and URL."

# `env` is a single string with one KEY=VALUE per line (matches Dokploy panel).
CURRENT_ENV="$(printf '%s' "$COMPOSE_JSON" | jq -r '.env // ""')"
CURRENT_NAME="$(printf '%s' "$COMPOSE_JSON" | jq -r '.name // .composeId')"
log "Compose name: $CURRENT_NAME"
log "Current env panel: $(printf '%s\n' "$CURRENT_ENV" | grep -c . || echo 0) keys"

# ---- compute the merged env ------------------------------------------------

# Strategy:
#   1. Start from current panel.
#   2. For each key in the defaults layer, replace OR append.
#   3. Preserve everything else verbatim (bws-managed secrets, etc.).

TMP_CURRENT="$(mktemp)"
TMP_NEW="$(mktemp)"
trap 'rm -f "$TMP_CURRENT" "$TMP_NEW"' EXIT

printf '%s' "$CURRENT_ENV"  > "$TMP_CURRENT"
printf '\n'               >> "$TMP_CURRENT"  # ensure trailing newline

awk -v defaults="$DEFAULTS_LINES" '
  BEGIN {
    n = split(defaults, lines, "\n")
    for (i = 1; i <= n; i++) {
      line = lines[i]
      if (line == "") continue
      eq = index(line, "=")
      if (eq < 2) continue
      k = substr(line, 1, eq-1)
      v = substr(line, eq+1)
      def_val[k] = v
      def_seen[k] = 0
    }
  }
  {
    line = $0
    if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) {
      print line
      next
    }
    eq = index(line, "=")
    if (eq < 2) {
      print line
      next
    }
    k = substr(line, 1, eq-1)
    if (k in def_val) {
      print k "=" def_val[k]
      def_seen[k] = 1
    } else {
      print line
    }
  }
  END {
    # Append keys that were in defaults but not in the current panel.
    n = asorti(def_val, sorted)
    appended = 0
    for (i = 1; i <= n; i++) {
      k = sorted[i]
      if (!def_seen[k]) {
        if (!appended) {
          print ""
          print "# === added by sync-dokploy-env.sh — values from .env.defaults* ==="
          appended = 1
        }
        print k "=" def_val[k]
      }
    }
  }
' "$TMP_CURRENT" > "$TMP_NEW"

# ---- compute diff ----------------------------------------------------------

# For each defaults key, classify: ADD / UPDATE / SAME
ADD_COUNT=0
UPDATE_COUNT=0
SAME_COUNT=0

while IFS= read -r line; do
  [ -n "$line" ] || continue
  key="${line%%=*}"
  new_val="${line#*=}"

  current_val="$(awk -F= -v k="$key" 'NF>=2 && $1==k { sub(/^[^=]*=/, ""); print; exit }' "$TMP_CURRENT")"

  if [ -z "$current_val" ] && ! grep -qE "^${key}=" "$TMP_CURRENT"; then
    ADD_COUNT=$((ADD_COUNT+1))
    [ "$DRY_RUN" -eq 1 ] && printf '  + %s=%s\n' "$key" "$new_val"
  elif [ "$current_val" != "$new_val" ]; then
    UPDATE_COUNT=$((UPDATE_COUNT+1))
    [ "$DRY_RUN" -eq 1 ] && printf '  ~ %s: %s → %s\n' "$key" "$current_val" "$new_val"
  else
    SAME_COUNT=$((SAME_COUNT+1))
  fi
done <<< "$DEFAULTS_LINES"

log "Diff vs Dokploy panel: +$ADD_COUNT new, ~$UPDATE_COUNT changed, =$SAME_COUNT unchanged"

if [ "$DRY_RUN" -eq 1 ]; then
  log "Dry-run mode — not pushing. Re-run without --dry-run to apply."
  exit 0
fi

if [ "$ADD_COUNT" -eq 0 ] && [ "$UPDATE_COUNT" -eq 0 ]; then
  log "No changes needed."
  if [ "$REDEPLOY" -eq 0 ]; then
    exit 0
  fi
fi

# ---- push to Dokploy ------------------------------------------------------

NEW_ENV="$(<"$TMP_NEW")"
PAYLOAD="$(jq -n --arg id "$COMPOSE_ID" --arg env "$NEW_ENV" \
  '{composeId: $id, env: $env}')"

log "Pushing merged env to Dokploy ($(printf '%s\n' "$NEW_ENV" | grep -c . || echo 0) keys)…"

RESP="$(curl -fsS -X POST \
  -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$DOKPLOY_URL/compose.update")" || die "Dokploy push failed:
$RESP"

log "Pushed. Dokploy will pick up the new env on the next deploy."

# ---- redeploy (optional) ---------------------------------------------------

if [ "$REDEPLOY" -eq 1 ]; then
  log "Triggering redeploy…"
  RD_RESP="$(curl -fsS -X POST \
    -H "x-api-key: $DOKPLOY_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"composeId\":\"$COMPOSE_ID\"}" \
    "$DOKPLOY_URL/compose.redeploy")" || die "Redeploy failed:
$RD_RESP"
  log "Redeploy queued. Watch Dokploy compose logs for completion."
fi

log "Done."
