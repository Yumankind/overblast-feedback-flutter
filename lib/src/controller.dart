import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'capture.dart';
import 'device.dart';
import 'log_buffer.dart';
import 'payload.dart';
import 'route_observer.dart';
import 'store/store.dart';
import 'transport.dart';

/// What the [OverblastFeedback] widget does for its controller: open the sheet, take a capture,
/// say how big the surface is. The controller works without one (logs, [OverblastFeedbackController.report]
/// without a screenshot, [OverblastFeedbackController.retryPending]).
abstract class FeedbackPresenter {
  Future<void> present({FeedbackCategory? category, String? message});
  Future<FeedbackCapture?> capture();
  FeedbackViewport? get viewport;
}

/// The library's state for one app: the key, the reporter, the session's logs and network calls,
/// and the unsent reports. Reached from widgets with `OverblastFeedback.of(context)`, or created
/// in `main()` and handed to the widget, so logging starts before the first frame.
class OverblastFeedbackController extends ChangeNotifier {
  OverblastFeedbackController({
    required this.feedbackKey,
    Uri? endpoint,
    FeedbackReporter? reporter,
    this.appVersion,
    this.buildNumber,
    this.timeZone,
    Map<String, String>? extra,
    http.Client? httpClient,
    FeedbackStore? store,
    int logCapacity = FeedbackLimits.logEntries,
    Future<FeedbackDeviceFacts> Function()? deviceFacts,
    DateTime Function()? clock,
  }) : _reporter = reporter,
       _extra = {...?extra},
       _clock = clock ?? DateTime.now,
       _deviceFactsReader = deviceFacts ?? readDeviceFacts,
       _store = store ?? FeedbackStore.platformDefault(),
       _logs = FeedbackLogBuffer(capacity: logCapacity, clock: clock),
       _network = RingBuffer<FeedbackNetworkEntry>(FeedbackLimits.networkEntries) {
    if (!RegExp(r'^obfk_[A-Za-z0-9]{8,}$').hasMatch(feedbackKey)) {
      // Fail at start-up, by name, rather than with an `unknown_key` from the first reporter.
      throw ArgumentError.value(
        feedbackKey,
        'feedbackKey',
        'is not a feedback key (obfk_...); copy it from Feedback keys in the console',
      );
    }
    _transport = FeedbackTransport(feedbackKey: feedbackKey, endpoint: endpoint, client: httpClient);
    current = this;
  }

  /// The controller created last, for code with no `BuildContext` (an HTTP client, a service).
  static OverblastFeedbackController? current;

  /// The workspace's public feedback key, `obfk_...`.
  final String feedbackKey;

  /// Override what `package_info_plus` reads (`context.appVersion` and `context.build`).
  final String? appVersion;
  final String? buildNumber;

  /// An IANA zone (`Europe/Lisbon`) if the app knows it; otherwise the platform's abbreviation (`WEST`),
  /// which is all Dart itself can tell.
  final String? timeZone;

  late final FeedbackTransport _transport;
  final FeedbackStore _store;
  final FeedbackLogBuffer _logs;
  final RingBuffer<FeedbackNetworkEntry> _network;
  final Map<String, String> _extra;
  final DateTime Function() _clock;
  final Future<FeedbackDeviceFacts> Function() _deviceFactsReader;
  Future<FeedbackDeviceFacts>? _facts;
  Future<String>? _deviceId;
  FeedbackReporter? _reporter;
  FeedbackPresenter? _presenter;
  bool _retrying = false;

  Uri get endpoint => _transport.endpoint;
  FeedbackStore get store => _store;

  // ── Reporter and context ─────────────────────────────────────────────────────────────────────

  FeedbackReporter? get reporter => _reporter;

  /// Who is signed in. Call it on sign-in and with nulls on sign-out. With an email, the sheet does not
  /// ask for one.
  void setReporter({String? email, String? name, String? accountRef}) {
    final next = FeedbackReporter(email: email, name: name, accountRef: accountRef);
    _reporter = next.isEmpty ? null : next;
    notifyListeners();
  }

