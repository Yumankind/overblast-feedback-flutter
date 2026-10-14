import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// How hard and how often the phone has to be shaken.
class ShakeOptions {
  const ShakeOptions({
    this.thresholdG = 2.5,
    this.peaks = 3,
    this.window = const Duration(milliseconds: 1200),
    this.minGap = const Duration(milliseconds: 120),
    this.cooldown = const Duration(seconds: 2),
  });

  /// The acceleration, in g including gravity (a phone at rest reads 1), a sample must exceed to
  /// count as part of a shake.
  final double thresholdG;

  /// How many separate peaks inside [window] make a shake. Three keeps a phone dropped on a table
  /// (one jolt and a bounce) from opening the sheet.
  final int peaks;
  final Duration window;

  /// Samples over the threshold closer together than this are one peak.
  final Duration minGap;

  /// After a shake, nothing for this long.
  final Duration cooldown;
}

/// Turns accelerometer samples into shakes. Pure, so it is tested without a sensor.
class ShakeDetector {
  ShakeDetector([this.options = const ShakeOptions()]);

  final ShakeOptions options;
  final List<DateTime> _peaks = [];
  DateTime? _lastAbove;
  DateTime? _lastShake;

  /// Feeds one sample in m/s². True when this sample completes a shake.
  bool addSample(double x, double y, double z, DateTime at) {
    final g = math.sqrt(x * x + y * y + z * z) / 9.80665;
    if (g < options.thresholdG) return false;
    final last = _lastShake;
    if (last != null && at.difference(last) < options.cooldown) return false;
    final previous = _lastAbove;
    _lastAbove = at;
    if (previous != null && at.difference(previous) < options.minGap) return false;
    _peaks
      ..add(at)
      ..removeWhere((p) => at.difference(p) > options.window);
    if (_peaks.length < options.peaks) return false;
    _peaks.clear();
    _lastShake = at;
    return true;
  }

  void reset() {
    _peaks.clear();
    _lastAbove = null;
    _lastShake = null;
  }
}

/// Listens to the accelerometer and calls [onShake]. Only on iOS and Android: desktop has no
/// accelerometer and the web library has its own shake, so elsewhere [start] does nothing.
class ShakeListener {
  ShakeListener({
    required this.onShake,
    ShakeOptions options = const ShakeOptions(),
    Stream<AccelerometerEvent>? events,
  }) : _detector = ShakeDetector(options),
       _events = events;

  final VoidCallback onShake;
  final ShakeDetector _detector;
  final Stream<AccelerometerEvent>? _events;
  StreamSubscription<AccelerometerEvent>? _sub;

  static bool get supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

  bool get listening => _sub != null;

  void start() {
    if (_sub != null) return;
    final Stream<AccelerometerEvent> events;
    if (_events != null) {
      events = _events;
    } else {
      if (!supported) return;
      try {
        events = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval);
      } catch (_) {
        return; // no sensor plugin registered (a test, an add-to-app host without it)
      }
    }
    _sub = events.listen(
      (e) {
        if (_detector.addSample(e.x, e.y, e.z, DateTime.now())) onShake();
      },
      // A device without an accelerometer answers with an error; shaking is then simply off.
      onError: (Object _) => stop(),
      cancelOnError: true,
    );
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _detector.reset();
  }
}
