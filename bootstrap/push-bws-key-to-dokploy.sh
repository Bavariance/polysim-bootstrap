#!/usr/bin/env bash
# push-bws-key-to-dokploy.sh — push a SINGLE bws-managed secret to the
# corresponding Dokploy compose's environment-variables panel, leaving
# every other key untouched.
#
# Why this exists:
#   sync-dokploy-env.sh deliberately only pushes keys present in the
#   <polysim-repo>/.env.defaults* layers, AND defaults to --skip-empty so
#   it never accidentally BLATs a bws-managed secret with an empty
#   placeholder. That's the right policy for the bulk-sync flow — but it
#   means there's no clean way to push ONE secret directly from bws to
#   Dokploy (e.g. you just rotated STRIPE_SUBSCRIPTION_WEBHOOK_SECRET in
#   bws and need that change live in the Dokploy panel + on-host .env).
#
#   This script closes that gap: read one key from bws, replace (or
#   append) the matching line in the Dokploy panel via compose.update,
#   and optionally trigger compose.deploy so the running container's
#   on-host .env picks up the new value.
#
# Layering vs sync-dokploy-env.sh:
#
#   sync-secrets.sh         →  generates a local .env from defaults + bws
#                              (consumed by `docker compose up` locally)
#   sync-dokploy-env.sh     →  pushes .env.defaults* (bulk) to Dokploy
#                              (consumed by Dokploy at deploy time)
#   push-bws-key-to-dokploy →  pushes ONE bws secret to Dokploy (this
#                              file). Used for ad-hoc secret rotation
#                              when running the full sync would be
#                              overkill or push other unintended changes.
#
# Mapping <env> → composeId (must match sync-dokploy-env.sh):
#   prod         → qCKlu4fStE0xLfZRCKUdw   (Production)
#   staging      → nG8qoVvsNNaMyycQ-OVZc   (Staging Frankfurt)
#   staging-api  → D7D0CWyem5CjJi2bTegfZ   (Staging-API US-East)
#   staging3     → 7zxtKuQLxU9Po8GmtMbJh   (Staging3 US-East)
#
# Override the mapping with --compose-id (rare — for new composes).
#
# Usage:
#   push-bws-key-to-dokploy.sh --env prod --key STRIPE_SUBSCRIPTION_WEBHOOK_SECRET
#   push-bws-key-to-dokploy.sh --env staging --key GRAFANA_PG_READER_PASSWORD
#   push-bws-key-to-dokploy.sh --env prod --key X --dry-run
#   push-bws-key-to-dokploy.sh --env prod --key X --deploy
#       → also POST compose.deploy and wait for deployments[0].status
#         to go running → done. Required when you want the on-host .env
#         regenerated immediately (compose.redeploy reuses the cached
#         .env; only compose.deploy re-renders it from stored env).
#   push-bws-key-to-dokploy.sh --env prod --key X --no-strip-quotes
#       → don't strip surrounding "..." from the bws value. Default ON
#         because bws often wraps values in literal double-quotes (the
#         2026-05-17 STRIPE_SUBSCRIPTION_WEBHOOK_SECRET incident).
#
# Quote-stripping default (ON):
#   bws sometimes returns values wrapped in literal " characters (e.g.
#   when a value was pasted into the bws UI with quotes). Pushing the
#   quoted form to Dokploy stores the quotes verbatim and consumers
#   parse e.g. STRIPE_SECRET=\"sk_live_...\" rather than the bare key.
#   Default behaviour: strip ONE leading + ONE trailing " if both are
#   present. Disable with --no-strip-quotes if your secret legitimately
#   has surrounding quotes.
#
# Refused keys (never pushable):
#   Some env-var names are owned by Dokploy itself (APP_NAME,
#   COMPOSE_PROJECT_NAME) — pushing user values for these breaks the
#   compose. The script refuses with a clear error.
#
# Auth resolution (highest precedence first; matches sync-dokploy-env.sh):
#   1. $DOKPLOY_API_KEY env var
#   2. bws secret DOKPLOY_API_KEY (override with --bws-key=NAME)
#   3. ~/.config/polysim/dokploy-api-key (legacy plaintext fallback)
#
# Skip the bws lookup with --no-bws (useful when you want to be sure
# the key file or env var is what's used).
#
# bws lookup for the SECRET being pushed:
#   Always done via the same bws machine-account project that
#   sync-secrets.sh uses ($BWS_PROJECT_ID env or
#   ~/.config/polysim/bws-project-id). The key being pushed lives in
#   the same project as the rest of the polysimulator secrets — there
#   is no per-env project split.
#
# Server URL:
#   - $DOKPLOY_URL env var
#   - ~/.config/polysim/dokploy-url
#   - default: https://hosting.wladefant.de/api

