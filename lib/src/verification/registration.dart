/// How well the worker knows the device a report comes from (docs/feedback-reports.md §8.1). It
/// decides which column of the limits table (§4) the report is counted in.
enum FeedbackDeviceLevel {
  /// No registered device: reports go unsigned and share the address's small allowance.
  none,

  /// The device holds a key it proved by proof of work, or its attestation was valid but did not
  /// meet everything (the development App Attest environment, an unlocked bootloader, an app the
  /// feedback key does not list).
  registered,

  /// Apple or Google says the key lives in secure hardware, in a chain naming this app.
  attested;

  static FeedbackDeviceLevel parse(Object? wire) => switch (wire) {
    'attested' => FeedbackDeviceLevel.attested,
    'none' => FeedbackDeviceLevel.none,
    // A level this version does not know is still a device the worker accepted.
    _ => FeedbackDeviceLevel.registered,
  };
}

/// How the device registered (§8.2). [wire] is the contract's spelling.
enum FeedbackDeviceMethod {
  appAttest('app_attest'),
  androidKey('android_key'),
  pow('pow');

  const FeedbackDeviceMethod(this.wire);
  final String wire;

  static FeedbackDeviceMethod? parse(Object? wire) {
    for (final m in values) {
      if (m.wire == wire) return m;
    }
    return null;
  }
}

/// A device the worker registered, as the library keeps it between launches.
///
/// It names the native key that signs for it, never holds it: [keyId] is the App Attest key's id (the
/// key itself is in the Secure Enclave and cannot leave it), [alias] is the Android Keystore alias or
/// the iOS keychain tag of a plain key. [scope] ties the registration to the feedback key and the
/// door it was made against, so changing either starts afresh rather than signing for a device the
/// new key's workspace has never seen.
class FeedbackDeviceRegistration {
  const FeedbackDeviceRegistration({
    required this.deviceId,
    required this.method,
    required this.level,
    required this.scope,
    required this.registeredAt,
    this.reason,
    this.keyId,
    this.alias,
  });

  /// `fbd_...`.
  final String deviceId;
  final FeedbackDeviceMethod method;
  final FeedbackDeviceLevel level;

  /// Why the level is not `attested`, in the worker's words, when it said.
  final String? reason;

  /// App Attest only.
  final String? keyId;

  /// `android_key` and `pow`.
  final String? alias;
  final String scope;

  /// Milliseconds since the epoch.
  final int registeredAt;

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'method': method.wire,
    'level': level.name,
    if (reason != null) 'reason': reason,
    if (keyId != null) 'keyId': keyId,
    if (alias != null) 'alias': alias,
    'scope': scope,
    'registeredAt': registeredAt,
  };

  static FeedbackDeviceRegistration? fromJson(Object? json) {
    if (json is! Map) return null;
    final deviceId = json['deviceId'];
    final method = FeedbackDeviceMethod.parse(json['method']);
    final scope = json['scope'];
    final registeredAt = json['registeredAt'];
    final keyId = json['keyId'];
    final alias = json['alias'];
    final reason = json['reason'];
    if (deviceId is! String || deviceId.isEmpty || method == null || scope is! String || registeredAt is! int) {
      return null;
    }
    // A registration that names no key to sign with is worth nothing; reading it as absent registers again.
    if (method == FeedbackDeviceMethod.appAttest ? keyId is! String : alias is! String) return null;
    return FeedbackDeviceRegistration(
      deviceId: deviceId,
      method: method,
      level: FeedbackDeviceLevel.parse(json['level']),
      reason: reason is String ? reason : null,
      keyId: keyId is String ? keyId : null,
      alias: alias is String ? alias : null,
      scope: scope,
      registeredAt: registeredAt,
    );
  }
}
