import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/transport.dart';

import 'helpers.dart';

void main() {
  const body = {
    'v': 1,
    'message': 'x',
    'context': {'platform': 'flutter'},
  };

  Future<Object> sendWith(http.Response response) async {
    final transport = FeedbackTransport(feedbackKey: testKey, client: MockClient((_) async => response));
    try {
      return await transport.send(body);
    } on OverblastFeedbackException catch (e) {
      return e;
    }
  }

  test('posts JSON to the door with the key header', () async {
    late http.Request seen;
    final transport = FeedbackTransport(
      feedbackKey: testKey,
      client: MockClient((req) async {
        seen = req;
        return http.Response(jsonEncode({'id': 'fbr_1', 'taskId': 't_1', 'conversationId': null}), 201);
      }),
    );
    final result = await transport.send(body);
    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'https://brain.deployd.network/v1/feedback');
    expect(seen.headers['X-Overblast-Feedback-Key'], testKey);
    expect(seen.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(seen.body), body);
    expect(result.id, 'fbr_1');
    expect(result.taskId, 't_1');
    expect(result.conversationId, isNull);
    expect(result.storageFull, isFalse);
  });

  test('the conversation id comes back when there is one', () async {
    final r = await sendWith(
      http.Response(jsonEncode({'id': 'fbr_2', 'taskId': 't', 'conversationId': 'c:ana@example.com'}), 201),
    );
    expect((r as FeedbackResult).conversationId, 'c:ana@example.com');
  });

  test('a refusal carries the worker sentence as is', () async {
    final r = await sendWith(
      http.Response(
        jsonEncode({'code': 'invalid_field', 'field': 'context.viewport', 'error': 'The viewport is not right.'}),
        400,
      ),
    );
    final e = r as OverblastFeedbackException;
    expect(e.status, 400);
    expect(e.code, 'invalid_field');
    expect(e.field, 'context.viewport');
    expect(e.message, 'The viewport is not right.');
    expect(e.savedForLater, isFalse);
  });

  test('each code has a sentence of ours when the worker sends none', () async {
    for (final (status, code) in [
      (401, 'unknown_key'),
      (403, 'key_disabled'),
      (403, 'origin_not_allowed'),
      (413, 'too_large'),
      (500, 'misconfigured'),
    ]) {
      final e = await sendWith(http.Response(jsonEncode({'code': code}), status)) as OverblastFeedbackException;
      expect(e.status, status);
      expect(e.code, code);
      expect(e.message, fallbackSentence(code));
      expect(e.message, isNot(contains('HTTP')));
    }
  });

  test('429 carries retryAfter, from the body or the header', () async {
    final a =
        await sendWith(
              http.Response(jsonEncode({'code': 'rate_limited', 'retryAfter': 120, 'error': 'Slow down.'}), 429),
            )
            as OverblastFeedbackException;
    expect(a.isRateLimited, isTrue);
    expect(a.retryAfter, 120);
    expect(a.message, 'Slow down.');
    final b = await sendWith(http.Response('', 429, headers: {'retry-after': '30'})) as OverblastFeedbackException;
    expect(b.code, 'rate_limited');
    expect(b.retryAfter, 30);
  });

  test('507 storage_full is a filed report with a notice', () async {
    final r =
        await sendWith(
              http.Response(
                jsonEncode({'code': 'storage_full', 'error': 'Filed without the screenshot.', 'taskId': 't'}),
                507,
              ),
            )
            as FeedbackResult;
    expect(r.storageFull, isTrue);
    expect(r.notice, 'Filed without the screenshot.');
    expect(r.taskId, 't');
  });

  test('a non-JSON answer still maps by status', () async {
    final e = await sendWith(http.Response('<html>bad gateway</html>', 502)) as OverblastFeedbackException;
    expect(e.code, 'http_502');
    expect(e.message, contains('502'));
  });

  test('no answer at all is status 0, code network', () async {
    final transport = FeedbackTransport(
      feedbackKey: testKey,
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    await expectLater(
      transport.send(body),
      throwsA(
        isA<OverblastFeedbackException>()
            .having((e) => e.isNetwork, 'isNetwork', isTrue)
            .having((e) => e.code, 'code', 'network'),
      ),
    );
  });

  test('OverblastHttpClient records method, bare URL, status and time', () async {
    final controller = OverblastFeedbackController(feedbackKey: testKey, store: MemoryFeedbackStore());
    final client = OverblastHttpClient(
      MockClient((req) async => req.url.path == '/boom' ? throw http.ClientException('x') : http.Response('ok', 404)),
      feedback: controller,
    );
    await client.get(Uri.parse('https://api.example.com/items?page=2&token=abc#x'));
    await expectLater(client.post(Uri.parse('https://api.example.com/boom')), throwsA(isA<http.ClientException>()));
    final net = controller.network;
    expect(net.length, 2);
    expect(net[0].method, 'GET');
    expect(net[0].url, 'https://api.example.com/items');
    expect(net[0].status, 404);
    expect(net[1].status, 0);
    // The report's own request is not recorded.
    controller.recordNetwork('POST', defaultFeedbackEndpoint, 201, 10);
    expect(controller.network.length, 2);
    controller.dispose();
  });
}
