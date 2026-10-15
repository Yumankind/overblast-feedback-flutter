import 'dart:async';

import 'package:flutter/services.dart';

import 'signing.dart' show b64url;

/// The channel the plugin's Swift and Kotlin halves answer on.
const MethodChannel deviceChannel = MethodChannel('overblast_feedback/device');

/// What the platform half can do. A platform with no implementation (desktop, the web, a widget test)
/// can do nothing, and reports from it go unsigned.
class DeviceCapabilities {
  const DeviceCapabilities({
    this.appAttest = false,
    this.androidKeyAttestation = false,
    this.plainKey = false,
    this.secureHardware = false,
  });

  static const DeviceCapabilities none = DeviceCapabilities();

  final bool appAttest;
  final bool androidKeyAttestation;
  final bool plainKey;

  /// A Secure Enclave or StrongBox is there. Informational only.
  final bool secureHardware;

  bool get any => appAttest || androidKeyAttestation || plainKey;
}

/// A native step that did not happen. [code] is the platform half's: `unsupported` (no App Attest on
/// this device, the simulator, no implementation at all), `invalid_key` (the key is gone), `bad_args`,
/// `failed`.
class DeviceKeyException implements Exception {
  const DeviceKeyException(this.code, [this.message]);

  final String code;
  final String? message;

  bool get unsupported => code == 'unsupported';

  @override
  String toString() => 'DeviceKeyException($code${message == null ? '' : ': $message'})';
}

/// The App Attest key and its attestation, as the worker takes them (§8.2): standard base64.
class AppleAttestation {
  const AppleAttestation({required this.keyId, required this.attestation});

  final String keyId;
  final String attestation;
}

/// The Dart face of the `overblast_feedback/device` channel. Every call either answers or throws a
/// [DeviceKeyException]; a missing implementation is `unsupported`.
class DeviceKeys {
  const DeviceKeys([this.channel = deviceChannel]);

  final MethodChannel channel;

  Future<DeviceCapabilities> capabilities() async {
    try {
      final map = await channel.invokeMapMethod<String, Object?>('capabilities');
      if (map == null) return DeviceCapabilities.none;
      bool flag(String k) => map[k] == true;
      return DeviceCapabilities(
        appAttest: flag('appAttest'),
        androidKeyAttestation: flag('androidKeyAttestation'),
        plainKey: flag('plainKey'),
        secureHardware: flag('secureHardware'),
      );
    } on MissingPluginException {
      return DeviceCapabilities.none;
    } on PlatformException {
      return DeviceCapabilities.none;
    }
  }

  /// iOS: a new App Attest key, attested with `clientDataHash = SHA-256(nonce bytes)`.
  Future<AppleAttestation> attestApple(String nonceB64url) async {
    final map = await _call<Map<Object?, Object?>>('attestApple', {'nonce': nonceB64url});
    final keyId = map['keyId'];
    final attestation = map['attestation'];
    if (keyId is! String || attestation is! String) throw const DeviceKeyException('failed', 'attestApple: no key');
    return AppleAttestation(keyId: keyId, attestation: attestation);
  }

  /// iOS: the App Attest assertion over [clientDataHash], base64url.
  Future<String> assertApple(String keyId, Uint8List clientDataHash) =>
      _call<String>('assertApple', {'keyId': keyId, 'clientDataHash': b64url(clientDataHash)});

  /// Android: a new attested keystore key under [alias]; its certificate chain, leaf first, base64 DER.
  Future<List<String>> attestAndroid(String alias, String nonceB64url) async {
    final list = await _call<List<Object?>>('attestAndroid', {'alias': alias, 'nonce': nonceB64url});
    final chain = list.whereType<String>().toList();
    if (chain.isEmpty || chain.length != list.length) throw const DeviceKeyException('failed', 'attestAndroid: no chain');
    return chain;
  }

  /// A new non-attested P-256 key under [alias] (Secure Enclave or keychain on iOS, keystore on
  /// Android); its SPKI, base64url.
  Future<String> createPlainKey(String alias) => _call<String>('createPlainKey', {'alias': alias});

  /// ECDSA P-256 / SHA-256 over [data] with the key under [alias]; DER, base64url.
  Future<String> sign(String alias, Uint8List data) => _call<String>('sign', {'alias': alias, 'data': b64url(data)});

  Future<void> deleteKey(String alias) async {
    try {
      await channel.invokeMethod<void>('deleteKey', {'alias': alias});
    } on MissingPluginException {
      // Nothing to delete where there is no keystore.
    } on PlatformException {
      // A key that cannot be deleted is forgotten all the same.
    }
  }

  Future<T> _call<T>(String method, Map<String, Object?> args) async {
    try {
      final value = await channel.invokeMethod<Object?>(method, args);
      if (value is T) return value;
      throw DeviceKeyException('failed', '$method answered ${value.runtimeType}');
    } on MissingPluginException {
      throw DeviceKeyException('unsupported', '$method has no implementation on this platform');
    } on PlatformException catch (e) {
      throw DeviceKeyException(e.code, e.message);
    }
  }
}
