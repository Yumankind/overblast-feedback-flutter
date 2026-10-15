import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/capture.dart' show privateFill;
import 'package:overblast_feedback/src/transport.dart' show interpretResponse;
import 'package:overblast_feedback/src/ui/redaction.dart';
import 'package:overblast_feedback/src/ui/theme.dart';

import 'helpers.dart';
import 'test_app.dart';

// The feedback window's look and layout: theme resolution, the sheet's height on small screens, the
// pick's thumbnail, the screenshot editor's covers and blurs, and the confirmation after sending.

void main() {
  late List<http.Request> requests;
  late List<http.Response> answers;
  late OverblastFeedbackController controller;

  setUp(() {
    requests = [];
    answers = [];
    controller = OverblastFeedbackController(
      feedbackKey: testKey,
      store: MemoryFeedbackStore(),
      deviceFacts: fakeFacts,
      deviceVerification: false,
      trackCrashes: false,
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/config')) return http.Response('', 404);
        requests.add(req);
        return answers.isEmpty
            ? http.Response(jsonEncode({'id': 'fbr_1', 'taskId': 't_1', 'conversationId': null}), 201)
            : answers.removeAt(0);
      }),
    );
  });

  tearDown(() => controller.dispose());

  Widget wrapped(Widget app, {FeedbackTheme? theme}) => OverblastFeedback(
    controller: controller,
    enableShake: false,
    captureDebugPrint: false,
    captureErrors: false,
    retryPendingOnStart: false,
    theme: theme,
    child: app,
  );

  /// Lets the engine finish the capture, then lets the sheet hear of it.
  Future<void> awaitCapture(WidgetTester tester) async {
    for (var i = 0; i < 30 && find.text('Private fields are blanked out.').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  group('theme', () {
    test('follows the app: its colour scheme and text theme', () {
      final app = ThemeData(colorSchemeSeed: Colors.teal, fontFamily: 'AppFont');
      final t = resolveFeedbackTheme(app: app);
      expect(t.colorScheme.primary, app.colorScheme.primary);
      expect(t.textTheme.bodyLarge?.fontFamily, 'AppFont');
      expect(t.extension<FeedbackStyle>()?.radius, FeedbackTheme.defaultRadius);
    });

    test('accent, font and radius go on top', () {
      const accent = Color(0xFF0B7A5A);
      final t = resolveFeedbackTheme(
        app: ThemeData(colorSchemeSeed: Colors.indigo),
        custom: const FeedbackTheme(accent: accent, fontFamily: 'Inter', radius: 12),
      );
      expect(t.colorScheme.primary, accent);
      expect(t.colorScheme.onPrimary, Colors.white, reason: 'a dark accent gets white text');
      expect(t.textTheme.bodyMedium?.fontFamily, 'Inter');
      expect(t.extension<FeedbackStyle>()?.radius, 12);
      final light = resolveFeedbackTheme(custom: const FeedbackTheme(accent: Color(0xFFFFE066)));
      expect(light.colorScheme.onPrimary, Colors.black);
    });

    test('no app theme: Material 3 in the system brightness', () {
      expect(resolveFeedbackTheme(brightness: Brightness.dark).brightness, Brightness.dark);
      expect(resolveFeedbackTheme().useMaterial3, isTrue);
    });

    testWidgets('above MaterialApp, the app theme below is found and used', (tester) async {
      final app = ThemeData(colorSchemeSeed: Colors.deepOrange);
      await tester.pumpWidget(wrapped(MaterialApp(theme: app, home: const CartScreen())));
      unawaited(controller.show(message: 'x'));
      await tester.pump();
      final send = tester.element(find.byKey(const ValueKey('overblast_feedback.send')));
      expect(Theme.of(send).colorScheme.primary, app.colorScheme.primary);
    });

    testWidgets('under MaterialApp (in its builder), the app theme above is used', (tester) async {
      final app = ThemeData(colorSchemeSeed: Colors.pink);
      await tester.pumpWidget(
        MaterialApp(theme: app, builder: (context, child) => wrapped(child!), home: const CartScreen()),
      );
      unawaited(controller.show(message: 'x'));
      await tester.pump();
      final send = tester.element(find.byKey(const ValueKey('overblast_feedback.send')));
      expect(Theme.of(send).colorScheme.primary, Theme.of(tester.element(find.byType(CartScreen))).colorScheme.primary);
    });

    testWidgets('the FeedbackTheme accent reaches the Send button', (tester) async {
      const accent = Color(0xFF0B7A5A);
      await tester.pumpWidget(
        wrapped(const MaterialApp(home: CartScreen()), theme: const FeedbackTheme(accent: accent)),
      );
      unawaited(controller.show(message: 'x'));
      await tester.pump();
      final material = tester.widget<Material>(
        find.descendant(of: find.byKey(const ValueKey('overblast_feedback.send')), matching: find.byType(Material)),
      );
      expect(material.color, accent);
    });
  });

  group('the sheet never exceeds the screen', () {
    Future<void> openSmall(
      WidgetTester tester, {
      required Size size,
      double textScale = 1,
      double keyboard = 0,
      bool screenshot = false,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      // An app that itself fits any screen, so an overflow can only be the window's.
      await tester.pumpWidget(
        wrapped(
          MaterialApp(
            home: Scaffold(body: ListView(children: [for (var i = 0; i < 30; i++) ListTile(title: Text('Row $i'))])),
          ),
        ),
      );
      unawaited(controller.show(message: 'Small screen'));
      await tester.pump();
      if (screenshot) {
        await awaitCapture(tester);
        await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.screenshot')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('overblast_feedback.screenshot')));
        await tester.pump();
      }
      if (keyboard > 0) {
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump();
        await tester.pump();
      }
    }

    void expectInside(WidgetTester tester, Size screen, {double keyboard = 0}) {
      expect(tester.takeException(), isNull, reason: 'no overflow');
      final sheet = tester.getRect(find.byKey(const ValueKey('overblast_feedback.sheet')));
      expect(sheet.top, greaterThanOrEqualTo(0));
      expect(sheet.bottom, lessThanOrEqualTo(screen.height - keyboard + 0.5));
      final send = tester.getRect(find.byKey(const ValueKey('overblast_feedback.send')));
      expect(send.top, greaterThanOrEqualTo(0));
      expect(send.bottom, lessThanOrEqualTo(screen.height - keyboard + 0.5), reason: 'Send above the keyboard');
    }

    testWidgets('a small phone with the screenshot preview on', (tester) async {
      await openSmall(tester, size: const Size(320, 480), screenshot: true);
      expect(find.byKey(const ValueKey('overblast_feedback.remove_screenshot')), findsOneWidget);
      expectInside(tester, const Size(320, 480));
    });

    testWidgets('a small phone at double text size', (tester) async {
      await openSmall(tester, size: const Size(320, 568), textScale: 2);
      expectInside(tester, const Size(320, 568));
    });

    testWidgets('the keyboard up: full size, Send just above it', (tester) async {
      await openSmall(tester, size: const Size(360, 640), keyboard: 260);
      expectInside(tester, const Size(360, 640), keyboard: 260);
      final bar = tester.getRect(find.byKey(const ValueKey('overblast_feedback.bar')));
      expect(bar.bottom, closeTo(640 - 260, 0.5));
    });

    testWidgets('a phone on its side with the keyboard up: everything scrolls, nothing overflows', (tester) async {
      await openSmall(tester, size: const Size(640, 320), keyboard: 200, textScale: 1.3);
      expect(tester.takeException(), isNull);
      final sheet = tester.getRect(find.byKey(const ValueKey('overblast_feedback.sheet')));
      expect(sheet.bottom, lessThanOrEqualTo(120.5));
    });

    testWidgets('dragged to full size, still within the screen', (tester) async {
      await openSmall(tester, size: const Size(360, 640));
      final half = tester.getRect(find.byKey(const ValueKey('overblast_feedback.sheet')));
      await tester.drag(find.bySemanticsLabel('Drag to resize'), const Offset(0, -500));
      await tester.pumpAndSettle();
      final full = tester.getRect(find.byKey(const ValueKey('overblast_feedback.sheet')));
      expect(full.height, greaterThan(half.height));
      expectInside(tester, const Size(360, 640));
    });
  });

  group('the pick', () {
    test('the thumbnail crop: the element with a margin, at the aspect, moved inside the screen', () {
      const surface = Size(400, 800);
      // In the middle: centred, grown to the minimum and the aspect.
      final mid = pickCropRect(const Rect.fromLTWH(180, 390, 40, 20), surface);
      expect(mid.center, const Offset(200, 400));
      expect(mid.height, 96);
      expect(mid.width, closeTo(128, 1e-9));
      // A wide element: its width plus margins, height from the aspect.
      final wide = pickCropRect(const Rect.fromLTWH(20, 100, 300, 40), surface);
      expect(wide.width, 348);
      expect(wide.height, closeTo(261, 1e-9));
      // At the corner: moved, not shrunk.
      final corner = pickCropRect(const Rect.fromLTWH(0, 0, 30, 30), surface);
      expect(corner.topLeft, Offset.zero);
      expect(corner.size, mid.size);
      final bottomRight = pickCropRect(const Rect.fromLTWH(380, 780, 20, 20), surface);
      expect(bottomRight.bottomRight, const Offset(400, 800));
      // Bigger than the screen: the screen.
      final huge = pickCropRect(const Rect.fromLTWH(0, 0, 400, 800), surface);
      expect(huge.width, lessThanOrEqualTo(400));
      expect(huge.height, lessThanOrEqualTo(800));
      expect(Offset.zero & surface, isA<Rect>().having((r) => r.contains(huge.topLeft), 'inside', isTrue));
      expect(pickCropRect(Rect.zero, Size.zero), Rect.zero);
    });

    testWidgets('confirmed, it shows a thumbnail and its label, with Change and Remove', (tester) async {
      await tester.pumpWidget(wrapped(const MaterialApp(home: CartScreen())));
      unawaited(controller.show(message: 'x'));
      await tester.pump();
      await awaitCapture(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.point')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.point')));
      await tester.pump();
      expect(find.text("Tap the part that's wrong"), findsOneWidget);
      expect(find.byKey(const ValueKey('overblast_feedback.pick_confirm')), findsNothing);
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('cart.remove'), skipOffstage: false)));
      await tester.pump();
      // Pick again clears; tap again; Use this confirms.
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.pick_again')));
      await tester.pump();
      expect(find.byKey(const ValueKey('overblast_feedback.pick_confirm')), findsNothing);
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('cart.remove'), skipOffstage: false)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.pick_confirm')));
      await tester.pump();
      expect(find.byKey(const ValueKey('overblast_feedback.pick_thumbnail')), findsOneWidget);
      expect(find.text('ElevatedButton “Remove”'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.pick_remove')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.pick_remove')));
      await tester.pump();
      expect(find.byKey(const ValueKey('overblast_feedback.selected')), findsNothing);
      expect(find.byKey(const ValueKey('overblast_feedback.point')), findsOneWidget);
    });
  });

  group('the screenshot editor', () {
    /// 100 x 100: black and white columns one pixel wide, the hardest thing to blur away.
    Future<ui.Image> stripes() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 100), Paint()..color = const Color(0xFFFFFFFF));
      for (var x = 0; x < 100; x += 2) {
        canvas.drawRect(Rect.fromLTWH(x.toDouble(), 0, 1, 100), Paint()..color = const Color(0xFF000000));
      }
      final picture = recorder.endRecording();
      return picture.toImage(100, 100);
    }

    Future<ByteData> rgba(ui.Image image) async => (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

    int at(ByteData d, int x, int y, [int channel = 0]) => d.getUint8((y * 100 + x) * 4 + channel);

    testWidgets('cover is solid, blur flattens, the rest is untouched', (tester) async {
      await tester.runAsync(() async {
        final source = await stripes();
        final out = await composeRedacted(
          source,
          pixelRatio: 1,
          redactions: const [
            FeedbackRedaction(Rect.fromLTWH(10, 10, 20, 20), FeedbackRedactionKind.cover),
            FeedbackRedaction(Rect.fromLTWH(50, 50, 40, 40), FeedbackRedactionKind.blur),
          ],
        );
        final d = await rgba(out);
        // Cover: every pixel the private colour.
        for (var y = 10; y < 30; y++) {
          for (var x = 10; x < 30; x++) {
            expect(at(d, x, y), (privateFill.r * 255).round());
            expect(at(d, x, y, 1), (privateFill.g * 255).round());
          }
        }
        // Blur: the stripes become a near-uniform grey in the middle of the region.
        var lo = 255, hi = 0;
        for (var x = 60; x < 80; x++) {
          final v = at(d, x, 70);
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
        expect(hi - lo, lessThan(40), reason: 'was 0..255 before the blur');
        expect(lo, greaterThan(60));
        // Outside both: the stripes as they were.
        expect(at(d, 2, 90), 0);
        expect(at(d, 3, 90), 255);
        source.dispose();
        out.dispose();
      });
    });

    testWidgets('a cover over a blur wins', (tester) async {
      await tester.runAsync(() async {
        final source = await stripes();
        final out = await composeRedacted(
          source,
          pixelRatio: 1,
          redactions: const [
            FeedbackRedaction(Rect.fromLTWH(0, 0, 50, 50), FeedbackRedactionKind.cover),
            FeedbackRedaction(Rect.fromLTWH(0, 0, 50, 50), FeedbackRedactionKind.blur),
          ],
        );
        final d = await rgba(out);
        expect(at(d, 25, 25), (privateFill.r * 255).round());
        source.dispose();
        out.dispose();
      });
    });

    testWidgets('draw, undo, clear, blur; the preview says what is hidden', (tester) async {
      await tester.pumpWidget(wrapped(const MaterialApp(home: CartScreen())));
      unawaited(controller.show(message: 'x'));
      await tester.pump();
      await awaitCapture(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.screenshot')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.screenshot')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.edit_screenshot')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.edit_screenshot')));
      await tester.pump();
      final canvas = find.byKey(const ValueKey('overblast_feedback.editor_canvas'));
      expect(canvas, findsOneWidget);
      final c = tester.getCenter(canvas);
      await tester.dragFrom(c - const Offset(40, 40), const Offset(80, 60));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.editor_undo')));
      await tester.pump();
      await tester.dragFrom(c - const Offset(40, 40), const Offset(80, 60));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.editor_clear')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.editor_blur')));
      await tester.pump();
      await tester.dragFrom(c - const Offset(40, 40), const Offset(80, 60));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.editor_done')));
      await tester.pump();
      expect(find.text('1 part hidden.'), findsOneWidget);
    });
  });

  group('after sending', () {
    late List<Map<Object?, Object?>> announcements;

    setUp(() {
      announcements = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
        SystemChannels.accessibility,
        (message) async {
          if (message is Map) announcements.add(message);
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
        SystemChannels.accessibility,
        null,
      );
    });

    Future<void> sendOne(WidgetTester tester) async {
      await tester.pumpWidget(wrapped(const MaterialApp(home: CartScreen())));
      unawaited(controller.show(message: 'Broken'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
    }

    final card = find.byKey(const ValueKey('overblast_feedback.done'));
    final doneButton = find.byKey(const ValueKey('overblast_feedback.done_button'));

    testWidgets('"Sent, thank you": announced, Done focused, gone by itself after 2 s', (tester) async {
      await sendOne(tester);
      expect(find.text('Sent, thank you.'), findsOneWidget);
      expect(
        announcements.where((m) => m['type'] == 'announce').map((m) => (m['data']! as Map)['message']),
        contains('Sent, thank you.'),
      );
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      expect(find.ancestor(of: find.byWidget(focused!.widget), matching: doneButton), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1800));
      expect(card, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(card, findsNothing);
      expect(find.text('Report a problem'), findsNothing);
    });

    testWidgets('known: "we already know about this one", nothing else about it, 4 s', (tester) async {
      answers.add(http.Response(jsonEncode({'id': 'fbr_2', 'taskId': 't_9', 'conversationId': null, 'known': true}), 201));
      await sendOne(tester);
      expect(find.text("Thanks. We already know about this one and we're on it."), findsOneWidget);
      expect(find.textContaining('t_9'), findsNothing);
      await tester.pump(const Duration(milliseconds: 3800));
      expect(card, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(card, findsNothing);
    });

    testWidgets('Done closes at once', (tester) async {
      await sendOne(tester);
      await tester.tap(doneButton);
      await tester.pump();
      expect(card, findsNothing);
    });

    testWidgets('a tap on the scrim closes it', (tester) async {
      await sendOne(tester);
      await tester.tapAt(const Offset(20, 20));
      await tester.pump();
      expect(card, findsNothing);
    });

    testWidgets('dragging it down closes it', (tester) async {
      await sendOne(tester);
      await tester.drag(find.text('Sent, thank you.'), const Offset(0, 80));
      await tester.pump();
      expect(card, findsNothing);
    });

    testWidgets('Back closes it', (tester) async {
      await sendOne(tester);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pump();
      expect(card, findsNothing);
    });

    testWidgets('a pointer over it holds the clock; leaving starts it again', (tester) async {
      await sendOne(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(card));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(card, findsOneWidget);
      await mouse.moveTo(const Offset(5, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2100));
      expect(card, findsNothing);
    });

    testWidgets('accessibility focus on Done holds the clock', (tester) async {
      final semantics = tester.ensureSemantics();
      await sendOne(tester);
      final owner = tester.binding.renderViews.first.owner!.semanticsOwner!;
      final node = tester.getSemantics(doneButton);
      owner.performAction(node.id, SemanticsAction.didGainAccessibilityFocus);
      await tester.pump(const Duration(seconds: 6));
      expect(card, findsOneWidget);
      owner.performAction(node.id, SemanticsAction.didLoseAccessibilityFocus);
      await tester.pump(const Duration(milliseconds: 2100));
      expect(card, findsNothing);
      semantics.dispose();
    });

    test('known is on the result, false when absent', () {
      expect(interpretResponse(201, jsonEncode({'id': 'a', 'known': true})).known, isTrue);
      expect(interpretResponse(201, jsonEncode({'id': 'a'})).known, isFalse);
      expect(interpretResponse(507, jsonEncode({'code': 'storage_full', 'known': true})).known, isTrue);
    });

    testWidgets('an error keeps the sheet open with the message', (tester) async {
      answers.add(http.Response(jsonEncode({'code': 'key_disabled', 'error': 'Feedback is paused.'}), 403));
      await sendOne(tester);
      expect(find.text('Feedback is paused.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Report a problem'), findsOneWidget);
    });
  });

  testWidgets('reduced motion: the sheet still opens at once and works', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(wrapped(const MaterialApp(home: CartScreen())));
    unawaited(controller.show(message: 'x'));
    await tester.pump();
    expect(find.byKey(const ValueKey('overblast_feedback.send')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('semantics: the sheet names its route, the pick and the screenshot are labelled', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrapped(const MaterialApp(home: CartScreen())));
    unawaited(controller.show(message: 'x'));
    await tester.pump();
    expect(find.bySemanticsLabel('Report a problem'), findsWidgets);
    expect(find.bySemanticsLabel('Drag to resize'), findsOneWidget);
    expect(find.bySemanticsLabel('Close the report'), findsOneWidget);
    handle.dispose();
  });
}
