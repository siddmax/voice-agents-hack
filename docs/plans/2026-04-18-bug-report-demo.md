# 2026-04-18 — Bug report demo plan

## One-line summary

Pivot Syndai's voice-agent shell into a focused bug-reporting demo: the user describes a bug by voice, the app asks for permission to capture the repro, automatically records the reproduction, extracts multimodal evidence, generates an engineer-ready bug report, and clearly confirms successful submission.

## Product story

Users are bad at writing bug reports, but they are good at showing what broke.

The product promise is:

> "Do not write the ticket. Just describe the bug, reproduce it once, and the app sends engineering everything they need."

For the demo, we should optimize for one polished golden path rather than broad feature coverage.

## Demo identity

Working demo name:

- `Drop-Guard`

Demo fiction:

- left screen: a high-pressure ticketing checkout flow
- right screen: an SRE dashboard receiving live telemetry
- bridge: direct issue submission to GitHub Issues plus local/live demo telemetry

This is the pitch version of the product, not the full platform story.
The audience should immediately understand:

- the user is stuck in a high-stakes flow
- the agent captures context without burdening the user
- engineering gets the exact failure signal quickly

## Demo goal

In under 2 minutes, show that the app can:

1. Understand a spoken bug report.
2. Ask for permission before capture starts.
3. Automatically record the reproduction once the user agrees.
4. Turn raw voice + visual + session evidence into a structured report.
5. Confirm that the bug report was successfully submitted.

## Stage setup

### Left screen — simulator

Run the Flutter app as a ticketing checkout experience:

- seat map visible
- high-tension purchase moment
- one seat in Section 102 selected
- add-to-cart action already available

Desired visual cues:

- blue seat dots
- one selected seat turns into a loading spinner that never resolves
- subtle urgency in copy and motion

### Right screen — laptop dashboard

Run a browser-based SRE dashboard with a dark terminal aesthetic:

- black or charcoal background
- neon green, cyan, and red accents
- auto-scrolling telemetry feed
- prominent red error card area
- final synthesized incident card

### Bridge — GitHub Issues

There is no database or back end in the demo flow.

Contract:

- Flutter app assembles the bug report locally
- the final submit action creates a GitHub issue directly
- the laptop dashboard visualizes live capture and analysis for the audience

Submission target:

- a GitHub repository's Issues tab

Recommended issue fields:

- title
- body with transcript, repro steps, expected vs actual, and trace
- labels such as `bug`, `demo`, `seat-lock`
- optional attachment links or placeholders for recording evidence

## The 30-second wow flow

### 1. The trigger — the panic

Action:

- click a blue seat
- it turns into a loading spinner that never ends

Narration:

> "I'm at the checkout for the biggest drop of the year. The UI is hung. Normally, this is where the customer churns and the ticket is lost."

Action:

- tap the Agent FAB
- a Siri-style waveform appears at the bottom of the simulator

### 2. The context — voice intake and consent

Action:

- speak clearly: "The seat map is frozen on Section 102. I've clicked Add to Cart three times and nothing is happening."

System:

- show a native-feeling `CupertinoAlertDialog`
- copy: `Grant Drop-Guard access to System Logs & Screen?`

Action:

- tap `Grant`

### 3. The reveal — the x-ray vision

Visual:

- the moment `Grant` is tapped, the laptop dashboard lights up
- logs begin scrolling in real time

Climax:

- a red error block lands in the dashboard:
  - `[DioError] 409: Conflict - Seat_Lock_Timeout`

Narration:

> "Look at the dashboard. Without me filming my screen or typing a word, the Agent mapped my voice to the exact API failure in the Flutter code. It's synthesizing intent with infrastructure."

### 4. The synthesis — the multimodal ticket

Action:

- tap `Submit` in Flutter

Visual:

- dashboard enters a short "crunching" state
- then renders a structured bug card

Required card content:

- `Transcript`: `Seat map frozen... Section 102.`
- `Trace`: `lib/logic/cart_provider.dart:88`
- `Evidence`: 5-second video loop of the spinner

Optional live reveal:

- the GitHub issue draft or newly created issue appears on the laptop after submit

### 5. The success — the dopamine hit

Action:

- simulator clears into a bold, full-screen green success state

Audio and haptics:

- trigger `HapticFeedback.heavyImpact()`
- play a deep success ping

Narration:

> "Bug submitted directly to GitHub Issues. The fan stays in the flow, and Engineering gets a perfect reproduction case in under 20 seconds."

## Golden path

### Step 1 — Voice intake

The user opens the app and taps the orb.

Example user line:

> "There is a bug in checkout. When I apply a coupon, go back, and return to checkout, the discount disappears."

The app responds with a short acknowledgement and 1 clarifying question at most.

Example app line:

> "I can help report that. When you are ready, I will record your reproduction and collect evidence for engineering."

