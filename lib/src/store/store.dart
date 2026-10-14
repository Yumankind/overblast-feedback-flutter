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

/// Where the library keeps its install id and its unsent reports.
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

  Future<List<PendingReport>> loadPending();
  Future<void> savePending(PendingReport report);
  Future<void> deletePending(String id);
}

/// Keeps everything in memory, for tests and for platforms without a file system.
class MemoryFeedbackStore implements FeedbackStore {
  String? _deviceId;
  final Map<String, PendingReport> _pending = {};

  @override
  Future<String?> readDeviceId() async => _deviceId;

  @override
  Future<void> writeDeviceId(String id) async => _deviceId = id;

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
