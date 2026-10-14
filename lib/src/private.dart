import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'tree.dart';

/// Marks a part of the screen that is never in a feedback screenshot: an account number, a
/// message thread, anything the reporter's team should not see. It is painted over with a flat box
/// before the reporter is even shown the image, and the anchor picker never reads its text.
///
/// ```dart
/// OverblastPrivate(child: Text(account.iban))
/// ```
///
/// Password fields (`obscureText: true`) and fields with a card or password autofill hint are blanked
/// without it.
class OverblastPrivate extends SingleChildRenderObjectWidget {
  const OverblastPrivate({super.key, required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => RenderOverblastPrivate();
}

/// A repaint boundary of its own, so whether it is on screen can be read off the layer tree (see
/// [isPainted]).
class RenderOverblastPrivate extends RenderProxyBox {
  @override
  bool get isRepaintBoundary => true;
}

const Set<String> _sensitiveHints = {
  AutofillHints.password,
  AutofillHints.newPassword,
  AutofillHints.oneTimeCode,
  AutofillHints.creditCardNumber,
  AutofillHints.creditCardSecurityCode,
  AutofillHints.creditCardExpirationDate,
  AutofillHints.creditCardExpirationMonth,
  AutofillHints.creditCardExpirationYear,
  AutofillHints.creditCardExpirationDay,
};

/// Whether [widget] is something the screenshot always blanks and the picker never reads.
bool isSensitiveWidget(Widget widget) {
  if (widget is OverblastPrivate) return true;
  if (widget is EditableText) {
    if (widget.obscureText) return true;
    final hints = widget.autofillHints;
    if (hints != null && hints.any(_sensitiveHints.contains)) return true;
  }
  return false;
}

/// The rectangles, in [boundary]'s logical coordinates, of every sensitive widget under [root] that
/// is actually painted right now. Offstage routes, an `IndexedStack`'s hidden children and the
/// like are left out, so the blanking lands only where something private is visible.
List<Rect> sensitiveRects(Element root, RenderBox boundary) {
  final rects = <Rect>[];
  final bounds = Offset.zero & boundary.size;
  walkElements(root, (element) {
    if (!isSensitiveWidget(element.widget)) return true;
    final ro = element.findRenderObject();
    if (ro is RenderBox && isPainted(ro, boundary)) {
      final r = rectIn(ro, boundary);
      if (r != null) {
        final clipped = r.inflate(1).intersect(bounds);
        if (!clipped.isEmpty) rects.add(clipped);
      }
    }
    return false; // everything inside is covered by this one rectangle
  });
  return rects;
}
