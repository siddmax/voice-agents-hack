import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../sdk/feedback_analyzer.dart';
import '../sdk/feedback_kb.dart';
import 'report_flow_controller.dart';

class ReportFlowOverlay extends StatelessWidget {
  final ReportFlowController controller;

  const ReportFlowOverlay({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.state == ReportFlowState.idle) {
          return const SizedBox.shrink();
        }
        if (controller.state == ReportFlowState.recordingRepro) {
          return Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: SafeArea(child: _ReproRecordingDock(controller: controller)),
          );
        }
        return Positioned.fill(
          child: Material(
            color: Colors.black.withValues(alpha: 0.90),
            child: SafeArea(child: _body(context)),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    return switch (controller.state) {
      ReportFlowState.choosingMode => _ModePicker(controller: controller),
      ReportFlowState.recordingFeedback => _RecordingPanel.feedback(
        controller: controller,
      ),
      ReportFlowState.analyzingFeedback => _SpinnerPanel(
        label: controller.agentActivity,
      ),
      ReportFlowState.feedbackPreview => _FeedbackPreview(
        controller: controller,
      ),
      ReportFlowState.recordingRepro => _RecordingPanel.repro(
        controller: controller,
      ),
      ReportFlowState.analyzingRepro => _SpinnerPanel(
        label: controller.agentActivity,
      ),
      ReportFlowState.reproPreview => _ReproPreview(controller: controller),
      ReportFlowState.submitting => _SpinnerPanel(
        label: controller.agentActivity,
      ),
      ReportFlowState.done => _DonePanel(controller: controller),
      ReportFlowState.error => _ErrorPanel(controller: controller),
      ReportFlowState.idle => const SizedBox.shrink(),
    };
  }
}

class _ModePicker extends StatelessWidget {
  final ReportFlowController controller;

