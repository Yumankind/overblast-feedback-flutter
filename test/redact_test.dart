import 'package:flutter_test/flutter_test.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/log_buffer.dart' show FeedbackLogBuffer, RingBuffer;
import 'package:overblast_feedback/src/redact.dart' show passesLuhn;

void main() {
  group('redact', () {
    test('bearer tokens', () {
      expect(redact('Authorization: Bearer abc.def-ghi_123456'), 'Authorization: Bearer [redacted]');
      expect(redact('basic dXNlcjpwYXNzd29yZA=='), 'basic [redacted]');
    });

    test('API keys: sk-, Stripe, ob_live_, obfk_', () {
      expect(redact('key sk-proj-AbCdEf1234567890 used'), 'key [redacted] used');
      expect(redact('sk_live_51HxYzAbCdEfGh'), '[redacted]');
      expect(redact('rk_test_51HxYzAbCdEfGh'), '[redacted]');
      expect(redact('ob_live_abcdefgh12345678'), '[redacted]');
      expect(redact('obfk_ABCDEFGHIJKLMNOPQRSTUVWX'), '[redacted]');
      expect(redact('task-1234 and skipped'), 'task-1234 and skipped');
    });

    test('JWTs', () {
      const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U';
      expect(redact('token $jwt here'), 'token [redacted] here');
    });

    test('password= and token= pairs, plain and JSON', () {
      expect(redact('login?user=ana&password=hunter2&x=1'), 'login?user=ana&password=[redacted]&x=1');
      expect(redact('token: abc123'), 'token: [redacted]');
      expect(redact('{"password": "s3cret", "user": "ana"}'), '{"password": "[redacted]", "user": "ana"}');
      expect(redact("authToken='abc'"), "authToken='[redacted]'");
      expect(redact('client_secret=xyz api_key=k1'), 'client_secret=[redacted] api_key=[redacted]');
    });

    test('card numbers that pass Luhn, in any grouping; other long numbers kept', () {
      expect(redact('card 4242 4242 4242 4242 ok'), 'card [redacted] ok');
      expect(redact('card 4242-4242-4242-4242'), 'card [redacted]');
      expect(redact('card 4242424242424242'), 'card [redacted]');
      expect(redact('amex 378282246310005'), 'amex [redacted]');
      expect(redact('order 4242424242424241'), 'order 4242424242424241'); // fails Luhn
      expect(redact('short 424242424242'), 'short 424242424242'); // 12 digits
      expect(redact('long 42424242424242424242424'), 'long 42424242424242424242424'); // 23 digits
    });

    test('ordinary text is untouched', () {
      const line = 'Loaded 12 items for cart 8812 in 340 ms';
      expect(redact(line), line);
      expect(redact(''), '');
    });

    test('Luhn', () {
      expect(passesLuhn('4242424242424242'), isTrue);
      expect(passesLuhn('4242424242424241'), isFalse);
      expect(passesLuhn('42a'), isFalse);
    });
  });

  group('ring buffer', () {
    test('forgets the oldest when full', () {
      final ring = RingBuffer<int>(3);
      for (var i = 0; i < 5; i++) {
        ring.add(i);
      }
      expect(ring.toList(), [2, 3, 4]);
      expect(ring.length, 3);
      ring.clear();
      expect(ring.toList(), isEmpty);
    });

    test('the log buffer holds 500 by default, redacted on the way in', () {
      var now = DateTime.fromMillisecondsSinceEpoch(1000);
      final logs = FeedbackLogBuffer(clock: () => now);
      for (var i = 0; i < 520; i++) {
        logs.add(FeedbackLogLevel.info, 'line $i');
      }
      expect(logs.length, 500);
      expect(logs.entries.first.msg, 'line 20');
      now = DateTime.fromMillisecondsSinceEpoch(2000);
      logs.add(FeedbackLogLevel.error, 'Bearer abcdefghijklmnop', src: 'app');
      final last = logs.entries.last;
      expect(last.msg, 'Bearer [redacted]');
      expect(last.t, 2000);
      expect(last.level, FeedbackLogLevel.error);
      expect(last.src, 'app');
    });

    test('a secret straddling the 4000 limit is still redacted', () {
      final logs = FeedbackLogBuffer();
      logs.add(FeedbackLogLevel.info, '${'x' * 3990} sk-abcdefghijklmnopqrstuvwxyz');
      // The marker itself may be cut by the limit; the secret is gone either way.
      expect(logs.entries.single.msg, contains('[redacted'));
      expect(logs.entries.single.msg, isNot(contains('sk-abc')));
      expect(logs.entries.single.msg.length, 4000);
    });
  });

  group('network urls', () {
    test('query, fragment and credentials are dropped', () {
      expect(stripUrl('https://api.example.com/cart?token=abc#top'), 'https://api.example.com/cart');
      expect(stripUrl('https://user:pw@example.com/a'), 'https://example.com/a');
      expect(stripUrl('/relative/path?x=1'), '/relative/path');
      expect(stripUrl('https://a.example/${'p' * 600}').length, 500);
    });

    test('an entry redacts what is left of the path', () {
      final e = FeedbackNetworkEntry(
        t: 1,
        method: 'get',
        url: 'https://a.example/k/sk-abcdefghijklmnop?q=1',
        status: 200,
        ms: 5,
      );
      expect(e.url, 'https://a.example/k/[redacted]');
      expect(e.method, 'GET');
    });
  });
}
