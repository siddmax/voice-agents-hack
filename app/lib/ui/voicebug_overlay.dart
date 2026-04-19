import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sdk/capture_flow.dart';
import '../sdk/feedback_analyzer.dart';

class VoiceBugOverlay extends StatelessWidget {
  final CaptureFlowController controller;

  const VoiceBugOverlay({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.state == CaptureState.idle) {
          return const SizedBox.shrink();
        }
        return _buildOverlay(context);
      },
    );
  }

  Widget _buildOverlay(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.92),
      child: SafeArea(
        child: switch (controller.state) {
          CaptureState.choosing => _ChooserView(controller: controller),
          CaptureState.listening => _ListeningView(controller: controller),
          CaptureState.transcribing => _TranscribingView(
            controller: controller,
          ),
          CaptureState.transcriptPreview => _TranscriptPreviewView(
            controller: controller,
          ),
          CaptureState.analyzingFeedback => _AnalyzingView(
            label: controller.agentActivity,
            controller: controller,
          ),
          CaptureState.feedbackResult => _FeedbackResultView(
            controller: controller,
          ),
          CaptureState.couponOffer => _CouponOfferView(controller: controller),
          CaptureState.recording => _RecordingView(controller: controller),
          CaptureState.analyzingBugRepro => _AnalyzingView(
            label: controller.agentActivity,
            controller: controller,
          ),
          CaptureState.bugReproPreview => _BugReproPreviewView(
            controller: controller,
          ),
          CaptureState.submitting => _SubmittingView(
            label: controller.agentActivity,
          ),
          CaptureState.done => _DoneView(controller: controller),
          CaptureState.error => _ErrorView(controller: controller),
          _ => const SizedBox.shrink(),
        },
      ),
    );
  }
}

// ── Mode chooser ──────────────────────────────────────────────────────────────

class _ChooserView extends StatelessWidget {
  final CaptureFlowController controller;
  const _ChooserView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'How can we help?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Choose what you\'d like to do',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
            const SizedBox(height: 36),
            _ModeCard(
              icon: Icons.mic_rounded,
              iconColor: const Color(0xFF38BDF8),
              title: 'Give us feedback',
              subtitle: 'Voice only — tell us what you think',
              onTap: () => controller.chooseMode(CaptureMode.feedback),
            ),
            const SizedBox(height: 16),
            _ModeCard(
              icon: Icons.videocam_rounded,
              iconColor: const Color(0xFFe74c3c),
              title: 'Reproduce a bug',
              subtitle: 'Record your screen while narrating',
              onTap: () => controller.chooseMode(CaptureMode.bugRepro),
            ),
            const SizedBox(height: 32),
            _ActionButton(
              label: 'Cancel',
              color: Colors.white12,
              onTap: controller.cancel,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: iconColor, size: 26),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}

// ── Listening (shared for feedback voice recording) ───────────────────────────

class _ListeningView extends StatelessWidget {
  final CaptureFlowController controller;
  const _ListeningView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _GlowingOrb(
              amplitude: controller.soundLevel,
              color: const Color(0xFF38BDF8),
            ),
            const SizedBox(height: 24),
            const Text(
              'Tell us what you think',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              controller.partialTranscript.isEmpty
                  ? 'Listening...'
                  : controller.partialTranscript,
              style: const TextStyle(color: Colors.white60, fontSize: 14),
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 32),
            _ActionButton(
              label: 'Done',
              color: const Color(0xFF16A34A),
              onTap: controller.stopListeningAndShowTranscript,
            ),
            const SizedBox(height: 12),
            _ActionButton(
              label: 'Cancel',
              color: Colors.white12,
              onTap: controller.cancel,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Transcribing ──────────────────────────────────────────────────────────────

class _TranscribingView extends StatelessWidget {
  final CaptureFlowController controller;
  const _TranscribingView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              color: Color(0xFF38BDF8),
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Processing your recording...',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const SizedBox(height: 24),
          _ActionButton(
            label: 'Cancel',
            color: Colors.white12,
            onTap: controller.cancel,
          ),
        ],
      ),
    );
  }
}

// ── Transcript preview (plain text, not JSON) ─────────────────────────────────

