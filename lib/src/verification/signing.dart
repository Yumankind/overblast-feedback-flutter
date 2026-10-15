import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'keys.dart';
import 'registration.dart';

/// The three headers of a signed report (docs/feedback-reports.md §8.3).
const String deviceHeader = 'X-Overblast-Feedback-Device';
const String timeHeader = 'X-Overblast-Feedback-Time';
const String signatureHeader = 'X-Overblast-Feedback-Signature';

/// base64url without padding.
String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// base64 or base64url, padded or not.
Uint8List decodeB64(String text) {
  var s = text.replaceAll('-', '+').replaceAll('_', '/');
  while (s.length % 4 != 0) {
    s += '=';
  }
  return base64.decode(s);
}

/// What a report's signature covers:
///
/// ```
/// overblast-feedback-v1\n<deviceId>\n<time>\n<base64url(SHA-256(the exact body bytes))>
/// ```
///
/// [body] must be the bytes that go on the wire, not a re-encoding of the same map.
String canonicalSigningString(String deviceId, int timeMs, List<int> body) =>
    'overblast-feedback-v1\n$deviceId\n$timeMs\n${b64url(sha256.convert(body).bytes)}';

/// Signs [body] for [device] and answers the three headers.
///
/// App Attest signs with an assertion whose `clientDataHash` is SHA-256 of the canonical string;
/// every other method is an ECDSA P-256 / SHA-256 signature of the string itself (the native side
/// hashes), DER. Throws [DeviceKeyException] when the key cannot sign.
Future<Map<String, String>> signReport(
  DeviceKeys keys,
  FeedbackDeviceRegistration device,
  List<int> body, {
  required int timeMs,
}) async {
  final canonical = Uint8List.fromList(utf8.encode(canonicalSigningString(device.deviceId, timeMs, body)));
  final String signature;
  if (device.method == FeedbackDeviceMethod.appAttest) {
    final hash = Uint8List.fromList(sha256.convert(canonical).bytes);
    signature = await keys.assertApple(device.keyId!, hash);
  } else {
    signature = await keys.sign(device.alias!, canonical);
  }
  return {deviceHeader: device.deviceId, timeHeader: '$timeMs', signatureHeader: signature};
}