  /// A string the team wants on every report (`plan`, `workspace`). Null removes it. At most 20 are
  /// sent.
  void setExtra(String key, String? value) {
    if (value == null) {
      _extra.remove(key);
    } else {
      _extra[key] = value;
    }
  }

  Map<String, String> get extra => Map.unmodifiable(_extra);

  /// A fresh observer for the app's navigator; any number of them feed the same current screen.
  NavigatorObserver get navigatorObserver => OverblastNavigatorObserver();

  // ── Logs and network ─────────────────────────────────────────────────────────────────────────

  /// Adds a line to the session's log. Redacted on the way in.
  void log(FeedbackLogLevel level, Object? message, {String src = 'app'}) => _logs.add(level, message, src: src);

  void debug(Object? message, {String src = 'app'}) => log(FeedbackLogLevel.debug, message, src: src);
  void info(Object? message, {String src = 'app'}) => log(FeedbackLogLevel.info, message, src: src);
  void warn(Object? message, {String src = 'app'}) => log(FeedbackLogLevel.warn, message, src: src);
  void error(Object? message, {String src = 'app'}) => log(FeedbackLogLevel.error, message, src: src);

  /// Records one network call. The query string and fragment are dropped here.
  void recordNetwork(String method, Object url, int status, int ms) {
    final target = url.toString();
    if (target.startsWith(_transport.endpoint.toString())) return; // the report itself
    _network.add(
      FeedbackNetworkEntry(t: _clock().millisecondsSinceEpoch, method: method, url: target, status: status, ms: ms),
    );
  }

  List<FeedbackLogEntry> get logs => _logs.entries;
  List<FeedbackNetworkEntry> get network => _network.toList();

  DebugPrintCallback? _previousDebugPrint;
  DebugPrintCallback? _ourDebugPrint;
  FlutterExceptionHandler? _previousFlutterError;
  FlutterExceptionHandler? _ourFlutterError;
  ErrorCallback? _previousPlatformError;
  ErrorCallback? _ourPlatformError;

  /// Copies every `debugPrint` into the log, then passes it on to whatever printed it before.
  void captureDebugPrint() {
    if (_ourDebugPrint != null) return;
    final previous = debugPrint;
    _previousDebugPrint = previous;
    void ours(String? message, {int? wrapWidth}) {
      if (message != null) log(FeedbackLogLevel.debug, message, src: 'debugPrint');
      previous(message, wrapWidth: wrapWidth);
    }

    _ourDebugPrint = ours;
    debugPrint = ours;
  }

  /// Logs framework errors (`FlutterError.onError`) and uncaught async errors
  /// (`PlatformDispatcher.instance.onError`), then hands each to the handler that was there before,
  /// unchanged: Crashlytics still gets its crashes, and nothing is swallowed.
  ///
  /// Call it after the app has installed its own handlers (the widget does it in `initState`, which
  /// is after `main()`'s); a handler installed later replaces this one, as it would any other.
  void captureErrors() {
    if (_ourFlutterError != null) return;
    final previousFlutter = FlutterError.onError;
    _previousFlutterError = previousFlutter;
    void onFlutterError(FlutterErrorDetails details) {
      final stack = details.stack?.toString().split('\n').take(12).join('\n') ?? '';
      log(FeedbackLogLevel.error, '${details.exceptionAsString()}\n$stack'.trim(), src: 'flutter');
      previousFlutter?.call(details);
    }

    _ourFlutterError = onFlutterError;
    FlutterError.onError = onFlutterError;

    final dispatcher = PlatformDispatcher.instance;
    final previousPlatform = dispatcher.onError;
    _previousPlatformError = previousPlatform;
    bool onPlatformError(Object error, StackTrace stack) {
      final lines = stack.toString().split('\n').take(12).join('\n');
      log(FeedbackLogLevel.error, '$error\n$lines'.trim(), src: 'uncaught');
      return previousPlatform?.call(error, stack) ?? false;
    }

    _ourPlatformError = onPlatformError;
    dispatcher.onError = onPlatformError;
  }

