# Syndai — running the real thing

## Supported OS versions

- iOS 26.0+ (iPhone 11 and newer)
- Android 16+ (API 36, ~Pixel 6+)
- macOS 11.0+ (developer build only)

If `flutter build apk` fails because your Android SDK doesn't have API 36
platforms installed, run:

```bash
sdkmanager "platforms;android-36" "build-tools;36.0.0"
```

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
export SYNDAI_GEMMA4_E2B_PATH=/Users/sidsharma/CactusHackathon/cactus/weights/gemma-4-e2b-it
export SYNDAI_GEMMA4_E4B_PATH=/Users/sidsharma/CactusHackathon/cactus/weights/gemma-4-e4b-it
```

`CACTUS_DYLIB_PATH` is read at runtime by Dart (`Platform.environment`).
The `SYNDAI_GEMMA4_*_PATH` vars are passed at **compile time** via
`--dart-define` — see below. The app auto-picks E2B vs. E4B based on the
device's detected RAM; see the [Model tier matrix](#model-tier-matrix).

`SYNDAI_GEMMA4_PATH` (singular, legacy) is still accepted as an alias for
the E4B path so existing scripts keep working.

## Run with the real model (macOS)

```bash
flutter run -d macos \
  --dart-define=SYNDAI_GEMMA4_E2B_PATH=$SYNDAI_GEMMA4_E2B_PATH \
  --dart-define=SYNDAI_GEMMA4_E4B_PATH=$SYNDAI_GEMMA4_E4B_PATH
```

To force a specific tier for testing:

```bash
flutter run -d macos \
  --dart-define=SYNDAI_GEMMA4_E2B_PATH=$SYNDAI_GEMMA4_E2B_PATH \
  --dart-define=SYNDAI_GEMMA4_E4B_PATH=$SYNDAI_GEMMA4_E4B_PATH \
  --dart-define=SYNDAI_MODEL_TIER=e2b
```

## Build for iOS (device)

```bash
# From app/
flutter build ios --release \
  --dart-define=SYNDAI_GEMMA4_E2B_PATH=$SYNDAI_GEMMA4_E2B_PATH \
  --dart-define=SYNDAI_GEMMA4_E4B_PATH=$SYNDAI_GEMMA4_E4B_PATH
# Open ios/Runner.xcworkspace in Xcode, sign with your team, run on device.
```

## Build for Android

Cactus for Android must be built first — Syndai expects `libcactus.so` under
`app/android/app/src/main/jniLibs/<abi>/`.

```bash
# 1. Build the Android shared lib.
cd /Users/sidsharma/CactusHackathon/cactus
source ./setup
cactus build --android

# 2. Copy the produced .so into the app's jniLibs dir (arm64-v8a for modern phones).
mkdir -p /Users/sidsharma/CactusHackathon/voice-agents-hack/app/android/app/src/main/jniLibs/arm64-v8a
cp <cactus-android-build-output>/libcactus.so \
   /Users/sidsharma/CactusHackathon/voice-agents-hack/app/android/app/src/main/jniLibs/arm64-v8a/

# 3. Build the APK. Model weights must already be on the device (e.g. via
#    `adb push` into a world-readable location like /data/local/tmp/).
cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app
flutter build apk --release \
  --dart-define=SYNDAI_GEMMA4_E2B_PATH=/data/local/tmp/gemma4-e2b \
  --dart-define=SYNDAI_GEMMA4_E4B_PATH=/data/local/tmp/gemma4-e4b