class _TranscriptPreviewView extends StatelessWidget {
  final CaptureFlowController controller;
  const _TranscriptPreviewView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final isFeedback = controller.mode == CaptureMode.feedback;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isFeedback ? 'Your Feedback' : 'Your Narration',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Here\'s what we heard. Does this look right?',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
            const SizedBox(height: 24),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 280),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: SingleChildScrollView(
                child: Text(
                  controller.transcript,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.6,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    label: 'Retake',
                    color: Colors.white12,
                    onTap: controller.retakeRecording,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ActionButton(
                    label: 'Submit',
                    color: const Color(0xFF16A34A),
                    onTap: isFeedback
                        ? controller.submitFeedback
                        : controller.stopRecordingAndAnalyze,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Analyzing (shared spinner) ────────────────────────────────────────────────

class _AnalyzingView extends StatelessWidget {
  final String label;
  final CaptureFlowController controller;
  const _AnalyzingView({required this.label, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              color: Color(0xFF38BDF8),
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const SizedBox(height: 12),
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock, color: Colors.white38, size: 14),
              SizedBox(width: 6),
              Text(
                'All processing on-device',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _ActionButton(
            label: 'Cancel',
            color: Colors.white12,
            onTap: controller.cancel,
          ),
        ],
      ),
    );
  }
}

// ── Feedback result ───────────────────────────────────────────────────────────

class _FeedbackResultView extends StatelessWidget {
  final CaptureFlowController controller;
  const _FeedbackResultView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final fb = controller.feedbackReport;
    if (fb == null) return const SizedBox.shrink();

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _sentimentIcon(fb.sentiment),
                color: _sentimentColor(fb.sentiment),
                size: 56,
              ),
              const SizedBox(height: 16),
              const Text(
                'Feedback Analysis',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 20),
              _InfoCard(
                children: [
                  _InfoRow(
                    label: 'SENTIMENT',
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _sentimentColor(
                              fb.sentiment,
                            ).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${fb.sentiment.label.toUpperCase()} · ${(fb.sentimentScore * 100).round()}%',
                            style: TextStyle(
                              color: _sentimentColor(fb.sentiment),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _InfoRow(
                    label: 'TONE',
                    child: Text(
                      fb.emotionalTone,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  _InfoRow(
                    label: 'CATEGORY',
                    child: Text(
                      fb.category,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (fb.themes.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: fb.themes
                            .map((t) => _ThemeChip(label: t))
                            .toList(),
                      ),
                    ),
                  ],
                  if (fb.actionableInsight.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.2),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ACTIONABLE INSIGHT',
                            style: TextStyle(
                              color: Color(0xFF38BDF8),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            fb.actionableInsight,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 20),
              Text(
                '"${fb.summary}"',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: 'Dismiss',
                      color: Colors.white12,
                      onTap: controller.cancel,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ActionButton(
                      label: 'Submit to Team',
                      color: const Color(0xFF16A34A),
                      onTap: controller.submitFeedbackToGitHub,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Coupon offer (negative sentiment) ─────────────────────────────────────────

class _CouponOfferView extends StatelessWidget {
  final CaptureFlowController controller;
  const _CouponOfferView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF7C3AED), Color(0xFFA855F7)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF7C3AED).withValues(alpha: 0.4),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Center(
                child: Text(
                  '10%',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'We\'re sorry about that',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your experience matters to us. Here\'s a little something to make it right.',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 14,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF7C3AED).withValues(alpha: 0.15),
                    const Color(0xFFA855F7).withValues(alpha: 0.08),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0xFF7C3AED).withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                children: [
                  const Text(
                    '10% OFF',
                    style: TextStyle(
                      color: Color(0xFFA855F7),
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'your next ticket purchase',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 14),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(const ClipboardData(text: 'SORRY10'));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Coupon code copied!'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.2),
                          style: BorderStyle.solid,
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'SORRY10',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 3,
                            ),
                          ),
                          SizedBox(width: 8),
                          Icon(Icons.copy, color: Colors.white54, size: 16),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            _ActionButton(
              label: 'Thanks! Continue',
              color: const Color(0xFF7C3AED),
              onTap: controller.dismissCoupon,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Recording (bug repro — voice + screen) ────────────────────────────────────

class _RecordingView extends StatelessWidget {
  final CaptureFlowController controller;
  const _RecordingView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _GlowingOrb(
              amplitude: controller.soundLevel,
              color: const Color(0xFFe74c3c),
            ),
            const SizedBox(height: 24),
            const Text(
              'Reproduce the bug',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Narrate what you\'re doing as you reproduce the issue',
              style: TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            _RecordingTimer(start: controller.recordingDuration),
            const SizedBox(height: 16),
            if (controller.partialTranscript.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  controller.partialTranscript,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 13,
                    height: 1.4,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.fiber_manual_record,
                  color: Color(0xFFe74c3c),
                  size: 10,
                ),
                const SizedBox(width: 6),
                const Text(
                  'Recording screen & voice',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _ActionButton(
              label: 'Done',
              color: const Color(0xFFe74c3c),
              onTap: controller.stopRecordingAndAnalyze,
            ),
            const SizedBox(height: 12),
            _ActionButton(
              label: 'Cancel',
              color: Colors.white12,
              onTap: controller.cancel,
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingTimer extends StatefulWidget {
  final Duration start;
  const _RecordingTimer({required this.start});

  @override
  State<_RecordingTimer> createState() => _RecordingTimerState();
}

class _RecordingTimerState extends State<_RecordingTimer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final elapsed =
            widget.start + Duration(seconds: (_ctrl.value * 1).round());
        final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
        final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
        return Text(
          '$minutes:$seconds',
          style: const TextStyle(
            color: Color(0xFFe74c3c),
            fontSize: 28,
            fontWeight: FontWeight.w800,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        );
      },
    );
  }
}

// ── Bug repro preview ─────────────────────────────────────────────────────────

class _BugReproPreviewView extends StatelessWidget {
  final CaptureFlowController controller;
  const _BugReproPreviewView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final br = controller.bugReproReport;
    if (br == null) return const SizedBox.shrink();

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Column(
                  children: [
                    const Icon(
                      Icons.bug_report,
                      color: Color(0xFFe74c3c),
                      size: 40,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Bug Report Preview',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _severityColor(
                          br.severity,
                        ).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        br.severity.toUpperCase(),
                        style: TextStyle(
                          color: _severityColor(br.severity),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _InfoCard(
                children: [
                  Text(
                    br.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'STEPS TO REPRODUCE',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...br.steps.asMap().entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF38BDF8,
                              ).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Center(
                              child: Text(
                                '${e.key + 1}',
                                style: const TextStyle(
                                  color: Color(0xFF38BDF8),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              e.value,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (br.expectedBehavior.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'EXPECTED',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      br.expectedBehavior,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                  if (br.actualBehavior.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'ACTUAL',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      br.actualBehavior,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
              if (controller.screenshotBytes != null) ...[
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    controller.screenshotBytes!,
                    height: 120,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: 'Retake',
                      color: Colors.white12,
                      onTap: controller.retakeRecording,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ActionButton(
                      label: 'Submit',
                      color: const Color(0xFF16A34A),
                      onTap: controller.submitBugRepro,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Submitting ────────────────────────────────────────────────────────────────

class _SubmittingView extends StatelessWidget {
  final String label;
  const _SubmittingView({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              color: Color(0xFF27ae60),
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

// ── Done ──────────────────────────────────────────────────────────────────────

class _DoneView extends StatelessWidget {
  final CaptureFlowController controller;
  const _DoneView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final isFeedback = controller.mode == CaptureMode.feedback;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF27ae60), size: 64),
          const SizedBox(height: 16),
          Text(
            isFeedback ? 'Feedback Submitted!' : 'Bug Report Created!',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isFeedback
                ? 'Thank you for your feedback'
                : 'Our team will investigate this',
            style: const TextStyle(color: Colors.white54, fontSize: 14),
          ),
          if (controller.issueUrl != null) ...[
            const SizedBox(height: 8),
            Text(
              controller.issueUrl!,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          _ActionButton(
            label: 'Done',
            color: Colors.white12,
            onTap: controller.reset,
          ),
        ],
      ),
    );
  }
}

// ── Error ─────────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final CaptureFlowController controller;
  const _ErrorView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFe74c3c), size: 48),
          const SizedBox(height: 16),
          Text(
            controller.errorMessage ?? 'Something went wrong',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          _ActionButton(
            label: 'Dismiss',
            color: Colors.white12,
            onTap: controller.reset,
          ),
        ],
      ),
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _GlowingOrb extends StatefulWidget {
  final double amplitude;
  final Color color;
  const _GlowingOrb({required this.amplitude, required this.color});

  @override
  State<_GlowingOrb> createState() => _GlowingOrbState();
}

class _GlowingOrbState extends State<_GlowingOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final pulse = (math.sin(_ctrl.value * math.pi * 2) + 1) / 2;
        final amp = widget.amplitude.clamp(0.0, 1.0);
        final scale = 0.85 + pulse * 0.1 + amp * 0.2;
        final glow = 20.0 + pulse * 20 + amp * 40;

        return Container(
          width: 120 * scale,
          height: 120 * scale,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                widget.color,
                widget.color.withValues(alpha: 0.7),
                widget.color.withValues(alpha: 0.2),
              ],
              stops: const [0.0, 0.6, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.5),
                blurRadius: glow,
                spreadRadius: glow / 3,
              ),
            ],
          ),
          child: Center(
            child: Icon(
              widget.color == const Color(0xFFe74c3c)
                  ? Icons.videocam
                  : Icons.mic,
              color: Colors.white,
              size: 40,
            ),
          ),
        );
      },
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final List<Widget> children;
  const _InfoCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final Widget child;
  const _InfoRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _ThemeChip extends StatelessWidget {
  final String label;
  const _ThemeChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white60,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

Color _sentimentColor(Sentiment s) => switch (s) {
  Sentiment.positive => const Color(0xFF22C55E),
  Sentiment.neutral => const Color(0xFF38BDF8),
  Sentiment.mixedNegative => const Color(0xFFf59e0b),
  Sentiment.negative => const Color(0xFFe74c3c),
};

IconData _sentimentIcon(Sentiment s) => switch (s) {
  Sentiment.positive => Icons.sentiment_very_satisfied,
  Sentiment.neutral => Icons.sentiment_neutral,
  Sentiment.mixedNegative => Icons.sentiment_dissatisfied,
  Sentiment.negative => Icons.sentiment_very_dissatisfied,
};

Color _severityColor(String severity) {
  return switch (severity) {
    'critical' => const Color(0xFFe74c3c),
    'high' => const Color(0xFFe67e22),
    'medium' => const Color(0xFFf1c40f),
    'low' => const Color(0xFF555555),
    _ => const Color(0xFF555555),
  };
}
