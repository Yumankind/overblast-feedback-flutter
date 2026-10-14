import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/shake.dart' show ShakeListener;
import 'package:sensors_plus/sensors_plus.dart';

void main() {
  final t0 = DateTime(2026, 10, 14, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
  const hard = 30.0; // m/s², about 3 g
  const rest = 9.8;

  test('three separate peaks inside the window make a shake', () {
    final d = ShakeDetector();
    expect(d.addSample(hard, 0, 0, at(0)), isFalse);
    expect(d.addSample(rest, 0, 0, at(100)), isFalse);
    expect(d.addSample(0, hard, 0, at(300)), isFalse);
    expect(d.addSample(0, 0, hard, at(600)), isTrue);
  });

  test('a phone at rest, or a single jolt with a bounce, is not a shake', () {
    final d = ShakeDetector();
    for (var i = 0; i < 100; i++) {
      expect(d.addSample(0, 0, rest, at(i * 20)), isFalse);
    }
    // One jolt sampled five times in 80 ms counts once; the bounce is a second peak, not a third.
    for (var i = 0; i < 5; i++) {
      expect(d.addSample(hard, 0, 0, at(3000 + i * 20)), isFalse);
    }
    expect(d.addSample(hard, 0, 0, at(3300)), isFalse);
  });

  test('peaks too far apart do not add up', () {
    final d = ShakeDetector();
    expect(d.addSample(hard, 0, 0, at(0)), isFalse);
    expect(d.addSample(hard, 0, 0, at(1000)), isFalse);
    expect(d.addSample(hard, 0, 0, at(2500)), isFalse);
    expect(d.addSample(hard, 0, 0, at(3000)), isFalse);
    expect(d.addSample(hard, 0, 0, at(3400)), isTrue);
  });

  test('nothing during the cooldown after a shake', () {
    final d = ShakeDetector(const ShakeOptions(peaks: 2));
    expect(d.addSample(hard, 0, 0, at(0)), isFalse);
    expect(d.addSample(hard, 0, 0, at(200)), isTrue);
    expect(d.addSample(hard, 0, 0, at(400)), isFalse);
    expect(d.addSample(hard, 0, 0, at(700)), isFalse);
    expect(d.addSample(hard, 0, 0, at(2400)), isFalse);
    expect(d.addSample(hard, 0, 0, at(2700)), isTrue);
  });

  test('the listener calls back on a shake and stops quietly on a sensor error', () async {
    final events = StreamController<AccelerometerEvent>();
    var shakes = 0;
    final listener = ShakeListener(
      onShake: () => shakes++,
      options: const ShakeOptions(peaks: 1, minGap: Duration.zero),
      events: events.stream,
    )..start();
    events.add(AccelerometerEvent(hard, 0, 0, DateTime.now()));
    await Future<void>.delayed(Duration.zero);
    expect(shakes, 1);
    events.addError(Exception('no accelerometer'));
    await Future<void>.delayed(Duration.zero);
    expect(listener.listening, isFalse);
    await events.close();
  });
}