set -euo pipefail

log()  { printf '\033[1;34m[bws-push]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- parse args -----------------------------------------------------------

ENV_NAME=""
KEY_NAME=""
DRY_RUN=0
DEPLOY=0
COMPOSE_ID_OVERRIDE=""
BWS_KEY_NAME="DOKPLOY_API_KEY"
NO_BWS=0
STRIP_QUOTES=1   # default ON — bws frequently wraps values in literal "..."

while [ $# -gt 0 ]; do
  case "$1" in
    --env|-e)         [ $# -ge 2 ] || die "--env requires a value"
                      ENV_NAME="$2"; shift 2 ;;
    --env=*)          ENV_NAME="${1#*=}"; shift ;;
    --key|-k)         [ $# -ge 2 ] || die "--key requires a value"
                      KEY_NAME="$2"; shift 2 ;;
    --key=*)          KEY_NAME="${1#*=}"; shift ;;
    --compose-id)     [ $# -ge 2 ] || die "--compose-id requires a value"
                      COMPOSE_ID_OVERRIDE="$2"; shift 2 ;;
    --compose-id=*)   COMPOSE_ID_OVERRIDE="${1#*=}"; shift ;;
    --bws-key)        [ $# -ge 2 ] || die "--bws-key requires a value"
                      BWS_KEY_NAME="$2"; shift 2 ;;
    --bws-key=*)      BWS_KEY_NAME="${1#*=}"; shift ;;
    --no-bws)         NO_BWS=1; shift ;;
    --strip-quotes)   STRIP_QUOTES=1; shift ;;
    --no-strip-quotes) STRIP_QUOTES=0; shift ;;
    --dry-run|-n)     DRY_RUN=1; shift ;;
    --deploy)         DEPLOY=1; shift ;;
    # --help renders only the leading comment header (lines 2–86 below
    # the shebang) — line 87 is the first executable line (`set -euo
    # pipefail`). Sibling scripts use the same pattern (e.g.
    # sync-dokploy-env.sh:97 → `sed -n '2,63p'`). When extending the
    # header in the future, bump the upper bound to stay in sync.
    # Copilot review on PR #4: prior `2,99p` leaked code into --help.
    -h|--help)        sed -n '2,86p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "Unknown argument: $1 (use --help)" ;;
  esac
done

[ -n "$ENV_NAME" ] || die "--env is required (e.g. --env prod). See --help."
case "$ENV_NAME" in
  ''|*[!a-zA-Z0-9_-]*) die "Invalid --env value: '$ENV_NAME'" ;;
esac

[ -n "$KEY_NAME" ] || die "--key is required (e.g. --key STRIPE_SUBSCRIPTION_WEBHOOK_SECRET). See --help."
# Enforce conventional env-var name syntax to avoid pushing
# whitespace-only or shell-metachar keys into the panel.
case "$KEY_NAME" in
  ''|*[!a-zA-Z0-9_]*|[0-9]*) die "Invalid --key value: '$KEY_NAME' (must match [A-Za-z_][A-Za-z0-9_]*)" ;;
esac

