import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class ScreenshotCapture {
  GlobalKey? _boundaryKey;

  void attach(GlobalKey key) => _boundaryKey = key;

  Future<Uint8List?> capture() async {
    final key = _boundaryKey;
    if (key == null) return null;
    final boundary =
        key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    try {
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