### Step 2 — Permission and capture handoff

Before recording begins, the app explicitly asks for permission.

Required UX:

- Explain what will be captured.
- Make it clear capture starts automatically after approval.
- Keep the prompt short and confident.

Example app line:

> "To capture the bug, I need permission to record the screen and session activity while you reproduce it. Start capture?"

Buttons:

- `Grant`
- `Not Now`

### Step 3 — Automatic reproduction capture

When the user approves:

- screen capture starts automatically
- narration transcript capture continues
- timestamps are tracked
- session evidence collection begins

The user should not need to manually take screenshots or trigger logging.

The UI should visibly switch into an active capture state:

- red or amber capture indicator
- elapsed time
- short status line such as `Recording reproduction`
- optional sub-status such as `Listening`, `Watching screen`, `Collecting session data`

### Step 4 — Reproduction complete

The user taps a single `Finish Reproduction` control when done.

The app then transitions into analysis mode and communicates that it is assembling a report, not just storing a recording.

Example app line:

> "I captured the reproduction. I am organizing the transcript, visual evidence, and session details into a bug report."

### Step 5 — Report synthesis

The app displays a clear summary of what it extracted:

- bug title
- impacted area
- repro steps
- expected behavior
- actual behavior
- severity or confidence
- attachments and evidence

The report should feel like something an engineer could act on immediately.

### Step 6 — Submission confirmation

This step is required. The user must know the report was actually sent.

After submission, show a distinct success state:

- success icon
- destination label
- GitHub issue identifier
- short confirmation copy

Example confirmation:

> "Bug report submitted successfully."
>
> "Sent to GitHub Issues as #142."

Secondary text:

> "The team received the transcript, screen recording, repro steps, and session evidence."

Optional CTA:

- `View Report`
- `Report Another Bug`

For the stage demo, the confirmation should also be visible full-screen on the simulator, not only as a small toast or inline message.

## Demo screens

### Screen A — Idle / ready

Purpose:

- establish the voice-first interaction
- invite the user to describe the problem naturally

Key UI:

- orb
- ticketing-seat-map failure state
- one-line prompt: `Describe what went wrong`
- subtle trust cue: `Voice-first. On-device. Evidence captured only with permission.`
- Agent FAB

### Screen B — Permission request

Purpose:

- build trust
- make capture explicit

Key UI:

- concise explanation of what will be captured
- `Grant` button
- `Not Now` button

### Screen C — Active capture

Purpose:

- make automatic recording obvious
- reassure the audience that the system is collecting evidence in real time

Key UI:

- capture badge
- elapsed timer
- Siri-style waveform or voice visualization
- short live transcript preview
- activity feed items such as:
  - `Screen recording started`
  - `Narration transcribed`
  - `Session log attached`
  - `Reproduction marker created`

### Screen D — Report assembly

Purpose:

- show intelligence, not just recording

Key UI:

- loading state with real artifact labels
- evidence chips
- draft title
- generated repro steps filling in

### Screen E — Submitted

Purpose:

- close the loop
- remove ambiguity about success

Key UI:

- success state
- issue number
- destination label
- timestamp
- giant green checkmark
- gradient pulse background
- primary CTA to view the report

## Recommended final report shape

The generated artifact should have this structure:

- `Title`
- `Product Area`
- `Severity`
- `Environment`
- `User Summary`
- `Steps to Reproduce`
- `Expected Result`
- `Actual Result`
- `Evidence`
- `Attachments`
- `Suggested Owner` or `Likely Team`

Example:

- `Title`: Coupon discount disappears after navigating back from checkout
- `Product Area`: Checkout
- `Severity`: High
- `Environment`: iOS app, signed-in user, promo code applied
- `User Summary`: User reports that returning to checkout removes the previously applied discount
- `Steps to Reproduce`:
  1. Open cart
  2. Proceed to checkout
  3. Apply coupon code
  4. Navigate back
  5. Return to checkout
- `Expected Result`: Coupon remains applied
- `Actual Result`: Discount is removed and total resets
- `Evidence`: Voice transcript, reproduction timeline, screen recording markers, session log snapshot
- `Attachments`: `recording.mp4`, transcript excerpt, timestamped event list

For the stage version, ensure the report card prominently surfaces:

- transcript snippet
- trace location
- video evidence
- GitHub-ready title and body

## What should be real vs mocked

We are building a demo, so realism should be concentrated where the audience notices it most.

### Must feel real

- voice input
- permission request
- automatic transition into capture mode
- visible recording state
- telemetry appearing on the dashboard at the exact moment consent is granted
- a specific backend failure surfacing as the likely root cause
- structured final bug report
- explicit GitHub issue submission confirmation

### Can be mocked safely

