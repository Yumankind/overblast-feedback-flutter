import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/controller.dart' show parseDiskLog;
import 'package:overblast_feedback/src/log_buffer.dart';
import 'package:overblast_feedback/src/logs/log_file.dart';
import 'package:overblast_feedback/src/store/store_io.dart';

import 'helpers.dart';

// Managing the logs (docs/feedback-reports.md §3.5): repeats, the intake cap, the budgets, the
// excerpt, the log file and the on-disk copy.

List<String> gunzipLines(Map<String, Object?> logFile) {
  final raw = base64Decode(logFile['base64']! as String);
  final text = utf8.decode(logFile['encoding'] == 'gzip' ? gzip.decode(raw) : raw);
  return const LineSplitter().convert(text);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int now;
  late int redactions;
  FeedbackLogBuffer buffer({int maxLines = 20000, int maxBytes = 2000000}) => FeedbackLogBuffer(
    maxLines: maxLines,
    maxBytes: maxBytes,
    clock: () => DateTime.fromMillisecondsSinceEpoch(now),
    redactor: (s) {
      redactions++;
      return redact(s);
    },
  );

  setUp(() {
    now = 1760440000000;
    redactions = 0;
  });

  group('repeats', () {
    test('five identical lines are one entry with repeat 5 and the last time', () {
      final logs = buffer();
      for (var i = 0; i < 5; i++) {
        now += 10;
        logs.add(FeedbackLogLevel.info, 'Polling cart', src: 'app');
      }
      final e = logs.entries.single;
      expect(e.repeat, 5);
      expect(e.toJson(), {
        't': 1760440000010,
        'level': 'info',
        'msg': 'Polling cart',
        'src': 'app',
        'repeat': 5,
        'last': 1760440000050,
      });
      expect(redactions, 1, reason: 'a repeat is not redacted again');
    });

    test('a line seen once carries neither repeat nor last', () {
      final logs = buffer()..add(FeedbackLogLevel.info, 'once');
      expect(logs.entries.single.toJson().keys.toSet(), {'t', 'level', 'msg'});
      expect(logs.entries.single.toJson().keys.toSet().intersection(logRepeatKeys), isEmpty);
    });

    test('a different level, source or text is a new line', () {
      final logs = buffer()
        ..add(FeedbackLogLevel.info, 'x', src: 'a')
        ..add(FeedbackLogLevel.warn, 'x', src: 'a')
        ..add(FeedbackLogLevel.warn, 'x', src: 'b')
        ..add(FeedbackLogLevel.warn, 'y', src: 'b')
        ..add(FeedbackLogLevel.warn, 'y', src: 'b');
      expect(logs.entries.map((e) => e.repeat), [1, 1, 1, 2]);
    });

    test('only the line just before collapses', () {
      final logs = buffer()
        ..add(FeedbackLogLevel.info, 'a')
        ..add(FeedbackLogLevel.info, 'b')
        ..add(FeedbackLogLevel.info, 'a');
      expect(logs.entries.map((e) => e.msg), ['a', 'b', 'a']);
    });
  });

  group('debugPrint storms', () {
    test('2,000 different lines in one second: 50 kept, one marker, 50 redactions', () {
      final logs = buffer();
      for (var i = 0; i < 2000; i++) {
        logs.add(FeedbackLogLevel.debug, 'frame $i rebuilt', src: 'debugPrint');
      }
      now += 1500; // the storm has passed
      logs.add(FeedbackLogLevel.info, 'quiet again');
      final entries = logs.entries;
      expect(entries.length, 52);
      expect(entries.take(50).last.msg, 'frame 49 rebuilt');
      final marker = entries[50];
      expect(marker.level, FeedbackLogLevel.warn);
      expect(marker.src, 'overblast');
      expect(marker.msg, '1,950 lines dropped in 1 s (too fast)');
      expect(entries.last.msg, 'quiet again');
      expect(redactions, 51, reason: 'dropped lines are never redacted');
    });

    test('a storm of the same line is one entry, nothing dropped', () {
      final logs = buffer();
      for (var i = 0; i < 5000; i++) {
        logs.add(FeedbackLogLevel.debug, 'setState() called', src: 'debugPrint');
      }
      expect(logs.entries.single.repeat, 5000);
      expect(redactions, 1);
    });

    test('a storm through the controller\'s debugPrint capture', () {
      final original = debugPrint;
      debugPrint = (m, {wrapWidth}) {};
      try {
        final c = OverblastFeedbackController(
          feedbackKey: testKey,
          store: MemoryFeedbackStore(),
          clock: () => DateTime.fromMillisecondsSinceEpoch(now),
        )..captureDebugPrint();
        for (var i = 0; i < 300; i++) {
          debugPrint('widget $i built');
        }
        c.error('real problem');
        final logs = c.logs;
        expect(logs.where((e) => e.src == 'debugPrint').length, 50);
        expect(logs.last.msg, '250 lines dropped in 1 s (too fast)');
        expect(logs.any((e) => e.msg == 'real problem'), isTrue, reason: 'errors still get in');
        c.dispose();
      } finally {
        debugPrint = original;
      }
    });

    test('a storm three seconds long is one marker', () {
      final logs = buffer();
      final start = now;
      for (var second = 0; second < 3; second++) {
        for (var i = 0; i < 1000; i++) {
          now = start + second * 1000 + i;
          logs.add(FeedbackLogLevel.info, 'tick $second.$i');
        }
      }
      now = start + 5000;
      logs.add(FeedbackLogLevel.info, 'after');
      final markers = logs.entries.where((e) => e.src == 'overblast').toList();
      expect(markers.single.msg, '2,850 lines dropped in 3 s (too fast)');
      expect(logs.entries.where((e) => e.msg.startsWith('tick')).length, 150);
    });

    test('warnings and errors get in past the 50, up to 200 a second', () {
      final logs = buffer();
      for (var i = 0; i < 100; i++) {
        logs.add(FeedbackLogLevel.debug, 'noise $i');
      }
      for (var i = 0; i < 300; i++) {
        logs.add(FeedbackLogLevel.error, 'error $i');
      }
      final entries = logs.entries;
      expect(entries.where((e) => e.level == FeedbackLogLevel.debug).length, 50);
      expect(entries.where((e) => e.level == FeedbackLogLevel.error).length, 200);
      expect(entries.last.msg, '150 lines dropped in 1 s (too fast)');
    });

    test('a report read mid-storm carries the marker', () {
      final logs = buffer();
      for (var i = 0; i < 80; i++) {
        logs.add(FeedbackLogLevel.info, 'l$i');
      }
      expect(logs.entries.last.msg, '30 lines dropped in 1 s (too fast)');
    });
  });

  group('budgets', () {
    test('debug and info go before warnings and errors', () {
      final logs = buffer(maxLines: 10);
      for (var i = 0; i < 3; i++) {
        now += 1000;
        logs.add(FeedbackLogLevel.error, 'old error $i');
      }
      for (var i = 0; i < 20; i++) {
        now += 1000;
        logs.add(FeedbackLogLevel.debug, 'debug $i');
      }
      final msgs = logs.entries.map((e) => e.msg).toList();
      expect(msgs.length, 10);
      expect(msgs.take(3), ['old error 0', 'old error 1', 'old error 2']);
      expect(msgs.last, 'debug 19');
      expect(msgs[3], 'debug 13');
    });

    test('the byte budget holds as well as the count', () {
      final logs = buffer(maxBytes: 50000);
      for (var i = 0; i < 100; i++) {
        now += 1000;
        logs.add(FeedbackLogLevel.info, '$i ${'x' * 3000}');
      }
      expect(logs.bytes, lessThanOrEqualTo(50000));
      expect(logs.length, lessThan(20));
      expect(logs.entries.last.msg, startsWith('99 '));
    });

    test('the defaults are the contract\'s', () {
      final logs = FeedbackLogBuffer();
      expect(logs.maxLines, 20000);
      expect(logs.maxBytes, 2000000);
      expect(logs.perSecond, 50);
      expect(logs.urgentPerSecond, 200);
    });

    test('paused, nothing is collected', () {
      final logs = buffer()..paused = true;
      logs.add(FeedbackLogLevel.error, 'while the sheet is open');
      expect(logs.entries, isEmpty);
      final c = OverblastFeedbackController(feedbackKey: testKey, store: MemoryFeedbackStore())..pauseLogs();
      c.info('x');
      c.recordNetwork('GET', 'https://a/b', 200, 1);
      expect(c.logs, isEmpty);
      expect(c.network, isEmpty);
      c.resumeLogs();
      c.info('y');
      expect(c.logs.single.msg, 'y');
      c.dispose();
    });
  });

  group('the excerpt', () {
    test('every warning and error in the two minutes before openedAt, then the newest others', () {
      final anchor = now;
      final all = <FeedbackLogEntry>[
        FeedbackLogEntry(t: anchor - 180000, level: FeedbackLogLevel.error, msg: 'too old to be chosen first'),
        for (var i = 0; i < 400; i++)
          FeedbackLogEntry(t: anchor - 119000 + i, level: FeedbackLogLevel.warn, msg: 'warn $i'),
        for (var i = 0; i < 1000; i++)
          FeedbackLogEntry(t: anchor - 60000 + i, level: FeedbackLogLevel.info, msg: 'info $i'),
      ];
      final excerpt = selectExcerpt(all, anchor: anchor);
      expect(excerpt.length, 500);
      expect(excerpt.where((e) => e.level == FeedbackLogLevel.warn).length, 400);
      expect(excerpt.where((e) => e.level == FeedbackLogLevel.info).length, 100);
      expect(excerpt.last.msg, 'info 999');
      expect(excerpt.any((e) => e.msg == 'too old to be chosen first'), isFalse);
      // Oldest first.
      for (var i = 1; i < excerpt.length; i++) {
        expect(excerpt[i].t, greaterThanOrEqualTo(excerpt[i - 1].t));
      }
    });

    test('the byte budget holds', () {
      final all = [
        for (var i = 0; i < 300; i++) FeedbackLogEntry(t: now - i, level: FeedbackLogLevel.error, msg: 'e' * 3000),
      ];
      final excerpt = selectExcerpt(all, anchor: now);
      expect(utf8.encode(jsonEncode([for (final e in excerpt) e.toJson()])).length, lessThanOrEqualTo(250000));
    });
  });

  group('the log file', () {
    FeedbackPayload payloadWith(List<FeedbackLogEntry> logs, {FeedbackScreenshot? shot}) => FeedbackPayload(
      message: 'x',
      context: FeedbackContext(openedAt: now, trigger: FeedbackTrigger.button),
      logs: logs,
      screenshot: shot,
    );

    test('left out when the excerpt holds every line', () {
      final json = payloadWith([FeedbackLogEntry(t: now, level: FeedbackLogLevel.info, msg: 'one')]).toJson();
      expect(json.containsKey('logFile'), isFalse);
    });

    test('gzip NDJSON of every line, oldest first, when the excerpt leaves some out', () {
      final logs = [
        for (var i = 0; i < 800; i++)
          FeedbackLogEntry(t: now - 800 + i, level: FeedbackLogLevel.info, msg: 'line $i', repeat: i == 5 ? 3 : 1),
      ];
      final json = payloadWith(logs).toJson();
      expect((json['logs']! as List).length, 500);
      final file = json['logFile']! as Map<String, Object?>;
      expect(file.keys.toSet(), logFileKeys);
      expect(file['contentType'], 'application/x-ndjson');
      expect(file['encoding'], 'gzip');
      expect(file['lines'], 800);
      expect(file['from'], now - 800);
      expect(file['to'], now - 1);
      final lines = gunzipLines(file);
      expect(lines.length, 800);
      expect(jsonDecode(lines.first), {'t': now - 800, 'level': 'info', 'msg': 'line 0'});
      expect(jsonDecode(lines[5]), containsPair('repeat', 3));
      expect(jsonDecode(lines.last)['msg'], 'line 799');
    });

    test('over its size, the oldest lines are cut and the first line says so', () {
      final logs = [
        for (var i = 0; i < 2000; i++) FeedbackLogEntry(t: now - 2000000 + i * 1000, level: FeedbackLogLevel.info, msg: 'line $i'),
      ];
      final file = buildLogFile(logs, maxBytes: 20000, compress: (b) => null)!;
      expect(file.gzip, isFalse);
      expect(file.bytes.length, lessThanOrEqualTo(20000));
      expect(file.cut, greaterThan(0));
      final lines = const LineSplitter().convert(utf8.decode(file.bytes));
      expect(file.lines, lines.length);
      final marker = jsonDecode(lines.first) as Map;
      expect(marker['src'], 'overblast');
      expect(marker['level'], 'warn');
      expect(
        marker['msg'],
        matches(RegExp(r'^older lines cut to fit: [\d,]+ lines from \d\d:\d\d to \d\d:\d\d$')),
      );
      expect(jsonDecode(lines.last)['msg'], 'line 1999');
      expect(jsonDecode(lines[1])['msg'], 'line ${file.cut}');
      expect(file.from, logs[file.cut].t);
    });

    test('beside a 5 MB screenshot the body stays within 8 MB: the log file shrinks', () {
      final random = math.Random(7);
      String noise(int n) => String.fromCharCodes(List.generate(n, (_) => 33 + random.nextInt(90)));
      final logs = [
        for (var i = 0; i < 520; i++) FeedbackLogEntry(t: now - 1000 + i, level: FeedbackLogLevel.info, msg: noise(3900)),
      ];
      final shot = FeedbackScreenshot(
        bytes: Uint8List.fromList(List.generate(FeedbackLimits.screenshotBytes, (_) => random.nextInt(256))),
      );
      final json = payloadWith(logs, shot: shot).toJson();
      final size = utf8.encode(jsonEncode(json)).length;
      expect(size, lessThanOrEqualTo(FeedbackLimits.bodyBytes));
      final file = json['logFile']! as Map<String, Object?>;
      final lines = gunzipLines(file);
      expect(jsonDecode(lines.first)['msg'], startsWith('older lines cut to fit'));
      expect(base64Decode(file['base64']! as String).length, lessThan(FeedbackLimits.logFileBytes));
    });
  });

  group('the on-disk copy', () {
    test('two rotating files, at most 4 MB, the newest lines kept', () async {
      final dir = await Directory.systemTemp.createTemp('overblast_feedback_logs');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileFeedbackStore(() async => dir);
      final line = 'x' * 999; // 1,000 bytes with its newline
      for (var batch = 0; batch < 10; batch++) {
        await store.appendLogLines([for (var i = 0; i < 1000; i++) '$batch-$i-$line'.substring(0, 999)]);
      }
      final files = [File('${dir.path}/logs.0.ndjson'), File('${dir.path}/logs.1.ndjson')];
      expect(files.every((f) => f.existsSync()), isTrue);
      for (final f in files) {
        expect(f.lengthSync(), lessThanOrEqualTo(FeedbackLimits.diskLogFileBytes));
      }
      final lines = await store.readLogLines();
      expect(lines.length * 1000, lessThanOrEqualTo(4000000));
      expect(lines.last, startsWith('9-999-'));
      await store.clearLogLines();
      expect(await store.readLogLines(), isEmpty);
    });

    test('the memory store rotates the same way', () async {
      final store = MemoryFeedbackStore();
      for (var batch = 0; batch < 10; batch++) {
        await store.appendLogLines([for (var i = 0; i < 1000; i++) 'b$batch-${'y' * 990}']);
      }
      final lines = await store.readLogLines();
      expect(lines.length, lessThanOrEqualTo(4000));
      expect(lines.last, startsWith('b9-'));
    });

    test('a line written again replaces its earlier copy; half a line is skipped', () {
      final logs = parseDiskLog([
        '{"s":1,"t":1,"level":"info","msg":"a"}',
        '{"s":2,"t":2,"level":"info","msg":"b"}',
        '{"s":1,"t":1,"level":"info","msg":"a","repeat":4,"last":9}',
        '{"s":3,"t":3,"level":"err',
      ]);
      expect(logs.map((e) => e.msg), ['a', 'b']);
      expect(logs.first.repeat, 4);
      expect(logs.first.last, 9);
    });
  });
}
