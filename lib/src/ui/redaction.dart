import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../capture.dart' show privateFill;

/// What the reporter drew over the screenshot in the editor.
enum FeedbackRedactionKind {
  /// A solid box: nothing under it survives.
  cover,

  /// A heavy blur of the region: the layout stays readable, the text does not.
  blur,
}

/// One rectangle drawn in the screenshot editor, in the captured surface's logical pixels.
class FeedbackRedaction {
  const FeedbackRedaction(this.rect, this.kind);

  final Rect rect;
  final FeedbackRedactionKind kind;
}

/// The blur's strength in logical pixels: strong enough that body text is unreadable.
const double redactionBlurSigma = 10;

/// Paints [image] (whose pixels are [pixelRatio] times the logical size) into [canvas] at [scale]
/// canvas units per image pixel, with [redactions] applied: covers as solid boxes, blurs as the same
/// image blurred and clipped to the region. Covers are painted last, so a cover over a blur wins.
void paintRedacted(
  Canvas canvas,
  ui.Image image, {
  required double pixelRatio,
  double scale = 1,
  List<FeedbackRedaction> redactions = const [],
}) {
  final paint = Paint()..filterQuality = FilterQuality.medium;
  canvas.save();
  canvas.scale(scale);
  canvas.drawImage(image, Offset.zero, paint);
  for (final r in redactions.where((r) => r.kind == FeedbackRedactionKind.blur)) {
    final region = _toImage(r.rect, pixelRatio);
    canvas.save();
    canvas.clipRect(region);
    // A blur samples beyond its edge; clamping keeps the region's own colours at the image border.
    final sigma = redactionBlurSigma * pixelRatio;
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp),
    );
    canvas.restore();
  }
  final cover = Paint()..color = privateFill;
  for (final r in redactions.where((r) => r.kind == FeedbackRedactionKind.cover)) {
    canvas.drawRect(_toImage(r.rect, pixelRatio), cover);
  }
  canvas.restore();
}

/// A new image: [image] with [redactions] applied, at the same size.
Future<ui.Image> composeRedacted(
  ui.Image image, {
  required double pixelRatio,
  List<FeedbackRedaction> redactions = const [],
}) async {
  final recorder = ui.PictureRecorder();
  paintRedacted(Canvas(recorder), image, pixelRatio: pixelRatio, redactions: redactions);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(image.width, image.height);
  } finally {
    picture.dispose();
  }
}

/// The part of the frozen screen the pick's thumbnail shows, in logical pixels: the element's box
/// with [margin] round it, grown to at least [minSize] on each side and to [aspect] (width / height),
/// centred on the element, and moved (not shrunk) to stay inside [surface]. On a surface smaller
/// than that, the whole surface.
Rect pickCropRect(Rect element, Size surface, {double margin = 24, double minSize = 96, double aspect = 4 / 3}) {
  if (surface.isEmpty) return Rect.zero;
  var w = math.max(element.width + margin * 2, minSize);
  var h = math.max(element.height + margin * 2, minSize);
  if (w / h < aspect) {
    w = h * aspect;
  } else {
    h = w / aspect;
  }
  w = math.min(w, surface.width);
  h = math.min(h, surface.height);
  final cx = element.center.dx;
  final cy = element.center.dy;
  final left = (cx - w / 2).clamp(0.0, surface.width - w);
  final top = (cy - h / 2).clamp(0.0, surface.height - h);
  return Rect.fromLTWH(left, top, w, h);
}

Rect _toImage(Rect r, double s) => Rect.fromLTRB(r.left * s, r.top * s, r.right * s, r.bottom * s);
