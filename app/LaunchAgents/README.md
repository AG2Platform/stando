# LaunchAgent templates

These `com.sutando.*.plist.template` files become per-user launchd agents
when the Sutando `.app` bundle installs them into `~/Library/LaunchAgents/`.

The Swift launcher reads each template, substitutes the placeholders below,
writes the result to `~/Library/LaunchAgents/com.sutando.<service>.plist`, and
runs `launchctl load` on it.

For the dev workflow (`bash src/startup.sh`), these templates are unused —
services are launched inline by the shell script. See `DISTRIBUTION.md`
Phase 0.5.

## Placeholders

| Placeholder | Resolved by the launcher to |
|---|---|
| `{{REPO_DIR}}` | `Bundle.main.resourcePath + "/repo"` (the bundled `src/` + `skills/` tree) |
| `{{NODE_BIN}}` | `Bundle.main.resourcePath + "/runtime/bin/node"` |
| `{{NPX_BIN}}` | `Bundle.main.resourcePath + "/runtime/bin/npx"` |
| `{{TSX_BIN}}` | `Bundle.main.resourcePath + "/runtime/bin/tsx"` |
| `{{PYTHON_BIN}}` | `Bundle.main.resourcePath + "/runtime/bin/python3"` |
| `{{SUTANDO_HOME}}` | `~/Library/Application Support/Sutando` |
| `{{LOG_DIR}}` | `{{SUTANDO_HOME}}/logs` |

## Services

| Plist | Port | Required |
|---|---|---|
| `com.sutando.voice-agent` | 9900 | yes |
| `com.sutando.web-client` | 8080 | yes |
| `com.sutando.dashboard` | 7844 | yes |
| `com.sutando.agent-api` | 7843 | yes |
| `com.sutando.screen-capture` | 7845 | yes |
| `com.sutando.credential-proxy` | 7846 | yes (for Claude quota visibility) |
| `com.sutando.phone-conversation` | 3100 | optional (paid tier) |
