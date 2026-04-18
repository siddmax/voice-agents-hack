import 'dart:math' as math;

import 'package:flutter/material.dart';

enum OrbState { idle, listening, thinking }

class JarvisOrb extends StatefulWidget {
  final OrbState state;
  final double amplitude;
  final double size;

  const JarvisOrb({
    super.key,
    this.state = OrbState.idle,
    this.amplitude = 0.0,
    this.size = 240,
  });

  @override
  State<JarvisOrb> createState() => _JarvisOrbState();
}

class _JarvisOrbState extends State<JarvisOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: _durationFor(widget.state),
    )..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant JarvisOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _ctrl.duration = _durationFor(widget.state);
      _ctrl
        ..reset()
        ..repeat(reverse: true);
    }
  }

  Duration _durationFor(OrbState s) {
    switch (s) {
      case OrbState.idle:
        return const Duration(milliseconds: 2400);
      case OrbState.listening:
        return const Duration(milliseconds: 900);
      case OrbState.thinking:
        return const Duration(milliseconds: 1200);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (widget.state) {
      OrbState.idle => scheme.primary.withValues(alpha: 0.55),
      OrbState.listening => scheme.tertiary,
      OrbState.thinking => scheme.secondary,
    };

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final breath = (math.sin(_ctrl.value * math.pi * 2) + 1) / 2;
        final amp = widget.state == OrbState.listening
            ? widget.amplitude.clamp(0.0, 1.0)
            : 0.0;
        final scale = 0.85 + breath * 0.12 + amp * 0.25;
        final glow = 20.0 + breath * 30 + amp * 50;

        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: widget.size * scale,
              height: widget.size * scale,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    color.withValues(alpha: 0.95),
                    color.withValues(alpha: 0.45),
                    color.withValues(alpha: 0.05),
                  ],
                  stops: const [0.0, 0.65, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.55),
                    blurRadius: glow,
                    spreadRadius: glow / 4,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