  /// Undoes [captureDebugPrint] and [captureErrors], where nothing has replaced them since.
  void releaseCaptures() {
    if (_ourDebugPrint != null && identical(debugPrint, _ourDebugPrint)) debugPrint = _previousDebugPrint!;
    _ourDebugPrint = null;
    _previousDebugPrint = null;
    if (_ourFlutterError != null && identical(FlutterError.onError, _ourFlutterError)) {
      FlutterError.onError = _previousFlutterError;
    }
    _ourFlutterError = null;
    _previousFlutterError = null;
    final dispatcher = PlatformDispatcher.instance;
    if (_ourPlatformError != null && identical(dispatcher.onError, _ourPlatformError)) {
      dispatcher.onError = _previousPlatformError;
    }
    _ourPlatformError = null;
    _previousPlatformError = null;
  }

  // ── The sheet ────────────────────────────────────────────────────────────────────────────────

  /// Called by the widget.
  void attach(FeedbackPresenter presenter) => _presenter = presenter;

  void detach(FeedbackPresenter presenter) {
    if (identical(_presenter, presenter)) _presenter = null;
  }

  bool get isAttached => _presenter != null;

  /// Opens the report sheet, as a shake does.
  Future<void> show({FeedbackCategory? category, String? message}) {
    final presenter = _presenter;
    if (presenter == null) {
      throw StateError('OverblastFeedback.show() needs the OverblastFeedback widget mounted around the app');
    }
    return presenter.present(category: category, message: message);
  }

  // ── Sending ──────────────────────────────────────────────────────────────────────────────────

  /// A random id per install, kept in the store: `context.deviceId`, which the worker's per-device
  /// limits count by.
  Future<String> deviceId() => _deviceId ??= _loadDeviceId();

  Future<String> _loadDeviceId() async {
    try {
      final stored = await _store.readDeviceId();
      if (stored != null && isValidDeviceId(stored)) return stored;
    } catch (_) {
      // Unreadable store: a fresh id for this session.
    }
    final id = _randomId(32);
    try {
      await _store.writeDeviceId(id);
    } catch (_) {
      // It lives for this session only.
    }
    return id;
  }

  /// Everything a report carries, from a message and whatever the sheet collected.
  Future<FeedbackPayload> buildPayload({
    required String message,
    FeedbackCategory category = FeedbackCategory.bug,
    FeedbackReporter? reporter,
    NativeAnchor? element,
    FeedbackScreenshot? screenshot,
    Map<String, String>? extra,
  }) async {
    final facts = await (_facts ??= _deviceFactsReader().catchError((Object _) => const FeedbackDeviceFacts()));
    final base = _reporter;
    final who = FeedbackReporter(
      email: _firstNonBlank(reporter?.email, base?.email),
      name: _firstNonBlank(reporter?.name, base?.name),
      accountRef: _firstNonBlank(reporter?.accountRef, base?.accountRef),
    );
    return FeedbackPayload(
      message: message,
      category: category,
      reporter: who.isEmpty ? null : who,
      context: FeedbackContext(
        screen: FeedbackRouteTracker.instance.currentScreen,
        appVersion: appVersion ?? facts.appVersion,
        build: buildNumber ?? facts.build,
        os: facts.os,
        osVersion: facts.osVersion,
        device: facts.device,
        locale: PlatformDispatcher.instance.locale.toLanguageTag(),
        timeZone: timeZone ?? _clock().timeZoneName,
        viewport: _presenter?.viewport ?? _implicitViewport(),
        deviceId: await deviceId(),
        extra: {..._extra, ...?extra},
      ),
      element: element,
      screenshot: screenshot,
      logs: _logs.entries,
      network: _network.toList(),
    );
  }

