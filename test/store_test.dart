import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/store/store_io.dart';

import 'helpers.dart';

void main() {
  group('stores', () {
    Future<void> roundTrip(FeedbackStore store) async {
      expect(await store.readDeviceId(), isNull);
      await store.writeDeviceId('dev_1');
      expect(await store.readDeviceId(), 'dev_1');
      for (var i = 0; i < 7; i++) {
        await store.savePending(PendingReport(id: 'p$i', createdAt: 100 + i, body: {'message': 'm$i'}));
      }
      final kept = await store.loadPending();
      expect(kept.map((p) => p.id), ['p2', 'p3', 'p4', 'p5', 'p6']); // the newest five
      expect(kept.first.body, {'message': 'm2'});
      await store.savePending(kept.first.copyWith(notBefore: 999));
      expect((await store.loadPending()).first.notBefore, 999);
      await store.deletePending('p2');
      expect((await store.loadPending()).map((p) => p.id), ['p3', 'p4', 'p5', 'p6']);
    }

    test('memory', () => roundTrip(MemoryFeedbackStore()));

    test('files', () async {
      final dir = await Directory.systemTemp.createTemp('obfb');
      addTearDown(() => dir.delete(recursive: true));
      await roundTrip(FileFeedbackStore(() async => dir));
      // A corrupt file is dropped, not fatal.
      File('${dir.path}/pending/bad.json').writeAsStringSync('{not json');
      expect((await FileFeedbackStore(() async => dir).loadPending()).length, 4);
      expect(File('${dir.path}/pending/bad.json').existsSync(), isFalse);
    });
  });

  group('controller', () {
    late List<http.Request> requests;
    late List<http.Response> answers;
    late MemoryFeedbackStore store;
    late DateTime now;

    OverblastFeedbackController make() => OverblastFeedbackController(
      feedbackKey: testKey,
      store: store,
      deviceFacts: fakeFacts,
      clock: () => now,
      httpClient: MockClient((req) async {
        requests.add(req);
        return answers.isEmpty ? http.Response(jsonEncode({'id': 'fbr_x', 'taskId': 't'}), 201) : answers.removeAt(0);
      }),
    );

    setUp(() {
      requests = [];
      answers = [];
      store = MemoryFeedbackStore();
      now = DateTime.fromMillisecondsSinceEpoch(1760440000000);
    });

    test('a key that is not obfk_ fails at once, by name', () {
      expect(() => OverblastFeedbackController(feedbackKey: 'ob_live_x', store: store), throwsArgumentError);
    });

    test('the payload carries the device, reporter, extra and a stable device id', () async {
      final c = make()
        ..setReporter(email: 'ana@example.com', name: 'Ana', accountRef: 'cus_1')
        ..setExtra('plan', 'pro')
        ..info('hello');
      final body = (await c.buildPayload(
        message: 'Broken',
        reporter: const FeedbackReporter(name: 'Ana B'),
      )).toJson();
      expect(body['reporter'], {'email': 'ana@example.com', 'name': 'Ana B', 'accountRef': 'cus_1'});
      final ctx = body['context']! as Map;
      expect(ctx['platform'], 'flutter');
      expect(ctx['os'], 'iOS');
      expect(ctx['osVersion'], '18.2');
      expect(ctx['device'], 'iPhone15,3');
      expect(ctx['appVersion'], '2.4.1');
      expect(ctx['build'], '412');
      expect(ctx['extra'], {'plan': 'pro'});
      expect(ctx['deviceId'], matches(RegExp(r'^[a-z0-9]{32}$')));
      expect(await store.readDeviceId(), ctx['deviceId']);
      expect((body['logs']! as List).single, containsPair('msg', 'hello'));
      c.dispose();
    });

    test('429 keeps the report with its retry time and says so; nothing is retried', () async {
      final c = make();
      answers.add(http.Response(jsonEncode({'code': 'rate_limited', 'retryAfter': 60, 'error': 'Too many.'}), 429));
      await expectLater(
        c.submit(await c.buildPayload(message: 'x')),
        throwsA(isA<OverblastFeedbackException>().having((e) => e.savedForLater, 'saved', isTrue)),
      );
      expect(requests.length, 1);
      final pending = await c.pending();
      expect(pending.single.notBefore, now.millisecondsSinceEpoch + 60000);
      expect(pending.single.body['message'], 'x');

      // Too early: not sent.
      expect(await c.retryPending(), 0);
      expect(requests.length, 1);
      // Later: sent once, and gone.
      now = now.add(const Duration(minutes: 2));
      expect(await c.retryPending(), 1);
      expect(requests.length, 2);
      expect(jsonDecode(requests.last.body)['message'], 'x');
      expect(await c.pending(), isEmpty);
      c.dispose();
    });

    test('a refusal for good is not kept; no answer is', () async {
      final c = make();
      answers.add(http.Response(jsonEncode({'code': 'unknown_key'}), 401));
      await expectLater(c.submit(await c.buildPayload(message: 'a')), throwsA(isA<OverblastFeedbackException>()));
      expect(await c.pending(), isEmpty);
      final offline = OverblastFeedbackController(
        feedbackKey: testKey,
        store: store,
        deviceFacts: fakeFacts,
        httpClient: MockClient((_) async => throw http.ClientException('offline')),
      );
      await expectLater(
        offline.submit(await offline.buildPayload(message: 'b')),
        throwsA(isA<OverblastFeedbackException>().having((e) => e.savedForLater, 'saved', isTrue)),
      );
      expect((await c.pending()).single.body['message'], 'b');
      c.dispose();
      offline.dispose();
    });

    test('retryPending stops at a 429, drops a dead report, keeps the rest', () async {
      final c = make();
      for (var i = 0; i < 3; i++) {
        await store.savePending(PendingReport(id: 'p$i', createdAt: i, body: {'message': 'm$i'}));
      }
      answers
        ..add(http.Response(jsonEncode({'code': 'invalid_field', 'field': 'message'}), 400))
        ..add(http.Response(jsonEncode({'code': 'rate_limited', 'retryAfter': 10}), 429));
      expect(await c.retryPending(), 0);
      expect(requests.length, 2); // p0 dropped, p1 rate limited, p2 not tried
      final left = await c.pending();
      expect(left.map((p) => p.id), ['p1', 'p2']);
      expect(left.first.notBefore, now.millisecondsSinceEpoch + 10000);
      c.dispose();
    });

    test('error capture logs and hands every error on; release restores the handlers', () {
      final originalFlutter = FlutterError.onError;
      final originalPlatform = PlatformDispatcher.instance.onError;
      final seen = <String>[];
      FlutterError.onError = (d) => seen.add('flutter:${d.exception}');
      PlatformDispatcher.instance.onError = (e, s) {
        seen.add('platform:$e');
        return true;
      };
      try {
        final c = make()..captureErrors();
        FlutterError.onError!(FlutterErrorDetails(exception: StateError('boom')));
        final handled = PlatformDispatcher.instance.onError!(StateError('async'), StackTrace.empty);
        expect(handled, isTrue);
        expect(seen, ['flutter:Bad state: boom', 'platform:Bad state: async']);
        expect(c.logs.map((l) => l.src), ['flutter', 'uncaught']);
        expect(c.logs.every((l) => l.level == FeedbackLogLevel.error), isTrue);
        c.releaseCaptures();
        FlutterError.onError!(FlutterErrorDetails(exception: StateError('after')));
        expect(c.logs.length, 2);
        c.dispose();
      } finally {
        FlutterError.onError = originalFlutter;
        PlatformDispatcher.instance.onError = originalPlatform;
      }
    });

    test('debugPrint capture passes lines on and is released', () {
      final original = debugPrint;
      final printed = <String?>[];
      debugPrint = (m, {wrapWidth}) => printed.add(m);
      try {
        final c = make()..captureDebugPrint();
        debugPrint('token=abc123');
        expect(printed, ['token=abc123']);
        expect(c.logs.single.msg, 'token=[redacted]');
        expect(c.logs.single.src, 'debugPrint');
        c.dispose(); // releases
        debugPrint('later');
        expect(c.logs.length, 1);
        expect(printed.last, 'later');
      } finally {
        debugPrint = original;
      }
    });

    test('show() without the widget fails by name', () {
      final c = make();
      expect(() => c.show(), throwsStateError);
      c.dispose();
    });
  });
}
