# 2026-04-18 — Output processor + semantic gate + mobile/model tiering

Second pass. Three tracks, parallel.

## One-line summary

Port LocalHost Router's output-cleanup pipeline (fuzzy name match, type coercion, string cleanup, NLP arg extraction, refusal detection, depth-tracking JSON parser) and semantic validation gate into Syndai's Dart path, and add Android build support with automatic model tiering (E2B on 8GB+ RAM, E4B on 12GB+ RAM).

## Why

- **Output processor (A)** is the single biggest JSON reliability win available without Cactus upstream changes. Port is pattern-transfer, not code-transfer.
- **Semantic gate (B)** stops wrong-tool hallucinations before they fire MCP side-effects — a safety issue for the B2B story.
- **Mobile + tiering (M)** is required for a device demo. Hackathon judges want a phone, not a Mac. Also: E2B on smaller phones preserves "works everywhere" story.

## Scope

### Track A — Output processor

**In:**
- `app/lib/agent/output_processor.dart`:
  - `int levenshtein(a, b)` — iterative two-row DP.
  - `Map<String, dynamic>? extractJsonObject(String raw)` — depth-tracking brace parser, handles fenced blocks, returns first complete JSON object.
  - `List<Map<String, dynamic>> fuzzyMatchNames(calls, tools, {maxDistance = 4})`.
  - `List<Map<String, dynamic>> coerceTypes(calls, tools)` — float→int on integer-typed fields, `abs()` negatives if schema disallows negatives, enum snap via Levenshtein ≤ 3.
  - `List<Map<String, dynamic>> cleanStringArgs(calls)` — strip trailing `.,!?`, leading `the /a /an `, surrounding quotes.
  - `List<Map<String, dynamic>> extractArgsFromQuery(calls, query)` — regex for `"H[:MM] AM|PM"` → `{hour, minute}`, `"N minute(s)"` → `{minutes:N}`, `"N hour(s)"` → `{hours:N}`. Only overwrites if arg is missing or fails validation.
  - `bool looksLikeRefusal(String response)` — regex `/i cannot|i am sorry|i'm sorry|i apologize|which (song|artist|one)|could you please/i`.
  - `Map<String, dynamic> process(Map<String, dynamic> call, {required List<Map<String, dynamic>> tools, String? query})` — pipeline entry.
- Wire into `CactusEngine.completeJson`: after JSON parse succeeds, if the parsed object looks like a tool call (has `name` + `arguments`) and `tools` was passed, run the pipeline. Also wire the improved `extractJsonObject` to replace `_tryParseJson` for malformed output.
- `app/test/output_processor_test.dart` — per helper, happy + edge cases (misspelled tool name, negative int, "7:30 PM", refusal phrase, malformed JSON with trailing prose).

**Out:**
- Tool-specific heuristics (LocalHost had `set_alarm`, `set_timer`). We ship only generic time/duration extractors because our tool set is MCP-sourced and unpredictable.
- Keyword-to-tool map (that's Track B's job).

### Track B — Semantic gate

**In:**
- `app/lib/agent/semantic_gate.dart`:
  - `class SemanticGate`, constructor takes `Map<String, List<String>> signals` (tool-name → keyword list).
  - `bool check(String toolName, String query, {required List<String> otherTools})` — returns `true` if the selected tool has at least one keyword in `query`, OR if no other tool has stronger signal. Returns `false` only when a *different* tool has a keyword match and the selected tool has zero.
  - Default signal map for common MCP tool names (`send_message`, `create_issue`, `search_issues`, `get_weather`, `play_track`, `set_reminder`). Merges user-supplied extras.
