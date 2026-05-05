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

For the internal release (Phase 1) the .app does **not** bundle the
runtime — it relies on the user already having these installed via
Homebrew or equivalent:

- **Node.js 22+** (`brew install node`)
- **Python 3.10+** (system `/usr/bin/python3` on macOS 15 works, or
  `brew install python@3.11`)
- **fswatch** (`brew install fswatch`)
- **claude** (Claude Code CLI — install per
  https://docs.anthropic.com/en/docs/claude-code/getting-started)
- **ffmpeg** (optional, for screen-record / video skills:
  `brew install ffmpeg`)

`LaunchAgentInstaller.placeholders()` (in
`src/Sutando/LaunchAgentInstaller.swift`) falls back to common system
paths (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`) when the
bundled runtime is absent, so the .app works as soon as the user has
those tools on their PATH.

Phase 1.5-full (post-internal release) replaces the Homebrew dependency
with statically-linked Node from the official tarball + a bundled
fswatch — at which point the .app becomes single-step-installable on a
fresh Mac.

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
