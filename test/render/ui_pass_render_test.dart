// Renders of the feedback window, for looking at, not for asserting: each scene is written as a PNG.
//
//   flutter test test/render/ui_pass_render_test.dart \
//     --dart-define=OBF_RENDER_DIR=/path/to/out \
//     --dart-define=OBF_FONTS_DIR=$FLUTTER_ROOT/bin/cache/artifacts/material_fonts
//
// Without OBF_RENDER_DIR every test here is skipped, so `flutter test` writes nothing. The fonts
// directory is Flutter's own copy of Roboto and Material Icons; without it, text renders as the test
// font's boxes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/ui/crash_offer.dart';
import 'package:overblast_feedback/src/ui/error_prompt.dart';
import 'package:overblast_feedback/src/ui/theme.dart';

import '../helpers.dart';

const String outDir = String.fromEnvironment('OBF_RENDER_DIR');
const String fontsDir = String.fromEnvironment('OBF_FONTS_DIR');
final bool skip = outDir.isEmpty;

Future<void> loadFonts() async {
  if (fontsDir.isEmpty) return;
  Future<ByteData> read(String name) async => ByteData.sublistView(await File('$fontsDir/$name').readAsBytes());
  final roboto = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    if (File('$fontsDir/$f').existsSync()) roboto.addFont(read(f));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(read('MaterialIcons-Regular.otf'));
  await icons.load();
}

/// A small shop screen to report on.
class DemoShop extends StatelessWidget {
  const DemoShop({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your cart')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final (name, price) in [('Blue mug', '12.00'), ('Linen apron', '28.00'), ('Tea towel', '9.50')])
            Card(
              child: ListTile(
                leading: const Icon(Icons.shopping_bag_outlined),
                title: Text(name),
                subtitle: const Text('Qty 1'),
                trailing: Text(price, style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
          const SizedBox(height: 16),
          const OverblastPrivate(
            child: ListTile(title: Text('Card ending 4242'), subtitle: Text('Visa')),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: Text('Total', style: Theme.of(context).textTheme.titleLarge)),
              Text('49.50', style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(key: const ValueKey('demo.checkout'), onPressed: () {}, child: const Text('Checkout')),
        ],
      ),
    );
  }
}

void main() {
  final root = GlobalKey();
  late OverblastFeedbackController controller;
  late List<http.Response> answers;

  setUpAll(loadFonts);

  setUp(() {
    answers = [];
    controller = OverblastFeedbackController(
      feedbackKey: testKey,
      store: MemoryFeedbackStore(),
      deviceFacts: fakeFacts,
      deviceVerification: false,
      trackCrashes: false,
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/config')) return http.Response('', 404);
        return answers.isEmpty
            ? http.Response(jsonEncode({'id': 'fbr_1', 'taskId': 't', 'conversationId': null}), 201)
            : answers.removeAt(0);
      }),
    );
  });

  tearDown(() => controller.dispose());

  Future<void> phone(WidgetTester tester, {Size size = const Size(390, 844), double dpr = 2, double text = 1}) async {
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = FakeViewPadding(top: 47 * dpr, bottom: 34 * dpr);
    tester.view.viewPadding = FakeViewPadding(top: 47 * dpr, bottom: 34 * dpr);
    tester.platformDispatcher.textScaleFactorTestValue = text;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Future<void> app(WidgetTester tester, {ThemeData? theme, FeedbackTheme? feedbackTheme}) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: root,
        child: OverblastFeedback(
          controller: controller,
          enableShake: false,
          captureDebugPrint: false,
          captureErrors: false,
          retryPendingOnStart: false,
          theme: feedbackTheme,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme ?? ThemeData(colorSchemeSeed: const Color(0xFF0B7A5A), fontFamily: 'Roboto'),
            home: const DemoShop(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> captured(WidgetTester tester) async {
    for (var i = 0; i < 40 && find.text('Private fields are blanked out.').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.pump(const Duration(milliseconds: 300)); // let switches and fades finish
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(root));
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('$outDir/$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<void> pick(WidgetTester tester, {bool confirm = true}) async {
    await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.point')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('overblast_feedback.point')));
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('demo.checkout'), skipOffstage: false)));
    await tester.pump();
    if (confirm) {
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.pick_confirm')));
      await tester.pump();
    }
  }

  const message = 'The total does not update when I remove the tea towel. It still says 49.50.';

  testWidgets('01 sheet, half height', skip: skip, (tester) async {
    debugDisableShadows = false; // real shadows in the renders; flutter_test draws black outlines otherwise
    try {
      await phone(tester);
      await app(tester);
      unawaited(controller.show(message: message));
      await tester.pump();
      await captured(tester);
      await shoot(tester, '01-sheet-half');
    } finally {
      debugDisableShadows = true;
    }
  });

  testWidgets('02 sheet, keyboard up', skip: skip, (tester) async {
    debugDisableShadows = false; // real shadows in the renders; flutter_test draws black outlines otherwise
    try {
      await phone(tester);
      await app(tester);
      unawaited(controller.show(message: message));
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 336 * 2);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await tester.pump();
      await shoot(tester, '02-sheet-keyboard');
    } finally {
      debugDisableShadows = true;
    }
  });

