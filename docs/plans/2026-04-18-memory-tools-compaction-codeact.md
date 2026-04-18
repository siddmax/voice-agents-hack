# 2026-04-18 — Memory tool surface + conversation compaction + CodeAct analysis

## One-line summary

Replace Syndai's flat `memory.md` with Anthropic's 6-command Memory tool surface over a PARA-flavoured hierarchical markdown tree, add conversation compaction at 50% of a 16K working window, and produce a written CodeAct-vs-JSON analysis on Gemma 4 E4B.

## Why

- The flat memory file is the single biggest gap between Syndai and the architectural brief. At ≥2–3 KB it already truncates-from-middle in the prompt assembler, and we have no way to write *into* it from the agent — only session-end appends.
- Without compaction, long conversations will blow out the 128K advertised window and, per the brief's "context rot at 4B is worse inside the nominal window," reliability will degrade well before 128K. We need an honest 16K working budget with proactive trimming.
- CodeAct is a legitimately different action space that the user keeps asking about. We should *decide* with numbers, not punt again.

## Scope

**In:**
- 6 memory tools exposed through the agent's `ToolRegistry`: `memory_view`, `memory_create`, `memory_append`, `memory_str_replace`, `memory_delete`, `memory_search`.
- Dart-side invariants for every write: path must resolve under `memory/`, reject `..` and absolute paths, slug normalization (lowercase, kebab-case, ASCII), atomic writes via `.tmp` + rename, secret-scan regex pre-write (bearer/`sk-`/PEM/AWS), per-file 50 KB cap.
- Directory bootstrap on first run: `memory/INDEX.md` (auto-maintained by Dart on every create/delete), `memory/AGENT.md` (read-only, app-shipped), `memory/identity/user.md`, `memory/preferences/general.md`, `memory/inbox/`.
- Prompt assembler change: inject `INDEX.md` + `AGENT.md` + `identity/user.md` + `preferences/general.md` every turn (not the full vault); agent calls `memory_view` to pull specific files.
- Compaction: when serialized working messages exceed 8K tokens (50% of 16K), summarize the oldest half into one assistant message and drop the originals. Use Cactus itself via `completeText` with a short summarize prompt. Preserve tool-result handles; never compact the active TODO block or the current system prompt.
- Token counter utility (rough char/4 proxy; adequate for decisions).
- Migration path: if a pre-existing flat `memory.md` is found in app documents, move it to `memory/Notes.md` on first launch. Idempotent.

**Out (defer to v2):**
- Reflection scheduler, importance-score write triggers, Auto Dream consolidation.
- Per-directory `INDEX.md` (only root `INDEX.md` in v1).
- Vector search / ripgrep FFI. Use pure-Dart substring search.
- CodeAct *implementation*. This plan produces the analysis; whether to build follows.

## Priority-zero honesty checks (carry forward from prior review)

