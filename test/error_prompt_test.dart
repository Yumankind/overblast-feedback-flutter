import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/ui/error_prompt.dart';

import 'helpers.dart';

// The error prompt (docs/feedback-reports.md §3.6): when it may show, how often, and the pill.

const int start = 1760500000000;
const int hour = 3600000;

/// One session's gate on fake time, with a store that outlives it.
class Harness {
  Harness(this.async, this.store, {int startedAt = start, this.kinds = const {FeedbackErrorKind.exception}}) {
    origin = startedAt - async.elapsed.inMilliseconds;
    gate = ErrorPromptGate(
      now: () => origin + async.elapsed.inMilliseconds,
      startedAt: startedAt,
      store: store,
      enabledFor: kinds.contains,
      minHoursBetween: () => 24,
      blocked: () => blocked,
      show: () {
        shows++;
        pending = Completer();
        return pending!.future;
      },
      log: lines.add,
      onReport: reports.add,
    );
  }

  final FakeAsync async;
  final MemoryFeedbackStore store;
  final Set<FeedbackErrorKind> kinds;
  late final int origin;
  late final ErrorPromptGate gate;
  bool blocked = false;
  int shows = 0;
  Completer<(ErrorPromptOutcome, int)>? pending;
  final List<String> lines = [];
  final List<int> reports = [];

  int get now => origin + async.elapsed.inMilliseconds;

