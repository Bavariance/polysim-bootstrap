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
# Auth resolution (highest precedence first):
#   1. $DOKPLOY_API_KEY env var (manual override always wins)
#   2. bws (Bitwarden Secrets Manager) — secret key DOKPLOY_API_KEY in
#      the configured project. This matches sync-secrets.sh, so a host
#      that already has bws set up needs no extra config. Override the
#      secret name with --bws-key=NAME.
#   3. ~/.config/polysim/dokploy-api-key (legacy plaintext fallback)
#
# Skip the bws lookup with --no-bws (useful when you want to be sure
# the key file or env var is what's used).
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
BWS_KEY_NAME="DOKPLOY_API_KEY"
NO_BWS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --env|-e)        [ $# -ge 2 ] || die "--env requires a value"
                     ENV_NAME="$2"; shift 2 ;;
    --env=*)         ENV_NAME="${1#*=}"; shift ;;
    --compose-id)    [ $# -ge 2 ] || die "--compose-id requires a value"
                     COMPOSE_ID_OVERRIDE="$2"; shift 2 ;;
    --compose-id=*)  COMPOSE_ID_OVERRIDE="${1#*=}"; shift ;;
    --bws-key)       [ $# -ge 2 ] || die "--bws-key requires a value"
                     BWS_KEY_NAME="$2"; shift 2 ;;
    --bws-key=*)     BWS_KEY_NAME="${1#*=}"; shift ;;
    --no-bws)        NO_BWS=1; shift ;;
    --dry-run|-n)    DRY_RUN=1; shift ;;
    --redeploy)      REDEPLOY=1; shift ;;
    -h|--help)       sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
BWS_TOKEN_FILE="$CFG_DIR/bws-token"
BWS_PROJECT_FILE="$CFG_DIR/bws-project-id"
BWS_SERVER_URL_FILE="$CFG_DIR/bws-server-url"

# Resolution order: env var → bws → legacy file.
# Step 1: env var wins immediately.
DOKPLOY_API_KEY_SOURCE=""
if [ -n "${DOKPLOY_API_KEY:-}" ]; then
  DOKPLOY_API_KEY_SOURCE="env var"
fi

# Step 2: bws (only if env var didn't resolve and --no-bws not passed).
# Mirrors the sync-secrets.sh setup: $BWS_ACCESS_TOKEN env var or
# ~/.config/polysim/bws-token, $BWS_PROJECT_ID env or bws-project-id.
if [ -z "${DOKPLOY_API_KEY:-}" ] && [ "$NO_BWS" -eq 0 ]; then
  if command -v bws >/dev/null 2>&1; then
    if [ -z "${BWS_ACCESS_TOKEN:-}" ] && [ -r "$BWS_TOKEN_FILE" ]; then
      BWS_ACCESS_TOKEN="$(cat "$BWS_TOKEN_FILE")"
    fi
    if [ -z "${BWS_PROJECT_ID:-}" ] && [ -r "$BWS_PROJECT_FILE" ]; then
      BWS_PROJECT_ID="$(cat "$BWS_PROJECT_FILE")"
    fi
    if [ -z "${BWS_SERVER_URL:-}" ] && [ -r "$BWS_SERVER_URL_FILE" ]; then
      BWS_SERVER_URL="$(cat "$BWS_SERVER_URL_FILE")"
    fi
    BWS_ACCESS_TOKEN="$(printf '%s' "${BWS_ACCESS_TOKEN:-}" | tr -d '[:space:]')"
    BWS_PROJECT_ID="$(printf '%s' "${BWS_PROJECT_ID:-}" | tr -d '[:space:]')"
    if [ -n "$BWS_ACCESS_TOKEN" ] && [ -n "$BWS_PROJECT_ID" ]; then
      export BWS_ACCESS_TOKEN BWS_PROJECT_ID
      [ -n "${BWS_SERVER_URL:-}" ] && export BWS_SERVER_URL
      log "Looking up '$BWS_KEY_NAME' in bws (project $BWS_PROJECT_ID)…"
      _bws_secrets="$(bws secret list -o json "$BWS_PROJECT_ID" 2>&1)" || {
        warn "bws fetch failed; falling back to key file. Output:"
        printf '%s\n' "$_bws_secrets" >&2
        _bws_secrets=""
      }
      if [ -n "$_bws_secrets" ]; then
        _bws_value="$(printf '%s' "$_bws_secrets" \
          | jq -r --arg k "$BWS_KEY_NAME" \
              '[.[] | select(.key == $k) | .value][0] // empty' 2>/dev/null)"
        if [ -n "$_bws_value" ]; then
          DOKPLOY_API_KEY="$_bws_value"
          DOKPLOY_API_KEY_SOURCE="bws ($BWS_KEY_NAME)"
        else
          warn "bws has no secret named '$BWS_KEY_NAME' — falling back to key file."
        fi
      fi
    fi
  fi