  const _ModePicker({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'What would you like to send?',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 24),
            _ModeCard(
              icon: Icons.mic_rounded,
              title: 'Give us feedback',
              subtitle: 'Tell us what worked or what felt off.',
              color: const Color(0xFF38BDF8),
              onTap: controller.chooseFeedback,
            ),
            const SizedBox(height: 12),
            _ModeCard(
              icon: Icons.videocam_rounded,
              title: 'Reproduce a bug',
              subtitle: 'Record the screen while narrating what happened.',
              color: const Color(0xFFE74C3C),
              onTap: controller.chooseBugRepro,
            ),
            const SizedBox(height: 20),
            _OverlayButton(
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
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white60, height: 1.3),
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

class _RecordingPanel extends StatelessWidget {
  final ReportFlowController controller;
  final bool repro;

  const _RecordingPanel.feedback({required this.controller}) : repro = false;
  const _RecordingPanel.repro({required this.controller}) : repro = true;

  @override
  Widget build(BuildContext context) {
    final color = repro ? const Color(0xFFE74C3C) : const Color(0xFF38BDF8);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PulseOrb(amplitude: controller.amplitude, color: color),
            const SizedBox(height: 24),
            Text(
              repro ? 'Reproduce the bug' : 'Recording your voice',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              repro
                  ? 'Reproduce the bug while narrating what you are doing. Tap Done when you finish.'
                  : 'Tell us what worked or what felt off. Tap Done when you finish.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, height: 1.4),
            ),
            const SizedBox(height: 26),
            _OverlayButton(
              label: 'Done',
              color: color,
              onTap: repro
                  ? controller.finishBugRepro
                  : controller.finishFeedback,
            ),
            const SizedBox(height: 12),
            _OverlayButton(
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

class _ReproRecordingDock extends StatelessWidget {
  final ReportFlowController controller;

  const _ReproRecordingDock({required this.controller});

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFE74C3C);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF111827).withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.42)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.26),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            _RecordingDot(amplitude: controller.amplitude),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Recording reproduction',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Use the app normally. Narrate what breaks.',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _DockButton(
              label: 'Cancel',
              color: Colors.white12,
              onTap: controller.cancel,
            ),
            const SizedBox(width: 8),
            _DockButton(
              label: 'Done',
              color: color,
              onTap: controller.finishBugRepro,
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingDot extends StatelessWidget {
  final double amplitude;

  const _RecordingDot({required this.amplitude});

  @override
  Widget build(BuildContext context) {
    final size = 12.0 + (amplitude.clamp(0, 1) * 8);
    return SizedBox(
      width: 28,
      height: 28,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: const Color(0xFFE74C3C),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _DockButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 64),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _FeedbackPreview extends StatelessWidget {
  final ReportFlowController controller;

  const _FeedbackPreview({required this.controller});

  @override
  Widget build(BuildContext context) {
    final report = controller.feedbackReport;
    if (report == null) return const SizedBox.shrink();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Your Feedback',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              _PlainTextCard(text: report.plainTranscript),
              if (report.offer != null) ...[
                const SizedBox(height: 14),
                _OfferCard(offer: report.offer!),
              ],
              if (report.resolution != null) ...[
                const SizedBox(height: 14),
                _ResolutionCard(resolution: report.resolution!),
              ],
              const SizedBox(height: 14),
              _InfoCard(
                children: [
                  _InfoLine(
                    label: 'Sentiment',
                    value:
                        '${report.sentiment.label} · ${(report.sentimentScore * 100).round()}%',
                  ),
                  _InfoLine(label: 'Tone', value: report.emotionalTone),
                  _InfoLine(label: 'Category', value: report.category),
                  if (report.themes.isNotEmpty)
                    _InfoLine(label: 'Themes', value: report.themes.join(', ')),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _OverlayButton(
                      label: 'Retake',
                      color: Colors.white12,
                      onTap: controller.retake,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _OverlayButton(
                      label: 'Submit',
                      color: const Color(0xFF16A34A),
                      onTap: controller.submit,
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

class _ReproPreview extends StatelessWidget {
  final ReportFlowController controller;

  const _ReproPreview({required this.controller});

  @override
  Widget build(BuildContext context) {
    final report = controller.bugReport;
    if (report == null) return const SizedBox.shrink();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Bug Report Preview',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              _InfoCard(
                children: [
                  Text(
                    report.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Steps to reproduce',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...report.steps.asMap().entries.map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${entry.key + 1}. ${entry.value}',
                        style: const TextStyle(
                          color: Colors.white70,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _InfoLine(label: 'Expected', value: report.expectedBehavior),
                  _InfoLine(label: 'Actual', value: report.actualBehavior),
                  _InfoLine(label: 'Severity', value: report.severity),
                ],
              ),
              const SizedBox(height: 14),
              _VideoEvidence(
                path: report.videoPath,
                note: report.videoUploadNote,
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _OverlayButton(
                      label: 'Retake',
                      color: Colors.white12,
                      onTap: controller.retake,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _OverlayButton(
                      label: 'Submit',
                      color: const Color(0xFF16A34A),
                      onTap: controller.submit,
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

class _VideoEvidence extends StatefulWidget {
  final String? path;
  final String? note;

  const _VideoEvidence({required this.path, this.note});

  @override
  State<_VideoEvidence> createState() => _VideoEvidenceState();
}

class _VideoEvidenceState extends State<_VideoEvidence> {
  VideoPlayerController? _controller;
  Future<void>? _init;
  bool _fileExists = false;
  int? _fileBytes;

  @override
  void initState() {
    super.initState();
    final path = widget.path;
    if (!kIsWeb && path != null) {
      final file = File(path);
      _fileExists = file.existsSync();
      if (!_fileExists) return;
      _fileBytes = file.lengthSync();
      final controller = VideoPlayerController.file(file);
      _controller = controller;
      _init = controller.initialize().then((_) {
        controller.setLooping(true);
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Video Evidence',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 10),
          if (controller == null)
            Text(
              _videoEvidenceMessage(),
              style: const TextStyle(color: Colors.white70, height: 1.4),
            )
          else
            FutureBuilder<void>(
              future: _init,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const SizedBox(
                    height: 140,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      controller.value.isPlaying
                          ? controller.pause()
                          : controller.play();
                    });
                  },
                  child: AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        VideoPlayer(controller),
                        if (!controller.value.isPlaying)
                          const Icon(
                            Icons.play_circle,
                            color: Colors.white70,
                            size: 44,
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  String _videoEvidenceMessage() {
    final path = widget.path;
    if (path == null || path.isEmpty) {
      return widget.note == null || widget.note!.isEmpty
          ? 'No local recording path was returned. The issue will still include narration, steps, and session evidence.'
          : '${widget.note} The issue will still include narration, steps, and session evidence.';
    }
    if (!_fileExists) {
      return 'Recording path returned, but the file is not readable from Flutter. Upload may be skipped; the issue will include the local path and diagnostics.';
    }
    final bytes = _fileBytes;
    final size = bytes == null ? 'unknown size' : _formatBytes(bytes);
    return 'Captured locally ($size). The recording will be uploaded before the GitHub issue is created.';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }
}

class _OfferCard extends StatelessWidget {
  final String offer;

  const _OfferCard({required this.offer});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16A34A).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF16A34A)),
      ),
      child: Row(
        children: [
          const Icon(Icons.local_offer, color: Color(0xFF4ADE80)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              offer,
              style: const TextStyle(color: Colors.white, height: 1.4),
            ),
          ),
          IconButton(
            tooltip: 'Copy coupon',
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: 'SORRY10'));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Coupon copied')));
            },
            icon: const Icon(Icons.copy, color: Colors.white70, size: 18),
          ),
        ],
      ),
    );
  }
}

class _ResolutionCard extends StatelessWidget {
  final FeedbackResolution resolution;

  const _ResolutionCard({required this.resolution});

  @override
  Widget build(BuildContext context) {
    final primary = resolution.matches.isEmpty
        ? null
        : resolution.matches.first.article;
    return _InfoCard(
      children: [
        const Row(
          children: [
            Icon(Icons.support_agent, color: Color(0xFF60A5FA), size: 18),
            SizedBox(width: 8),
            Text(
              'Likely fix',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        if (primary != null) ...[
          const SizedBox(height: 8),
          Text(
            primary.title,
            style: const TextStyle(color: Colors.white70, height: 1.35),
          ),
        ],
        if (resolution.customerSteps.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'Try this',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          ...resolution.customerSteps.map(
            (step) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '- $step',
                style: const TextStyle(color: Colors.white70, height: 1.35),
              ),
            ),
          ),
        ],
        if (resolution.teamActions.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            resolution.teamActions.first,
            style: const TextStyle(color: Color(0xFF93C5FD), height: 1.35),
          ),
        ],
      ],
    );
  }
}

class _PlainTextCard extends StatelessWidget {
  final String text;

  const _PlainTextCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: SingleChildScrollView(
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, height: 1.5),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final String label;
  final String value;

  const _InfoLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(color: Colors.white70, height: 1.35),
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

class _SpinnerPanel extends StatelessWidget {
  final String label;

  const _SpinnerPanel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Color(0xFF38BDF8)),
          const SizedBox(height: 18),
          Text(label, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

class _DonePanel extends StatelessWidget {
  final ReportFlowController controller;

  const _DonePanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 64),
            const SizedBox(height: 16),
            Text(
              controller.mode == ReportMode.feedback
                  ? 'Feedback Submitted'
                  : 'Bug Report Submitted',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (controller.issueUrl != null) ...[
              const SizedBox(height: 8),
              Text(
                controller.issueUrl!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),
            ],
            const SizedBox(height: 22),
            _OverlayButton(
              label: 'Done',
              color: Colors.white12,
              onTap: controller.cancel,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  final ReportFlowController controller;

  const _ErrorPanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFE74C3C), size: 54),
            const SizedBox(height: 14),
            Text(
              controller.errorMessage ?? 'Something went wrong',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 22),
            _OverlayButton(
              label: 'Dismiss',
              color: Colors.white12,
              onTap: controller.cancel,
            ),
          ],
        ),
      ),
    );
  }
}

class _OverlayButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _OverlayButton({
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
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _PulseOrb extends StatefulWidget {
  final double amplitude;
  final Color color;

  const _PulseOrb({required this.amplitude, required this.color});

  @override
  State<_PulseOrb> createState() => _PulseOrbState();
}

class _PulseOrbState extends State<_PulseOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final pulse = (math.sin(_controller.value * math.pi * 2) + 1) / 2;
        final size = 108 + pulse * 16 + widget.amplitude * 18;
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.45),
                blurRadius: 28 + pulse * 24,
                spreadRadius: 6,
              ),
            ],
          ),
          child: const Icon(
            Icons.graphic_eq_rounded,
            color: Colors.white,
            size: 40,
          ),
        );
      },
    );
  }
}