- log ingestion internals
- issue-routing logic
- deep multimodal reasoning details
- the actual stored video can be a looped asset if real screen capture is too risky

The GitHub issue creation itself can be real or staged. What matters is that the audience clearly sees the output as an issue, not an internal opaque database entry.

### Good enough implementation strategy

- use the current voice shell and activity feed
- replace cowork-agent language with bug-reporting language
- script or semi-script the capture and report-generation sequence
- show a realistic final GitHub issue payload
- generate or create a believable issue number such as `#142`
- have the dashboard render local or streamed telemetry for the audience, but make GitHub Issues the final destination

## Mapping to current repo

These parts already help:

- `app/lib/ui/jarvis_screen.dart` — voice-first home screen
- `app/lib/ui/activity_feed.dart` — live event timeline
- `app/lib/ui/jarvis_orb.dart` — central interaction affordance
- `app/lib/ui/chat_controller.dart` — session event handling
- `app/lib/agent/mock_agent_service.dart` — easiest place to pivot demo behavior first

This demo does not need full production instrumentation to be compelling.
The fastest path is to swap the mock flow from "cowork assistant" to "bug capture assistant" and make the event stream tell the right story.

## Suggested event sequence for the demo

The mock or scripted demo flow should emit a sequence like:

1. `AgentToken`: acknowledgement of the bug description
2. `AgentToolCall`: `prepare_bug_intake`
3. `AgentToolResult`: confirmation of extracted issue summary
4. `AgentToolCall`: `request_capture_permission`
5. `AgentToolResult`: user approved system logs and screen capture
6. `AgentToolCall`: `start_repro_capture`
7. `AgentToolResult`: spinner recording and narration capture started
8. `AgentToolCall`: `inspect_network_failures`
9. `AgentToolResult`: `[DioError] 409: Conflict - Seat_Lock_Timeout`
10. `AgentToolCall`: `map_trace_location`
11. `AgentToolResult`: `lib/logic/cart_provider.dart:88`
12. `AgentToolCall`: `generate_bug_report`
13. `AgentToolResult`: structured report assembled with transcript, trace, and evidence
14. `AgentToolCall`: `create_github_issue`
15. `AgentToolResult`: issue created as `#142`
16. `AgentFinished`: spoken confirmation to the user

## Demo implementation notes

### Flutter observer pattern

Use the agent activation moment to begin observing local app failures and buffering the material needed for the GitHub issue.

Illustrative shape:

```dart
void _onActivateAgent() async {
  setState(() => isAgentActive = true);

  DioInterceptor.onData = (data) {
    telemetryBuffer.add({
      'log': data.toString(),
      'type': 'network',
      'timestamp': DateTime.now().toIso8601String(),
    });
  };
}
```

The key behavior is not the exact code. The key behavior is:

- activate agent
- start voice intake
- start listening for network and UI failure signals
- surface those signals in the demo dashboard
- package those signals into the GitHub issue body at submit time

### Success-state visual

For the final "wow" frame on the simulator:

- use a `Stack`
- render a massive green checkmark
- use a subtle pulsing gradient from green into black
- pair with heavy haptics and a deep success sound

### Dashboard behavior

The right-side dashboard should have 3 visual moments:

1. idle dark terminal
2. sudden live telemetry burst after consent
3. synthesized bug card and GitHub issue creation after submit

The red failure block should be visually dominant enough that the audience instantly understands cause and effect.

## Suggested user-facing copy

Keep the app language short, calm, and competent.

Recommended lines:

- `Tell me what went wrong.`
- `I am ready to capture the bug when you are.`
- `I will record the screen and session activity only during this reproduction.`
- `Recording reproduction. Recreate the issue now.`
- `I captured the issue. Building the report for engineering.`
- `Bug report submitted successfully. Sent to GitHub Issues as #142.`

## Final judge hook

Close with:

> "We aren't just reporting bugs. We're closing the gap between user frustration and engineering resolution. This is the end of 'It works on my machine'."

## Exit criteria

The demo is ready when:

- the app clearly supports voice intake
- the app asks permission before recording
- recording starts automatically after approval
- the user does not need to manually document the bug
- the app shows evidence being assembled into a report
- the app ends with a visible submission confirmation
- the final state includes a report ID and a destination for the submission

## Next build tasks

1. Replace the current mock agent story with the bug-report flow.
2. Add a dedicated `Grant` permission step before capture begins.
3. Add an active capture state in the Flutter UI with waveform and timer.
4. Add a laptop dashboard that visualizes capture and analysis for the audience.
5. Add the red `DioError 409` reveal and trace-location card in the dashboard.
6. Add a report assembly state with transcript, trace, and evidence.
7. Add direct GitHub issue creation or a realistic staged issue-create flow.
8. Add a full-screen submitted state with success confirmation and GitHub issue number.
9. Polish copy so every screen reinforces the same product promise.