fi

# Step 3: legacy plaintext file (only if still unresolved).
if [ -z "${DOKPLOY_API_KEY:-}" ] && [ -r "$KEY_FILE" ]; then
  DOKPLOY_API_KEY="$(<"$KEY_FILE")"
  DOKPLOY_API_KEY_SOURCE="$KEY_FILE"
fi

DOKPLOY_API_KEY="$(printf '%s' "${DOKPLOY_API_KEY:-}" | tr -d '[:space:]')"
[ -n "$DOKPLOY_API_KEY" ] || die "DOKPLOY_API_KEY could not be resolved.
Tried (in order):
  1. \$DOKPLOY_API_KEY env var
  2. bws (secret '$BWS_KEY_NAME' in project \$BWS_PROJECT_ID)
  3. $KEY_FILE
Either:
  - Add the secret to bws as $BWS_KEY_NAME (recommended), OR
  - export DOKPLOY_API_KEY=<token>, OR
  - Persist a key file:
      mkdir -p $CFG_DIR && printf '%s\n' '<token>' > $KEY_FILE && chmod 600 $KEY_FILE"

log "Auth source: $DOKPLOY_API_KEY_SOURCE"

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
  # Use POSIX awk only — `gawk`-isms (asorti, gensub) break on mawk/busybox.
  awk '
    /^[[:space:]]*#/    { next }
    /^[[:space:]]*$/    { next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
      # Strip leading whitespace, then any whitespace immediately
      # before `=` so `FOO =bar` becomes `FOO=bar` (otherwise the key
      # would be `FOO ` with a trailing space, never matching the
      # Dokploy panel and creating a phantom variable).
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+=/, "=")
      print
      next
    }
  ' "$f"
}

# Stable join of env-var lines, with later values winning duplicate keys.
# Stdin: KEY=VALUE per line. Stdout: KEY=VALUE per line, sorted by key.
#
# Sorting is delegated to `LC_ALL=C sort` so we don't depend on
# `asorti()` (a gawk-only extension; mawk is the default `awk` on
# Ubuntu/Debian and would crash with `function asorti never defined`).
# Sorting `KEY=VALUE` lines by full-line ASCII order is equivalent to
# sorting by key, since `=` is a fixed delimiter.
merge_env_layers() {
  awk -F= '
    {
      key = $1
      sub(/^[^=]*=/, "")
      val[key] = $0
    }
    END {
      for (k in val) print k "=" val[k]
    }
  ' | LC_ALL=C sort
}

# ---- build the merged defaults layer --------------------------------------