- **GBNF still not exposed in the Cactus C FFI.** Adding 6 more tools increases JSON retry surface. Measure retry rate on a representative vault before claiming reliability improved.
- **Gemma 4 E4B degrades past ~turn 11** (Lane A's 20-step eval). 6 memory tools + MCP tools + 4 core tools = 10–20 tools in the schema list. Schema bloat hurts tool-name selection accuracy. Keep descriptions tight.
- **Cactus `set_tool_constraints` FFI wrapping is the real fix.** This plan explicitly does not take that on; a separate PR against upstream `cactus-compute/cactus` does.

## CodeAct research track (parallel, document-only)

Produce `docs/codeact-analysis.md` answering:

1. Does CodeAct outperform JSON tool calls on models smaller than ~13B? Cite any published eval (BFCL, CodeActAgent paper, arXiv).
2. What would it cost in this codebase specifically? (`serious_python` bundle size, sandbox story, tool schema vs raw-exec surface.)
3. What does the failure mode look like at Gemma 4 E4B's measured ~11-turn ceiling when the action space is arbitrary Python?
4. Decision: **build / don't build / build behind a feature flag with a measured eval first**. Commit to one.

Explicitly reference (a) the leaked Claude Code system prompt patterns the user shared earlier, (b) Anthropic's public Memory Tool docs, and (c) at least one third-party Claude Code reimplementation on GitHub. Flag anything unofficial honestly.

## File structure

```
app/lib/agent/
  memory.dart              # REWRITE — was flat; becomes MemoryVault over a dir
  memory_tools.dart        # NEW — registers the 6 tools + invariants
  compaction.dart          # NEW — token counter + summarize pass
  prompt_assembler.dart    # MODIFY — inject root INDEX + AGENT + identity/prefs
  agent_loop.dart          # MODIFY — call compaction before plan/execute
  real_agent_factory.dart  # MODIFY — use new Memory constructor

app/assets/memory_bootstrap/
  AGENT.md                 # read-only, ships with the app
  INDEX.md                 # seed; Dart rewrites as files change
  identity/user.md
  preferences/general.md

app/test/
  memory_vault_test.dart
  memory_tools_test.dart
  compaction_test.dart

docs/
  codeact-analysis.md      # NEW — research output
```

## Tasks (TDD, bite-sized, in order per track; tracks run in parallel)

### Track 1 — Memory vault + tools

- [ ] T1.1 `MemoryVault` class with `root` directory, path validation helper `_resolveSafe(String)`, slug normalization.
- [ ] T1.2 Test: `_resolveSafe` rejects `..`, absolute paths, null bytes, paths escaping `root`.
- [ ] T1.3 `memory_view(path, view_range?)` tool + test: returns file contents, honors optional `[start, end]` line range, errors cleanly on missing file / directory paths.
- [ ] T1.4 `memory_create(path, content)` + atomic write (`.tmp` + rename) + test: creates parent dirs, fails on existing file.
- [ ] T1.5 `memory_append(path, content)` + test: appends with newline, creates file if missing.
- [ ] T1.6 `memory_str_replace(path, old_str, new_str)` + test: errors if `old_str` not found or not unique.
- [ ] T1.7 `memory_delete(path)` + test: refuses to delete dirs, refuses `AGENT.md`.
- [ ] T1.8 `memory_search(query, path?)` + test: case-insensitive substring, returns list of `{path, line_number, preview}`.
- [ ] T1.9 Secret-scan regex pre-write: reject if content matches `sk-[A-Za-z0-9]{16,}`, `Bearer [A-Za-z0-9_.-]{20,}`, `-----BEGIN (RSA |EC |)PRIVATE KEY-----`, `AKIA[0-9A-Z]{16}`. Tests cover all four.
- [ ] T1.10 Per-file 50 KB cap on create/append/str_replace. Test: reject with clear error.
- [ ] T1.11 Root `INDEX.md` auto-maintained: one line per top-level file/dir, rewritten on every mutation. Test.
- [ ] T1.12 Bootstrap on first launch: copy `assets/memory_bootstrap/` into app documents `memory/` if absent. Requires adding the asset dir to `pubspec.yaml` under `flutter: assets:`. Use `rootBundle.loadString` to read each bootstrap file. Test with a temp dir.
- [ ] T1.13 Migration: if legacy `memory.md` exists at docs root, move to `memory/Notes.md`. Idempotent. Test.
- [ ] T1.14 Wire all 6 tools into `AgentLoop` via `_registerCoreTools`. Test: loop run that views + appends + verifies via view again.

### Track 2 — Compaction

- [ ] T2.1 `TokenCounter.estimate(String) → int` using chars/4. Test with known strings.
- [ ] T2.2 `MessageListCompactor` with threshold 8000 tokens, target 4000. Test: under threshold → noop; over → returns new list.
- [ ] T2.3 Summarize call: send the oldest-half slice as a user message to `CactusEngine.completeText` with system "summarize this conversation in ≤300 tokens, preserve all tool handles and decisions." Test against `FakeCactusEngine`.
- [ ] T2.4 Preserve tool-result handles (`tr_NNNN`) by regex-extracting from the slice and appending "Handles still valid: …" to the summary. Test.
- [ ] T2.5 Never compact: (a) system message, (b) last 3 messages, (c) messages newer than the latest `write_todos`. Test each guard.
- [ ] T2.6 `AgentLoop.run` calls compactor before each plan and each execute step. Integration test with `FakeCactusEngine` showing compaction fires at threshold and conversation stays under budget for 20 simulated turns.

### Track 3 — CodeAct analysis (document-only)

- [ ] T3.1 Survey published results: CodeActAgent paper (arXiv 2402.01030), BFCL leaderboard CodeAct vs JSON, any Gemma-family CodeAct runs.
- [ ] T3.2 Survey implementation cost: `serious_python` (or `python_ffi`) package status, bundle size, sandbox story, iOS App Store viability.
- [ ] T3.3 Map to our measured Gemma 4 E4B ceiling: at ~11 reliable JSON calls, what is the expected Python-generation reliability? Honest estimate, flag uncertainty.
- [ ] T3.4 Reference the Claude Code reimplementation repos the user linked and Anthropic's Memory Tool docs; cite specific patterns worth stealing.
- [ ] T3.5 Write `docs/codeact-analysis.md` with a bold one-word verdict (BUILD / DON'T / FLAG) and 3 bullet justification.

## Test plan summary

- Unit: per tool method, per compaction guard, secret-scan regex, path validation.
- Integration: `FakeCactusEngine`-driven `AgentLoop` runs covering (a) view/create/append chain, (b) compaction firing at threshold, (c) secret-scan rejection on a poisoned write.
- Manual: one `flutter run -d macos --dart-define=SYNDAI_GEMMA4_PATH=...` session that does a multi-turn conversation long enough to trip compaction, plus a memory-write + memory-view round trip.

## Risk register

1. Cactus summarize calls in the compactor are themselves subject to the ~11-turn reliability ceiling. If a user stays in one session long enough to need compaction *and* has already burned turns, the summarize call may itself fail. Mitigate: fall back to a fixed "elided N messages" placeholder if `completeText` throws.
2. Pure-Dart substring search on a large vault (100+ files) on an older iPhone could hit ~500 ms. We're shipping macOS first so acceptable, but note it.
3. Any secret in existing real memory content will refuse to save. Ship with a bypass flag `allowSecrets: true` for the migration step only.
4. Adding 6 tools to the registry grows the tool schema list. Keep each tool description under 25 words.

## Parallelization

Three worktrees, three branches:

| Branch | Worktree | Owner | Depends on |
|---|---|---|---|
| `feat/memory-tools` | `voice-agents-hack-mem/` | Track 1 | — |
| `feat/compaction` | `voice-agents-hack-compact/` | Track 2 | — |
| `feat/codeact-analysis` | `voice-agents-hack-codeact/` | Track 3 | — |

Tracks 1 and 2 share `agent_loop.dart` and `prompt_assembler.dart` — expect merge conflict, resolve by hand. Track 3 only writes to `docs/`.

Merge order: 1 → 2 → 3. 2 needs 1's `MemoryVault` available under the assembler's injected files.

## Exit criteria

- Every checkbox above checked.
- `flutter analyze` clean (upstream `cactus.dart` warnings aside).
- `flutter test` green with all new tests passing.
- `flutter build macos --debug` succeeds.
- `docs/codeact-analysis.md` written with explicit verdict.
- Commit history tells a story; no squash-of-everything.
