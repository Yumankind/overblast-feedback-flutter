import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/store/store_io.dart';
import 'package:overblast_feedback/src/transport.dart';
import 'package:overblast_feedback/src/verification/keys.dart';
import 'package:overblast_feedback/src/verification/pow.dart';
import 'package:overblast_feedback/src/verification/signing.dart';

import 'helpers.dart';

// Device registration and report signing (docs/feedback-reports.md §8), against a fake worker and a
// fake platform half on the real `overblast_feedback/device` channel.

const String otherKey = 'obfk_ZYXWVUTSRQPONMLKJIHGFEDCBA';
const String challengePath = '/v1/feedback/devices/challenge';
const String devicesPath = '/v1/feedback/devices';
const String reportPath = '/v1/feedback';
const String configPath = '/v1/feedback/config';

/// The worker's three doors. Answers are queued per door; with none queued, each door says yes.
class FakeWorker {
  final List<http.Request> requests = [];
  final List<http.Response> challengeAnswers = [];
  final List<http.Response> deviceAnswers = [];
  final List<http.Response> reportAnswers = [];

  /// The key's `verification` as the config door answers it (§2.1); `flag` unless a test says.
  String verification = 'flag';
  int _challenges = 0;
  int _devices = 0;

  late final http.Client client = MockClient((req) async {
    requests.add(req);
    switch (req.url.path) {
      case configPath:
        return json(200, {
          'verification': verification,
          'errorPrompt': {'enabled': false, 'on': ['exception'], 'minHoursBetween': 24},
          'screenshots': true,
        });
      case challengePath:
        if (challengeAnswers.isNotEmpty) return challengeAnswers.removeAt(0);
        _challenges++;
        return json(200, {
          'challenge': {
            'id': 'ch_$_challenges',
            'salt': 'salt$_challenges',
            'difficulty': 6,
            'expiresAt': DateTime.utc(2026, 10, 14, 12, 5).toIso8601String(),
            'nonce': 'bm9uY2Utbm9uY2Utbm9uY2Utbm9uY2Utbm9uY2Utbm8',
          },
        });
      case devicesPath:
        if (deviceAnswers.isNotEmpty) return deviceAnswers.removeAt(0);
        _devices++;
        final method = (jsonDecode(req.body) as Map)['method'];
        return json(201, {
          'deviceId': 'fbd_$_devices',
          'level': method == 'pow' ? 'registered' : 'attested',
          'reason': method == 'pow' ? 'proof of work' : null,
        });
      case reportPath:
        if (reportAnswers.isNotEmpty) return reportAnswers.removeAt(0);
        return json(201, {'id': 'fbr_1', 'taskId': 't_1', 'conversationId': null});
    }
    return json(404, {'code': 'not_found'});
  });

  List<http.Request> at(String path) => requests.where((r) => r.url.path == path).toList();
  List<http.Request> get reports => at(reportPath);
  List<Map<String, Object?>> get registrations =>
      [for (final r in at(devicesPath)) (jsonDecode(r.body) as Map).cast<String, Object?>()];

  static http.Response json(int status, Object body, {Map<String, String> headers = const {}}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...headers});
}

/// The Swift and Kotlin halves, as far as the Dart side can tell. Plain-key signatures are a hash of
/// the alias and the data, so a test can recompute one from the request it saw.
class FakeNative {
  FakeNative(this.caps);

  Map<String, Object?> caps;
  final List<MethodCall> calls = [];
  final Set<String> liveKeys = {};
  final Map<String, Future<Object?> Function(MethodCall call)> overrides = {};

  static String plainSignature(String alias, List<int> data) =>
      b64url(sha256.convert([...utf8.encode('$alias|'), ...data]).bytes);