DEFAULTS_LINES="$( { parse_env_file "$DEFAULTS_FILE"; parse_env_file "$ENV_DEFAULTS_FILE"; } | merge_env_layers )"
DEFAULTS_KEYS="$(printf '%s\n' "$DEFAULTS_LINES" | awk -F= 'NF>0{print $1}')"
# `grep -c .` always prints a number (including 0 for empty input)
# and exits 1 when zero matches; piping `|| true` keeps the printed
# count and ignores the exit. (Earlier `|| echo 0` would emit "0\n0"
# in the empty case — confusing, fixed.)
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
log "Current env panel: $(printf '%s\n' "$CURRENT_ENV" | grep -c . || true) keys"

# ---- compute the merged env ------------------------------------------------

# Strategy:
#   1. Start from current panel.
#   2. For each key in the defaults layer, replace OR append.
#   3. Preserve everything else verbatim (bws-managed secrets, etc.).

TMP_CURRENT="$(mktemp)"
TMP_BODY="$(mktemp)"
TMP_TAIL="$(mktemp)"
TMP_NEW="$(mktemp)"
trap 'rm -f "$TMP_CURRENT" "$TMP_BODY" "$TMP_TAIL" "$TMP_NEW"' EXIT

printf '%s' "$CURRENT_ENV"  > "$TMP_CURRENT"
printf '\n'               >> "$TMP_CURRENT"  # ensure trailing newline

# POSIX awk only (no asorti) — body lines emit normally; defaults
# that weren't already in the panel are emitted to $TMP_TAIL via
# `print ... > file`, then sorted externally with `LC_ALL=C sort`
# before being concatenated onto the body.
awk -v defaults="$DEFAULTS_LINES" -v tail_file="$TMP_TAIL" '
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
    # Stream unseen defaults to a side-channel file; sorted in shell.
    for (k in def_val) {
      if (!def_seen[k]) print k "=" def_val[k] > tail_file
    }
  }
' "$TMP_CURRENT" > "$TMP_BODY"

# Stitch body + (sorted, deduped) appended new-defaults section.
cp "$TMP_BODY" "$TMP_NEW"
if [ -s "$TMP_TAIL" ]; then
  {
    printf '\n'
    printf '# === added by sync-dokploy-env.sh — values from .env.defaults* ===\n'
    LC_ALL=C sort -u "$TMP_TAIL"
  } >> "$TMP_NEW"
fi

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

log "Pushing merged env to Dokploy ($(printf '%s\n' "$NEW_ENV" | grep -c . || true) keys)…"

# `curl -f` discards the response body on HTTP errors, which
# leaves $RESP empty and makes `die` print no diagnostic. Capture
# body + status code separately so the failure message includes
# Dokploy's actual error text (typically `{"error":"..."}` JSON).
post_dokploy() {
  # $1 = endpoint path, $2 = JSON payload, $3 = label for errors
  local endpoint="$1" body="$2" label="$3"
  local body_file status
  body_file="$(mktemp)"
  status="$(curl -sS -o "$body_file" -w '%{http_code}' \
    -X POST \
    -H "x-api-key: $DOKPLOY_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$DOKPLOY_URL/$endpoint" || echo "000")"
  if [ "$status" = "000" ]; then
    local err; err="$(cat "$body_file")"; rm -f "$body_file"
    die "$label failed (curl error / no HTTP response):
$err"
  fi
  if [ "$status" -ge 400 ]; then
    local err; err="$(cat "$body_file")"; rm -f "$body_file"
    die "$label failed (HTTP $status):
$err"
  fi
  cat "$body_file"
  rm -f "$body_file"
}

RESP="$(post_dokploy "compose.update" "$PAYLOAD" "Dokploy push")"

log "Pushed. Dokploy will pick up the new env on the next deploy."

# ---- redeploy (optional) ---------------------------------------------------

if [ "$REDEPLOY" -eq 1 ]; then
  log "Triggering redeploy…"
  RD_RESP="$(post_dokploy "compose.redeploy" \
    "{\"composeId\":\"$COMPOSE_ID\"}" "Redeploy")"
  log "Redeploy queued. Watch Dokploy compose logs for completion."
fi

log "Done."
