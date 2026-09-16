# HeyCast — Plan

A native Swift/AppKit/SwiftUI rewrite of [RustCast](../rustcast), a Raycast-style
launcher for macOS — *Hey* because that's the word that starts everything,
*cast* because you call it out to invoke it. The project replaces the Rust/iced
implementation with a pure-Apple stack so it can lean on the platform directly: AppKit windows,
LaunchServices, Spotlight, Carbon hotkeys, the Accessibility API, haptics,
SMAppService, and more.

## Why native

| RustCast (Rust)                     | HeyCast (native macOS)                                  |
| ----------------------------------- | --------------------------------------------------------- |
| iced UI in a winit window           | AppKit `NSPanel` + SwiftUI content + `NSVisualEffectView` |
| `global-hotkey` crate (event tap)   | Carbon `RegisterEventHotKey` (no permissions needed)      |
| `dlopen`'d `LSCopyAllApplicationURLs` | `NSWorkspace.urlsForApplications(toOpen:)` + dir scan fallback |
| `NSWorkspace` via objc2 bindings    | `NSWorkspace` directly (open/quit/icons)                  |
| `mdfind` subprocess                 | `NSMetadataQuery` (Spotlight API, streamed results)       |
| `evalexpr` crate                    | `NSExpression` expression evaluation                      |
| hand-rolled unit conversion tables  | Foundation `Measurement<Unit…>`                           |
| `arboard` clipboard polling         | `NSPasteboard` changeCount polling                        |
| `rusqlite`                          | system `libsqlite3` via `import SQLite3`                  |
| `tray-icon` crate                   | `NSStatusItem` + `NSMenu`                                 |
| private `MTActuator` IOKit haptics  | `NSHapticFeedbackManager` (public API)                    |
| `SMAppService` via objc2            | `SMAppService.mainApp` directly                           |
| TOML config (`toml` crate)          | JSON config (Codable) in `~/Library/Application Support/HeyCast/` |
| window tiling via AX C functions    | same `AXUIElement` C API (no Swift wrapper exists)        |
| bundled emoji dataset via crate     | generated `emoji.json` (committed, from Unicode data)     |

## Feature parity targets

- Floating borderless launcher panel (550 pt wide, max 5 result rows, dynamic
  height), appears on all Spaces, hides on focus loss / Esc cascade.
- Global hotkeys: toggle (default `ALT+SPACE`), clipboard history
  (default `SUPER+SHIFT+C`), optional per-shell-command hotkeys.
- Main search: fuzzy app search, favorites (♥, pinned top), usage ranking,
  web search (`?` suffix or ≥3 words, configurable engine), URL opening,
  calculator, unit conversion (`5 km to mi`), `>` inline shell, quit apps,
  easter eggs (`randomvar`, `67`, `lemon`, `zombo`, Ferris plushies link).
- Pages: Main, File search, Clipboard history (`cbhist`), Emoji search.
- Clipboard history: text/URL/image, SQLite-backed, paste-on-select, clear.
- Emoji page: 6-wide grid, hover tooltip, Enter/click copies.
- Window tiling: 12 positions (halves/quarters/thirds/maximize) via AX API.
- Settings window (General / Appearance / Commands), config hot-reload (`⌘R`).
- Menu bar status item with menu, `heycast://` URL scheme, start-at-login,
  input-source switching, haptic ticks, calendar events main page.

## Deliberate deviations

- Favorites sort **above** other results (Raycast/Alfred convention) instead of
  below, which is what the original's ranking arithmetic produced.
- Empty query shows core built-ins (settings, emoji, clipboard, files, reload)
  instead of an empty pane — better discoverability.
- No auto-updater (fresh project, no release feed yet).
- Hotkeys are edited in the config JSON; in-app hotkey recording is future work.

## Architecture

```
Sources/HeyCast/
├── Main.swift               # NSApplication bootstrap (accessory app)
├── AppDelegate.swift        # lifecycle, menus, URL scheme
├── Model/
│   ├── LauncherModel.swift  # @MainActor state machine (query/results/pages)
│   ├── Config.swift         # Codable config + defaults + load/save
│   ├── Ranking.swift        # usage counts + favorites persistence
│   └── Theme.swift          # colors/fonts derived from config
├── Search/
│   ├── SearchEngine.swift   # query classifier + pipeline
│   ├── FuzzyMatch.swift     # fzf-style subsequence scorer
│   ├── AppIndex.swift       # installed-app discovery + icons
│   ├── Calculator.swift     # NSExpression eval with input validation
│   ├── UnitConversion.swift # Measurement<Unit…> mapping
│   ├── EmojiIndex.swift     # emoji.json load + search
│   └── FileSearch.swift     # NSMetadataQuery wrapper
├── Services/                # one file per native integration
│   ├── AppLauncher.swift  ClipboardService.swift  ClipboardStore.swift
│   ├── HotKeyManager.swift  HapticsService.swift  InputSourceService.swift
│   ├── LoginItemService.swift  TilingService.swift  ShellRunner.swift
├── UI/
│   ├── PanelController.swift    # NSPanel, vibrancy, sizing, key monitor
│   ├── LauncherView.swift       # SwiftUI search bar + results + footer
│   ├── EmojiGridView.swift  ClipboardPageView.swift
│   ├── SettingsWindow.swift     # General/Appearance/Commands tabs
│   └── StatusItemController.swift
└── Resources/emoji.json

scripts/
├── make_app.sh              # assemble HeyCast.app from `swift build` output
├── make_icon.swift          # draw the app icon, emit .icns
└── gen_emoji.py             # regenerate emoji.json from Unicode data
```

## Milestones (each lands as a git commit)

1. App skeleton: accessory NSApplication, floating panel, global hotkey,
   status item, empty results.
2. App discovery + fuzzy search + launching (LaunchServices/NSWorkspace).
3. Search pipeline: web search, URL, calculator, easter eggs, quit.
4. Clipboard history page (NSPasteboard + SQLite + paste-on-select).
5. Emoji page, unit conversion, settings window, theming (dark/light/system).
6. Window tiling (AX), haptics, shell commands + modes, file search page.
7. App bundle packaging, icon, visual verification pass, polish.

## Verification

`scripts/make_app.sh` builds the release binary and assembles
`build/HeyCast.app`. Launch it, drive it with the desktop-automation tools,
and confirm visually: panel appears centered-top on `⌥Space`, app results with
real icons, calculator/URL/web rows, `cbhist` and emoji pages, settings window,
dynamic window height, hide-on-blur and Esc cascade.
