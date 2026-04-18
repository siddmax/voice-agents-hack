# Syndai — running the real thing

The app has two modes:

- **Mock mode (default)** — no model, fake agent, fake tool calls. Useful for UI dev. Just `flutter run -d macos`.
- **Real mode** — Gemma 4 E4B running locally via Cactus, plus every tool from every MCP server you have configured in settings.

## Prereqs (one-time)

1. **Build Cactus v1.14 for macOS.**
   ```bash
   cd ../../cactus
   git fetch --tags && git checkout v1.14
   source ./setup
   cactus build --python      # builds libcactus.dylib for Dart FFI
   ```
   Result: `/Users/sidsharma/CactusHackathon/cactus/cactus/build/libcactus.dylib`.

2. **Download Gemma 4 E4B INT4 weights** (~8 GB, takes a while).
   ```bash
   cactus download google/gemma-4-E4B-it --precision INT4
   ```
   Result: `/Users/sidsharma/CactusHackathon/cactus/weights/gemma-4-e4b-it/`.

## Every-session env vars

```bash
export CACTUS_DYLIB_PATH=/Users/sidsharma/CactusHackathon/cactus/cactus/build/libcactus.dylib
export SYNDAI_GEMMA4_PATH=/Users/sidsharma/CactusHackathon/cactus/weights/gemma-4-e4b-it
```

`CACTUS_DYLIB_PATH` is read at runtime by Dart (`Platform.environment`).
`SYNDAI_GEMMA4_PATH` is passed at **compile time** via `--dart-define` — see below.

## Run with the real model

```bash
flutter run -d macos --dart-define=SYNDAI_GEMMA4_PATH=$SYNDAI_GEMMA4_PATH
```

First launch blocks for ~30 s while the model loads. If the path is wrong or
the dylib can't be found, the app falls back to mock mode and shows a snackbar
with the reason.

## Adding an MCP server (live, no restart needed for config changes, but the
real agent picks up new servers only on next app launch)

1. Go to the **Settings** tab.
2. Tap the Linear row to edit: paste your bearer token, flip the switch to
   Enabled. (URL defaults to `https://mcp.linear.app/sse`.)
3. Or hit "Add MCP server" and enter any remote MCP endpoint with a token.
4. Restart the app. On next launch, Syndai connects to every enabled server,
   calls `tools/list`, and registers every returned tool.

## Demo flow (2 min)

1. **Voice query**: tap and hold the mic, say "What Linear issues are assigned
   to me this sprint?" Release.
2. Syndai streams back an answer, shows the Linear MCP tool call as a chip,
   flips to a result chip with the issue titles.
3. **Tab to Tasks**: see the auto-planned TODO ledger.
4. **Follow-up**: "Close the top one with a comment that we shipped the fix in
   PR 142." — another MCP tool call, another result, `finish` gets called,
   TTS speaks the summary.

## Tuning knobs

- `AgentLoop(maxSteps: N)` — default 10 (based on Lane A's eval showing Gemma
  4 E4B INT4 degrades past ~turn 11 without `set_tool_constraints`).
- `completeJson(retries: N)` — default 3. JSON parse-and-retry is our
  fallback for the missing tool-call grammar.

## Known gaps

- `set_tool_constraints` is in Cactus C++ but not the C FFI. Agent relies on
  JSON parse-and-retry. Reliability ceiling ~11 sequential tool calls.
- No persistent conversation history across app restarts (memory.md is the
  only persistence).
- No TTS model in Cactus yet — voice out uses platform TTS (AVSpeechSynthesizer).
- iOS build path works but untested on a physical device (no device in the
  kit).