  testWidgets('03 picking, before and after the tap', skip: skip, (tester) async {
    debugDisableShadows = false; // real shadows in the renders; flutter_test draws black outlines otherwise
    try {
      await phone(tester);
      await app(tester);
      unawaited(controller.show(message: message));
      await tester.pump();
      await captured(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.point')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.point')));
      await tester.pump();
      await shoot(tester, '03a-picker-hint');
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('demo.checkout'), skipOffstage: false)));
      await tester.pump();
      await shoot(tester, '03b-picker-confirm');
    } finally {
      debugDisableShadows = true;
    }
  });

  testWidgets('04 sheet with the pick and the screenshot, full height', skip: skip, (tester) async {
    debugDisableShadows = false; // real shadows in the renders; flutter_test draws black outlines otherwise
    try {
      await phone(tester);
      await app(tester);
      unawaited(controller.show(message: message));
      await tester.pump();
      await captured(tester);
      await pick(tester);
      await tester.drag(find.bySemanticsLabel('Drag to resize'), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.screenshot')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.screenshot')));
      await tester.pump();
      await tester.drag(find.byKey(const ValueKey('overblast_feedback.body')), const Offset(0, -260));
      await tester.pump();
      await shoot(tester, '04-sheet-pick-and-screenshot');
    } finally {
      debugDisableShadows = true;
    }
  });

  testWidgets('05 screenshot editor', skip: skip, (tester) async {
    debugDisableShadows = false; // real shadows in the renders; flutter_test draws black outlines otherwise
    try {
      await phone(tester);
      await app(tester);
      unawaited(controller.show(message: message));
      await tester.pump();
      await captured(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.screenshot')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.screenshot')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.edit_screenshot')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.edit_screenshot')));
      await tester.pump();
      final canvas = tester.getRect(find.byKey(const ValueKey('overblast_feedback.editor_canvas')));
      await tester.dragFrom(canvas.topLeft + Offset(canvas.width * 0.25, canvas.height * 0.12), const Offset(140, 50));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.editor_blur')));
      await tester.pump();
      await tester.dragFrom(canvas.topLeft + Offset(canvas.width * 0.2, canvas.height * 0.3), const Offset(200, 70));
      await tester.pump();
      await shoot(tester, '05-screenshot-editor');
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.editor_done')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.edit_screenshot')));
      await tester.pump();
      await shoot(tester, '05b-screenshot-preview-redacted');
    } finally {
      debugDisableShadows = true;
    }
  });

  testWidgets('06 sent, and already known', skip: skip, (tester) async {
    debugDisableShadows = false; // real shadows in the renders; flutter_test draws black outlines otherwise
    try {
      await phone(tester);
      await app(tester);
      unawaited(controller.show(message: message));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      await shoot(tester, '06a-sent');
      await tester.pump(const Duration(seconds: 2));
      answers.add(http.Response(jsonEncode({'id': 'fbr_2', 'taskId': 't', 'known': true}), 201));
      unawaited(controller.show(message: message));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      await shoot(tester, '06b-known');
      await tester.pump(const Duration(seconds: 2));
    } finally {
      debugDisableShadows = true;
    }
  });

  testWidgets('07 dark app, custom accent and radius', skip: skip, (tester) async {
    debugDisableShadows = false; // real shadows in the renders; flutter_test draws black outlines otherwise
    try {
      await phone(tester);
      await app(
        tester,
        theme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: Colors.indigo, fontFamily: 'Roboto'),
        feedbackTheme: const FeedbackTheme(accent: Color(0xFFFFB020), radius: 12),
      );
      unawaited(controller.show(message: message, category: FeedbackCategory.idea));
      await tester.pump();
      await captured(tester);
      await shoot(tester, '07-dark-accent');
    } finally {
      debugDisableShadows = true;
    }
  });

  testWidgets('08 small phone, large text', skip: skip, (tester) async {
    debugDisableShadows = false; // real shadows in the renders; flutter_test draws black outlines otherwise
    try {
      await phone(tester, size: const Size(320, 568), text: 1.6);
      await app(tester);
      unawaited(controller.show(message: message));
      await tester.pump();
      await captured(tester);
      expect(tester.takeException(), isNull);
      await shoot(tester, '08-small-phone-large-text');
    } finally {
      debugDisableShadows = true;
    }
  });

  for (final (name, crash) in [('09a-error-prompt', false), ('09b-crash-card', true)]) {
    testWidgets('09 $name', skip: skip, (tester) async {
      debugDisableShadows = false; // real shadows in the renders; flutter_test draws black outlines otherwise
      try {
        // The pill and the card as the widget draws them over the app.
        await phone(tester);
        final theme = resolveFeedbackTheme(
          app: ThemeData(colorSchemeSeed: const Color(0xFF0B7A5A), fontFamily: 'Roboto'),
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: root,
            child: Stack(
              textDirection: TextDirection.ltr,
              children: [
                MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: ThemeData(colorSchemeSeed: const Color(0xFF0B7A5A), fontFamily: 'Roboto'),
                  home: const DemoShop(),
                ),
                Positioned.fill(
                  child: crash
                      ? FeedbackCrashOffer(theme: theme, onSend: () {}, onDismiss: () {})
                      : FeedbackErrorPrompt(theme: theme, onReport: () {}, onClose: () {}, onTimeout: () {}),
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await shoot(tester, name);
      } finally {
        debugDisableShadows = true;
      }
    });
  }
}
