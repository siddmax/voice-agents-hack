# 2026-04-18 — Jarvis pivot: one-tap UI, first-launch downloader, OS floor bumps

## One-line summary

Replace Syndai's tabbed shell with a single Jarvis-style screen (one tap → voice in → live activity feed → voice out), add a first-launch model downloader (E2B or E4B per detected RAM), bump iOS minimum to 26.0 and Android minSdk to 36 (Android 16).

## Why

- The 3-tab UI (Chat / Tasks / Settings) is 3× more interaction than the user wants for a voice-first demo.
- Shipping the model in the app bundle is impossible (E2B is ~1.5 GB, E4B ~2.5 GB — over App Store and Play limits).
- Floor-OS bumps eliminate compatibility code paths and let us assume modern APIs (iOS 26's `LiveActivity` + Android 16's `richText` etc).

## Scope

### Track J — Jarvis UI

**In:**
- `app/lib/ui/jarvis_screen.dart` — single screen; replaces Chat / Tasks / Settings tabs.
  - Hero: an animated, breathing orb (`AnimatedContainer` + a few `Tween`s, no shader complexity). Three states:
    - **Idle** — slow breathing, neutral color.
    - **Listening** — pulse synced to audio amplitude (use `speech_to_text`'s `onSoundLevelChange`).
    - **Thinking/Speaking** — faster pulse, accent color.
  - One large tap-target covering most of the screen: tap to start listening (toggle, not press-and-hold — friendlier on mobile). Tap again to interrupt + send.
  - Bottom third: a vertical scrolling activity feed of the agent's current run:
    - Streaming token output (live, monospace optional).
    - Tool-call chips: "→ memory_view", "→ search_issues" — grey while running, green/red when done.
    - Current TODO (the active in-progress one, big and bold).
    - Compaction events ("[compacted: 12 messages]").
    - Memory writes ("→ wrote identity/user.md").
  - No bottom nav. No tabs. Settings is a single gear icon top-right that opens a modal sheet (MCP servers + model status + debug info).
- `app/lib/ui/jarvis_orb.dart` — the breathing orb widget.
- `app/lib/ui/activity_feed.dart` — feed renderer over `AgentEvent` stream.
- `app/lib/ui/settings_sheet.dart` — replaces `settings_screen.dart`'s standalone screen with a bottom sheet. Same `McpServerStore` content; smaller, modal.
- Delete `app/lib/ui/chat_screen.dart`, `app/lib/ui/task_ledger.dart`, `app/lib/ui/settings_screen.dart`.
- Update `app/lib/main.dart` to remove the `_HomeShell` tab scaffold; route directly to either `ModelDownloadScreen` or `JarvisScreen`.
- Tests: `jarvis_screen_test.dart` boots the screen with a fake agent, taps the orb, verifies STT-toggle + activity-feed render.

**Out:**
- Custom shader animations (over-engineering for v1).
- Voice activity detection (use the toggle pattern instead).
- Multiple conversations / history (single live session view).

### Track D — Model downloader

**In:**
- `app/lib/cactus/model_downloader.dart`:
  - `class ModelDownloader` with `Stream<DownloadEvent> download({required ModelTier tier, required Directory destination})`.
  - `DownloadEvent` sealed class: `Progress(bytes, total)`, `Verifying`, `Done(modelPath)`, `Failed(reason)`.
  - Uses `package:http`'s streaming + `Range:` for resumable. No external pub package.
  - Source: HuggingFace `Cactus-Compute/gemma-4-E{2,4}B-it` resolve URLs at INT4 precision. The model is a directory of files (~80–2000 small files plus weights). Download a manifest first (`models.json` from the cactus repo OR a single tarball if available).
  - **Decision point:** check whether HuggingFace Cactus-Compute exposes a single `.zip` per model (the `cactus download` Python CLI grabs `gemma-4-e4b-it-int4-apple.zip` per Lane A's earlier work). If yes, fetch one zip + extract via `package:archive`. That's MUCH simpler than per-file downloads. Use this path.
  - Verify: SHA-256 of the downloaded zip against a known-good hash (hardcode for v1; in v2 fetch from a manifest).
  - Atomic: download to `<destination>/.tmp-<tier>.zip`, extract to `<destination>/.tmp-<tier>/`, rename to `<destination>/gemma-4-<tier>-it/` only on success.
- `app/lib/ui/model_download_screen.dart`:
  - Shown on first launch when no model is present.
  - Detects tier, displays "Downloading Gemma 4 E2B (~1.5 GB)" with a progress bar + cancel.
  - Shows estimated time + bytes/sec.
  - On done → push `JarvisScreen`.
  - On failure → retry button + error string.
- `main.dart` pre-routing:
  - Determine expected model path from tier.
  - If exists → `JarvisScreen` direct.
  - If missing → `ModelDownloadScreen`.
- Tests: `model_downloader_test.dart` mocks the HTTP client, asserts resume-on-partial works, asserts atomic rename on success, asserts `.tmp-` cleanup on failure.

**Out:**
- Wi-Fi-only download enforcement (v2 — need `connectivity_plus`).
- Background-task download (v2 — needs platform channels).
- Model deletion / re-download UI (v2).

### Track O — OS floor bumps

**In:**
- iOS:
  - Bump `IPHONEOS_DEPLOYMENT_TARGET` from 13.0 → 26.0 in `ios/Runner.xcodeproj/project.pbxproj` (every occurrence) and `ios/Podfile` (`platform :ios, '26.0'`).
  - Update `ios/Flutter/AppFrameworkInfo.plist` `MinimumOSVersion` to 26.0.
- Android:
  - Bump `minSdk` from 24 → 36 in `android/app/build.gradle.kts` (or `.gradle`).
  - Bump `compileSdk` and `targetSdk` to 36.
- macOS deployment target stays at 11.0 (lane B set this for `speech_to_text`; no need to bump for Jarvis).
- Document the floor + the device implications in DEMO.md (iPhone 11+, Pixel 5+, etc).
- Verify `flutter build ios --simulator --no-codesign` succeeds.
- Verify `flutter build apk --debug` succeeds.
- Resolve the leftover `pod install` warning about base config not being set (need to add `#include "../Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig"` to `ios/Flutter/Debug.xcconfig` and equivalents).

**Out:**
- Splash screen redesign for iOS 26 (defer).
- Android 16 edge-to-edge mandatory mode handling (need to verify; if the floor bump triggers it, fix; otherwise defer).

## Tasks (TDD where reasonable; UI tracks lean on widget tests)

### Track J

- [ ] J.1 `JarvisOrb` widget with 3 states + amplitude input. Widget test: state changes drive scale tween.
- [ ] J.2 `ActivityFeed` widget consuming a `Stream<AgentEvent>`. Widget test: sequence of events renders in order, tool calls flip from grey to green.
- [ ] J.3 `SettingsSheet` modal (port content from `settings_screen.dart`, drop the screen).
- [ ] J.4 `JarvisScreen` ties it all together: tap-to-toggle STT, on transcribed text call `chat.send(text)`, render the resulting event stream into the feed, speak the final summary via `flutter_tts` if voice-output is on.
- [ ] J.5 Delete `chat_screen.dart`, `task_ledger.dart`, `settings_screen.dart`. Update imports in `main.dart`.
- [ ] J.6 Widget test: `jarvis_screen_test.dart` boots screen with fake agent + fake STT; tap orb, verify `chat.send` called, verify tool-call chip appears.

### Track D

- [ ] D.1 Inspect `cactus/python/src/cli.py` to confirm the per-model zip URL pattern at HuggingFace. Hard-code the two URLs (E2B + E4B INT4 Apple/Android variants).
- [ ] D.2 `ModelDownloader.download` with streaming + Range resumption + SHA-256 verify + atomic rename. Test with a stubbed `http.Client` that simulates partial then complete.
- [ ] D.3 `ModelDownloadScreen` with progress bar, ETA, cancel. Shows tier name + size estimate.
- [ ] D.4 `main.dart` pre-routing: model-present check → `JarvisScreen`, else → `ModelDownloadScreen`.
- [ ] D.5 Tests: download success, download fail-then-retry, partial-then-resume.

### Track O

- [ ] O.1 Bump iOS deployment target to 26.0 in pbxproj + Podfile + AppFrameworkInfo.plist.
- [ ] O.2 Bump Android minSdk + compileSdk + targetSdk to 36.
- [ ] O.3 Fix Pods-Runner xcconfig include warning.
- [ ] O.4 `flutter build ios --simulator` green; `flutter build apk --debug` green.
- [ ] O.5 DEMO.md: add the OS floor table and device implications.

## Risk register

1. iOS 26 simulator — the dev machine has iOS 18.4 + iOS 26.2 simulators. Boot the iOS 26.2 sim for testing. Existing iPhone 16 Pro on iOS 18.4 won't run after the bump.
2. HuggingFace zip URL might 404 or change name. Track D.1 checks first; if missing, falls back to per-file download.
3. `package:archive` zip extraction is slow on large files. Acceptable for 1.5–2.5 GB / one-time download. Show "Verifying…" state during extract.
4. Tap-to-toggle vs hold-to-talk — tap-to-toggle is friendlier but means the user must tap twice (once to start, once to send). Acceptable; we can add "tap and hold" as a power-user option later.
5. Android minSdk 36 means the APK won't install on most current devices. User confirmed they want this as a floor.
6. The settings sheet still needs to expose MCP server config — this is the primary B2B configuration surface and cannot be removed.

## Merge order

J → D → O. J restructures `main.dart`, D wraps that restructured `main.dart` in pre-routing, O is mostly platform files with minimal Dart impact.

## Exit criteria

- All checkboxes checked.
- `flutter analyze` clean (cactus.dart upstream lints aside).
- `flutter test` green.
- `flutter build ios --simulator` green.
- `flutter build apk --debug` green.
- `flutter run -d "iPhone 16 Pro"` (or iOS 26 sim) boots to either ModelDownloadScreen or JarvisScreen depending on whether weights exist.
- DEMO.md reflects new floors + new UI flow.
