import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../sdk/capture_flow.dart';
import '../sdk/screen_analyzer.dart';

class VoiceBugOverlay extends StatelessWidget {
  final CaptureFlowController controller;

  const VoiceBugOverlay({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.state == CaptureState.idle) return const SizedBox.shrink();
        return _buildOverlay(context);
      },
    );
  }

  Widget _buildOverlay(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.85),
      child: switch (controller.state) {
        CaptureState.listening => _ListeningView(controller: controller),
        CaptureState.analyzing => const _AnalyzingView(),
        CaptureState.previewing => _PreviewView(controller: controller),
        CaptureState.submitting => const _SubmittingView(),
        CaptureState.done => _DoneView(controller: controller),
        CaptureState.error => _ErrorView(controller: controller),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

class _ListeningView extends StatelessWidget {
  final CaptureFlowController controller;
  const _ListeningView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GlowingOrb(amplitude: controller.soundLevel),
          const SizedBox(height: 24),
          Text(
            controller.partialTranscript.isEmpty
                ? 'Listening...'
                : controller.partialTranscript,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          const Text(
            'Tap to stop recording',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 32),
          _ActionButton(
            label: 'Stop',
            color: const Color(0xFFe74c3c),
            onTap: controller.stopAndAnalyze,
          ),
          const SizedBox(height: 12),
          _ActionButton(
            label: 'Cancel',
            color: Colors.white24,
            onTap: controller.cancel,
          ),
        ],
      ),
    );
  }
}

class _GlowingOrb extends StatefulWidget {
  final double amplitude;
  const _GlowingOrb({required this.amplitude});

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
            gradient: const RadialGradient(
              colors: [
                Color(0xFFe74c3c),
                Color(0xFFc0392b),
                Color(0x33e74c3c),
              ],
              stops: [0.0, 0.6, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFe74c3c).withValues(alpha: 0.5),
                blurRadius: glow,
                spreadRadius: glow / 3,
              ),
            ],
          ),
          child: const Center(
            child: Icon(Icons.mic, color: Colors.white, size: 40),
          ),
        );
      },
    );
  }
}

class _AnalyzingView extends StatelessWidget {
  const _AnalyzingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              color: Color(0xFFe74c3c),
              strokeWidth: 3,
            ),
          ),
          SizedBox(height: 24),
          Text(
            'Structuring your report...',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          SizedBox(height: 12),
          Row(
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
        ],
      ),
    );
  }
}

class _PreviewView extends StatelessWidget {
  final CaptureFlowController controller;
  const _PreviewView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final report = controller.report!;
    final severityColor = _severityColor(report.severity);

    return Center(
      child: Container(
        width: 400,
        constraints: const BoxConstraints(maxHeight: 600),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1a1a1a),
                  borderRadius: BorderRadius.circular(12),
                  border: Border(left: BorderSide(color: severityColor, width: 4)),
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      report.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _SeverityBadge(severity: report.severity),
                    const SizedBox(height: 16),
                    _FieldSection(label: 'Description', value: report.description),
                    _FieldSection(label: 'Steps Context', value: report.stepsContext),
                    _FieldSection(label: 'Expected', value: report.expected),
                    _FieldSection(label: 'Actual', value: report.actual),
                    if (controller.screenshotBytes != null) ...[
                      const Text(
                        'SCREENSHOT',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          controller.screenshotBytes!,
                          height: 120,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (controller.metadata != null)
                      Text(
                        '${controller.metadata!.device} · ${controller.metadata!.os}',
                        style: const TextStyle(color: Colors.white24, fontSize: 11),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: 'Cancel',
                      color: Colors.white12,
                      onTap: controller.cancel,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ActionButton(
                      label: 'Submit Report',
                      color: const Color(0xFF27ae60),
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

class _SubmittingView extends StatelessWidget {
  const _SubmittingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              color: Color(0xFF27ae60),
              strokeWidth: 3,
            ),
          ),
          SizedBox(height: 16),
          Text(
            'Creating GitHub Issue...',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _DoneView extends StatelessWidget {
  final CaptureFlowController controller;
  const _DoneView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF27ae60), size: 64),
          const SizedBox(height: 16),
          const Text(
            'Issue Created!',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
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

class _FieldSection extends StatelessWidget {
  final String label;
  final String value;
  const _FieldSection({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty || value == 'Not available') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 10,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _SeverityBadge extends StatelessWidget {
  final String severity;
  const _SeverityBadge({required this.severity});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _severityColor(severity),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        severity.toUpperCase(),
        style: TextStyle(
          color: severity == 'medium' ? Colors.black87 : Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionButton({required this.label, required this.color, required this.onTap});

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

Color _severityColor(String severity) {
  return switch (severity) {
    'critical' => const Color(0xFFe74c3c),
    'high' => const Color(0xFFe67e22),
    'medium' => const Color(0xFFf1c40f),
    'low' => const Color(0xFF555555),
    _ => const Color(0xFF555555),
  };
}