  void install() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    deviceChannel,
    _handle,
  );

  List<String> get methods => [for (final c in calls) c.method];
  Map<Object?, Object?> argsOf(String method) => calls.lastWhere((c) => c.method == method).arguments as Map;

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final override = overrides[call.method];
    if (override != null) return override(call);
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'capabilities':
        return caps;
      case 'attestApple':
        return {'keyId': 'S2V5SWQ+Lz0=', 'attestation': 'o2NmbXRvYXBwbGUtYXBwYXR0ZXN0'};
      case 'assertApple':
        return 'assert.${args['clientDataHash']}';
      case 'attestAndroid':
        liveKeys.add(args['alias'] as String);
        return ['TEVBRg==', 'Uk9PVA=='];
      case 'createPlainKey':
        liveKeys.add(args['alias'] as String);
        return 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE${args['alias']}';
      case 'sign':
        final alias = args['alias'] as String;
        if (!liveKeys.contains(alias)) throw PlatformException(code: 'invalid_key', message: 'no key');
        return plainSignature(alias, decodeB64(args['data'] as String));
      case 'deleteKey':
        liveKeys.remove(args['alias']);
        return null;
    }
    throw MissingPluginException();
  }
}

const Map<String, Object?> iosCaps = {'appAttest': true, 'androidKeyAttestation': false, 'plainKey': true};
const Map<String, Object?> iosSimulatorCaps = {'appAttest': false, 'androidKeyAttestation': false, 'plainKey': true};
const Map<String, Object?> androidCaps = {'appAttest': false, 'androidKeyAttestation': true, 'plainKey': true};

/// The request carries the three headers, and the signature covers the canonical string of the very
/// bytes that were sent.
void expectSignedBy(http.Request req, String deviceId, {String? alias, bool appAttest = false}) {
  final h = req.headers;
  expect(h[deviceHeader], deviceId);
  final time = int.parse(h[timeHeader]!);
  final canonical = utf8.encode(canonicalSigningString(deviceId, time, req.bodyBytes));
  if (appAttest) {
    expect(h[signatureHeader], 'assert.${b64url(sha256.convert(canonical).bytes)}');
  } else {
    expect(h[signatureHeader], FakeNative.plainSignature(alias!, canonical));
  }
}