# ---- refuse system-owned keys --------------------------------------------
#
# These names are populated by Dokploy itself. Pushing user values for
# them either gets overwritten on next deploy or breaks the compose
# entirely.
REFUSED_KEYS=" APP_NAME COMPOSE_PROJECT_NAME "
case " $KEY_NAME " in
  *" $KEY_NAME "*)
    if printf '%s' "$REFUSED_KEYS" | grep -q " $KEY_NAME "; then
      die "Key '$KEY_NAME' is Dokploy-managed and must not be pushed manually.
Refused keys: $(printf '%s' "$REFUSED_KEYS" | sed 's/^ //;s/ $//')"
    fi
    ;;
esac

# ---- resolve composeId from env name -------------------------------------

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

# ---- resolve Dokploy auth + URL ------------------------------------------

CFG_DIR="$HOME/.config/polysim"
KEY_FILE="$CFG_DIR/dokploy-api-key"
URL_FILE="$CFG_DIR/dokploy-url"
BWS_TOKEN_FILE="$CFG_DIR/bws-token"
BWS_PROJECT_FILE="$CFG_DIR/bws-project-id"
BWS_SERVER_URL_FILE="$CFG_DIR/bws-server-url"

# Resolution order: env var → bws → legacy file.
DOKPLOY_API_KEY_SOURCE=""
if [ -n "${DOKPLOY_API_KEY:-}" ]; then
  DOKPLOY_API_KEY_SOURCE="env var"
fi

# Hydrate bws env (used both for Dokploy auth lookup AND the actual
# secret fetch below). Done unconditionally — bws auth resolution is
# cheap and we always need bws on the path for the secret push.
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
[ -n "$BWS_ACCESS_TOKEN" ] && export BWS_ACCESS_TOKEN
[ -n "$BWS_PROJECT_ID" ]   && export BWS_PROJECT_ID
[ -n "${BWS_SERVER_URL:-}" ] && export BWS_SERVER_URL

# bws lookup for Dokploy API key (Step 2).
if [ -z "${DOKPLOY_API_KEY:-}" ] && [ "$NO_BWS" -eq 0 ]; then
  if command -v bws >/dev/null 2>&1 && [ -n "$BWS_ACCESS_TOKEN" ] && [ -n "$BWS_PROJECT_ID" ]; then
    log "Looking up Dokploy auth '$BWS_KEY_NAME' in bws (project $BWS_PROJECT_ID)…"
    _bws_secrets_auth="$(bws secret list -o json "$BWS_PROJECT_ID" 2>&1)" || {
      warn "bws fetch failed; falling back to key file. Output:"
      printf '%s\n' "$_bws_secrets_auth" >&2
      _bws_secrets_auth=""
    }
    if [ -n "$_bws_secrets_auth" ]; then
      _bws_value_auth="$(printf '%s' "$_bws_secrets_auth" \
        | jq -r --arg k "$BWS_KEY_NAME" \
            '[.[] | select(.key == $k) | .value][0] // empty' 2>/dev/null)"
      if [ -n "$_bws_value_auth" ]; then
        DOKPLOY_API_KEY="$_bws_value_auth"
        DOKPLOY_API_KEY_SOURCE="bws ($BWS_KEY_NAME)"
      else
        warn "bws has no secret named '$BWS_KEY_NAME' — falling back to key file."
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
command -v bws  >/dev/null 2>&1 || die "bws not installed — run ./bootstrap/install.sh first"

[ -n "${BWS_ACCESS_TOKEN:-}" ] || die "BWS_ACCESS_TOKEN not set and $BWS_TOKEN_FILE not found.
Get a machine-account token from sm.bitwarden.com, then either:
  export BWS_ACCESS_TOKEN=<token>
or persist it:
  mkdir -p $CFG_DIR && printf '%s\n' '<token>' > $BWS_TOKEN_FILE && chmod 600 $BWS_TOKEN_FILE"

[ -n "${BWS_PROJECT_ID:-}" ] || die "BWS_PROJECT_ID not set and $BWS_PROJECT_FILE not found.
Persist it:
  mkdir -p $CFG_DIR && printf '%s\n' '<uuid>' > $BWS_PROJECT_FILE && chmod 600 $BWS_PROJECT_FILE"

