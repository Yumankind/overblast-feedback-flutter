import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'payload.dart' show FeedbackCategory;
import 'store/store.dart';

/// The key's `verification` (docs/feedback-reports.md §2): whether devices register at all.
enum FeedbackVerification {
  /// The default. No registration, no proof of work, no attestation; every report unsigned.
  off,

  /// Register and sign; an unregistered device's report is still accepted.
  flag,

  /// Register and sign; an unregistered device's report is refused (`403 device_required`).
  require;

  bool get registers => this != FeedbackVerification.off;
}

/// What counts towards the error prompt (§3.6). [wire] is the contract's spelling.
enum FeedbackErrorKind {
  /// An uncaught Dart error, or `log(error, unexpected: true)`.
  exception('exception'),

  /// A request to one of the app's own hosts answered 500 to 599.
  serverError('server_error'),

  /// A request to one of the app's own hosts that never answered.
  network('network');

  const FeedbackErrorKind(this.wire);
  final String wire;
}

/// The key's `errorPrompt` (§2): off unless the owner turned it on.
class FeedbackErrorPromptConfig {
  const FeedbackErrorPromptConfig({
    this.enabled = false,
    this.on = const {FeedbackErrorKind.exception},
    this.minHoursBetween = 24,
  });

  final bool enabled;
  final Set<FeedbackErrorKind> on;
  final num minHoursBetween;

  static FeedbackErrorPromptConfig fromJson(Object? json) {
    if (json is! Map) return const FeedbackErrorPromptConfig();
    final on = json['on'];
    final hours = json['minHoursBetween'];
    return FeedbackErrorPromptConfig(
      enabled: json['enabled'] == true,
      on: on is List
          ? {
              for (final k in FeedbackErrorKind.values)
                if (on.contains(k.wire)) k,
            }
          : const {FeedbackErrorKind.exception},
      minHoursBetween: hours is num && hours >= 0 ? hours : 24,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'on': [for (final k in on) k.wire],
    'minHoursBetween': minHoursBetween,
  };
}

/// `GET /v1/feedback/config` (§2.1): what the key lets the library do. [defaults] is what the
/// library does before it has ever had an answer: no registration, no error prompt, screenshots on.
class FeedbackRemoteConfig {
  const FeedbackRemoteConfig({
    this.verification = FeedbackVerification.off,
    this.errorPrompt = const FeedbackErrorPromptConfig(),
    this.screenshots = true,
    this.categories = FeedbackCategory.values,
  });

  static const FeedbackRemoteConfig defaults = FeedbackRemoteConfig();

  final FeedbackVerification verification;
  final FeedbackErrorPromptConfig errorPrompt;
  final bool screenshots;

  /// The kinds of report the key accepts, in the key's order: the first is the sheet's default, and
  /// with only one the sheet offers no choice (§2). Never empty.
  final List<FeedbackCategory> categories;

  static FeedbackRemoteConfig fromJson(Object? json) {
    if (json is! Map) return defaults;
    final raw = json['categories'];
    final byName = FeedbackCategory.values.asNameMap();
    final categories = <FeedbackCategory>[];
    if (raw is List) {
      for (final c in raw) {
        final category = byName[c];
        if (category != null && !categories.contains(category)) categories.add(category);
      }
    }
    return FeedbackRemoteConfig(
      verification: FeedbackVerification.values.asNameMap()[json['verification']] ?? FeedbackVerification.off,
      errorPrompt: FeedbackErrorPromptConfig.fromJson(json['errorPrompt']),
      screenshots: json['screenshots'] != false,
      categories: categories.isEmpty ? FeedbackCategory.values : categories,
    );
  }

  Map<String, Object?> toJson() => {
    'verification': verification.name,
    'errorPrompt': errorPrompt.toJson(),
    'screenshots': screenshots,
    'categories': [for (final c in categories) c.name],
  };
}

/// Reads the config door once per start and at most every [minInterval] after, with the `ETag`, and
/// keeps the last answer in the store, which is what is used while the door cannot be reached.
class FeedbackConfigClient {
  FeedbackConfigClient({
    required this.feedbackKey,
    required Uri endpoint,
    required FeedbackStore store,
    http.Client? client,
    DateTime Function()? clock,
    this.minInterval = const Duration(minutes: 5),
    this.timeout = const Duration(seconds: 15),
  }) : uri = endpoint.replace(
         path: '${endpoint.path.endsWith('/') ? endpoint.path.substring(0, endpoint.path.length - 1) : endpoint.path}/config',
         query: null,
         fragment: null,
       ),
       _store = store,
       _client = client,
       _clock = clock ?? DateTime.now;

  static const String storeName = 'config';

  final String feedbackKey;
  final Uri uri;
  final Duration minInterval;
  final Duration timeout;
  final FeedbackStore _store;
  final http.Client? _client;
  final DateTime Function() _clock;

  FeedbackRemoteConfig _current = FeedbackRemoteConfig.defaults;
  String? _etag;
  int? _fetchedAt;
  Future<void>? _loaded;
  Future<FeedbackRemoteConfig>? _inFlight;

  FeedbackRemoteConfig get current => _current;

  /// Whether this start has had an answer from the door (a 200 or a 304).
  bool get fresh => _fetchedAt != null;

  /// The kept answer, read once. A kept answer for another key is ignored.
  Future<void> load() => _loaded ??= () async {
    try {
      final kept = await _store.readState(storeName);
      if (kept != null && kept['key'] == feedbackKey) {
        _current = FeedbackRemoteConfig.fromJson(kept['config']);
        final etag = kept['etag'];
        _etag = etag is String ? etag : null;
      }
    } catch (_) {
      // Nothing kept: the defaults stand until the door answers.
    }
  }();

  /// Asks the door unless it was asked less than [minInterval] ago (or [force]). Never throws; on
  /// any failure the kept answer stands.
  Future<FeedbackRemoteConfig> refresh({bool force = false}) {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final last = _fetchedAt;
    if (!force && last != null && _clock().millisecondsSinceEpoch - last < minInterval.inMilliseconds) {
      return Future.value(_current);
    }
    final run = _fetch();
    _inFlight = run;
    return run.whenComplete(() => _inFlight = null);
  }

  /// A refresh in flight, if any, so a caller can wait for it without starting one.
  Future<FeedbackRemoteConfig>? get inFlight => _inFlight;

  Future<FeedbackRemoteConfig> _fetch() async {
    await load();
    final client = _client ?? http.Client();
    try {
      final response = await client
          .get(uri, headers: {'X-Overblast-Feedback-Key': feedbackKey, 'If-None-Match': ?_etag})
          .timeout(timeout);
      if (response.statusCode == 304) {
        _fetchedAt = _clock().millisecondsSinceEpoch;
      } else if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json is Map) {
          _current = FeedbackRemoteConfig.fromJson(json);
          _etag = response.headers['etag'];
          _fetchedAt = _clock().millisecondsSinceEpoch;
          await _store.writeState(storeName, {
            'key': feedbackKey,
            'etag': _etag,
            'config': _current.toJson(),
          });
        }
      }
    } catch (_) {
      // Offline, a proxy's page, a store that cannot write: the kept answer stands.
    } finally {
      if (_client == null) client.close();
    }
    return _current;
  }
}
