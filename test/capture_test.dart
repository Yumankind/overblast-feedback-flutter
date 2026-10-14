import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/capture.dart' show privateFill;

import 'test_app.dart';

Color pixel(ByteData rgba, int width, Offset logical, double ratio) {
  final x = (logical.dx * ratio).round();
  final y = (logical.dy * ratio).round();
  final i = (y * width + x) * 4;
  return Color.fromARGB(rgba.getUint8(i + 3), rgba.getUint8(i), rgba.getUint8(i + 1), rgba.getUint8(i + 2));
}

void main() {
  testWidgets('private regions and password fields are painted over; the rest is the app', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: const MaterialApp(home: CartScreen()),
      ),
    );
    final iban = tester.getCenter(find.byKey(const ValueKey('iban')));
    final password = tester.getCenter(find.byKey(const ValueKey('password')));
    final button = tester.getCenter(find.byKey(const ValueKey('cart.remove')));

    await tester.runAsync(() async {
      final element = key.currentContext! as Element;
      final capture = await FeedbackCapture.take(
        element.findRenderObject()! as RenderRepaintBoundary,
        element,
        devicePixelRatio: 1.5,
      );
      expect(capture.pixelRatio, 1.5);
      expect(capture.logicalSize, const Size(800, 600));
      expect(capture.image.width, 1200);
      expect(capture.blankedRects.length, 2);
      final rgba = (await capture.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      expect(pixel(rgba, capture.image.width, iban, 1.5), privateFill);
      expect(pixel(rgba, capture.image.width, password, 1.5), privateFill);
      expect(pixel(rgba, capture.image.width, button, 1.5), isNot(privateFill));

      final png = (await capture.encodePng(highlight: tester.getRect(find.byKey(const ValueKey('cart.remove')))))!;
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(png.length, lessThanOrEqualTo(FeedbackLimits.screenshotBytes));

      // Over the byte budget, it is made smaller until it fits.
      final small = (await capture.encodePng(maxBytes: png.length ~/ 2))!;
      expect(small.length, lessThanOrEqualTo(png.length ~/ 2));
      capture.dispose();
      expect(await capture.encodePng(), isNull);
    });
  });

  testWidgets('the long side is held to 2400 physical pixels', (tester) async {
    tester.view.physicalSize = const Size(1290, 2796);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: const MaterialApp(home: CartScreen()),
      ),
    );
    await tester.runAsync(() async {
      final element = key.currentContext! as Element;
      final capture = await FeedbackCapture.take(
        element.findRenderObject()! as RenderRepaintBoundary,
        element,
        devicePixelRatio: 3,
      );
      expect(capture.image.height, lessThanOrEqualTo(2400));
      expect(capture.image.height, greaterThanOrEqualTo(2399));
      capture.dispose();
    });
  });
}
