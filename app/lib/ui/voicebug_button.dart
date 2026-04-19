import 'package:flutter/material.dart';

class VoiceBugButton extends StatelessWidget {
  final VoidCallback onTap;

  const VoiceBugButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 24,
      right: 24,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFe74c3c),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFe74c3c).withValues(alpha: 0.4),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Center(
            child: Text('\u{1F41B}', style: TextStyle(fontSize: 24)),
          ),
        ),
      ),
    );
  }
}
