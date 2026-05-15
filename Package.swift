// swift-tools-version:5.9
//
// SwiftPM manifest for the Sutando.app launcher (the AppKit menu-bar app
// implemented in `src/Sutando/`).
//
// **Why this exists.** Two things used to compile from `src/Sutando/`:
//   1. `app/build-app.sh` — invokes `swiftc` directly with the source
//      list and produces `app/build/Sutando.app/Contents/MacOS/Sutando`.
//      This is the path that ships.
//   2. A separate Xcode project under `Sutando Mac/` — built an entirely
//      different SwiftUI app with its own UI sidebar, missing most of
//      the production features (cloud auth, hotkeys, task watcher,
//      screen-capture server, LaunchAgent installer, Sparkle, ...).
//
// The two never shared code, so opening "Sutando Mac.xcodeproj" in Xcode
// produced a different app than the one users downloaded. That fork has
// been deleted; this `Package.swift` is the replacement: open the
// workspace in Xcode (`File → Open` on the repo root) and Xcode will
// generate a project from this manifest, building the exact same Swift
// sources that `app/build-app.sh` ships.
//
// **What this does NOT do.** Producing a deployable .app bundle still
// goes through `bash app/build-app.sh` — that script also stages the
// repo source under `Resources/repo`, the bundled Node + tmux runtime
// under `Resources/runtime`, the LaunchAgent templates, the Sparkle
// framework, and re-signs every Mach-O. SwiftPM only compiles the
// launcher binary; it doesn't know about any of that.
//
// **How to use.** From this repo root:
//   - `open Package.swift` (or `File → Open` the folder in Xcode) →
//     edit + build the AppKit launcher in Xcode with full debugger,
//     code completion, and refactoring. Run target produces an unsigned
//     dev binary you can launch from Xcode.
//   - `bash app/build-app.sh` (when you want a real .app bundle) — same
//     sources, full bundling pipeline.

import PackageDescription

let package = Package(
    name: "Sutando",
    platforms: [
        // Matches app/Info.plist LSMinimumSystemVersion=13.0. Bumping
        // this here MUST be paired with a bump in Info.plist or installs
        // on older macOS will silently fail at runtime instead of being
        // refused at install time.
        .macOS(.v13),
    ],
    products: [
        .executable(name: "Sutando", targets: ["Sutando"]),
    ],
    targets: [
        .executableTarget(
            name: "Sutando",
            // Source list mirrors `SWIFT_SOURCES` in app/build-app.sh.
            // Adding a new .swift file? Update both this `sources` array
            // AND the array in build-app.sh — there is no shared source
            // of truth (yet).
            path: "src/Sutando",
            exclude: [
                ".gitignore",
            ],
            sources: [
                "main.swift",
                "LaunchAgentInstaller.swift",
                "ScreenCaptureServer.swift",
                "SparkleUpdater.swift",
                "CloudAuth.swift",
                "CloudClient.swift",
                "EnvFile.swift",
                "FeedbackWindow.swift",
                "Permissions.swift",
                "SettingsWindow.swift",
                "UnifiedMainWindow.swift",
                "Uninstaller.swift",
                "WebWindow.swift",
            ],
            // Cocoa, AppKit, AVFoundation, WebKit, Network, and
            // UserNotifications are all auto-linked when SwiftPM
            // detects the import on the macOS platform. Only Carbon
            // needs an explicit -framework flag because the legacy
            // RegisterEventHotKey C API in main.swift is what pulls
            // it in (no `import Carbon` for the Swift runtime).
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