# ---- fetch the secret from bws -------------------------------------------

log "Fetching secret '$KEY_NAME' from bws (project $BWS_PROJECT_ID)…"
BWS_SECRETS_JSON="$(bws secret list -o json "$BWS_PROJECT_ID" 2>&1)" \
  || die "bws fetch failed:
$BWS_SECRETS_JSON"

printf '%s' "$BWS_SECRETS_JSON" | jq empty >/dev/null 2>&1 \
  || die "bws returned non-JSON output:
$BWS_SECRETS_JSON"

# Use --arg + [...][0] // empty so that:
#   - exact key match wins
#   - if the key is missing we get empty string (not jq error)
SECRET_VALUE="$(printf '%s' "$BWS_SECRETS_JSON" \
  | jq -r --arg k "$KEY_NAME" \
      '[.[] | select(.key == $k) | .value][0] // empty')"

if [ -z "$SECRET_VALUE" ]; then
  die "bws has no secret named '$KEY_NAME' in project $BWS_PROJECT_ID.
Either:
  - Verify the key name with: bws secret list -o json '$BWS_PROJECT_ID' | jq -r '.[].key' | grep -iF -- '$KEY_NAME'
  - Add it via the bws CLI or the sm.bitwarden.com UI."
fi

# Strip surrounding double-quotes if BOTH leading + trailing are present
# (default ON — bws frequently wraps values in literal "...").
if [ "$STRIP_QUOTES" -eq 1 ]; then
  case "$SECRET_VALUE" in
    \"*\")
      _stripped="${SECRET_VALUE#\"}"
      _stripped="${_stripped%\"}"
      if [ "$_stripped" != "$SECRET_VALUE" ]; then
        log "Stripped surrounding \"...\" from bws value (use --no-strip-quotes to disable)."
        SECRET_VALUE="$_stripped"
      fi
      ;;
  esac
fi

# Newlines in a value would corrupt the Dokploy panel's KEY=VALUE-per-line
# format. Refuse explicitly — multi-line secrets should be routed
# differently (SSH_KEY_* convention, etc).
case "$SECRET_VALUE" in
  *$'\n'*) die "Secret '$KEY_NAME' contains newline(s) — refusing to push to a KEY=VALUE-per-line panel. If this is an SSH key, use the SSH_KEY_*/SSH_PUB_* convention in sync-secrets.sh instead." ;;
esac

SECRET_LEN="${#SECRET_VALUE}"
log "Resolved secret: $KEY_NAME (length=$SECRET_LEN, value REDACTED)"

# ---- fetch current Dokploy compose env -----------------------------------

log "Target compose: $COMPOSE_ID (env=$ENV_NAME)"
log "Dokploy URL:    $DOKPLOY_URL"
log "Fetching current compose env from Dokploy…"
COMPOSE_JSON="$(curl -fsS -H "x-api-key: $DOKPLOY_API_KEY" \
  "$DOKPLOY_URL/compose.one?composeId=$COMPOSE_ID")" \
  || die "Failed to fetch compose.one — check the composeId, API key, and URL."

CURRENT_ENV="$(printf '%s' "$COMPOSE_JSON" | jq -r '.env // ""')"
CURRENT_NAME="$(printf '%s' "$COMPOSE_JSON" | jq -r '.name // .composeId')"
log "Compose name: $CURRENT_NAME"
log "Current env panel: $(printf '%s\n' "$CURRENT_ENV" | grep -c . || true) keys"

# ---- compute the merged env ----------------------------------------------
#
# Walk the current panel line-by-line; if any existing line matches
# `^KEY_NAME=`, replace it; otherwise append. Comments and blank lines
# are preserved verbatim. Exactly ONE entry for $KEY_NAME ends up in
# the output.

TMP_CURRENT="$(mktemp)"
TMP_NEW="$(mktemp)"
trap 'rm -f "$TMP_CURRENT" "$TMP_NEW"' EXIT

