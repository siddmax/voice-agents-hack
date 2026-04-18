import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../voice/stt.dart';
import '../voice/tts.dart';
import 'activity_feed.dart';
import 'app_settings.dart';
import 'chat_controller.dart';
import 'jarvis_orb.dart';
import 'settings_sheet.dart';

class JarvisScreen extends StatefulWidget {
  final String? startupError;
  const JarvisScreen({super.key, this.startupError});

  @override
  State<JarvisScreen> createState() => _JarvisScreenState();
}

class _JarvisScreenState extends State<JarvisScreen> {
  OrbState _orb = OrbState.idle;
  double _amplitude = 0.0;
  StreamSubscription<double>? _levelSub;
  bool _wasRunning = false;
  ChatController? _chatRef;

  @override
  void initState() {
    super.initState();
    if (widget.startupError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.startupError!),
          duration: const Duration(seconds: 6),
        ));
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final chat = context.read<ChatController>();
    if (!identical(_chatRef, chat)) {
      _chatRef?.removeListener(_onChatChanged);
      _chatRef = chat;
      chat.addListener(_onChatChanged);
    }
  }

  void _onChatChanged() {
    final chat = _chatRef;
    if (chat == null || !mounted) return;
    if (_wasRunning && !chat.running) {
      final summary = chat.consumeFinishedSummary();
      final wantsVoice = context.read<AppSettings>().voiceOutput;
      if (summary != null && wantsVoice) {
        context.read<TextToSpeechService>().speak(summary);
      }
      setState(() => _orb = OrbState.idle);
    }
    _wasRunning = chat.running;
  }

  @override
  void dispose() {
    _levelSub?.cancel();
    _chatRef?.removeListener(_onChatChanged);
    super.dispose();
  }

  Future<void> _onTap() async {
    final stt = context.read<SpeechToTextService>();
    final chat = context.read<ChatController>();

    if (chat.running) return;

    if (_orb == OrbState.listening) {
      final text = await stt.stopListening();
      await _levelSub?.cancel();
      _levelSub = null;
      if (!mounted) return;
      setState(() {
        _amplitude = 0;
        _orb = text.trim().isEmpty ? OrbState.idle : OrbState.thinking;
      });
      if (text.trim().isNotEmpty) {
        _wasRunning = true;
        await chat.send(text);
      }
      return;
    }

    _levelSub = stt.soundLevel.listen((l) {
      if (mounted) setState(() => _amplitude = l);
    });
    final messenger = ScaffoldMessenger.of(context);
    final result = await stt.startListening();
    if (!mounted) return;
    if (result == SttStartResult.started) {
      setState(() => _orb = OrbState.listening);
    } else {
      await _levelSub?.cancel();
      _levelSub = null;
      messenger.showSnackBar(SnackBar(
        content: Text(result == SttStartResult.permissionDenied
            ? 'Microphone permission denied.'
            : 'Speech recognition unavailable.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final media = MediaQuery.of(context);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                SizedBox(
                  height: media.size.height * 0.6,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _onTap,
                    child: Center(
                      child: JarvisOrb(
                        state: _orb,
                        amplitude: _amplitude,
                        size: media.size.width * 0.6,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ActivityFeed(events: chat.events),
                ),
              ],
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () => SettingsSheet.show(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
