import 'package:flutter/widgets.dart';

/// Text whose lines come out about the same length: "Thanks. We already know about this one / and
/// we're on it." rather than a full line and a lonely "it.".
///
/// It lays the text out once at the width available to count the lines, then finds by binary search
/// the narrowest width that still gives that many lines, and lays the text out at that width. One
/// line stays one line; nothing ever gains a line.
class BalancedText extends StatelessWidget {
  const BalancedText(this.data, {super.key, this.style, this.textAlign = TextAlign.start, this.maxLines});

  final String data;
  final TextStyle? style;
  final TextAlign textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(this.style);
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    final scaler = MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = balancedWidth(
          data,
          style: style,
          maxWidth: constraints.maxWidth,
          textDirection: direction,
          textScaler: scaler,
        );
        // In a tight slot (Expanded) the box fills it and the text sits by [textAlign]; in a loose one
        // (Flexible) it shrinks to the balanced width.
        return Align(
          alignment: switch (textAlign) {
            TextAlign.center => Alignment.center,
            TextAlign.right || TextAlign.end => AlignmentDirectional.centerEnd,
            _ => AlignmentDirectional.centerStart,
          },
          widthFactor: 1,
          child: SizedBox(
            width: width,
            child: Text(data, style: this.style, textAlign: textAlign, maxLines: maxLines),
          ),
        );
      },
    );
  }
}

/// The narrowest width, at most [maxWidth], at which [text] takes no more lines than it does at
/// [maxWidth]. With an unbounded [maxWidth], the text's natural one-line width.
double balancedWidth(
  String text, {
  required TextStyle style,
  required double maxWidth,
  TextDirection textDirection = TextDirection.ltr,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: textDirection,
    textScaler: textScaler,
  );
  try {
    int linesAt(double w) {
      painter.layout(maxWidth: w);
      return painter.computeLineMetrics().length;
    }

    if (!maxWidth.isFinite) {
      painter.layout();
      return painter.width;
    }
    final lines = linesAt(maxWidth);
    if (lines <= 1) {
      painter.layout(maxWidth: maxWidth);
      return painter.width.ceilToDouble().clamp(0, maxWidth);
    }
    var lo = 0.0;
    var hi = maxWidth;
    // Half a pixel is as close as it matters.
    while (hi - lo > 0.5) {
      final mid = (lo + hi) / 2;
      if (linesAt(mid) <= lines) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    // The text at that width can be a hair narrower than the box; give it a pixel so rounding never
    // pushes a word onto a new line.
    return (hi + 1).clamp(0, maxWidth);
  } finally {
    painter.dispose();
  }
}
