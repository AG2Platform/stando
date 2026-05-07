# app/

The macOS `.app` bundle layer for Sutando.

```
app/
├── Info.plist                  # bundle metadata, TCC usage descriptions
├── Sutando.entitlements        # hardened-runtime entitlements
├── LaunchAgents/               # *.plist.template files for launchd
├── build-app.sh                # builds Sutando.app
├── build/                      # output (gitignored)
└── README.md                   # this file
```

## Building

```bash
bash app/build-app.sh
# → app/build/Sutando.app
```

The build script:
1. Compiles `src/Sutando/main.swift` + `src/Sutando/LaunchAgentInstaller.swift`
   into the bundle's `Contents/MacOS/Sutando` binary.
2. Copies `Info.plist`, the `LaunchAgents/*.plist.template` files, and an
   icon (or PNG fallback) into the bundle.
3. Stages `src/`, `skills/`, `package.json`, `package-lock.json`,
   `tsconfig.json`, `CLAUDE.md`, `assets/`, and `node_modules/` into
   `Contents/Resources/repo/`.
4. Ad-hoc signs (`codesign -s -`). Real Developer ID signing + notarization
   land in Phase 2.

## Prerequisites on the target Mac

For internal + public release the .app bundles its runtime. The only
thing the user has to install separately is Claude Code itself (the
`claude` CLI), since Anthropic's terms don't allow redistributing it.

- **claude** (Claude Code CLI — install per
  https://docs.anthropic.com/en/docs/claude-code/getting-started, then
  run `claude auth login` once)

Bundled inside `Sutando.app/Contents/Resources/runtime/`:

- **node** (static Node 22 from the official macOS tarball)
- **tmux** (Homebrew tmux + libevent/libncurses dylibs, rpaths
  rewritten to `@executable_path/../lib`)

Bundled inside `Sutando.app/Contents/Resources/repo/node_modules/`:

- **tsx**, **chokidar**, etc. — every npm dep the services need.

System-provided (always available on macOS 15+):

- **python3** (`/usr/bin/python3`)

`LaunchAgentInstaller.placeholders()` (in
`src/Sutando/LaunchAgentInstaller.swift`) prefers the bundled runtime
and falls back to `/opt/homebrew/bin` / `/usr/local/bin` for the dev
workflow (where the .app is built straight from the repo and the
bundled runtime hasn't been staged).

Optional Homebrew installs (only matter if you use the matching skill):
ffmpeg for screen-record + video skills.

## Running

```bash
open app/build/Sutando.app
```

First-launch checklist:
1. Grant TCC permissions (Screen Recording, Accessibility, Microphone)
   when macOS prompts.
2. Click the menu-bar **S** icon → **Install Background Services…** to
   render the LaunchAgent plists into `~/Library/LaunchAgents/` and
   bootstrap them. Services start automatically on login thereafter.

## Uninstalling

```bash
# From the menu bar: Sutando → Uninstall Background Services
# Or manually:
for label in com.sutando.voice-agent com.sutando.web-client com.sutando.dashboard \
             com.sutando.agent-api com.sutando.screen-capture com.sutando.credential-proxy \
             com.sutando.phone-conversation; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
rm -rf /Applications/Sutando.app
```

State in `~/Library/Application Support/Sutando/` is preserved (delete
manually if you want a clean slate).