  void answer(ErrorPromptOutcome outcome) {
    pending!.complete((outcome, now));
    pending = null;
    async.flushMicrotasks();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('when it may appear', () {
    test('not before ten seconds after start', () {
      fakeAsync((async) {
        final h = Harness(async, MemoryFeedbackStore());
        async.elapse(const Duration(seconds: 2));
        h.gate.notice(FeedbackErrorKind.exception);
        async.elapse(const Duration(milliseconds: 7900));
        expect(h.shows, 0);
        async.elapse(const Duration(milliseconds: 200));
        expect(h.shows, 1);
        expect(h.lines, ['error prompt shown']);
      });
    });

    test('two errors a second apart are one prompt, and one a session', () {
      fakeAsync((async) {
        final h = Harness(async, MemoryFeedbackStore());
        async.elapse(const Duration(seconds: 20));
        h.gate.notice(FeedbackErrorKind.exception);
        async.elapse(const Duration(milliseconds: 500));
        h.gate.notice(FeedbackErrorKind.exception);
        async.elapse(const Duration(seconds: 2));
        expect(h.shows, 1);
        h.answer(ErrorPromptOutcome.timedOut);
        h.gate.notice(FeedbackErrorKind.exception);
        async.elapse(const Duration(minutes: 5));
        expect(h.shows, 1);
      });
    });

    test('only the kinds the key lists', () {
      fakeAsync((async) {
        final h = Harness(async, MemoryFeedbackStore());
        async.elapse(const Duration(seconds: 20));
        h.gate.notice(FeedbackErrorKind.serverError);
        h.gate.notice(FeedbackErrorKind.network);
        async.elapse(const Duration(seconds: 5));
        expect(h.shows, 0);
      });
    });

    test('while blocked (typing, the sheet, the background) it waits up to 30 s, then gives up', () {
      fakeAsync((async) {
        final h = Harness(async, MemoryFeedbackStore());
        async.elapse(const Duration(seconds: 20));
        h.blocked = true;
        h.gate.notice(FeedbackErrorKind.exception);
        async.elapse(const Duration(seconds: 20));
        expect(h.shows, 0);
        h.blocked = false;
        async.elapse(const Duration(seconds: 1));
        expect(h.shows, 1, reason: 'shown once the typing stopped');
      });
      fakeAsync((async) {
        final h = Harness(async, MemoryFeedbackStore());
        async.elapse(const Duration(seconds: 20));
        h.blocked = true;
        h.gate.notice(FeedbackErrorKind.exception);
        async.elapse(const Duration(seconds: 32));
        h.blocked = false;
        async.elapse(const Duration(seconds: 5));
        expect(h.shows, 0, reason: 'gave up after 30 s');
        h.gate.notice(FeedbackErrorKind.exception);
        async.elapse(const Duration(seconds: 2));
        expect(h.shows, 1, reason: 'a later error may try again');
      });
    });
  });

  group('how often', () {
    test('at most once per minHoursBetween on the device', () {
      final store = MemoryFeedbackStore();
      fakeAsync((async) {
        final first = Harness(async, store);
        async.elapse(const Duration(seconds: 20));
        first.gate.notice(FeedbackErrorKind.exception);
        async.elapse(const Duration(seconds: 2));
        first.answer(ErrorPromptOutcome.timedOut);
        expect(first.lines.last, 'error prompt went by itself');

        async.elapse(const Duration(hours: 2));
        final second = Harness(async, store, startedAt: first.now);
        async.elapse(const Duration(seconds: 20));
        second.gate.notice(FeedbackErrorKind.exception);
        async.elapse(const Duration(seconds: 2));
        expect(second.shows, 0);

        async.elapse(const Duration(hours: 23));
        final third = Harness(async, store, startedAt: second.now);
        async.elapse(const Duration(seconds: 20));
        third.gate.notice(FeedbackErrorKind.exception);
        async.elapse(const Duration(seconds: 2));
        expect(third.shows, 1);
      });
    });

    test('two closes without reporting: not again for seven days; going by itself is not a close', () {
      final store = MemoryFeedbackStore();
      fakeAsync((async) {
        void session(ErrorPromptOutcome outcome, {required int expectShows}) {
          final h = Harness(async, store, startedAt: start + async.elapsed.inMilliseconds);
          async.elapse(const Duration(seconds: 20));
          h.gate.notice(FeedbackErrorKind.exception);
          async.elapse(const Duration(seconds: 2));
          expect(h.shows, expectShows);
          if (h.pending != null) h.answer(outcome);
          async.elapse(const Duration(hours: 25));
        }

        session(ErrorPromptOutcome.dismissed, expectShows: 1);
        session(ErrorPromptOutcome.timedOut, expectShows: 1);
        session(ErrorPromptOutcome.dismissed, expectShows: 1); // the second close
        session(ErrorPromptOutcome.dismissed, expectShows: 0); // muted
        async.elapse(const Duration(days: 6));
        session(ErrorPromptOutcome.report, expectShows: 1); // seven days on
      });
    });

    test('Report opens with openedAt at the tap and resets the closes', () {
      final store = MemoryFeedbackStore();
      fakeAsync((async) {
        final h = Harness(async, store);
        async.elapse(const Duration(seconds: 20));
        h.gate.notice(FeedbackErrorKind.exception);
        async.elapse(const Duration(seconds: 3));
        final tap = h.now;
        h.answer(ErrorPromptOutcome.report);
        expect(h.reports, [tap]);
        expect(h.lines, ['error prompt shown', 'error prompt: reporting']);
        async.flushMicrotasks();
      });
      expect(store.readState('error_prompt'), completion(containsPair('closes', 0)));
    });
  });

  group('the pill', () {
    late List<http.Request> reports;
    late List<Map<String, Object?>> announcements;
    late int now;

    OverblastFeedbackController make({List<String> appHosts = const [], List<String> on = const ['exception']}) =>
        OverblastFeedbackController(
          feedbackKey: testKey,
          store: MemoryFeedbackStore(),
          deviceFacts: fakeFacts,
          clock: () => DateTime.fromMillisecondsSinceEpoch(now),
          deviceVerification: false,
          trackCrashes: false,
          appHosts: appHosts,
          httpClient: MockClient((req) async {
            if (req.url.path.endsWith('/config')) {
              return http.Response(
                jsonEncode({
                  'verification': 'off',
                  'errorPrompt': {'enabled': true, 'on': on, 'minHoursBetween': 24},
                  'screenshots': true,
                }),
                200,
              );
            }
            reports.add(req);
            return http.Response(jsonEncode({'id': 'fbr_1', 'taskId': 't'}), 201);
          }),
        );

    Widget app(OverblastFeedbackController c, {bool errorPrompt = true}) => OverblastFeedback(
      controller: c,
      enableShake: false,
      captureDebugPrint: false,
      captureErrors: false,
      retryPendingOnStart: false,
      errorPrompt: errorPrompt,
      child: const MaterialApp(home: Scaffold(body: TextField(key: ValueKey('field')))),
    );

    /// Fake time for the widget test and the controller's clock together.
    Future<void> wait(WidgetTester tester, Duration d) async {
      final steps = (d.inMilliseconds / 100).ceil();
      for (var i = 0; i < steps; i++) {
        now += 100;
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    setUp(() {
      reports = [];
      announcements = [];
      now = start;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
        SystemChannels.accessibility,
        (message) async {
          if (message is Map) announcements.add(message.cast<String, Object?>());
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

    final pill = find.byKey(const ValueKey('overblast_feedback.error_prompt'));

    testWidgets('an unexpected error: the pill, announced politely; Report opens the sheet as error_prompt', (
      tester,
    ) async {
      final c = make();
      await tester.pumpWidget(app(c));
      await wait(tester, const Duration(seconds: 11));
      c.error('Checkout failed: total is null', unexpected: true);
      await wait(tester, const Duration(milliseconds: 1500));
      expect(pill, findsOneWidget);
      expect(find.text('Something may have gone wrong. Tell us?'), findsOneWidget);
      final announce = announcements.singleWhere((m) => m['type'] == 'announce');
      expect((announce['data']! as Map)['message'], 'Something may have gone wrong. Tell us?');
      expect((announce['data']! as Map)['assertiveness'], anyOf(isNull, 0));

      await wait(tester, const Duration(seconds: 2));
      final tapAt = now;
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.error_prompt.report')));
      await tester.pump();
      expect(pill, findsNothing);
      expect(find.text('Report a problem'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('overblast_feedback.message')), 'It broke');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
      await wait(tester, const Duration(milliseconds: 500));
      final body = jsonDecode(reports.single.body) as Map;
      expect(body['category'], 'bug');
      final context = body['context'] as Map;
      expect(context['trigger'], 'error_prompt');
      expect(context['openedAt'], tapAt);
      final msgs = (body['logs'] as List).map((l) => (l as Map)['msg']).toList();
      expect(msgs, containsAllInOrder(['Checkout failed: total is null', 'error prompt shown', 'error prompt: reporting']));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('it goes by itself after about eight seconds', (tester) async {
      final c = make();
      await tester.pumpWidget(app(c));
      await wait(tester, const Duration(seconds: 11));
      c.error('x', unexpected: true);
      await wait(tester, const Duration(milliseconds: 1500));
      expect(pill, findsOneWidget);
      await wait(tester, const Duration(seconds: 7));
      expect(pill, findsOneWidget);
      await wait(tester, const Duration(seconds: 2));
      expect(pill, findsNothing);
      expect(c.logs.map((e) => e.msg), contains('error prompt went by itself'));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('closing it is logged', (tester) async {
      final c = make();
      await tester.pumpWidget(app(c));
      await wait(tester, const Duration(seconds: 11));
      c.error('x', unexpected: true);
      await wait(tester, const Duration(milliseconds: 1500));
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.error_prompt.close')));
      await tester.pump();
      expect(pill, findsNothing);
      expect(c.logs.map((e) => e.msg), contains('error prompt dismissed'));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('an error logged as expected, a 4xx, or a third-party host does not count', (tester) async {
      final c = make(appHosts: ['example.com'], on: ['exception', 'server_error', 'network']);
      await tester.pumpWidget(app(c));
      await wait(tester, const Duration(seconds: 11));
      c.error('handled and fine');
      c.recordNetwork('GET', 'https://api.example.com/cart', 404, 10);
      c.recordNetwork('GET', 'https://ads.tracker.net/pixel', 0, 10);
      c.recordNetwork('POST', 'https://brain.deployd.network/v1/feedback/config', 503, 10);
      await wait(tester, const Duration(seconds: 3));
      expect(pill, findsNothing);
      c.recordNetwork('POST', 'https://api.example.com/cart', 503, 10);
      await wait(tester, const Duration(milliseconds: 1500));
      expect(pill, findsOneWidget, reason: "a 5xx from the app's own host does");
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('a network failure counts only when the key lists it', (tester) async {
      final c = make(appHosts: ['api.example.com']);
      await tester.pumpWidget(app(c));
      await wait(tester, const Duration(seconds: 11));
      c.recordNetwork('GET', 'https://api.example.com/cart', 0, 10);
      await wait(tester, const Duration(seconds: 3));
      expect(pill, findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('not while the keyboard is up, nor within 5 s of typing', (tester) async {
      final c = make();
      await tester.pumpWidget(app(c));
      await wait(tester, const Duration(seconds: 11));
      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      addTearDown(tester.view.resetViewInsets);
      c.error('x', unexpected: true);
      await wait(tester, const Duration(seconds: 5));
      expect(pill, findsNothing);
      tester.view.resetViewInsets();
      await wait(tester, const Duration(seconds: 1));
      expect(pill, findsOneWidget, reason: 'the keyboard went down within 30 s');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('a key pressed in a text field holds it back', (tester) async {
      final c = make();
      await tester.pumpWidget(app(c));
      await tester.tap(find.byKey(const ValueKey('field')));
      await wait(tester, const Duration(seconds: 11));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      c.error('x', unexpected: true);
      await wait(tester, const Duration(seconds: 3));
      expect(pill, findsNothing);
      await wait(tester, const Duration(seconds: 3));
      expect(pill, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('not while the sheet is open', (tester) async {
      final c = make();
      await tester.pumpWidget(app(c));
      await wait(tester, const Duration(seconds: 11));
      unawaited(c.show());
      await tester.pump();
      c.error('x', unexpected: true);
      await wait(tester, const Duration(seconds: 3));
      expect(pill, findsNothing);
      await tester.tap(find.text('Cancel'));
      await wait(tester, const Duration(seconds: 1));
      expect(pill, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('errorPrompt: false turns it off whatever the key says', (tester) async {
      final c = make();
      await tester.pumpWidget(app(c, errorPrompt: false));
      await wait(tester, const Duration(seconds: 11));
      c.error('x', unexpected: true);
      await wait(tester, const Duration(seconds: 3));
      expect(pill, findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('reduced motion: no fade', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
        disableAnimations: true,
      );
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final c = make();
      await tester.pumpWidget(app(c));
      await wait(tester, const Duration(seconds: 11));
      c.error('x', unexpected: true);
      await wait(tester, const Duration(milliseconds: 1500));
      final fade = tester.widget<AnimatedOpacity>(find.ancestor(of: pill, matching: find.byType(AnimatedOpacity)));
      expect(fade.duration, Duration.zero);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('it sits above the keyboard and the safe area', (tester) async {
      // A home indicator: 34 logical pixels at dpr 3. A real view reports it in both.
      tester.view.padding = const FakeViewPadding(bottom: 102);
      tester.view.viewPadding = const FakeViewPadding(bottom: 102);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final c = make();
      await tester.pumpWidget(app(c));
      await wait(tester, const Duration(seconds: 11));
      c.error('x', unexpected: true);
      await wait(tester, const Duration(milliseconds: 1500));
      final height = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(tester.getRect(pill).bottom, closeTo(height - 34 - 12, 0.5));
      // The keyboard comes up: the pill moves above it.
      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      expect(tester.getRect(pill).bottom, closeTo(height - 300 - 12, 0.5));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });
}