printf '%s' "$CURRENT_ENV"  > "$TMP_CURRENT"
printf '\n'               >> "$TMP_CURRENT"  # ensure trailing newline

REPLACED_OLD=""   # the previous value, for diff output (only set if key existed)
ACTION="add"      # default → append; set to "update" if we find an existing line

# Detect whether the key already exists in the panel (informs both the
# action label and the diff output). Use grep -c against an anchored
# pattern so we don't false-match KEY_NAME as a value substring.
EXISTING_COUNT="$(grep -cE "^${KEY_NAME}=" "$TMP_CURRENT" || true)"

if [ "$EXISTING_COUNT" -gt 0 ]; then
  ACTION="update"
  # Capture the previous value (for diff output). awk wins over sed
  # here because the value may contain shell metachars.
  REPLACED_OLD="$(awk -F= -v k="$KEY_NAME" 'NF>=2 && $1==k { sub(/^[^=]*=/, ""); print; exit }' "$TMP_CURRENT")"
fi

# Single-pass awk: replace any existing line for KEY_NAME with the new
# value (keeping only the first occurrence; any duplicates are dropped).
# If no existing line was found, the END block appends one. Other
# lines (comments, blanks, unrelated KEY=VALUE) are preserved verbatim.
#
# CRITICAL — Codex P1 review on PR #4: `awk -v newval="$SECRET_VALUE"`
# interprets backslash escapes in the value (\n, \t, \r, \\, etc.). A
# secret like `whsec_a\nb` would be rewritten to `whsec_a<newline>b`
# before being written to the env blob — silently corrupting the secret
# AND bypassing the earlier newline-rejection guard. The fix: pass the
# secret via the environment (ENVIRON[]), which awk treats as a literal
# byte stream with no escape interpretation. The `key` var is safe
# because env-var-name syntax forbids backslashes.
NEW_VAL_FOR_AWK="$SECRET_VALUE" \
awk -v key="$KEY_NAME" '
  BEGIN { found = 0; newval = ENVIRON["NEW_VAL_FOR_AWK"] }
  {
    line = $0
    eq = index(line, "=")
    if (eq < 2) { print line; next }
    k = substr(line, 1, eq-1)
    if (k == key) {
      if (!found) {
        print key "=" newval
        found = 1
      }
      # silently drop any duplicate lines for the same key
      next
    }
    print line
  }
  END {
    if (!found) print key "=" newval
  }
' "$TMP_CURRENT" > "$TMP_NEW"

# Sanity: ensure exactly one occurrence of the key now exists.
FINAL_COUNT="$(grep -cE "^${KEY_NAME}=" "$TMP_NEW" || true)"
[ "$FINAL_COUNT" -eq 1 ] \
  || die "Internal error: expected 1 occurrence of '$KEY_NAME' in merged env, got $FINAL_COUNT."

# ---- diff output ----------------------------------------------------------

if [ "$ACTION" = "add" ]; then
  log "Action: ADD  $KEY_NAME (new key, length=$SECRET_LEN)"
  [ "$DRY_RUN" -eq 1 ] && printf '  + %s=<REDACTED length=%s>\n' "$KEY_NAME" "$SECRET_LEN" >&2
else
  OLD_LEN="${#REPLACED_OLD}"
  if [ "$REPLACED_OLD" = "$SECRET_VALUE" ]; then
    log "Action: UNCHANGED  $KEY_NAME (existing value matches bws — nothing to push)"
    if [ "$DEPLOY" -eq 0 ]; then
      log "No-op. Re-run with --deploy if you want to force a redeploy anyway."
      exit 0
    fi
  else
    log "Action: UPDATE  $KEY_NAME (old length=$OLD_LEN → new length=$SECRET_LEN)"
    [ "$DRY_RUN" -eq 1 ] && printf '  ~ %s: <REDACTED length=%s> → <REDACTED length=%s>\n' "$KEY_NAME" "$OLD_LEN" "$SECRET_LEN" >&2
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "Dry-run mode — not pushing. Re-run without --dry-run to apply."
  exit 0
