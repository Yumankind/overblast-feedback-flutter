import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overblast_feedback/src/ui/balanced_text.dart';

// The width search behind BalancedText. The test font draws every character as a square of the font
// size, so widths here are exact: at size 10, "abc def" is 70 wide.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const style = TextStyle(fontSize: 10, fontFamily: 'FlutterTest', height: 1);

  List<double> lineWidths(String text, double width) {
    final p = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)
      ..layout(maxWidth: width);
    final widths = [for (final l in p.computeLineMetrics()) l.width];
    p.dispose();
    return widths;
  }

  const known = "Thanks. We already know about this one and we're on it.";

  test('two lines come out about the same length', () {
    // At 520 the sentence breaks as a full line and a lonely "it.".
    expect(lineWidths(known, 520), [510, 30]);
    final w = balancedWidth(known, style: style, maxWidth: 520);
    final lines = lineWidths(known, w);
    expect(lines.length, 2);
    final ratio = lines.reduce((a, b) => a < b ? a : b) / lines.reduce((a, b) => a > b ? a : b);
    expect(ratio, greaterThan(0.8), reason: 'within about 20%: $lines');
  });

  test('never adds a line, and it is the narrowest width that does not', () {
    for (final maxWidth in [200.0, 260.0, 333.0, 520.0]) {
      final before = lineWidths(known, maxWidth).length;
      final w = balancedWidth(known, style: style, maxWidth: maxWidth);
      expect(w, lessThanOrEqualTo(maxWidth));
      expect(lineWidths(known, w).length, before, reason: 'at $maxWidth');
      expect(lineWidths(known, w - 2).length, greaterThan(before), reason: 'two pixels narrower adds a line');
    }
  });

  test('one line stays one line, at its own width; unbounded is the natural width', () {
    expect(balancedWidth('Sent, thank you.', style: style, maxWidth: 400), 160);
    expect(balancedWidth('Sent, thank you.', style: style, maxWidth: double.infinity), 160);
  });

  test('a word longer than the width does not loop or overflow the width', () {
    final w = balancedWidth('supercalifragilistic word', style: style, maxWidth: 100);
    expect(w, lessThanOrEqualTo(100));
  });

  testWidgets('the widget lays the text out at the balanced width and stays centred', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 520,
            child: BalancedText(known, style: style, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
    final text = tester.getRect(find.text(known));
    expect(text.width, lessThan(520));
    expect(text.center.dx, closeTo(400, 1));
    expect(text.height, 20, reason: 'still two lines of 10');
  });
}
