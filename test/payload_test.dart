import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/payload.dart' show clip, fitLogs;

import 'helpers.dart';

FeedbackPayload full({String message = 'The total does not update', List<FeedbackLogEntry>? logs}) => FeedbackPayload(
  message: message,
  category: FeedbackCategory.idea,
  reporter: const FeedbackReporter(email: 'ana@example.com', name: 'Ana', accountRef: 'cus_8812'),
  context: const FeedbackContext(
    screen: 'CartScreen',
    title: 'Your cart',
    appVersion: '2.4.1',
    build: '412',
    os: 'iOS',
    osVersion: '18.2',
    device: 'iPhone15,3',
    locale: 'pt-PT',
    timeZone: 'Europe/Lisbon',
    viewport: FeedbackViewport(width: 393, height: 852, devicePixelRatio: 3),
    deviceId: 'abc123_-',
    extra: {'plan': 'pro'},
  ),
  element: NativeAnchor(
    path: ['MaterialApp', 'CartScreen', 'ElevatedButton'],
    type: 'ElevatedButton',
    id: 'cart.remove',
    label: 'Remove',
    rect: FeedbackRect(x: 0.61, y: 0.42, w: 0.2, h: 0.05),
    viewportWidth: 393,
    viewportHeight: 852,
  ),
  screenshot: FeedbackScreenshot(bytes: Uint8List.fromList([1, 2, 3]), highlighted: true),
  logs: logs ?? [FeedbackLogEntry(t: 1760440000123, level: FeedbackLogLevel.error, msg: 'TypeError', src: 'flutter')],
  network: [
    FeedbackNetworkEntry(
      t: 1760440000100,
      method: 'post',
      url: 'https://api.example.com/cart?x=1#f',
      status: 500,
      ms: 312,
    ),
  ],
);

