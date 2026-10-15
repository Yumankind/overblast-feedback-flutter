import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'keys.dart';
import 'pow.dart';
import 'registration.dart';

/// A challenge from `POST /v1/feedback/devices/challenge` (docs/feedback-reports.md §8.2).
class DeviceChallenge {
  const DeviceChallenge({
    required this.id,
    required this.salt,
    required this.difficulty,
    required this.nonce,
    this.expiresAt,
  });

  final String id;
  final String salt;
  final int difficulty;

  /// 32 random bytes, base64url, that an attestation carries.
  final String nonce;

  /// Milliseconds since the epoch, when the worker said.
  final int? expiresAt;

  static DeviceChallenge? fromJson(Object? json) {
    final c = json is Map ? json['challenge'] : null;
    if (c is! Map) return null;
    final id = c['id'];
    final salt = c['salt'];
    final difficulty = c['difficulty'];
    final nonce = c['nonce'];
    if (id is! String || salt is! String || difficulty is! num || nonce is! String) return null;
    // The contract does not say how expiresAt is spelt; both readings are taken.
    final raw = c['expiresAt'];
    int? expiresAt;
    if (raw is num) {
      expiresAt = raw < 1e11 ? (raw * 1000).round() : raw.round(); // seconds or milliseconds
    } else if (raw is String) {
      expiresAt = DateTime.tryParse(raw)?.millisecondsSinceEpoch;
    }
    return DeviceChallenge(id: id, salt: salt, difficulty: difficulty.toInt(), nonce: nonce, expiresAt: expiresAt);
  }
}

/// One step of the registration: a device, a reason to fall back to the proof of work, or a reason
/// to stop (the door refused or could not be reached; trying more would only spend the allowance).
sealed class _Step {
  const _Step();
}

class _Done extends _Step {
  const _Done(this.device);
  final FeedbackDeviceRegistration device;
}

class _FallBack extends _Step {
  const _FallBack();
}

class _Stop extends _Step {
  const _Stop();
}

class _Refused implements Exception {
  const _Refused(this.status, this.code, this.retryAfter);
  final int status;
  final String? code;
  final int? retryAfter;
}

/// Registers this install as a device with the worker, once (§8.2): App Attest on iOS, hardware key
/// attestation on Android, and on anything else, or when attestation is unavailable or refused with
/// `attestation_invalid`, a fresh challenge and a proof of work with a native plain key.
///
/// [register] never throws. A failure is null, and [retryNotBefore] says when trying again is worth
/// it (a `429`'s `Retry-After`, or ten minutes).
class DeviceRegistrar {
  DeviceRegistrar({
    required this.feedbackKey,
    required Uri endpoint,
    http.Client? client,
    this.keys = const DeviceKeys(),
    PowSolver? powSolver,
    this.powBudget = const Duration(seconds: 20),
    this.requestTimeout = const Duration(seconds: 20),
    DateTime Function()? clock,
    void Function(String message)? log,
  }) : challengeUri = _child(endpoint, 'devices/challenge'),
       devicesUri = _child(endpoint, 'devices'),
       scope = '$feedbackKey@${endpoint.origin}',
       _client = client,
       _solver = powSolver ?? solvePowInBackground,
       _clock = clock ?? DateTime.now,
       _log = log;

  final String feedbackKey;
  final Uri challengeUri;
  final Uri devicesUri;
  final DeviceKeys keys;

  /// How long the proof of work may take before the registration gives up (§8.2 suggests about 20 s).
  final Duration powBudget;
  final Duration requestTimeout;

  /// The hardest proof of work the library will attempt (§8.2).
  static const int maxDifficulty = 40;

  /// What a registration is bound to: the feedback key and the door's origin.
  final String scope;

  final http.Client? _client;
  final PowSolver _solver;
  final DateTime Function() _clock;
  final void Function(String message)? _log;

  /// After a failed [register], not worth trying again before this (milliseconds since the epoch).
  int? retryNotBefore;

  static Uri _child(Uri endpoint, String path) {
    final base = endpoint.path.endsWith('/') ? endpoint.path.substring(0, endpoint.path.length - 1) : endpoint.path;
    return endpoint.replace(path: '$base/$path', query: null, fragment: null);
  }

  Future<FeedbackDeviceRegistration?> register() async {
    retryNotBefore = null;
    try {
      final caps = await keys.capabilities();
      if (!caps.any) {
        _note('no native keys on this platform; reports go unsigned');
        return _fail(const Duration(days: 365));
      }
      _Step step = const _FallBack();
      final platform = defaultTargetPlatform;
      if (!kIsWeb && platform == TargetPlatform.iOS && caps.appAttest) {
        step = await _appAttest();
      } else if (!kIsWeb && platform == TargetPlatform.android && caps.androidKeyAttestation) {
        step = await _androidKey();
      }
      if (step is _Done) return step.device;
      if (step is _Stop) return _fail();
      if (!caps.plainKey) return _fail(const Duration(days: 365));
      final pow = await _pow();
      return pow is _Done ? pow.device : _fail();
    } on _Refused catch (e) {
      _note('device door refused: ${e.status} ${e.code ?? ''}');
      return _fail(e.retryAfter == null ? null : Duration(seconds: e.retryAfter!));
    } catch (e) {
      _note('device registration failed: $e');
      return _fail();
    }
  }

  FeedbackDeviceRegistration? _fail([Duration? wait]) {
    retryNotBefore ??= _clock().add(wait ?? const Duration(minutes: 10)).millisecondsSinceEpoch;
    return null;
  }

