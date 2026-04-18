# Bitwarden vault layout

`restore-secrets.sh` looks up items by name. To use the defaults, create the
following items in your Bitwarden vault. Each item should be of type **Login**
with the secret stored in the **password** field.

| Item name (default)            | Field used | Maps to env var          |
| ------------------------------ | ---------- | ------------------------ |
| `polysim/database-url`         | password   | `DATABASE_URL`           |
| `polysim/openai-api-key`       | password   | `OPENAI_API_KEY`         |
| `polysim/anthropic-api-key`    | password   | `ANTHROPIC_API_KEY`      |
| `polysim/github-pat`           | password   | (used for `gh auth`)     |
| `polysim/grafana-api-key`      | password   | `GRAFANA_API_KEY`        |
| `polysim/supabase-access-token`| password   | `SUPABASE_ACCESS_TOKEN`  |
| `polysim/dokploy-api-token`    | password   | `DOKPLOY_API_TOKEN`      |

If your items use different names, override at runtime:

```bash
POLYSIM_BW_DB_URL_ITEM=my-pg-url ./bootstrap/restore-secrets.sh
```

## Getting an API key

1. Web vault → **Account settings** → **Security** → **Keys** → **View API key**
2. Copy `client_id` and `client_secret`. These are the values for
   `BW_CLIENTID` and `BW_CLIENTSECRET`.
3. `BW_PASSWORD` is your vault master password.

The API key auths the CLI without an interactive login — required for
non-interactive runs over SSH.
