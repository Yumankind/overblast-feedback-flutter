import 'dart:convert';

import '../payload.dart' show FeedbackLimits;
import '../verification/registration.dart';
import 'store_stub.dart' if (dart.library.io) 'store_io.dart' as platform;

/// A report the worker refused with `429` (or that never reached it), kept to be sent later by
/// [OverblastFeedbackController.retryPending]. The body is the exact request body, already redacted.
class PendingReport {
  const PendingReport({required this.id, required this.createdAt, required this.body, this.notBefore});

  final String id;

  /// Milliseconds since the epoch.
  final int createdAt;

  /// Not to be sent before this time (milliseconds since the epoch), from the refusal's `retryAfter`.
  final int? notBefore;
  final Map<String, Object?> body;

  PendingReport copyWith({int? notBefore}) =>
      PendingReport(id: id, createdAt: createdAt, body: body, notBefore: notBefore ?? this.notBefore);

  Map<String, Object?> toJson() => {
    'id': id,
    'createdAt': createdAt,
    if (notBefore != null) 'notBefore': notBefore,
    'body': body,
  };

  static PendingReport? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final createdAt = json['createdAt'];
    final body = json['body'];
    final notBefore = json['notBefore'];
    if (id is! String || createdAt is! int || body is! Map) return null;
    return PendingReport(
      id: id,
      createdAt: createdAt,
      notBefore: notBefore is int ? notBefore : null,
      body: body.cast<String, Object?>(),
    );
  }
}

/// Where the library keeps its install id, its registered device and its unsent reports.
///
/// The default ([FeedbackStore.platformDefault]) is a folder in the app's support directory on
/// iOS, Android and desktop, and memory on the web. Tests and integrators with their own storage
/// can pass any implementation.
abstract class FeedbackStore {
  /// At most this many unsent reports are kept; saving another drops the oldest.
  static const int maxPending = 5;

  static FeedbackStore platformDefault() => platform.createDefaultStore();

  Future<String?> readDeviceId();
  Future<void> writeDeviceId(String id);

  /// The device registered with the worker (docs/feedback-reports.md §8), if any. Since 0.2.0. The
  /// defaults keep nothing, so a store written for 0.1.0 that `extends` this class registers once per
  /// launch; one that `implements` it has to add both methods.
  Future<FeedbackDeviceRegistration?> readRegisteredDevice() async => null;

  /// Null forgets the device.
  Future<void> writeRegisteredDevice(FeedbackDeviceRegistration? device) async {}

  // The crash case (docs/feedback-reports.md §3.4, §3.5), since 0.2.0. The defaults keep nothing, so a
  // store that does not implement them never offers a report after a crash.

  /// Appends lines (one JSON object each, no newline) to the on-disk copy of the log: at most 4 MB in
  /// two rotating files of [FeedbackLimits.diskLogFileBytes], the older deleted when the newer fills.
  Future<void> appendLogLines(List<String> lines) async {}

  /// The on-disk copy, oldest first.
  Future<List<String>> readLogLines() async => const [];

  Future<void> clearLogLines() async {}

  /// The session marker: `{id, startedAt, closed, lastError?}`. Null forgets it.
  Future<Map<String, Object?>?> readSession() async => null;
  Future<void> writeSession(Map<String, Object?>? session) async {}

  /// Small named records the library keeps between launches: `config` (the key's last answer from
  /// the config door, §2.1) and `error_prompt` (when the error prompt last showed, §3.6). Null
  /// forgets one. The defaults keep nothing.
  Future<Map<String, Object?>?> readState(String name) async => null;
  Future<void> writeState(String name, Map<String, Object?>? value) async {}

  Future<List<PendingReport>> loadPending();
  Future<void> savePending(PendingReport report);
  Future<void> deletePending(String id);
}

/// Keeps everything in memory, for tests and for platforms without a file system.
class MemoryFeedbackStore implements FeedbackStore {
  String? _deviceId;
  FeedbackDeviceRegistration? _device;
  final Map<String, PendingReport> _pending = {};
  List<String> _olderLog = [];
  List<String> _newerLog = [];
  int _newerBytes = 0;
  Map<String, Object?>? _session;
  final Map<String, Map<String, Object?>> _state = {};

  @override
  Future<Map<String, Object?>?> readState(String name) async => _state[name] == null ? null : {..._state[name]!};

  @override
  Future<void> writeState(String name, Map<String, Object?>? value) async {
    if (value == null) {
      _state.remove(name);
    } else {
      _state[name] = {...value};
    }
  }

  @override
  Future<void> appendLogLines(List<String> lines) async {
    for (final line in lines) {
      final size = utf8.encode(line).length + 1;
      if (_newerBytes + size > FeedbackLimits.diskLogFileBytes && _newerLog.isNotEmpty) {
        _olderLog = _newerLog;
        _newerLog = [];
        _newerBytes = 0;
      }
      _newerLog.add(line);
      _newerBytes += size;
    }
  }

  @override
  Future<List<String>> readLogLines() async => [..._olderLog, ..._newerLog];

  @override
  Future<void> clearLogLines() async {
    _olderLog = [];
    _newerLog = [];
    _newerBytes = 0;
  }

  @override
  Future<Map<String, Object?>?> readSession() async => _session == null ? null : {..._session!};

  @override
  Future<void> writeSession(Map<String, Object?>? session) async => _session = session == null ? null : {...session};

  @override
  Future<String?> readDeviceId() async => _deviceId;

  @override
  Future<void> writeDeviceId(String id) async => _deviceId = id;

  @override
  Future<FeedbackDeviceRegistration?> readRegisteredDevice() async => _device;

  @override
  Future<void> writeRegisteredDevice(FeedbackDeviceRegistration? device) async => _device = device;

  @override
  Future<List<PendingReport>> loadPending() async =>
      _pending.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> savePending(PendingReport report) async {
    _pending[report.id] = report;
    final all = await loadPending();
    for (var i = 0; i < all.length - FeedbackStore.maxPending; i++) {
      _pending.remove(all[i].id);
    }
  }

  @override
  Future<void> deletePending(String id) async => _pending.remove(id);
}
