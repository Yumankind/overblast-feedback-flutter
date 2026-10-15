import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/route_observer.dart' show FeedbackRouteTracker;

import 'helpers.dart';
import 'test_app.dart';

void main() {
  late List<http.Request> requests;
  late List<http.Response> answers;
  late MemoryFeedbackStore store;
  late OverblastFeedbackController controller;

  setUp(() {
    FeedbackRouteTracker.instance.reset();
    requests = [];
    answers = [];
    store = MemoryFeedbackStore();
    controller = OverblastFeedbackController(
      feedbackKey: testKey,
      store: store,
      deviceFacts: fakeFacts,
      // These tests are about the sheet. Device registration has its own (device_test.dart); left on
      // here, an unmocked platform channel never answers inside a widget test's fake clock, and Send
      // would wait out its three seconds.
      deviceVerification: false,
      // Crash tracking has its own tests (crash_test.dart).
      trackCrashes: false,
      httpClient: MockClient((req) async {
        // The config door (§2.1) answers nothing here: the defaults stand.
        if (req.url.path.endsWith('/config')) return http.Response('', 404);
        requests.add(req);
        return answers.isEmpty
            ? http.Response(jsonEncode({'id': 'fbr_1', 'taskId': 't_1', 'conversationId': null}), 201)
            : answers.removeAt(0);
      }),
    );
  });

  tearDown(() => controller.dispose());

  Widget wrapped(Widget app) => OverblastFeedback(
    controller: controller,
    enableShake: false,
    captureDebugPrint: false,
    captureErrors: false,
    retryPendingOnStart: false,
    child: app,
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The sheet opens at half height, so a control may be below the fold: scroll to it, then tap.
  Future<void> tapIn(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  testWidgets('message, point at the button, send: the body is the contract and the element is the button', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapped(MaterialApp(navigatorObservers: [OverblastFeedback.navigatorObserver], home: const CartScreen())),
    );
    controller.info('cart loaded');
    final closed = controller.show();
    await tester.pump();
    expect(find.text('Report a problem'), findsOneWidget);
    expect(find.text('Email (optional)'), findsOneWidget);
    // The screenshot is off until the reporter turns it on.
    final toggle = tester.widget<SwitchListTile>(find.byKey(const ValueKey('overblast_feedback.screenshot')));
    expect(toggle.value, isFalse);

    // Send stays disabled until there is a message.
    expect(
      tester
          .widget<FilledButton>(find.ancestor(of: find.text('Send'), matching: find.bySubtype<FilledButton>()))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const ValueKey('overblast_feedback.message')), "The total doesn't update");
    await tapIn(tester, find.text('Question'));
    await tester.pump();

    await tapIn(tester, find.byKey(const ValueKey('overblast_feedback.point')));
    await tester.pump();
    expect(find.text("Tap the part that's wrong"), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('cart.remove'))));
    await tester.pump();
    // The pick is shown on the frozen screen first; "Use this" confirms it.
    expect(find.text('ElevatedButton “Remove”'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('overblast_feedback.pick_confirm')));
    await tester.pump();
    expect(find.text('ElevatedButton “Remove”'), findsOneWidget);
    expect(find.byKey(const ValueKey('overblast_feedback.pick_change')), findsOneWidget);
    expect(find.textContaining('the selected element'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.email')));
    await tester.enterText(find.byKey(const ValueKey('overblast_feedback.email')), 'ana@example.com');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
    await settle(tester);

    expect(requests.length, 1);
    final req = requests.single;
    expect(req.headers['X-Overblast-Feedback-Key'], testKey);
    final body = jsonDecode(req.body) as Map<String, Object?>;
    expect(body.keys.toSet().difference(topKeys), isEmpty);
    expect(body.containsKey('screenshot'), isFalse);
    expect(body['message'], "The total doesn't update");
    expect(body['category'], 'question');
    expect(body['reporter'], {'email': 'ana@example.com'});
    final context = body['context']! as Map;
    expect(context.keys.toSet().difference(contextKeys), isEmpty);
    expect(context['platform'], 'flutter');
    expect(context['trigger'], 'button');
    expect(context['openedAt'], isA<int>());
    expect(context['screen'], '/');
    expect(context['viewport'], {'w': 800, 'h': 600, 'dpr': 3.0});
    final element = body['element']! as Map;
    expect(element.keys.toSet().difference(nativeElementKeys), isEmpty);
    expect(element['type'], 'ElevatedButton');
    expect(element['id'], 'cart.remove');
    expect(element['label'], 'Remove');
    expect((element['path']! as List).last, 'ElevatedButton');
    expect((body['logs']! as List).first, containsPair('msg', 'cart loaded'));

    expect(find.text('Sent, thank you.'), findsOneWidget);
    // It goes by itself.
    await tester.pump(const Duration(milliseconds: 2100));
    expect(find.text('Sent, thank you.'), findsNothing);
    expect(find.text('Report a problem'), findsNothing);
    await closed;
  });

  testWidgets('with the screenshot on: a PNG with the element drawn on it, private parts blanked', (tester) async {
    await tester.pumpWidget(wrapped(const MaterialApp(home: CartScreen())));
    unawaited(controller.show(message: 'Wrong total'));
    await tester.pump();
    // The capture runs on the engine; give it real time, then let the sheet hear of it.
    for (var i = 0; i < 20 && find.text('Private fields are blanked out.').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.text('Private fields are blanked out.'), findsOneWidget);

    await tapIn(tester, find.byKey(const ValueKey('overblast_feedback.point')));
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('cart.remove'), skipOffstage: false)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('overblast_feedback.pick_confirm')));
    await tester.pump();
    await tapIn(tester, find.byKey(const ValueKey('overblast_feedback.screenshot')));
    await tester.pump();
    expect(find.byKey(const ValueKey('overblast_feedback.remove_screenshot')), findsOneWidget);
    expect(find.textContaining('the screenshot'), findsOneWidget);

    // The thumbnail makes the sheet taller than the test screen.
    await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.send')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
    for (var i = 0; i < 300 && requests.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('overblast_feedback.error')), findsNothing);
    await settle(tester);
    final body = jsonDecode(requests.single.body) as Map<String, Object?>;
    final shot = body['screenshot']! as Map;
    expect(shot.keys.toSet(), screenshotKeys);
    expect(shot['contentType'], 'image/png');
    expect(shot['highlighted'], true);
    final png = base64Decode(shot['base64']! as String);
    expect(png.sublist(1, 4), 'PNG'.codeUnits);
    expect((body['element']! as Map)['id'], 'cart.remove');
    expect(find.text('Sent, thank you.'), findsOneWidget);
  });

  testWidgets('removing the screenshot sends none', (tester) async {
    await tester.pumpWidget(wrapped(const MaterialApp(home: CartScreen())));
    unawaited(controller.show(message: 'x'));
    await tester.pump();
    for (var i = 0; i < 20 && find.text('Private fields are blanked out.').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tapIn(tester, find.byKey(const ValueKey('overblast_feedback.screenshot')));
    await tester.pump();
    await tapIn(tester, find.byKey(const ValueKey('overblast_feedback.remove_screenshot')));
    await tester.pump();
    expect(find.byKey(const ValueKey('overblast_feedback.remove_screenshot')), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.send')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
    await settle(tester);
    expect(jsonDecode(requests.single.body).containsKey('screenshot'), isFalse);
  });

  testWidgets('a 429 keeps the report and says so, once', (tester) async {
    answers.add(
      http.Response(
        jsonEncode({'code': 'rate_limited', 'retryAfter': 3600, 'error': 'Too many reports from this device for now.'}),
        429,
      ),
    );
    controller.setReporter(email: 'ana@example.com');
    await tester.pumpWidget(wrapped(const MaterialApp(home: CartScreen())));
    unawaited(controller.show());
    await tester.pump();
    // The app already knows the email: no field.
    expect(find.text('Email (optional)'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('overblast_feedback.message')), 'Broken');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
    await settle(tester);

    expect(requests.length, 1);
    expect(find.text('Too many reports from this device for now.'), findsOneWidget);
    expect(find.text('It is saved on this device and will be sent later.'), findsOneWidget);
    final pending = await store.loadPending();
    expect(pending.single.body['message'], 'Broken');
    expect((pending.single.body['reporter']! as Map)['email'], 'ana@example.com');
    await settle(tester);
    expect(requests.length, 1); // never retried on its own
  });

  testWidgets('a refusal shows the worker sentence and keeps the sheet open', (tester) async {
    answers.add(http.Response(jsonEncode({'code': 'key_disabled', 'error': 'Feedback is paused for this app.'}), 403));
    await tester.pumpWidget(wrapped(const MaterialApp(home: CartScreen())));
    unawaited(controller.show(message: 'Prefilled'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
    await settle(tester);
    expect(find.text('Feedback is paused for this app.'), findsOneWidget);
    expect(find.text('Report a problem'), findsOneWidget);
    expect(await store.loadPending(), isEmpty);
  });

  testWidgets('an invalid email is caught before sending', (tester) async {
    await tester.pumpWidget(wrapped(const MaterialApp(home: CartScreen())));
    unawaited(controller.show(message: 'x'));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('overblast_feedback.email')));
    await tester.enterText(find.byKey(const ValueKey('overblast_feedback.email')), 'ana@');
    await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
    await settle(tester);
    expect(requests, isEmpty);
    expect(find.textContaining('email address does not look right'), findsOneWidget);
  });

  testWidgets('inside MaterialApp.builder, reached with OverblastFeedback.of(context)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => wrapped(child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(onPressed: () => OverblastFeedback.of(context).show(), child: const Text('Feedback')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Feedback'));
    await tester.pump();
    expect(find.text('Report a problem'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('overblast_feedback.message')), 'From the builder');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
    await settle(tester);
    expect(find.text('Sent, thank you.'), findsOneWidget);
    expect(jsonDecode(requests.single.body)['message'], 'From the builder');
  });

  testWidgets('the back button closes the sheet, not the page beneath', (tester) async {
    await tester.pumpWidget(wrapped(const MaterialApp(home: CartScreen())));
    unawaited(controller.show());
    await tester.pump();
    final handled = await tester.binding.handlePopRoute();
    await tester.pump();
    expect(handled, isTrue);
    expect(find.text('Report a problem'), findsNothing);
    expect(find.text('Your cart'), findsOneWidget);
  });

  testWidgets('of() without the widget fails by name', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      Builder(
        builder: (c) {
          ctx = c;
          return const SizedBox();
        },
      ),
    );
    expect(() => OverblastFeedback.of(ctx), throwsFlutterError);
    expect(OverblastFeedback.maybeOf(ctx), isNull);
  });
}
