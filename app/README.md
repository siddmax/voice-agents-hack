# Syndai

On-device voice cowork agent. Gemma 4 E4B on Cactus, Flutter UI, MCP tools configured by the user.

## What this is

The B2B pitch: your company already has an MCP server (Linear, Notion, GitHub, your internal REST wrapped as MCP). Paste the URL and a bearer token into Syndai's settings. Every tool on that server lights up as a voice action. Nothing leaves the phone except the tool call itself.

## Module layout

```
lib/
  cactus/   # FFI wrapper + JSON retry + eval harness   (lane A)
  voice/    # speech_to_text + flutter_tts              (lane B)
  ui/       # chat, task ledger, settings               (lane B)
  agent/    # loop, TodoWrite, memory.md                (lane C)
  mcp/      # mcp_client + registry + config store      (lane C)
```

## Three worktrees, three branches

| Branch | Worktree path | Module | Depends on |
|---|---|---|---|
| `feat/cactus-ffi` | `../voice-agents-hack-ffi/app/` | `lib/cactus/` | — |
| `feat/ui-voice` | `../voice-agents-hack-ui/app/` | `lib/voice/`, `lib/ui/` | — |
| `feat/agent-mcp` | `../voice-agents-hack-agent/app/` | `lib/agent/`, `lib/mcp/` | `feat/cactus-ffi` |

Lanes A and B run in parallel from day 1. Lane C gates on A's FFI smoke passing.

## Build prerequisites

1. Cactus built for macOS/iOS: `cd ../../cactus && source ./setup && cactus build --apple` (pin to tag `v1.14`).
2. Gemma 4 E4B weights downloaded: `cactus download google/gemma-4-E4B-it --precision INT4`.
3. Flutter 3.41+, Dart 3.11+.

## Known constraints

- `set_tool_constraints` is **not** exposed through the Cactus C FFI layer today. Lane A uses JSON parse-and-retry instead. If Cactus exposes it later, Lane A swaps the helper out.
- Thinking-mode toggle is not exposed from Dart either. Non-thinking is the Gemma 4 default as of Cactus v1.14, which is what we want for execution-phase reliability anyway.
- iOS/macOS only for v1. No Android.
