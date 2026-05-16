# polysim-bootstrap — improvements survey (2026-05-17)

Scope: `bootstrap/install.sh`, `bootstrap/link-configs.sh`, `bootstrap/sync-secrets.sh`,
`bootstrap/sync-dokploy-env.sh`, `configs/polysim/shell-init.sh`. Survey done
alongside the PR that adds `bootstrap/push-bws-key-to-dokploy.sh`.

## P0 (this PR)

Nothing additional — keep this PR small. Only ships the new single-key push
wrapper. Everything below ships as separate PRs.

## P1 (next PR, in order)

### 1. Standalone `bootstrap/dokploy-deploy.sh` wrapper

The operator constantly hand-rolls `curl … compose.deploy` (and `compose.redeploy`,
and `compose.stop` + `compose.deploy` for stuck-deploy recovery). The new
`push-bws-key-to-dokploy.sh --deploy` flag triggers a deploy inline, but the
recovery flow (`stop` + `deploy`) and the "just redeploy after a merge"
flow are still raw curl. Wrap them.

Sketch:

```
bootstrap/dokploy-deploy.sh --env prod                     # → compose.deploy
bootstrap/dokploy-deploy.sh --env staging --redeploy       # → compose.redeploy
bootstrap/dokploy-deploy.sh --env prod --force-restart     # → stop + deploy (wedge recovery)
bootstrap/dokploy-deploy.sh --env prod --wait              # poll deployments[0].status → done
bootstrap/dokploy-deploy.sh --env prod --status            # one-shot read of deployments[0]
```

Reuses the same auth-resolution, compose-id mapping, and `post_dokploy`
helper as the existing scripts. Replaces an entire CLAUDE.md "Stuck deploy"
section with one script call.

### 2. Hoist shared helpers into `bootstrap/lib/dokploy.sh`

Both `sync-dokploy-env.sh` and the new `push-bws-key-to-dokploy.sh` carry
identical copies of:

- `log` / `warn` / `die` colour-prefix helpers
- Auth resolution (env → bws → key file) — ~50 lines duplicated
- Compose-id mapping for prod/staging/staging-api/staging3
- `post_dokploy` curl wrapper

If P1 #1 lands, that's three scripts with the same boilerplate. Sketch:

```bash
# bootstrap/lib/dokploy.sh — sourced by every Dokploy-touching script
# shellcheck shell=bash

dokploy_log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${DOKPLOY_LOG_TAG:-dok}" "$*" >&2; }
dokploy_die()  { ... }
dokploy_resolve_auth() { ... }   # sets DOKPLOY_API_KEY + DOKPLOY_URL
dokploy_resolve_compose_id() { ... }  # $1 = env name → composeId
dokploy_post() { ... }   # endpoint, payload, label
```

Then each script becomes ~30 lines of arg-parsing + the actual logic.
**Trade-off:** sourced libs are less greppable than self-contained scripts;
operator should weigh that vs the maintenance load of keeping the three
copies in sync.

### 3. `set -e` audit in `link-configs.sh`

`link-configs.sh` declares `set -euo pipefail` at the top but the `link()`
function silently `return`s on `[ -e "$src" ] || { warn …; return; }`. If
the warn path fires for one of the required configs (e.g.
`configs/zsh/zshrc` was renamed/moved), the user gets a yellow warning
but the script exits 0. Then `~/.zshrc` is missing and the next shell
session is broken.

Sketch: return non-zero from `link()` on missing source, and have the main
script `|| FAIL_COUNT=$((FAIL_COUNT+1))` then `exit 1` at the end if
non-zero. Keeps the per-file warn behaviour but surfaces the failure.

## P2 (nice-to-have, polish)

- **Documentation drift in compose-id mapping.** `sync-dokploy-env.sh:20`
  says the mapping is from "`dokploy project list` 2026-05-07". Six weeks
  old. Add a script (`bootstrap/refresh-compose-ids.sh`?) that re-fetches
  the mapping via the Dokploy API and prints a diff. Or: pull the mapping
  from `~/.config/polysim/dokploy-compose-map.json` if present, falling
  back to the in-script defaults — operators on different Dokploy hosts
  (e.g. forks) won't need to patch the script.

- **`install.sh` runs `apt-get update` unconditionally** even when every
  package is already installed. Skip the `update` if all `COMMON_PKGS` are
  already on `dpkg -l`. Trims ~10s off re-runs.

