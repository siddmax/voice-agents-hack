import 'package:flutter/material.dart';

import '../agent/agent_service.dart';

class DropGuardDashboard extends StatelessWidget {
  final List<AgentEvent> events;
  final String transcript;
  final bool captureGranted;

  const DropGuardDashboard({
    super.key,
    required this.events,
    required this.transcript,
    required this.captureGranted,
  });

  @override
  Widget build(BuildContext context) {
    final snapshot = _DashboardSnapshot.fromEvents(
      events: events,
      transcript: transcript,
      captureGranted: captureGranted,
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF020617), Color(0xFF030712), Color(0xFF000000)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SRE Dashboard',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: const Color(0xFFD1FAE5),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              'Live diagnosis stream · local telemetry and GitHub issue synthesis',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF86EFAC),
                  ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF03111E),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFF0F766E).withValues(alpha: 0.25)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x2206B6D4),
                      blurRadius: 28,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _DashboardHeader(snapshot: snapshot),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView(
                          children: [
                            _TerminalPane(lines: snapshot.logs),
                            const SizedBox(height: 12),
                            if (snapshot.error != null)
                              _ErrorBlast(error: snapshot.error!),
                            if (snapshot.reportReady) ...[
                              const SizedBox(height: 12),
                              _BugReportCard(snapshot: snapshot),
                            ],
                            if (snapshot.issueNumber != null) ...[
                              const SizedBox(height: 12),
                              _GitHubIssueCard(snapshot: snapshot),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  final _DashboardSnapshot snapshot;
  const _DashboardHeader({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final badgeColor = snapshot.captureGranted
        ? const Color(0xFF10B981)
        : const Color(0xFF334155);
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: badgeColor.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: badgeColor.withValues(alpha: 0.35)),
          ),
          child: Text(
            snapshot.captureGranted ? 'CAPTURE LIVE' : 'STANDBY',
            style: TextStyle(
              color: snapshot.captureGranted
                  ? const Color(0xFFA7F3D0)
                  : const Color(0xFF94A3B8),
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ),
        const Spacer(),
        if (snapshot.trace != null)
          Text(
            snapshot.trace!,
            style: const TextStyle(
              color: Color(0xFF67E8F9),
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}

class _TerminalPane extends StatelessWidget {
  final List<String> lines;
  const _TerminalPane({required this.lines});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF020617),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF164E63).withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'event_stream',
            style: TextStyle(
              color: Color(0xFF67E8F9),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (final line in lines.take(10))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                line,
                style: const TextStyle(
                  color: Color(0xFF86EFAC),
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorBlast extends StatelessWidget {
  final String error;
  const _ErrorBlast({required this.error});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF450A0A), Color(0xFF7F1D1D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF87171).withValues(alpha: 0.45)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x55EF4444),
            blurRadius: 24,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'FAILURE SIGNAL',
            style: TextStyle(
              color: Color(0xFFFECACA),
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            error,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 16,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _BugReportCard extends StatelessWidget {
  final _DashboardSnapshot snapshot;
  const _BugReportCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Multimodal ticket synthesis',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 14),
          _FieldLine(label: 'Transcript', value: snapshot.transcriptDisplay),
          const SizedBox(height: 10),
          _FieldLine(label: 'Trace', value: snapshot.trace ?? 'Mapping trace...'),
          const SizedBox(height: 10),
          _FieldLine(
            label: 'Expected',
            value: 'Seat lock should complete and place the ticket in cart.',
          ),
          const SizedBox(height: 10),
          _FieldLine(
            label: 'Actual',
            value: 'Spinner hangs indefinitely after repeated Add to Cart attempts.',
          ),
          const SizedBox(height: 14),
          Row(
            children: const [
              Expanded(child: _EvidenceChip(label: '5-second spinner loop')),
              SizedBox(width: 10),
              Expanded(child: _EvidenceChip(label: 'Session log snapshot')),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: const [
              Expanded(child: _EvidenceChip(label: 'Voice transcript')),
              SizedBox(width: 10),
              Expanded(child: _EvidenceChip(label: 'Repro steps extracted')),
            ],
          ),
        ],
      ),
    );
  }
}

class _GitHubIssueCard extends StatelessWidget {
  final _DashboardSnapshot snapshot;
  const _GitHubIssueCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF4ADE80).withValues(alpha: 0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.check_circle_outline, color: Color(0xFF4ADE80)),
              SizedBox(width: 8),
              Text(
                'GitHub issue created',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            snapshot.issueNumber!,
            style: const TextStyle(
              color: Color(0xFFBBF7D0),
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Title: Seat map frozen in Section 102 after repeated Add to Cart attempts',
            style: TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 6),
          Text(
            'Destination: GitHub Issues · Trace: ${snapshot.trace ?? "lib/logic/cart_provider.dart:88"}',
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _FieldLine extends StatelessWidget {
  final String label;
  final String value;
  const _FieldLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF67E8F9),
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(color: Colors.white, height: 1.4),
        ),
      ],
    );
  }
}

class _EvidenceChip extends StatelessWidget {
  final String label;
  const _EvidenceChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFF93C5FD),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardSnapshot {
  final bool captureGranted;
  final List<String> logs;
  final String? error;
  final String? trace;
  final bool reportReady;
  final String? issueNumber;
  final String transcriptDisplay;

  const _DashboardSnapshot({
    required this.captureGranted,
    required this.logs,
    required this.error,
    required this.trace,
    required this.reportReady,
    required this.issueNumber,
    required this.transcriptDisplay,
  });

  factory _DashboardSnapshot.fromEvents({
    required List<AgentEvent> events,
    required String transcript,
    required bool captureGranted,
  }) {
    final logs = <String>[
      captureGranted
          ? '[voice] intake armed · transcript linked to active repro session'
          : '[system] dashboard idle · waiting for agent consent',
      if (transcript.trim().isNotEmpty)
        '[voice] "${transcript.trim()}"',
    ];

    String? error;
    String? trace;
    bool reportReady = false;
    String? issueNumber;

    for (final event in events) {
      switch (event) {
        case AgentToolCall(:final toolName):
          logs.add('[agent] -> $toolName');
        case AgentToolResult(:final toolName, :final summary):
          logs.add('[$toolName] $summary');
          if (toolName == 'inspect_network_failures') {
            error = summary;
          }
          if (toolName == 'map_trace_location') {
            trace = summary;
          }
          if (toolName == 'generate_bug_report') {
            reportReady = true;
          }
          if (toolName == 'create_github_issue') {
            issueNumber = summary;
          }
        case AgentToken(:final text):
          if (text.trim().isNotEmpty) {
            logs.add('[token] ${text.trim()}');
          }
        case AgentThinking(:final activeTodo):
          logs.add('[thinking] ${activeTodo ?? "reasoning"}');
        case AgentFinished(:final summary):
          logs.add('[done] $summary');
        case AgentError(:final message):
          logs.add('[error] $message');
        case AgentTodoUpdate():
          logs.add('[planner] todo ledger updated');
      }
    }

    return _DashboardSnapshot(
      captureGranted: captureGranted,
      logs: logs.reversed.take(14).toList().reversed.toList(),
      error: error,
      trace: trace,
      reportReady: reportReady,
      issueNumber: issueNumber,
      transcriptDisplay: transcript.trim().isEmpty
          ? 'Seat map frozen... Section 102.'
          : transcript.trim(),
    );
  }
}
