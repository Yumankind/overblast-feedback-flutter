import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Finds a proof of work in the background and answers the nonce, or null when [budget] runs out.
/// The default is [solvePowInBackground]; tests pass their own.
typedef PowSolver = Future<String?> Function(String salt, int difficulty, Duration budget);

/// The number of leading zero bits of [bytes].
int leadingZeroBits(List<int> bytes) {
  var bits = 0;
  for (final b in bytes) {
    if (b == 0) {
      bits += 8;
      continue;
    }
    var v = b;
    while (v & 0x80 == 0) {
      bits++;
      v <<= 1;
    }
    break;
  }
  return bits;
}

/// The smallest decimal nonce such that `SHA-256("<salt>:<nonce>")` starts with [difficulty] zero
/// bits (docs/feedback-reports.md §8.2), or null once the clock passes [deadline] (milliseconds since
/// the epoch). Synchronous and CPU-bound: run it off the UI isolate.
///
/// The nonce is decimal because the worker's existing challenge door (the 00 Mini embed's) takes
/// `^\d{1,16}$`; a counter from zero stays well inside that for any difficulty a phone can solve.
String? solvePow(String salt, int difficulty, {int? deadline}) {
  if (difficulty <= 0) return '0';
  final prefix = utf8.encode('$salt:');
  final buffer = Uint8List(prefix.length + 20)..setRange(0, prefix.length, prefix);
  for (var n = 0; n < 9007199254740991; n++) {
    if (deadline != null && n & 0xfff == 0 && DateTime.now().millisecondsSinceEpoch > deadline) return null;
    final digits = n.toString().codeUnits;
    buffer.setRange(prefix.length, prefix.length + digits.length, digits);
    final digest = sha256.convert(Uint8List.sublistView(buffer, 0, prefix.length + digits.length)).bytes;
    if (leadingZeroBits(digest) >= difficulty) return '$n';
  }
  return null;
}

/// [solvePow] on a background isolate (`compute`, which is `Isolate.run` on every native platform),
/// giving up after [budget]: the isolate checks the clock itself, so nothing is left spinning.
Future<String?> solvePowInBackground(String salt, int difficulty, Duration budget) {
  final deadline = DateTime.now().add(budget).millisecondsSinceEpoch;
  return compute(_solve, (salt, difficulty, deadline));
}

String? _solve((String, int, int) args) => solvePow(args.$1, args.$2, deadline: args.$3);
