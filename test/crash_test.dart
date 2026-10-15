import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overblast_feedback/overblast_feedback.dart';

import 'helpers.dart';

// What happened just before (docs/feedback-reports.md §3.4): openedAt and trigger, the session
// marker, the on-disk log, the crash a relaunch report carries, and the one-time offer.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryFeedbackStore store;
  late int now;
  late List<http.Request> requests;
  FeedbackCrash? nativeExit;

  setUp(() {
    store = MemoryFeedbackStore();
    now = 1760440000000;
    requests = [];
    nativeExit = null;
  });

  OverblastFeedbackController launch({bool trackCrashes = true}) => OverblastFeedbackController(
    feedbackKey: testKey,
    store: store,
    deviceFacts: fakeFacts,
    clock: () => DateTime.fromMillisecondsSinceEpoch(now),
    deviceVerification: false,
    trackCrashes: trackCrashes,
    lastExit: () async => nativeExit,
    httpClient: MockClient((req) async {
      if (req.url.path.endsWith('/config')) return http.Response('', 404);
      requests.add(req);
      return http.Response(jsonEncode({'id': 'fbr_1', 'taskId': 't_1', 'conversationId': null}), 201);
    }),
  );

  group('openedAt and trigger', () {
    test('report() is trigger api, opened when it was called', () async {
      final c = launch(trackCrashes: false);
      await c.report(message: 'From my own form');
      final context = (jsonDecode(requests.single.body) as Map)['context'] as Map;
      expect(context['trigger'], 'api');
      expect(context['openedAt'], now);
      expect(triggers, contains(context['trigger']));
      c.dispose();
    });

    test('every trigger is a contract value', () {
      expect(FeedbackTrigger.values.map((t) => t.wire).toSet(), triggers);
      expect(FeedbackCrashKind.values.map((k) => k.name).toSet(), {'crash', 'exception', 'oom', 'killed', 'unknown'});
      expect(FeedbackCrashSource.values.map((s) => s.wire).toSet(), {'metrickit', 'exit_info', 'handler', 'marker'});
    });

    test('a crash is redacted and cut to its limits', () {
      final json = FeedbackCrash(
        kind: FeedbackCrashKind.exception,
        source: FeedbackCrashSource.handler,
        at: 5,
        message: 'Bad state: token=abc123 ${'m' * 3000}',
        stack: 's' * 20000,
      ).toJson();
      expect(json.keys.toSet(), {'kind', 'at', 'message', 'stack', 'source'});
      expect(json['message'], startsWith('Bad state: token=[redacted]'));
      expect((json['message']! as String).length, 2000);
      expect((json['stack']! as String).length, 16000);
      expect(json['source'], 'handler');
    });
  });

  group('the session', () {
    test('a session that closed is not a crash', () async {
      final first = launch();
      expect(await first.startSession(), isNull);
      first.info('working');
      await first.closeSession();
      first.dispose();

      final second = launch();
      expect(await second.startSession(), isNull);
      expect(second.pendingCrash, isNull);
      second.dispose();
    });

    test('a session that never closed comes back with its logs, as an unknown end the marker saw', () async {
      final first = launch();
      await first.startSession();
      first.info('opened cart 8812');
      now += 1000;
      first.error('TypeError: total is null'); // an error goes to disk at once
      await first.flushLogs();
      first.dispose(); // the process "dies": no close

      now += 60000;
      final second = launch();
      final previous = (await second.startSession())!;
      expect(previous.crash.kind, FeedbackCrashKind.unknown);
      expect(previous.crash.source, FeedbackCrashSource.marker);
      expect(previous.crash.at, 1760440001000);
      expect(previous.logs.map((e) => e.msg), ['opened cart 8812', 'TypeError: total is null']);
      expect(previous.startedAt, 1760440000000);
      expect(second.pendingCrash, same(previous));
      // This session's disk log starts empty.
      expect((await store.readLogLines()).where((l) => l.contains('8812')), isEmpty);
      second.dispose();
    });

    test('a Dart error caught by the hooks is the account of the end', () async {
      final originalFlutter = FlutterError.onError;
      final originalPlatform = PlatformDispatcher.instance.onError;
      FlutterError.onError = (_) {};
      try {
        final first = launch();
        await first.startSession();
        first.captureErrors();
        FlutterError.onError!(
          FlutterErrorDetails(exception: StateError('cart total with token=abc123'), stack: StackTrace.current),
        );
        await first.flushLogs();
        await Future<void>.delayed(Duration.zero);
        first.releaseCaptures();
        first.dispose();

        final second = launch();
        final crash = (await second.startSession())!.crash;
        expect(crash.kind, FeedbackCrashKind.exception);
        expect(crash.source, FeedbackCrashSource.handler);
        expect(crash.message, 'Bad state: cart total with token=[redacted]');
        expect(crash.stack, isNotEmpty);
        expect(crash.at, now);
        second.dispose();
      } finally {
        FlutterError.onError = originalFlutter;
        PlatformDispatcher.instance.onError = originalPlatform;
      }
    });

    test('the platform\'s exit reason from inside the session wins', () async {
      final first = launch();
      await first.startSession();
      first.dispose();
      nativeExit = FeedbackCrash(
        kind: FeedbackCrashKind.oom,
        source: FeedbackCrashSource.exitInfo,
        at: now + 30000,
        message: 'low memory',
      );
      final second = launch();
      final crash = (await second.startSession())!.crash;
      expect(crash.kind, FeedbackCrashKind.oom);
      expect(crash.source, FeedbackCrashSource.exitInfo);
      second.dispose();
    });

    test('an exit from before the session started is someone else\'s', () async {
      final first = launch();
      await first.startSession();
      first.dispose();
      nativeExit = FeedbackCrash(kind: FeedbackCrashKind.crash, source: FeedbackCrashSource.exitInfo, at: now - 3600000);
      final second = launch();
      expect((await second.startSession())!.crash.source, FeedbackCrashSource.marker);
      second.dispose();
    });

    test('back in the foreground, the session is open again', () async {
      final first = launch();
      await first.startSession();
      await first.closeSession();
      await first.reopenSession();
      first.dispose();
      final second = launch();
      expect(await second.startSession(), isNotNull);
      second.dispose();
    });

    test('trackCrashes: false keeps nothing on disk', () async {
      final c = launch(trackCrashes: false);
      expect(await c.startSession(), isNull);
      c.error('x');
      await c.flushLogs();
      expect(await store.readSession(), isNull);
      expect(await store.readLogLines(), isEmpty);
      c.dispose();
    });

    testWidgets('ordinary lines reach the disk five seconds later, errors at once', (tester) async {
      final c = launch();
      await c.startSession();
      c.info('a quiet line');
      await tester.pump();
      expect(await store.readLogLines(), isEmpty);
      await tester.pump(const Duration(seconds: 5));
      expect((await store.readLogLines()).single, contains('a quiet line'));
      c.error('loud');
      await tester.pump();
      expect((await store.readLogLines()).last, contains('loud'));
      // A repeat of a line already on disk is written again with its count.
      c.error('loud');
      await tester.pump();
      expect((await store.readLogLines()).last, contains('"repeat":2'));
      c.dispose();
    });
  });

  group('the sheet', () {
    Widget app(OverblastFeedbackController c, {bool offer = true}) => OverblastFeedback(
      controller: c,
      enableShake: false,
      captureDebugPrint: false,
      captureErrors: false,
      retryPendingOnStart: false,
      offerReportAfterCrash: offer,
      child: const MaterialApp(home: Scaffold(body: Center(child: Text('Cart')))),
    );

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> leaveCrashedSession() async {
      final first = launch();
      await first.startSession();
      first.info('loading checkout');
      first.error('SocketException: connection reset');
      await first.flushLogs();
      first.dispose();
    }

    testWidgets('logs stop while the sheet is open; the report is of what came before', (tester) async {
      final c = launch(trackCrashes: false);
      await tester.pumpWidget(app(c));
      c.info('before');
      now += 2000;
      final closed = c.show();
      await tester.pump();
      c.info('during');
      c.recordNetwork('GET', 'https://api.example.com/x', 200, 5);
      await tester.enterText(find.byKey(const ValueKey('overblast_feedback.message')), 'Broken');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
      await settle(tester);
      final body = jsonDecode(requests.single.body) as Map;
      expect((body['logs'] as List).map((l) => (l as Map)['msg']), ['before']);
      expect(body.containsKey('network'), isFalse);
      expect((body['context'] as Map)['openedAt'], now);
      expect((body['context'] as Map)['trigger'], 'button');
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.close')));
      await tester.pump();
      await closed;
      c.info('after');
      expect(c.logs.map((e) => e.msg), ['before', 'after']);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('after a crash: offered once, and the report carries the crash and that session\'s logs', (
      tester,
    ) async {
      await tester.runAsync(leaveCrashedSession);
      now += 600000;
      final c = launch();
      await tester.pumpWidget(app(c));
      await settle(tester);
      expect(find.text('The app closed unexpectedly. Send a report?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.crash_offer.send')));
      await tester.pump();
      expect(find.text('The app closed unexpectedly. Send a report?'), findsNothing);
      expect(c.pendingCrash, isNull, reason: 'offered once');
      await tester.enterText(find.byKey(const ValueKey('overblast_feedback.message')), 'It just closed');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
      await settle(tester);
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['category'], 'bug');
      final context = body['context'] as Map;
      expect(context['trigger'], 'relaunch');
      expect(context['openedAt'], now);
      final crash = body['crash'] as Map;
      expect(crash.keys.toSet().difference(crashKeys), isEmpty);
      expect(crash['kind'], 'unknown');
      expect(crash['source'], 'marker');
      expect((body['logs'] as List).map((l) => (l as Map)['msg']), [
        'loading checkout',
        'SocketException: connection reset',
      ]);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('"Not now" forgets it', (tester) async {
      await tester.runAsync(leaveCrashedSession);
      final c = launch();
      await tester.pumpWidget(app(c));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.crash_offer.dismiss')));
      await tester.pump();
      expect(find.byKey(const ValueKey('overblast_feedback.crash_offer')), findsNothing);
      expect(c.pendingCrash, isNull);
      expect(find.text('Report a problem'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('offerReportAfterCrash: false shows nothing and leaves the crash to the app', (tester) async {
      await tester.runAsync(leaveCrashedSession);
      final c = launch();
      await tester.pumpWidget(app(c, offer: false));
      await settle(tester);
      expect(find.byKey(const ValueKey('overblast_feedback.crash_offer')), findsNothing);
      expect(c.pendingCrash, isNotNull);
      final closed = c.show(trigger: FeedbackTrigger.relaunch);
      await tester.pump();
      expect(find.textContaining('how the app closed last time'), findsOneWidget);
      expect(c.pendingCrash, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await closed;
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('the widget going away closes the session', (tester) async {
      final c = launch();
      await tester.pumpWidget(app(c));
      await settle(tester);
      expect((await store.readSession())!['closed'], isFalse);
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      expect((await store.readSession())!['closed'], isTrue);
      c.dispose();
    });
  });
}