  /// Sends [payload]. A `429`, or no answer at all, keeps the report on the device for
  /// [retryPending] and throws with [OverblastFeedbackException.savedForLater] set; nothing is
  /// retried here.
  Future<FeedbackResult> submit(FeedbackPayload payload) async {
    final body = payload.toJson();
    try {
      return await _transport.send(body);
    } on OverblastFeedbackException catch (e) {
      if (!e.isRateLimited && !e.isNetwork) rethrow;
      final now = _clock().millisecondsSinceEpoch;
      var saved = false;
      try {
        await _store.savePending(
          PendingReport(
            id: 'p_${now}_${_randomId(6)}',
            createdAt: now,
            notBefore: e.retryAfter == null ? null : now + e.retryAfter! * 1000,
            body: body,
          ),
        );
        saved = true;
      } catch (_) {
        // Nowhere to keep it: the reporter is told it was not sent, without the promise of later.
      }
      throw saved ? e.copyWith(savedForLater: true) : e;
    }
  }

  /// Files a report without the sheet, for an app's own "report a problem" form. With
  /// [includeScreenshot], the screen is captured as it is now (private regions blanked).
  Future<FeedbackResult> report({
    required String message,
    FeedbackCategory category = FeedbackCategory.bug,
    FeedbackReporter? reporter,
    bool includeScreenshot = false,
    NativeAnchor? element,
    Map<String, String>? extra,
  }) async {
    FeedbackScreenshot? shot;
    if (includeScreenshot) {
      final capture = await _presenter?.capture();
      if (capture != null) {
        try {
          final bytes = await capture.encodePng();
          if (bytes != null) shot = FeedbackScreenshot(bytes: bytes);
        } finally {
          capture.dispose();
        }
      }
    }
    final payload = await buildPayload(
      message: message,
      category: category,
      reporter: reporter,
      element: element,
      screenshot: shot,
      extra: extra,
    );
    return submit(payload);
  }

  /// The reports kept for later, oldest first.
  Future<List<PendingReport>> pending() => _store.loadPending();

  /// Tries each kept report once, oldest first, and returns how many were filed.
  ///
  /// It stops at the first `429` (recording when to try again) or failed connection, drops a report
  /// the worker refuses for good (a bad field, a revoked key), and never loops: call it again when
  /// there is reason to (the app starting, the reporter tapping "Send saved reports").
  Future<int> retryPending() async {
    if (_retrying) return 0;
    _retrying = true;
    var sent = 0;
    try {
      final now = _clock().millisecondsSinceEpoch;
      for (final report in await _store.loadPending()) {
        if (report.notBefore != null && report.notBefore! > now) continue;
        try {
          await _transport.send(report.body);
          await _store.deletePending(report.id);
          sent++;
        } on OverblastFeedbackException catch (e) {
          if (e.isRateLimited) {
            await _store.savePending(report.copyWith(notBefore: now + (e.retryAfter ?? 3600) * 1000));
            break;
          }
          if (e.isNetwork || e.status >= 500) break;
          await _store.deletePending(report.id);
        }
      }
    } finally {
      _retrying = false;
    }
    return sent;
  }

  @override
  void dispose() {
    releaseCaptures();
    if (identical(current, this)) current = null;
    super.dispose();
  }
}

FeedbackViewport? _implicitViewport() {
  final view = PlatformDispatcher.instance.implicitView;
  if (view == null || view.devicePixelRatio <= 0) return null;
  final size = view.physicalSize / view.devicePixelRatio;
  return FeedbackViewport(width: size.width, height: size.height, devicePixelRatio: view.devicePixelRatio);
}

String? _firstNonBlank(String? a, String? b) {
  if (a != null && a.trim().isNotEmpty) return a.trim();
  if (b != null && b.trim().isNotEmpty) return b.trim();
  return null;
}

final math.Random _random = math.Random.secure();

String _randomId(int length) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(length, (_) => alphabet[_random.nextInt(alphabet.length)]).join();
}