```

> Note: `flutter build apk --debug` currently links and produces an APK even
> without `libcactus.so` in place; loading the model at runtime will fail with
> a "libcactus.so not found" FFI error, and the app will fall back to the mock
> agent with a snackbar. Ship the `.so` before demoing.

## Model tier matrix

| Device RAM | Tier  | Model                              |
|------------|-------|------------------------------------|
| ≥ 12 GB    | `e4b` | `google/gemma-4-E4B-it` INT4 (~4B) |
| 4–11 GB    | `e2b` | `google/gemma-4-E2B-it` INT4 (~2B) |
| Unknown    | `e2b` | Safer default                      |

Override auto-detection with:

```bash
--dart-define=SYNDAI_MODEL_TIER=e2b   # or e4b
```

Detection uses `device_info_plus`:

- **Android** → `ActivityManager.MemoryInfo.totalMem`
- **iOS**     → `NSProcessInfo.physicalMemory`
- **macOS**   → `sysctl hw.memsize`

If RAM can't be read, the app defaults to E2B.

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

## Memory tools (6, Anthropic-style)

The agent can read and write its own memory. Files live under
`<app_documents>/memory/` and are seeded on first launch from
`app/assets/memory_bootstrap/`:

- `AGENT.md` — read-only, app-shipped operating rules.
- `INDEX.md` — auto-maintained by Dart on every mutation.
- `identity/user.md`, `preferences/general.md` — empty stubs.

The 6 tools the model sees:

- `memory_view(path, view_range?)` — read a file.
- `memory_create(path, content)` — create new file (fails if exists).
- `memory_append(path, content)` — append, create if missing.
- `memory_str_replace(path, old_str, new_str)` — single-occurrence replace.
- `memory_delete(path)` — refuses dirs and `AGENT.md`.
- `memory_search(query, path?)` — case-insensitive substring.

Enforced in Dart (not the prompt): path validation, slug normalization,
atomic writes, 50 KB per-file cap, secret-scan regex blocking 5 patterns
(`sk-…`, `Bearer …`, `PRIVATE KEY`, AWS AKIA, one extra the Track 1 agent
added).

## Compaction

Conversations get summarized when the serialized `_history` crosses 8K
tokens (50% of 16K). The oldest compactable half gets replaced by one
synthetic `assistant` message produced by Cactus itself. Protected:
system message, last 3 messages, anything newer than the most recent
`write_todos`. Tool-result handles (`tr_NNNN`) are extracted and
carried into the synthetic summary. Measured: 2359 → 1195 tokens on
first firing in the integration test.

## Output processor + semantic gate (ported from LocalHost Router)

Every tool-call output passes through an `OutputProcessor` pipeline before the
agent loop ever executes it:

- **Depth-tracking JSON extractor** — pulls the first complete JSON object out
  of trailing prose, code fences, or nested braces.
- **Levenshtein fuzzy tool-name match** (≤ 4 edits) — `plat_music` → `play_music`.
- **Type coercion** — float→int on integer schema fields, `.abs()` on negatives
  where the schema has `minimum: 0`, enum snap via Levenshtein ≤ 3.
- **String arg cleanup** — strip trailing punctuation, leading `the|a|an`,
  surrounding quotes.
- **Schema-generic NLP extraction** — regex pulls `"6 AM"` → `{hour: 6, minute: 0}`,
  `"10 minutes"` → `{minutes: 10}`, `"2 hours"` → `{hours: 2}` from the user
  query when the schema has matching int fields and the model filled garbage.
- **Refusal detection** — phrases like `"I cannot"`, `"I apologize"`, `"which song"`
  short-circuit retries instead of burning them.

Before the tool actually runs, the `SemanticGate` checks whether the model's
selected tool has at least one keyword in the user query. If not AND a different
available tool does, the call is killed and a reminder is injected so the loop
replans. Core tools (`write_todos`, `finish`, etc.) and `memory_*` are exempt.

Patterns adapted from [Rayhanpatel/functiongemma-hackathon](https://github.com/Rayhanpatel/functiongemma-hackathon)
(Cactus × DeepMind Feb 2026 hackathon, 80.9% objective score).

## Tuning knobs

- `AgentLoop(maxSteps: N)` — default 10 (Gemma 4 E4B INT4 degrades
  past ~turn 11 without `set_tool_constraints`).
- `AgentLoop(semanticGate: SemanticGate(yourSignals))` — merge your own
  tool→keyword mappings into the default map.
- `MessageListCompactor(thresholdTokens: N, targetTokens: M)` —
  defaults 8000 / 4000.
- `completeJson(retries: N)` — default 3.
- `--dart-define=SYNDAI_MODEL_TIER=e2b|e4b` — override auto RAM detection.

## Known gaps

- `set_tool_constraints` is in Cactus C++ but not the C FFI. Agent
  relies on JSON parse-and-retry. Reliability ceiling ~11 tool calls.
- iOS build path works but untested on a physical device.
- No TTS model in Cactus yet — voice out uses `AVSpeechSynthesizer`.

## CodeAct decision

We evaluated Python-as-action-space (CodeAct). Verdict: **don't build**.
See `docs/codeact-analysis.md`. Short version: CodeAct's published gains
are on 7B+ fine-tuned models; `serious_python` ships unsandboxed CPython;
widening the output grammar on a 4B model that already drifts past turn
11 predicts worse reliability, not better.