void expectUnsigned(http.Request req) {
  expect(req.headers.containsKey(deviceHeader), isFalse);
  expect(req.headers.containsKey(signatureHeader), isFalse);
  expect(req.headers.containsKey(timeHeader), isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWorker worker;
  late FakeNative native;
  late MemoryFeedbackStore store;
  late DateTime now;
  final made = <OverblastFeedbackController>[];

  setUp(() {
    worker = FakeWorker();
    native = FakeNative(androidCaps)..install();
    store = MemoryFeedbackStore();
    now = DateTime.utc(2026, 10, 14, 12);
  });

  tearDown(() {
    for (final c in made) {
      c.dispose();
    }
    made.clear();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(deviceChannel, null);
  });

  Future<OverblastFeedbackController> make({
    String key = testKey,
    FeedbackStore? withStore,
    PowSolver? solver,
    Duration wait = const Duration(seconds: 3),
    bool verification = true,
  }) async {
    final c = OverblastFeedbackController(
      feedbackKey: key,
      store: withStore ?? store,
      deviceFacts: fakeFacts,
      httpClient: worker.client,
      clock: () => now,
      deviceVerification: verification,
      deviceWait: wait,
      powSolver: solver ?? (salt, difficulty, budget) async => solvePow(salt, difficulty),
    );
    made.add(c);
    // What the widget does at start: read what the key allows.
    await c.refreshConfig();
    return c;
  }

  Future<FeedbackResult> send(OverblastFeedbackController c, [String message = 'The total is wrong']) async =>
      c.submit(await c.buildPayload(message: message));

  group('the signed string', () {
    test('is the contract string over SHA-256 of the exact bytes, base64url without padding', () {
      // Written out by hand: SHA-256("abc") is ba7816bf...15ad.
      expect(
        canonicalSigningString('fbd_1', 1760440000000, utf8.encode('abc')),
        'overblast-feedback-v1\nfbd_1\n1760440000000\nungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0',
      );
    });

    test('one byte of difference is a different string', () {
      final a = canonicalSigningString('fbd_1', 1, utf8.encode('{"v":1}'));
      final b = canonicalSigningString('fbd_1', 1, utf8.encode('{"v": 1}'));
      expect(a, isNot(b));
    });

    test('base64 helpers round-trip either alphabet, padded or not', () {
      final bytes = [0xfb, 0xff, 0xfe, 0x00, 0x01];
      expect(b64url(bytes), '-__-AAE');
      expect(decodeB64('-__-AAE'), bytes);
      expect(decodeB64('+//+AAE='), bytes);
    });

    test('the transport sends the given bytes as they are, with the device headers', () async {
      late http.Request seen;
      final transport = FeedbackTransport(
        feedbackKey: testKey,
        client: MockClient((req) async {
          seen = req;
          return FakeWorker.json(201, {'id': 'fbr_1', 'taskId': 't'});
        }),
      );
      final bytes = utf8.encode('{"v":1,  "message":"spaced"}');
      await transport.sendBytes(bytes, headers: {deviceHeader: 'fbd_1', timeHeader: '1', signatureHeader: 'sig'});
      expect(seen.bodyBytes, bytes);
      expect(seen.headers[deviceHeader], 'fbd_1');
      expect(seen.headers['X-Overblast-Feedback-Key'], testKey);
    });
  });

  group('proof of work', () {
    test('leading zero bits', () {
      expect(leadingZeroBits([0x00, 0x00, 0xff]), 16);
      expect(leadingZeroBits([0x00, 0x0f]), 12);
      expect(leadingZeroBits([0x80]), 0);
      expect(leadingZeroBits([0x01]), 7);
      expect(leadingZeroBits([0, 0]), 16);
    });

    test('finds the smallest decimal nonce for SHA-256("<salt>:<nonce>")', () {
      final nonce = solvePow('8f3a-salt', 12)!;
      expect(nonce, matches(RegExp(r'^\d{1,16}$')));
      expect(leadingZeroBits(sha256.convert(utf8.encode('8f3a-salt:$nonce')).bytes), greaterThanOrEqualTo(12));
      for (var n = 0; n < int.parse(nonce); n++) {
        expect(leadingZeroBits(sha256.convert(utf8.encode('8f3a-salt:$n')).bytes), lessThan(12));
      }
    });

    test('gives up at the deadline', () {
      final past = DateTime.now().millisecondsSinceEpoch - 1;
      expect(solvePow('s', 60, deadline: past), isNull);
    });

    test('runs on a background isolate', () async {
      final nonce = await solvePowInBackground('isolate', 10, const Duration(seconds: 20));
      expect(leadingZeroBits(sha256.convert(utf8.encode('isolate:$nonce')).bytes), greaterThanOrEqualTo(10));
    });
  });

  group('registration', () {
    test('Android: hardware key attestation with the challenge nonce, then reports signed by that key', () async {
      final c = await make();
      final device = await c.prepareDevice();
      expect(device!.method, FeedbackDeviceMethod.androidKey);
      expect(c.deviceLevel, FeedbackDeviceLevel.attested);
      final attest = native.argsOf('attestAndroid');
      expect(attest['nonce'], 'bm9uY2Utbm9uY2Utbm9uY2Utbm9uY2Utbm9uY2Utbm8');
      expect(device.alias, attest['alias']);
      expect(worker.registrations.single, {
        'challengeId': 'ch_1',
        'method': 'android_key',
        'chain': ['TEVBRg==', 'Uk9PVA=='],
      });
      expect(worker.at(challengePath).single.headers['X-Overblast-Feedback-Key'], testKey);

      await send(c);
      expectSignedBy(worker.reports.single, 'fbd_1', alias: device.alias);
      expect(worker.reports.single.headers[timeHeader], '${now.millisecondsSinceEpoch}');
      // Kept for the next launch.
      expect((await store.readRegisteredDevice())!.deviceId, 'fbd_1');
    });

    test('iOS: App Attest, then each report is an assertion over SHA-256 of the canonical string', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      native.caps = iosCaps;
      final c = await make();
      final device = await c.prepareDevice();
      expect(device!.method, FeedbackDeviceMethod.appAttest);
      expect(device.keyId, 'S2V5SWQ+Lz0=');
      expect(device.alias, isNull);
      expect(worker.registrations.single, {
        'challengeId': 'ch_1',
        'method': 'app_attest',
        'keyId': 'S2V5SWQ+Lz0=',
        'attestation': 'o2NmbXRvYXBwbGUtYXBwYXR0ZXN0',
      });
      expect(native.methods, isNot(contains('createPlainKey')));

      await send(c);
      expectSignedBy(worker.reports.single, 'fbd_1', appAttest: true);
      expect(native.argsOf('assertApple')['keyId'], 'S2V5SWQ+Lz0=');
    });

    test('iOS without App Attest (the simulator): a fresh challenge and a proof of work with a plain key', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      native.caps = iosSimulatorCaps;
      final c = await make();
      final device = await c.prepareDevice();
      expect(device!.method, FeedbackDeviceMethod.pow);
      expect(c.deviceLevel, FeedbackDeviceLevel.registered);
      expect(device.reason, 'proof of work');
      expect(native.methods, isNot(contains('attestApple')));
      final reg = worker.registrations.single;
      expect(reg['method'], 'pow');
      expect(reg['publicKey'], startsWith('MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE'));
      final nonce = reg['powNonce'] as String;
      expect(leadingZeroBits(sha256.convert(utf8.encode('salt1:$nonce')).bytes), greaterThanOrEqualTo(6));

      await send(c);
      expectSignedBy(worker.reports.single, device.deviceId, alias: device.alias);
    });

    test('iOS: App Attest that fails on the device falls back to the proof of work on a fresh challenge', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      native.caps = iosCaps;
      native.overrides['attestApple'] = (_) async =>
          throw PlatformException(code: 'failed', message: 'attestKey: missing entitlement');
      final c = await make();
      final device = await c.prepareDevice();
      expect(device!.method, FeedbackDeviceMethod.pow);
      expect(worker.at(challengePath).length, 2);
      expect(worker.registrations.single['challengeId'], 'ch_2');
    });

    test('403 attestation_invalid: the attested key is deleted and the proof of work follows', () async {
      worker.deviceAnswers.add(FakeWorker.json(403, {'code': 'attestation_invalid', 'error': 'Bad chain.'}));
      final c = await make();
      final device = await c.prepareDevice();
      final attestedAlias = native.argsOf('attestAndroid')['alias'];
      expect(native.calls.any((m) => m.method == 'deleteKey' && (m.arguments as Map)['alias'] == attestedAlias), isTrue);
      expect(device!.method, FeedbackDeviceMethod.pow);
      expect(worker.registrations.map((r) => r['method']), ['android_key', 'pow']);
      expect(worker.registrations.last['challengeId'], 'ch_2');
      expect(native.liveKeys, {device.alias});
    });

    test('an attestation the worker calls registered is kept, not retried for better', () async {
      worker.deviceAnswers.add(FakeWorker.json(201, {'deviceId': 'fbd_x', 'level': 'registered', 'reason': 'unlocked'}));
      final c = await make();
      final device = await c.prepareDevice();
      expect(device!.method, FeedbackDeviceMethod.androidKey);
      expect(c.deviceLevel, FeedbackDeviceLevel.registered);
      expect(device.reason, 'unlocked');
      expect(worker.registrations.length, 1);
    });

    test('no platform half at all (desktop, the web): nothing is asked of the worker, reports go unsigned', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(deviceChannel, null);
      final c = await make();
      expect(await c.prepareDevice(), isNull);
      await send(c);
      expect(worker.at(challengePath), isEmpty);
      expectUnsigned(worker.reports.single);
      expect(c.deviceLevel, FeedbackDeviceLevel.none);
    });

    test('a native key that cannot be made: no registration, unsigned', () async {
      native.caps = iosSimulatorCaps;
      native.overrides['createPlainKey'] = (_) async => throw PlatformException(code: 'failed');
      final c = await make();
      expect(await c.prepareDevice(), isNull);
      await send(c);
      expect(worker.registrations, isEmpty);
      expectUnsigned(worker.reports.single);
    });

    test('a proof of work not found in its budget deletes the key and sends unsigned', () async {
      native.caps = iosSimulatorCaps;
      final c = await make(solver: (salt, difficulty, budget) async => null);
      expect(await c.prepareDevice(), isNull);
      expect(native.liveKeys, isEmpty);
      expect(worker.registrations, isEmpty);
    });

    test('429 on the challenge door: unsigned, and not asked again before Retry-After', () async {
      worker.challengeAnswers.add(FakeWorker.json(429, {'code': 'rate_limited', 'retryAfter': 60}));
      final c = await make();
      await send(c);
      expectUnsigned(worker.reports.single);
      await send(c);
      expect(worker.at(challengePath).length, 1);
      now = now.add(const Duration(seconds: 61));
      await send(c);
      expect(worker.at(challengePath).length, 2);
      expectSignedBy(worker.reports.last, 'fbd_1', alias: c.device!.alias);
    });

    test('429 on the devices door: unsigned', () async {
      worker.deviceAnswers.add(FakeWorker.json(429, {'code': 'rate_limited', 'retryAfter': 60}));
      final c = await make();
      await send(c);
      expectUnsigned(worker.reports.single);
      expect(native.liveKeys, isEmpty, reason: 'the key made for the refused registration is deleted');
    });

    test('concurrent callers share one registration', () async {
      final c = await make();
      final results = await Future.wait([c.prepareDevice(), c.prepareDevice(), send(c).then((_) => null)]);
      expect(results[0]!.deviceId, results[1]!.deviceId);
      expect(worker.at(challengePath).length, 1);
    });

    test('deviceVerification: false never registers and never signs', () async {
      final c = await make(verification: false);
      expect(await c.prepareDevice(), isNull);
      await send(c);
      expect(native.calls, isEmpty);
      expectUnsigned(worker.reports.single);
    });

    test('the level notifies listeners when it changes', () async {
      final c = await make();
      final levels = <FeedbackDeviceLevel>[];
      c.addListener(() => levels.add(c.deviceLevel));
      await c.prepareDevice();
      expect(levels, contains(FeedbackDeviceLevel.attested));
    });
  });

  group('kept between launches', () {
    test('a stored device is used as it is, with no new challenge', () async {
      final first = await make();
      final device = await first.prepareDevice();
      final second = await make();
      await send(second);
      expect(worker.at(challengePath).length, 1);
      expectSignedBy(worker.reports.single, device!.deviceId, alias: device.alias);
      expect(second.deviceLevel, FeedbackDeviceLevel.attested);
    });

    test('a device registered under another feedback key is forgotten and its key deleted', () async {
      final first = await make();
      final old = await first.prepareDevice();
      final second = await make(key: otherKey);
      final fresh = await second.prepareDevice();
      expect(fresh!.deviceId, isNot(old!.deviceId));
      expect(native.liveKeys, {fresh.alias});
      expect(worker.at(challengePath).last.headers['X-Overblast-Feedback-Key'], otherKey);
    });

    test('the file store keeps it in device.json and forgets it on null', () async {
      final dir = await Directory.systemTemp.createTemp('overblast_feedback_device');
      addTearDown(() => dir.delete(recursive: true));
      final files = FileFeedbackStore(() async => dir);
      final c = await make(withStore: files);
      final device = await c.prepareDevice();
      final read = await FileFeedbackStore(() async => dir).readRegisteredDevice();
      expect(read!.toJson(), device!.toJson());
      expect(File('${dir.path}/device.json').existsSync(), isTrue);
      await files.writeRegisteredDevice(null);
      expect(await files.readRegisteredDevice(), isNull);
    });

    test('a record that names no key reads as absent', () {
      expect(
        FeedbackDeviceRegistration.fromJson({
          'deviceId': 'fbd_1',
          'method': 'pow',
          'level': 'registered',
          'scope': 's',
          'registeredAt': 1,
        }),
        isNull,
      );
    });
  });

  group('refusals of a signed report', () {
    for (final code in ['unknown_device', 'device_signature_invalid']) {
      test('401 $code: drop the device and its key, register again, resend once', () async {
        final c = await make();
        final old = (await c.prepareDevice())!;
        worker.reportAnswers.add(FakeWorker.json(401, {'code': code, 'error': 'Unknown device.'}));
        final result = await send(c);
        expect(result.id, 'fbr_1');
        expect(worker.reports.length, 2);
        expectSignedBy(worker.reports[0], old.deviceId, alias: old.alias);
        final fresh = c.device!;
        expect(fresh.deviceId, isNot(old.deviceId));
        expectSignedBy(worker.reports[1], fresh.deviceId, alias: fresh.alias);
        expect(native.liveKeys, {fresh.alias});
        // The same report: the body did not change between the two sends.
        expect(worker.reports[1].body, worker.reports[0].body);
      });
    }

    test('a second 401 is not resent again', () async {
      final c = await make();
      await c.prepareDevice();
      worker.reportAnswers
        ..add(FakeWorker.json(401, {'code': 'unknown_device'}))
        ..add(FakeWorker.json(401, {'code': 'unknown_device'}));
      await expectLater(
        send(c),
        throwsA(isA<OverblastFeedbackException>().having((e) => e.code, 'code', 'unknown_device')),
      );
      expect(worker.reports.length, 2);
    });

    test('403 device_required while the registration is still running: wait for it, resend once signed', () async {
      native.caps = iosSimulatorCaps;
      final gate = Completer<String?>();
      final c = await make(solver: (salt, difficulty, budget) => gate.future, wait: const Duration(milliseconds: 50));
      worker.reportAnswers.add(FakeWorker.json(403, {'code': 'device_required', 'error': 'Verified devices only.'}));
      final sent = send(c);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(worker.reports.length, 1);
      expectUnsigned(worker.reports.single);
      gate.complete(solvePow('salt1', 6));
      final result = await sent;
      expect(result.id, 'fbr_1');
      expect(worker.reports.length, 2);
      expectSignedBy(worker.reports[1], c.device!.deviceId, alias: c.device!.alias);
    });

    test('403 device_required after a registration already failed: no resend', () async {
      worker.challengeAnswers.add(FakeWorker.json(503, {'code': 'misconfigured'}));
      final c = await make();
      worker.reportAnswers.add(FakeWorker.json(403, {'code': 'device_required', 'error': 'Verified devices only.'}));
      await expectLater(
        send(c),
        throwsA(
          isA<OverblastFeedbackException>()
              .having((e) => e.code, 'code', 'device_required')
              .having((e) => e.message, 'message', 'Verified devices only.'),
        ),
      );
      expect(worker.reports.length, 1);
    });

    test('a key that can no longer sign: the device is dropped and the report goes unsigned', () async {
      final c = await make();
      await c.prepareDevice();
      native.liveKeys.clear(); // restored onto another phone, say
      await send(c);
      expectUnsigned(worker.reports.first);
    });

    test('a draft kept after a 429 is signed afresh when it is sent', () async {
      final c = await make();
      final device = (await c.prepareDevice())!;
      worker.reportAnswers.add(FakeWorker.json(429, {'code': 'rate_limited', 'retryAfter': 1}));
      await expectLater(
        send(c),
        throwsA(isA<OverblastFeedbackException>().having((e) => e.savedForLater, 'saved', isTrue)),
      );
      now = now.add(const Duration(seconds: 5));
      expect(await c.retryPending(), 1);
      final first = worker.reports[0];
      final retry = worker.reports[1];
      expectSignedBy(retry, device.deviceId, alias: device.alias);
      expect(int.parse(retry.headers[timeHeader]!), int.parse(first.headers[timeHeader]!) + 5000);
      expect(retry.headers[signatureHeader], isNot(first.headers[signatureHeader]));
    });
  });

  group('the key decides (§2.1)', () {
    test('verification off: no challenge, no key, unsigned', () async {
      worker.verification = 'off';
      final c = await make();
      expect(await c.prepareDevice(), isNull);
      await send(c);
      expect(worker.at(challengePath), isEmpty);
      expect(native.calls, isEmpty);
      expectUnsigned(worker.reports.single);
    });

    test('before the config door has ever answered, the defaults hold: nothing registers', () async {
      final c = OverblastFeedbackController(
        feedbackKey: testKey,
        store: store,
        deviceFacts: fakeFacts,
        httpClient: worker.client,
        clock: () => now,
      );
      made.add(c);
      expect(c.config.verification, FeedbackVerification.off);
      await send(c);
      expect(worker.at(challengePath), isEmpty);
      expectUnsigned(worker.reports.single);
    });

    test('a device kept from when verification was on signs nothing once it is off', () async {
      final first = await make();
      await first.prepareDevice();
      worker.verification = 'off';
      final second = await make();
      await send(second);
      expectUnsigned(worker.reports.single);
    });

    test('403 device_required with a stale "off": the config is read again, then the device registers', () async {
      worker.verification = 'off';
      final c = await make();
      worker.verification = 'require';
      worker.reportAnswers.add(FakeWorker.json(403, {'code': 'device_required', 'error': 'Verified devices only.'}));
      final result = await send(c);
      expect(result.id, 'fbr_1');
      expect(worker.at(configPath).length, 2);
      expectSignedBy(worker.reports.last, c.device!.deviceId, alias: c.device!.alias);
    });
  });

  testWidgets('Send waits three seconds for a registration in flight, then sends unsigned', (tester) async {
    native.caps = iosSimulatorCaps;
    final gate = Completer<String?>();
    final c = OverblastFeedbackController(
      feedbackKey: testKey,
      store: store,
      deviceFacts: fakeFacts,
      httpClient: worker.client,
      clock: () => now,
      powSolver: (salt, difficulty, budget) => gate.future,
    );
    expect(c.deviceWait, const Duration(seconds: 3));
    await c.refreshConfig();
    final payload = await c.buildPayload(message: 'Slow phone');
    var done = false;
    unawaited(c.submit(payload).then((_) => done = true));
    await tester.pump(const Duration(milliseconds: 2900));
    expect(worker.reports, isEmpty);
    expect(worker.at(challengePath).length, 1, reason: 'the registration is under way');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(worker.reports.length, 1);
    expectUnsigned(worker.reports.single);
    expect(done, isTrue);
    c.dispose();
  });

  testWidgets('the sheet starts the registration as it opens', (tester) async {
    final c = OverblastFeedbackController(
      feedbackKey: testKey,
      store: store,
      deviceFacts: fakeFacts,
      httpClient: worker.client,
      clock: () => now,
      trackCrashes: false,
    );
    await tester.pumpWidget(
      OverblastFeedback(
        controller: c,
        enableShake: false,
        captureDebugPrint: false,
        captureErrors: false,
        retryPendingOnStart: false,
        child: const SizedBox.expand(),
      ),
    );
    expect(native.calls, isEmpty);
    unawaited(c.show());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(native.methods, containsAllInOrder(['capabilities', 'attestAndroid']));
    expect(c.deviceLevel, FeedbackDeviceLevel.attested);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