fi

# ---- push to Dokploy ------------------------------------------------------

NEW_ENV="$(<"$TMP_NEW")"
PAYLOAD="$(jq -n --arg id "$COMPOSE_ID" --arg env "$NEW_ENV" \
  '{composeId: $id, env: $env}')"

log "Pushing merged env to Dokploy ($(printf '%s\n' "$NEW_ENV" | grep -c . || true) keys)…"

# Capture body + status code separately so curl -f doesn't swallow
# Dokploy's `{"error":"..."}` JSON on failure.
post_dokploy() {
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

log "Pushed. '$KEY_NAME' is now in the Dokploy panel (length=$SECRET_LEN)."

# ---- deploy (optional) ----------------------------------------------------

if [ "$DEPLOY" -eq 1 ]; then
  # compose.deploy (not compose.redeploy) — compose.deploy re-renders
  # the on-host .env file from stored env, which is what we need when
  # we just rotated a secret. compose.redeploy reuses the cached .env.
  # Verified 2026-05-14 (PR #1199 daemon poller flip).
  log "Triggering compose.deploy (re-renders on-host .env from stored env)…"
  # jq -n --arg ensures JSON-correct escaping of the compose-id + title
  # (Copilot review on PR #4: prior string-interpolation would emit
  # invalid JSON if either field contained a `"` or `\` byte). The
  # compose-id is typically alphanumeric+dashes (Dokploy convention),
  # but the title contains user-supplied KEY_NAME which could include
  # any env-var-syntax character — safer to escape via jq.
  DEPLOY_PAYLOAD="$(jq -n \
    --arg id "$COMPOSE_ID" \
    --arg title "push-bws-key-to-dokploy.sh: $KEY_NAME" \
    '{composeId: $id, title: $title}')"
  DEPLOY_RESP="$(post_dokploy "compose.deploy" "$DEPLOY_PAYLOAD" "Deploy")"
  log "Deploy queued. Polling deployments[0].status…"

  # Poll compose.one.deployments[0].status: running → done.
  POLL_INTERVAL=10
  POLL_MAX=60  # 60 * 10s = 10 minutes
  POLL_I=0
  LAST_STATUS=""
  while [ "$POLL_I" -lt "$POLL_MAX" ]; do
    POLL_I=$((POLL_I+1))
    sleep "$POLL_INTERVAL"
    POLL_JSON="$(curl -fsS -H "x-api-key: $DOKPLOY_API_KEY" \
      "$DOKPLOY_URL/compose.one?composeId=$COMPOSE_ID" 2>/dev/null || true)"
    [ -n "$POLL_JSON" ] || { warn "Poll attempt $POLL_I: compose.one returned no body — retrying."; continue; }
    DEPLOY_STATUS="$(printf '%s' "$POLL_JSON" | jq -r '.deployments[0].status // "unknown"')"
    if [ "$DEPLOY_STATUS" != "$LAST_STATUS" ]; then
      log "Poll $POLL_I/$POLL_MAX: deployments[0].status=$DEPLOY_STATUS"
      LAST_STATUS="$DEPLOY_STATUS"
    fi
    case "$DEPLOY_STATUS" in
      done)
        log "Deploy complete. The on-host .env now contains the new $KEY_NAME (length=$SECRET_LEN)."
        log "Verify with: docker exec <container> env | grep '^${KEY_NAME}='"
        exit 0
        ;;
      error)
        die "Deploy failed (deployments[0].status=error). Inspect:
  curl -s -H 'x-api-key: \$DOKPLOY_API_KEY' '$DOKPLOY_URL/compose.one?composeId=$COMPOSE_ID' | jq '.deployments[0]'"
        ;;
    esac
  done

  warn "Deploy did not reach 'done' within $((POLL_INTERVAL*POLL_MAX))s. Last status: $LAST_STATUS.
The deploy is still queued/running — watch Dokploy compose logs for completion."
  exit 1
fi

log "Done. Run with --deploy to also regenerate the on-host .env immediately."