- **`install.sh:280` Stripe CLI version detection uses `python3` inline.**
  Replace with `jq -r '.tag_name'` — `jq` is already a hard dep, removes a
  python dependency from the install path. Same for `mcp-grafana:323` and
  the bws version detection (`install.sh:181-186`).

- **`sync-secrets.sh` doesn't `set -E` (ERR trap inheritance).** Not a
  bug today, but if anyone adds a `trap … ERR` for cleanup it'll silently
  not fire inside the `while IFS= read` loops. Cheap insurance.

- **`shell-init.sh` `keychain` invocation eats the prompt.** If a user has
  passphrase-protected keys, `keychain --quiet` runs at shell startup and
  the prompt arrives before the user's prompt is drawn. Adding
  `--noask` matches the "be quiet on minimal systems" intent and only
  loads keys without prompting; users opt back in with a deliberate
  `keychain ~/.ssh/<key>`.

- **`sync-dokploy-env.sh --redeploy` should be `--deploy`** to match the
  new script's vocabulary (and to match the CLAUDE.md note that
  `compose.deploy` is what re-renders the on-host `.env`, while
  `compose.redeploy` does not). Add `--deploy` as the new canonical name
  with `--redeploy` kept as a deprecated alias.

- **Structured logging escape hatch.** All three scripts use raw ANSI-coloured
  stderr. When run from CI or a hook, colours leak into logs. Honour
  `NO_COLOR=1` (the de facto standard, https://no-color.org/).

- **`link-configs.sh` should emit a final summary.** "Linked 9 files, 0
  backups, 0 errors." Currently the user has to count the green log lines
  by eye.

- **`install.sh` summary block always claims success.** Even when packages
  failed to install (line 101 has `|| warn`), the final `Install complete.
  Versions:` block runs unconditionally and the exit code is 0. A user
  doing `./bootstrap/install.sh && ./bootstrap/link-configs.sh && …` will
  cascade past silent failures. Track a global `FAILED=0` and `exit 1` if
  anything warned.

- **bws JSON parsing is repeated in three places.** `sync-secrets.sh`,
  `sync-dokploy-env.sh`, and the new `push-bws-key-to-dokploy.sh` each
  call `bws secret list -o json` + `jq` filtering. If `lib/dokploy.sh`
  lands (P1 #2), add a sibling `lib/bws.sh` with `bws_fetch_secret <key>`
  and `bws_fetch_all_secrets`.

## Open questions for the operator

1. **Naming convention for new wrappers.** Is `bootstrap/push-bws-key-to-dokploy.sh`
   the right pattern, or do you prefer a sub-namespace like
   `bootstrap/dokploy/{deploy,env-push,bws-push}.sh`? The former keeps
   discovery easy via `ls bootstrap/`; the latter scales better past ~6
   scripts.

2. **Should `--deploy` in `push-bws-key-to-dokploy.sh` use `compose.deploy`
   or `compose.redeploy`?** This PR uses `compose.deploy` (the documented
   "re-render the on-host .env" behaviour per CLAUDE.md's 2026-05-14
   note about PR #1199). If the operator wants the legacy redeploy
   semantics in some cases, the script should grow a
   `--deploy-mode {deploy,redeploy}` flag.

3. **bws value quote-stripping default.** This PR defaults `--strip-quotes`
   ON because the 2026-05-17 STRIPE secret was wrapped in literal `"`.
   But if there's any secret in bws whose value LEGITIMATELY starts AND
   ends with `"`, it would be silently corrupted. Two alternative
   defaults: (a) default OFF + require explicit `--strip-quotes`, or
   (b) leave default ON but bws-sweep all keys for the `"…"` pattern
   and rename them once at the source. Worth a one-time grep in bws.

4. **Should `sync-secrets.sh` also strip surrounding quotes from bws
   values?** Today it dumps the raw bws value into `<repo>/.env`. If bws
   wraps a value in `"`, docker-compose-style env files preserve them
   literally — and the local app then parses the secret as `"sk_…"`
   including the quotes. Likely the right fix is to canonicalise once
   in bws and never strip, but worth confirming.

5. **Dokploy `compose.update` race window.** All three Dokploy-writing
   scripts do read-modify-write on `compose.env` with no etag/version
   check. If two scripts run concurrently (or operator + CI), one
   write silently clobbers the other. Likelihood is low (single
   operator, no CI yet) but it's a known footgun — flag now to design
   in advisory locking before we add automation.