- Wire into `AgentLoop` inside the execute loop, after parsing the next call and before `tools.call`. On fail → inject a `[semantic-gate] wrong tool for query; pick a different tool or call finish.` system message and `continue` (don't execute).
- Record the count of gate triggers in `AgentLoop` state so the UI can surface it.
- `app/test/semantic_gate_test.dart` — covers all default signals.

**Out:**
- Cloud rescue (no cloud path in Scope A).
- Fuzzy signal matching (exact substring is enough).

### Track M — Mobile + model tiering

**In:**
- `flutter create --platforms=android .` on top of the existing app (non-destructive; adds only `android/` dir).
- Android manifest permissions: `INTERNET`, `RECORD_AUDIO`, `READ_CALENDAR`, `WRITE_CALENDAR`, `READ_CONTACTS`, plus Play-safe `<queries>` block for common MCP hosts (empty for now).
- Android `minSdkVersion` 24 (for `mcp_client` HTTP + speech APIs).
- Ship Cactus `libcactus.so` via `cactus/android/build.sh` outputs, placed in `app/android/app/src/main/jniLibs/<abi>/libcactus.so`. Document the build command in DEMO.md; do not commit the binary. Add `jniLibs/*.so` to `.gitignore`.
- Add `device_info_plus: ^11` dependency.
- `app/lib/cactus/model_tier.dart`:
  - `enum ModelTier { e2b, e4b }`.
  - `Future<ModelTier> detectTier()` — uses `device_info_plus` for `totalPhysicalMemory` (iOS → `utsname` + `NSProcessInfo`, Android → `MemoryInfo.totalMem`, macOS → sysctl). Returns `e4b` if ≥ 12 GB, else `e2b`.
  - Override via `--dart-define=SYNDAI_MODEL_TIER=e2b|e4b` for testing. No runtime env vars — all config is compile-time dart-defines for consistency with `SYNDAI_GEMMA4_*_PATH`.
- Modify `main.dart` / `RealAgentFactory`:
  - Accept `SYNDAI_GEMMA4_E2B_PATH` and `SYNDAI_GEMMA4_E4B_PATH` at compile time (keep legacy `SYNDAI_GEMMA4_PATH` as E4B alias for back-compat).
  - At startup: detect tier, pick the matching path, fall back to the other if the preferred path is missing.
- `app/test/model_tier_test.dart` — mocks `device_info_plus` for three cases: 6 GB (e2b), 10 GB (e2b), 16 GB (e4b); verifies env-var override wins.
- DEMO.md: add "Build for iOS" and "Build for Android" sections, model-tier table.

**Out:**
- On-device model download UI (v2). User pre-downloads both model variants.
- Dynamic runtime model switching (v2). Tier is chosen at launch.
- macOS NPU path (already a known gap).

## Tasks (TDD, bite-sized)

### Track A

- [ ] A.1 `levenshtein` + test (empty, one-char, classic "kitten/sitting" = 3).
- [ ] A.2 `extractJsonObject` + test (plain, fenced, trailing prose, nested braces, malformed).
- [ ] A.3 `fuzzyMatchNames` + test (exact match, 2-edit, 5-edit rejected, no-tool-list noop).
- [ ] A.4 `coerceTypes` + test (float→int, negative-clamp, enum snap, no-op for strings).
- [ ] A.5 `cleanStringArgs` + test.
- [ ] A.6 `extractArgsFromQuery` + test (AM/PM, 24h, minutes, hours, no-match noop).
- [ ] A.7 `looksLikeRefusal` + test (each phrase, negative cases).
- [ ] A.8 `process` pipeline + wire into `CactusEngine.completeJson`; test that a single call goes through in one shot.
- [ ] A.9 Replace `_tryParseJson` internals with `extractJsonObject`. Verify all existing tests still pass.

### Track B

- [ ] B.1 `SemanticGate` class + default signal map + test for every default.
- [ ] B.2 `check` returns true when only-selected-tool matches, false when a different tool matches, true when neither matches (benefit of the doubt).
- [ ] B.3 Wire into `AgentLoop` after the `_canonicalKey` step; new branch: if `!gate.check(...)`, inject reminder, skip execution, continue loop. Test with `FakeCactusEngine` scripting a wrong-tool call.
- [ ] B.4 Expose `AgentLoop.gateTriggerCount` for UI debugging.

### Track M

- [ ] M.1 Run `flutter create --platforms=android .` from `app/`. Commit diff.
- [ ] M.2 Patch `android/app/src/main/AndroidManifest.xml` with required permissions + `<queries>` stub.
- [ ] M.3 Set `minSdkVersion 24` in `android/app/build.gradle.kts` (or `.gradle`).
- [ ] M.4 Add `jniLibs/*.so` to `.gitignore` and document the build command in DEMO.md.
- [ ] M.5 Add `device_info_plus` to pubspec.
- [ ] M.6 `ModelTier` + `detectTier` + env-var override + test.
- [ ] M.7 Modify `main.dart` to accept both E2B and E4B paths via `--dart-define`, resolve against tier.
- [ ] M.8 Modify `RealAgentFactory.tryBuild` signature to take `{required String modelPath}` (unchanged) — tier resolution lives in `main.dart`.
- [ ] M.9 Update DEMO.md with: build-for-iOS, build-for-Android, the per-device model matrix, and the new `--dart-define` flags.

## Merge order

A → B → M. A and B touch `AgentLoop` and `CactusEngine` / assembler; expect minor conflict. M touches `main.dart`, pubspec, new `model_tier.dart`, Android platform files — mostly orthogonal.

## Risk register

1. `cactus build --android` may not produce a `.so` we can drop in cleanly; could need upstream tweaks. Flagged in Track M; if blocked >20 min, the agent reports and we ship iOS-only for the demo with a follow-up issue filed.
2. `device_info_plus` `physicalMemory` field availability varies by platform version. Fallback: if detection fails, default to `e2b` (safer).
3. Output processor's regex for refusal phrases will fire false positives on someone literally typing "I cannot make it on Friday." Mitigation: scope refusal check to non-tool-call outputs only (responses where `function_calls` is empty).
4. Semantic gate's default signal map will be wrong for many MCP tools. Mitigation: document that `SemanticGate` accepts user-supplied extras; default map is permissive (only kills on explicit wrong-tool, not on missing keyword).

## Attribution

Output-processor and semantic-gate patterns are adapted from `Rayhanpatel/functiongemma-hackathon` (Cactus × DeepMind Feb 2026 hackathon submission, 80.9% score). Patterns are re-implemented in Dart; commit messages and `docs/` credit the original.

## Exit criteria

- All checkboxes checked.
- `flutter analyze` clean (upstream cactus.dart warnings aside).
- `flutter test` green with all new tests.
- `flutter build macos --debug` green.
- `flutter build ios --debug --no-codesign` green OR documented blocker.
- `flutter build apk --debug` green OR documented blocker.
- DEMO.md has iOS + Android run commands and the model tier matrix.
