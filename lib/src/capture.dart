import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'payload.dart';
import 'private.dart';
import 'ui/redaction.dart';

/// The colour private regions are painted with.
const Color privateFill = Color(0xFF26282B);

/// The colour the selected element's box is drawn in.
const Color highlightColor = Color(0xFFFF3B30);

/// A frozen image of the app, private regions already painted over. Taken when the sheet opens,
/// shown to the reporter, and encoded only if they choose to attach it.
class FeedbackCapture {
  FeedbackCapture._(this.image, this.pixelRatio, this.logicalSize, this.blankedRects);

  /// The image, private regions blanked.
  final ui.Image image;

  /// Physical pixels per logical pixel in [image].
  final double pixelRatio;

  /// The captured surface's size in logical pixels: the same coordinates the anchor's rect uses.
  final Size logicalSize;

  /// The regions painted over, in logical pixels.
  final List<Rect> blankedRects;

  bool _disposed = false;

  /// Captures [boundary] (whose element is [root]) at no more than [devicePixelRatio], and no more
  /// than [maxLongSide] physical pixels on its long side.
  static Future<FeedbackCapture> take(
    RenderRepaintBoundary boundary,
    Element root, {
    required double devicePixelRatio,
    int maxLongSide = 2400,
  }) async {
    if (kDebugMode && boundary.debugNeedsPaint) await SchedulerBinding.instance.endOfFrame;
    final size = boundary.size;
    final longSide = math.max(size.width, size.height);
    final ratio = longSide <= 0 ? 1.0 : math.min(devicePixelRatio, maxLongSide / longSide);
    // Both read in the same synchronous turn: toImage composes its scene before its first await, so
    // the rectangles describe exactly the frame in the image.
    final rects = sensitiveRects(root, boundary);
    final raw = await boundary.toImage(pixelRatio: ratio);
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImage(raw, Offset.zero, Paint());
      final fill = Paint()..color = privateFill;
      for (final r in rects) {
        canvas.drawRect(_scale(r, ratio), fill);
      }
      final picture = recorder.endRecording();
      final blanked = await picture.toImage(raw.width, raw.height);
      picture.dispose();
      return FeedbackCapture._(blanked, ratio, size, rects);
    } finally {
      raw.dispose();
    }
  }

  /// PNG bytes of the image, with the reporter's [redactions] applied (covers and blurs from the
  /// editor) and [highlight] (logical pixels) drawn on it when given, made smaller until it fits
  /// [maxBytes]. Null if it cannot be made to fit.
  ///
  /// PNG, not JPEG: Flutter encodes PNG without a dependency, and a screen of flat interface colours
  /// compresses well in it.
  Future<Uint8List?> encodePng({
    Rect? highlight,
    List<FeedbackRedaction> redactions = const [],
    int maxBytes = FeedbackLimits.screenshotBytes,
  }) async {
    if (_disposed) return null;
    var scale = 1.0;
    for (var attempt = 0; attempt < 5; attempt++) {
      final w = math.max(1, (image.width * scale).round());
      final h = math.max(1, (image.height * scale).round());
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      paintRedacted(canvas, image, pixelRatio: pixelRatio, scale: scale, redactions: redactions);
      canvas.scale(scale);
      if (highlight != null) paintHighlight(canvas, _scale(highlight, pixelRatio), pixelRatio);
      final picture = recorder.endRecording();
      final out = await picture.toImage(w, h);
      picture.dispose();
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      out.dispose();
      if (data == null) return null;
      if (data.lengthInBytes <= maxBytes) return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      scale *= 0.7;
    }
    return null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    image.dispose();
  }
}

/// Draws the selected element's box: a translucent fill and a solid outline.
void paintHighlight(Canvas canvas, Rect rect, double pixelRatio) {
  canvas.drawRect(rect, Paint()..color = highlightColor.withValues(alpha: 0.12));
  canvas.drawRect(
    rect.deflate(pixelRatio),
    Paint()
      ..color = highlightColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.0, 2.5 * pixelRatio),
  );
}

Rect _scale(Rect r, double s) => Rect.fromLTRB(r.left * s, r.top * s, r.right * s, r.bottom * s);