  Future<_Step> _appAttest() async {
    final challenge = await _challenge();
    final AppleAttestation attestation;
    try {
      attestation = await keys.attestApple(challenge.nonce);
    } on DeviceKeyException catch (e) {
      _note('App Attest unavailable (${e.code}${e.message == null ? '' : ': ${e.message}'}); proof of work instead');
      return const _FallBack();
    }
    try {
      final answer = await _post(devicesUri, {
        'challengeId': challenge.id,
        'method': FeedbackDeviceMethod.appAttest.wire,
        'keyId': attestation.keyId,
        'attestation': attestation.attestation,
      });
      return _Done(_registration(answer, FeedbackDeviceMethod.appAttest, keyId: attestation.keyId));
    } on _Refused catch (e) {
      if (e.status == 403 && e.code == 'attestation_invalid') {
        _note('App Attest attestation refused; proof of work instead');
        return const _FallBack();
      }
      rethrow;
    }
  }

  Future<_Step> _androidKey() async {
    final challenge = await _challenge();
    final alias = _newAlias();
    final List<String> chain;
    try {
      chain = await keys.attestAndroid(alias, challenge.nonce);
    } on DeviceKeyException catch (e) {
      await keys.deleteKey(alias);
      _note('key attestation unavailable (${e.code}); proof of work instead');
      return const _FallBack();
    }
    try {
      final answer = await _post(devicesUri, {
        'challengeId': challenge.id,
        'method': FeedbackDeviceMethod.androidKey.wire,
        'chain': chain,
      });
      return _Done(_registration(answer, FeedbackDeviceMethod.androidKey, alias: alias));
    } on _Refused catch (e) {
      await keys.deleteKey(alias);
      if (e.status == 403 && e.code == 'attestation_invalid') {
        _note('key attestation refused; proof of work instead');
        return const _FallBack();
      }
      rethrow;
    } catch (_) {
      await keys.deleteKey(alias);
      rethrow;
    }
  }

  Future<_Step> _pow() async {
    final challenge = await _challenge(); // always a fresh one: an attestation may have spent the last
    if (challenge.difficulty > maxDifficulty) {
      // §8.2: the worker never asks for more than 24 bits; a challenge above 40 is refused, unsigned.
      _note('proof of work difficulty ${challenge.difficulty} refused (above $maxDifficulty)');
      return const _Stop();
    }
    final alias = _newAlias();
    final String publicKey;
    try {
      publicKey = await keys.createPlainKey(alias);
    } on DeviceKeyException catch (e) {
      await keys.deleteKey(alias);
      _note('no plain key on this device (${e.code}); reports go unsigned');
      return const _Stop();
    }
    try {
      var budget = powBudget;
      final expiresAt = challenge.expiresAt;
      if (expiresAt != null) {
        // Leave a few seconds to send the answer before the challenge lapses.
        final left = Duration(milliseconds: expiresAt - _clock().millisecondsSinceEpoch - 5000);
        if (left < budget) budget = left;
      }
      final nonce = budget <= Duration.zero ? null : await _solver(challenge.salt, challenge.difficulty, budget);
      if (nonce == null) {
        await keys.deleteKey(alias);
        _note('proof of work (difficulty ${challenge.difficulty}) not found within ${budget.inSeconds} s');
        return const _Stop();
      }
      final answer = await _post(devicesUri, {
        'challengeId': challenge.id,
        'method': FeedbackDeviceMethod.pow.wire,
        'powNonce': nonce,
        'publicKey': publicKey,
      });
      return _Done(_registration(answer, FeedbackDeviceMethod.pow, alias: alias));
    } catch (_) {
      await keys.deleteKey(alias);
      rethrow;
    }
  }

  FeedbackDeviceRegistration _registration(
    Map<String, Object?> answer,
    FeedbackDeviceMethod method, {
    String? keyId,
    String? alias,
  }) {
    final deviceId = answer['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) throw const _Refused(201, 'no_device_id', null);
    final reason = answer['reason'];
    return FeedbackDeviceRegistration(
      deviceId: deviceId,
      method: method,
      level: FeedbackDeviceLevel.parse(answer['level']),
      reason: reason is String ? reason : null,
      keyId: keyId,
      alias: alias,
      scope: scope,
      registeredAt: _clock().millisecondsSinceEpoch,
    );
  }

  Future<DeviceChallenge> _challenge() async {
    final answer = await _post(challengeUri, const {});
    final challenge = DeviceChallenge.fromJson(answer);
    if (challenge == null) throw const _Refused(200, 'bad_challenge', null);
    return challenge;
  }

  Future<Map<String, Object?>> _post(Uri uri, Map<String, Object?> body) async {
    final client = _client ?? http.Client();
    final http.Response response;
    try {
      response = await client
          .post(
            uri,
            headers: {'Content-Type': 'application/json', 'X-Overblast-Feedback-Key': feedbackKey},
            body: jsonEncode(body),
          )
          .timeout(requestTimeout);
    } finally {
      if (_client == null) client.close();
    }
    Map<String, Object?> json = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, Object?>) json = decoded;
    } on FormatException {
      // The status says enough.
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return json;
    final code = json['code'];
    final ra = json['retryAfter'];
    final retryAfter = ra is num ? ra.ceil() : int.tryParse(response.headers['retry-after'] ?? '');
    throw _Refused(response.statusCode, code is String ? code : null, retryAfter);
  }

  void _note(String message) => _log?.call(message);

  static final math.Random _random = math.Random.secure();

  static String _newAlias() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return 'device_${List.generate(20, (_) => alphabet[_random.nextInt(alphabet.length)]).join()}';
  }
}