void main() {
  test('every key is one the contract names, and none is missing from a full report', () {
    final json = full().toJson();
    expect(json.keys.toSet(), topKeys);
    expect((json['reporter']! as Map).keys.toSet(), reporterKeys);
    final context = json['context']! as Map;
    // url and userAgent are the web library's.
    expect(context.keys.toSet(), contextKeys.difference({'url', 'userAgent'}));
    expect((context['viewport']! as Map).keys.toSet(), viewportKeys);
    expect((context['sdk']! as Map).keys.toSet(), sdkKeys);
    final element = json['element']! as Map;
    expect(element.keys.toSet(), nativeElementKeys);
    expect((element['rect']! as Map).keys.toSet(), rectKeys);
    expect((element['viewport']! as Map).keys.toSet(), {'w', 'h'});
    expect((json['screenshot']! as Map).keys.toSet(), screenshotKeys);
    expect(((json['logs']! as List).single as Map).keys.toSet(), logKeys);
    expect(((json['network']! as List).single as Map).keys.toSet(), networkKeys);
  });

  test('the values are the contract shapes', () {
    final json = full().toJson();
    expect(json['v'], 1);
    expect(json['category'], 'idea');
    final context = json['context']! as Map;
    expect(context['platform'], 'flutter');
    expect(context['sdk'], {'name': 'overblast-feedback-flutter', 'version': sdkVersion});
    expect(context['viewport'], {'w': 393, 'h': 852, 'dpr': 3.0});
    final element = json['element']! as Map;
    expect(element['kind'], 'native');
    expect(element['viewport'], {'w': 393, 'h': 852});
    final shot = json['screenshot']! as Map;
    expect(shot['contentType'], 'image/png');
    expect(base64Decode(shot['base64']! as String), [1, 2, 3]);
    expect(shot['highlighted'], true);
    final net = (json['network']! as List).single as Map;
    expect(net['method'], 'POST');
    expect(net['url'], 'https://api.example.com/cart');
    // The body survives JSON as is.
    expect(jsonDecode(jsonEncode(json)), json);
  });

  test('nulls, blanks and empty lists are left out', () {
    final json = const FeedbackPayload(message: '  hello  ', context: FeedbackContext()).toJson();
    expect(json.keys.toSet(), {'v', 'message', 'category', 'context'});
    expect(json['message'], 'hello');
    expect(json['category'], 'bug');
    expect((json['context']! as Map).keys.toSet(), {'platform', 'sdk'});
    final noReporter = const FeedbackPayload(
      message: 'x',
      reporter: FeedbackReporter(email: ' ', name: ''),
      context: FeedbackContext(),
    ).toJson();
    expect(noReporter.containsKey('reporter'), isFalse);
  });

  test('an implausible email is not sent; the rest of the reporter is', () {
    final json = const FeedbackPayload(
      message: 'x',
      reporter: FeedbackReporter(email: 'not an email', accountRef: 'u_1'),
      context: FeedbackContext(),
    ).toJson();
    expect(json['reporter'], {'accountRef': 'u_1'});
  });

  test('an empty message and an oversized screenshot are refused, not trimmed', () {
    expect(() => const FeedbackPayload(message: '   ', context: FeedbackContext()).toJson(), throwsArgumentError);
    expect(
      () => FeedbackPayload(
        message: 'x',
        context: const FeedbackContext(),
        screenshot: FeedbackScreenshot(bytes: Uint8List(FeedbackLimits.screenshotBytes + 1)),
      ).toJson(),
      throwsArgumentError,
    );
  });

  test('every string is trimmed to its limit', () {
    final long = 'a' * 5000;
    final json = FeedbackPayload(
      message: long,
      reporter: FeedbackReporter(name: long, accountRef: long),
      context: FeedbackContext(
        screen: long,
        title: long,
        appVersion: long,
        build: long,
        os: long,
        osVersion: long,
        device: long,
        locale: long,
        timeZone: long,
        extra: {for (var i = 0; i < 30; i++) 'k$i': long},
      ),
      element: NativeAnchor(
        path: List.generate(20, (i) => 'Widget$i${'x' * 100}'),
        type: long,
        id: long,
        label: long,
        rect: FeedbackRect(x: 0, y: 0, w: 1, h: 1),
        viewportWidth: 1,
        viewportHeight: 1,
      ),
    ).toJson();
    expect((json['message']! as String).length, 4000);
    final r = json['reporter']! as Map;
    expect((r['name']! as String).length, 120);
    expect((r['accountRef']! as String).length, 200);
    final c = json['context']! as Map;
    expect((c['screen']! as String).length, 200);
    expect((c['title']! as String).length, 200);
    for (final k in ['appVersion', 'build', 'os', 'osVersion', 'locale', 'timeZone']) {
      expect((c[k]! as String).length, 40, reason: k);
    }
    expect((c['device']! as String).length, 80);
    final extra = c['extra']! as Map;
    expect(extra.length, 20);
    expect(extra.values.every((v) => (v as String).length == 200), isTrue);
    final e = json['element']! as Map;
    final path = (e['path']! as List).cast<String>();
    expect(path.length, 12);
    expect(path.first, startsWith('Widget8')); // the 12 nearest the target are kept
    expect(path.every((s) => s.length <= 80), isTrue);
    expect((e['type']! as String).length, 80);
    expect((e['id']! as String).length, 120);
    expect((e['label']! as String).length, 120);
  });

  test('a deviceId outside [A-Za-z0-9_-]{1,64} is left out', () {
    Map ctx(String id) =>
        FeedbackPayload(
              message: 'x',
              context: FeedbackContext(deviceId: id),
            ).toJson()['context']!
            as Map;
    expect(ctx('ok-id_1')['deviceId'], 'ok-id_1');
    expect(ctx('has space').containsKey('deviceId'), isFalse);
    expect(ctx('a' * 65).containsKey('deviceId'), isFalse);
  });

  test('logs keep the newest 500 entries within the byte budget', () {
    final many = List.generate(
      800,
      (i) => FeedbackLogEntry(t: i, level: FeedbackLogLevel.info, msg: 'line $i', src: 'app'),
    );
    final kept = fitLogs(many);
    expect(kept.length, 500);
    expect(kept.first['t'], 300);
    expect(kept.last['t'], 799);

    final big = List.generate(200, (i) => FeedbackLogEntry(t: i, level: FeedbackLogLevel.info, msg: 'x' * 4000));
    final fitted = fitLogs(big);
    expect(utf8.encode(jsonEncode(fitted)).length, lessThanOrEqualTo(FeedbackLimits.logBytes));
    expect(fitted.last['t'], 199);
    expect(fitted.length, lessThan(200));
  });

  test('a log message is cut to 4000 and its source to 40', () {
    final e = FeedbackLogEntry(t: 1, level: FeedbackLogLevel.warn, msg: 'm' * 5000, src: 's' * 50);
    expect(e.msg.length, 4000);
    expect(e.src!.length, 40);
    expect(FeedbackLogEntry(t: 1, level: FeedbackLogLevel.warn, msg: 'm').toJson().containsKey('src'), isFalse);
  });

  test('network keeps the newest 100', () {
    final json = FeedbackPayload(
      message: 'x',
      context: const FeedbackContext(),
      network: List.generate(
        150,
        (i) => FeedbackNetworkEntry(t: i, method: 'GET', url: 'https://a/$i', status: 200, ms: 1),
      ),
    ).toJson();
    final net = json['network']! as List;
    expect(net.length, 100);
    expect((net.first as Map)['t'], 50);
  });

  test('rect fractions are clamped to the viewport', () {
    final r = FeedbackRect(x: -0.2, y: 0.9, w: 0.5, h: 0.5);
    expect(r.x, 0);
    expect(r.y, 0.9);
    expect(r.w, 0.5);
    expect(r.h, closeTo(0.1, 1e-9));
    final over = FeedbackRect(x: 1.4, y: double.nan, w: 2, h: -1);
    expect(over.x, 1);
    expect(over.w, 0);
    expect(over.y, 0);
    expect(over.h, 0);
    expect(FeedbackRect(x: 0.123456, y: 0, w: 0.1, h: 0.1).toJson()['x'], 0.1235);
  });

  test('clip never splits a surrogate pair', () {
    final s = '${'a' * 3}😀';
    expect(clip(s, 4), 'aaa');
    expect(clip(s, 5), s);
    expect(clip('abc', 10), 'abc');
  });
}
