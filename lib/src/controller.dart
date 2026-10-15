import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'capture.dart';
import 'config.dart';
import 'crash.dart';
import 'device.dart';
import 'log_buffer.dart';
import 'native_exit.dart';
import 'payload.dart';
import 'route_observer.dart';
import 'store/store.dart';
import 'transport.dart';
import 'verification/keys.dart';
import 'verification/pow.dart';
import 'verification/registrar.dart';
import 'verification/registration.dart';
import 'verification/signing.dart';

/// What the [OverblastFeedback] widget does for its controller: open the sheet, take a capture,
/// say how big the surface is. The controller works without one (logs, [OverblastFeedbackController.report]
/// without a screenshot, [OverblastFeedbackController.retryPending]).
abstract class FeedbackPresenter {
  Future<void> present({FeedbackCategory? category, String? message, FeedbackTrigger trigger});
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
    int logCapacity = FeedbackLimits.bufferLines,
    Future<FeedbackDeviceFacts> Function()? deviceFacts,
    DateTime Function()? clock,
    this.deviceVerification = true,
    this.deviceWait = const Duration(seconds: 3),
    Duration powBudget = const Duration(seconds: 20),
    PowSolver? powSolver,
    this.trackCrashes = true,
    Future<FeedbackCrash?> Function()? lastExit,
    this.screenshots = true,
    this.errorPrompt = true,
    List<String> appHosts = const [],
  }) : _reporter = reporter,
       appHosts = [for (final h in appHosts) h.trim().toLowerCase()].where((h) => h.isNotEmpty).toList(),
       _lastExit = lastExit ?? readLastExit,
       _extra = {...?extra},
       _clock = clock ?? DateTime.now,
       _deviceFactsReader = deviceFacts ?? readDeviceFacts,
       _store = store ?? FeedbackStore.platformDefault(),
       _logs = FeedbackLogBuffer(maxLines: logCapacity, clock: clock),
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
    _registrar = DeviceRegistrar(
      feedbackKey: feedbackKey,
      endpoint: _transport.endpoint,
      client: httpClient,
      keys: _keys,
      powSolver: powSolver,
      powBudget: powBudget,
      clock: _clock,
      log: (message) => log(FeedbackLogLevel.debug, message, src: 'overblast'),
    );
    _logs.onAdded = _onLogAdded;
    _config = FeedbackConfigClient(
      feedbackKey: feedbackKey,
      endpoint: _transport.endpoint,
      store: _store,
      client: httpClient,
      clock: _clock,
    );
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

  /// Register this install as a device and sign every report (docs/feedback-reports.md §8): App
  /// Attest on iOS, hardware key attestation on Android, a proof of work with a native key where
  /// attestation is unavailable. Platforms with no native keys (desktop, the web) send unsigned.
  final bool deviceVerification;

  /// How much longer Send waits for a registration still in flight before sending unsigned.
  final Duration deviceWait;

  /// Offer a screenshot in the sheet. Only turns it off: the key's `screenshots` (§2.1) still decides
  /// when this is true.
  final bool screenshots;

  /// Allow the error prompt (§3.6). Only turns it off: it shows only when the key has it enabled.
  final bool errorPrompt;

  /// The app's own hosts (`api.example.com`; a subdomain matches too), the only ones whose failed
  /// requests count towards the error prompt as `server_error` or `network`. Empty: only exceptions
  /// count.
  final List<String> appHosts;

  /// Keep the log on disk and a session marker, so that after an unexpected end the next launch can
  /// offer a report with that session's logs and how it ended (docs/feedback-reports.md §3.4). Starts
  /// with [startSession], which the widget calls.
  final bool trackCrashes;

  late final FeedbackTransport _transport;
  late final FeedbackConfigClient _config;
  final StreamController<FeedbackErrorKind> _errors = StreamController<FeedbackErrorKind>.broadcast();
  final Future<FeedbackCrash?> Function() _lastExit;
  Future<FeedbackPreviousSession?>? _sessionStart;
  Map<String, Object?>? _session;
  FeedbackPreviousSession? _pendingCrash;
  FeedbackCrash? _lastError;
  Timer? _persistTimer;
  Future<void> _diskChain = Future.value();
  int _persistedSeq = 0;
  FeedbackLogEntry? _repeatedSincePersist;
  bool _flushQueued = false;
  late final DeviceRegistrar _registrar;
  final DeviceKeys _keys = const DeviceKeys();
  FeedbackDeviceRegistration? _device;
  bool _deviceLoaded = false;
  bool _registrationAttempted = false;
  Future<FeedbackDeviceRegistration?>? _registering;
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

  /// The controller's clock, in milliseconds since the epoch (the sheet stamps `openedAt` with it).
  int get nowMillis => _clock().millisecondsSinceEpoch;
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
  ///
  /// [unexpected] marks an error the app caught but did not expect (the `catch` that should never
  /// run): it counts towards the error prompt as an `exception` (§3.6), as an uncaught one does.
  void log(FeedbackLogLevel level, Object? message, {String src = 'app', bool unexpected = false}) {
    _logs.add(level, message, src: src);
    if (unexpected && level == FeedbackLogLevel.error) _notice(FeedbackErrorKind.exception);
  }

  void debug(Object? message, {String src = 'app'}) => log(FeedbackLogLevel.debug, message, src: src);
  void info(Object? message, {String src = 'app'}) => log(FeedbackLogLevel.info, message, src: src);
  void warn(Object? message, {String src = 'app'}) => log(FeedbackLogLevel.warn, message, src: src);
  void error(Object? message, {String src = 'app', bool unexpected = false}) =>
      log(FeedbackLogLevel.error, message, src: src, unexpected: unexpected);

  /// Records one network call. The query string and fragment are dropped here.
  void recordNetwork(String method, Object url, int status, int ms) {
    if (_logs.paused) return; // the sheet is open (§3.4)
    final target = url.toString();
    if (target.startsWith(_transport.endpoint.toString())) return; // the report itself
    _network.add(
      FeedbackNetworkEntry(t: _clock().millisecondsSinceEpoch, method: method, url: target, status: status, ms: ms),
    );
    if ((status == 0 || (status >= 500 && status <= 599)) && _isAppHost(target)) {
      _notice(status == 0 ? FeedbackErrorKind.network : FeedbackErrorKind.serverError);
    }
  }

  List<FeedbackLogEntry> get logs => _logs.entries;

  bool _isAppHost(String url) {
    if (appHosts.isEmpty) return false;
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    return appHosts.any((h) => host == h || host.endsWith('.$h'));
  }

  void _notice(FeedbackErrorKind kind) {
    if (!_errors.isClosed && _errors.hasListener) _errors.add(kind);
  }

  /// What went wrong, as the error prompt counts it (§3.6): uncaught Dart errors through the hooks
  /// [captureErrors] installs, `log(error, unexpected: true)`, and failed requests to [appHosts]. The
  /// widget listens and decides whether to prompt.
  Stream<FeedbackErrorKind> get errorsNoticed => _errors.stream;

  // ── What the key allows (§2.1) ───────────────────────────────────────────────────────────────

  /// The key's last answer from the config door, or the defaults (no registration, no prompt) before
  /// there has ever been one.
  FeedbackRemoteConfig get config => _config.current;

  /// Reads the config door: the widget calls it at start and when the app comes back to the
  /// foreground, at most every five minutes; a controller used without the widget calls it itself.
  /// Never throws; offline, the kept answer stands.
  Future<FeedbackRemoteConfig> refreshConfig({bool force = false}) async {
    final before = _config.current;
    final after = await _config.refresh(force: force);
    if (!identical(before, after)) notifyListeners();
    return after;
  }

  /// The sheet offers a screenshot.
  bool get screenshotsAllowed => screenshots && config.screenshots;

  /// The categories the key accepts, its default first (§2).
  List<FeedbackCategory> get categories => config.categories;

  /// [category] if the key accepts it, otherwise the key's default.
  FeedbackCategory acceptedCategory(FeedbackCategory? category) =>
      category != null && categories.contains(category) ? category : categories.first;

  /// The error prompt may show at all.
  bool get errorPromptAllowed => errorPrompt && config.errorPrompt.enabled;

  bool get _registers => deviceVerification && config.verification.registers;

  /// Stops collecting logs and network calls, as the sheet does while it is open, so its own
  /// activity never fills the buffer (§3.4).
  void pauseLogs() => _logs.paused = true;
  void resumeLogs() => _logs.paused = false;
  bool get logsPaused => _logs.paused;
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
      if (!details.silent) _recordError(details.exceptionAsString(), details.stack);
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
      _recordError('$error', stack);
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

  /// Opens the report sheet. [trigger] is what the report says opened it: `button` for the app's own
  /// control (the default), `shake` and `relaunch` for the library's.
  Future<void> show({FeedbackCategory? category, String? message, FeedbackTrigger trigger = FeedbackTrigger.button}) {
    final presenter = _presenter;
    if (presenter == null) {
      throw StateError('OverblastFeedback.show() needs the OverblastFeedback widget mounted around the app');
    }
    return presenter.present(category: category, message: message, trigger: trigger);
  }

  // ── The session and the crash case (§3.4) ───────────────────────────────────────────────────

  /// The previous session, when it ended unexpectedly and no report about it has been offered yet.
  FeedbackPreviousSession? get pendingCrash => _pendingCrash;

  /// Forgets [pendingCrash]: the offer was made, answered or declined.
  void dismissPendingCrash() {
    if (_pendingCrash == null) return;
    _pendingCrash = null;
    notifyListeners();
  }

  /// Opens this session: reads how the last one ended, then marks this one open and starts keeping
  /// the log on disk. Answers the previous session when it never closed (the app crashed, was killed,
  /// or ran out of memory), with its saved logs and what the platform says about the end. Called once
  /// by the widget; later calls share the first.
  Future<FeedbackPreviousSession?> startSession() => _sessionStart ??= _startSession().catchError((Object e) {
    log(FeedbackLogLevel.debug, 'Feedback session start failed: $e', src: 'overblast');
    return null;
  });

  Future<FeedbackPreviousSession?> _startSession() async {
    if (!trackCrashes) return null;
    Map<String, Object?>? previous;
    try {
      previous = await _store.readSession();
    } catch (_) {
      previous = null;
    }
    // Asked every launch, so iOS hands over (and forgets) a MetricKit diagnostic even after a clean
    // session; only one that falls inside an unclosed session is used.
    final exit = await _lastExit().catchError((Object _) => null);
    FeedbackPreviousSession? crashed;
    if (previous != null && previous['closed'] != true) {
      var lines = const <String>[];
      try {
        lines = await _store.readLogLines();
      } catch (_) {
        // Its logs are lost; the crash is still worth offering.
      }
      final logs = parseDiskLog(lines);
      final startedAt = previous['startedAt'] is int ? previous['startedAt']! as int : 0;
      final lastSeen = logs.isEmpty ? null : (logs.last.last ?? logs.last.t);
      final dartError = FeedbackCrash.fromJson(previous['lastError']);
      // Within a minute of the start: the platform's clock and ours are the same clock, but an exit's
      // timestamp is not always exact.
      final FeedbackCrash crash;
      if (exit != null && (exit.at == null || exit.at! >= startedAt - 60000)) {
        crash = exit;
      } else if (dartError != null) {
        crash = dartError;
      } else {
        crash = FeedbackCrash(kind: FeedbackCrashKind.unknown, source: FeedbackCrashSource.marker, at: lastSeen);
      }
      crashed = FeedbackPreviousSession(crash: crash, logs: logs, startedAt: startedAt);
    }
    try {
      await _store.clearLogLines();
    } catch (_) {}
    _session = {'id': _randomId(12), 'startedAt': _clock().millisecondsSinceEpoch, 'closed': false};
    if (_lastError != null) _session!['lastError'] = _lastError!.toJson();
    await _writeSession();
    _pendingCrash = crashed;
    await flushLogs();
    if (crashed != null) notifyListeners();
    return crashed;
  }

  /// Marks the session closed: the app went to the background or is exiting cleanly. What happens to
  /// it from here (the system reclaiming a backgrounded app) is not a crash.
  Future<void> closeSession() async {
    final session = _session;
    if (session == null || session['closed'] == true) return;
    session['closed'] = true;
    await flushLogs();
    await _writeSession();
  }

  /// Marks the session open again, back in the foreground.
  Future<void> reopenSession() async {
    final session = _session;
    if (session == null || session['closed'] != true) return;
    session['closed'] = false;
    await _writeSession();
  }

  Future<void> _writeSession() {
    final snapshot = _session == null ? null : {..._session!};
    return _diskChain = _diskChain.then((_) => _store.writeSession(snapshot)).catchError((Object _) {});
  }

  /// Keeps the last fatal-looking Dart error for the session marker: Flutter does not end the process
  /// on one, but when the session then never closes, it is the best account of why.
  void _recordError(String message, StackTrace? stack) {
    _notice(FeedbackErrorKind.exception);
    _lastError = FeedbackCrash(
      kind: FeedbackCrashKind.exception,
      source: FeedbackCrashSource.handler,
      at: _clock().millisecondsSinceEpoch,
      message: message,
      stack: stack?.toString(),
    );
    final session = _session;
    if (session == null) return;
    session['lastError'] = _lastError!.toJson(); // redacted and cut by toJson
    unawaited(flushLogs().then((_) => _writeSession()));
  }

  void _onLogAdded(FeedbackLogEntry entry, {required bool updated}) {
    if (_session == null) return;
    if (updated && entry.seq <= _persistedSeq) _repeatedSincePersist = entry;
    if (entry.level == FeedbackLogLevel.error) {
      // At once, but one write for all the errors of one turn of the event loop.
      if (!_flushQueued) {
        _flushQueued = true;
        scheduleMicrotask(() {
          _flushQueued = false;
          unawaited(flushLogs());
        });
      }
    } else {
      _persistTimer ??= Timer(const Duration(seconds: 5), () => unawaited(flushLogs()));
    }
  }

  /// Writes the lines logged since the last write to the on-disk copy. The widget calls it when the
  /// app goes to the background; an error line calls it at once; otherwise it runs five seconds after
  /// the first unwritten line.
  Future<void> flushLogs() {
    _persistTimer?.cancel();
    _persistTimer = null;
    if (_session == null) return _diskChain;
    final fresh = _logs.entriesSince(_persistedSeq);
    final repeated = _repeatedSincePersist;
    _repeatedSincePersist = null;
    final lines = <String>[
      // An entry already on disk whose count grew is written again; the reader keeps the later copy.
      if (repeated != null) jsonEncode({'s': repeated.seq, ...repeated.toJson()}),
      for (final e in fresh) jsonEncode({'s': e.seq, ...e.toJson()}),
    ];
    if (fresh.isNotEmpty) _persistedSeq = fresh.last.seq;
    if (lines.isEmpty) return _diskChain;
    return _diskChain = _diskChain.then((_) => _store.appendLogLines(lines)).catchError((Object _) {});
  }

  // ── The device (§8) ──────────────────────────────────────────────────────────────────────────

  /// How well the worker knows this install, as of the last registration: `none` until one has
  /// succeeded. The controller notifies its listeners when it changes.
  FeedbackDeviceLevel get deviceLevel => _device?.level ?? FeedbackDeviceLevel.none;

  /// The registered device, or null.
  FeedbackDeviceRegistration? get device => _device;

  /// Loads the registered device, or registers one. The sheet calls it as it opens, so the
  /// registration (which can take seconds: an attestation, or a proof of work) runs while the reporter
  /// types. Never throws; null when there is no device to sign with. Calls while one is in flight share
  /// it, and a failed registration is not tried again until the worker's `Retry-After`, or ten minutes.
  Future<FeedbackDeviceRegistration?> prepareDevice() {
    if (!deviceVerification) return Future.value();
    final inFlight = _registering;
    if (inFlight != null) return inFlight;
    final run = _prepareDevice().catchError((Object _) => null);
    _registering = run;
    run.whenComplete(() {
      if (identical(_registering, run)) _registering = null;
    });
    return run;
  }

  Future<FeedbackDeviceRegistration?> _prepareDevice() async {
    // The key decides (§2.1): with verification off, which is also what holds before the config door
    // has ever answered, nothing registers.
    await _config.load();
    final reading = _config.inFlight;
    if (reading != null) await reading;
    if (!_registers) return null;
    await _loadDevice();
    if (_device != null) return _device;
    final notBefore = _registrar.retryNotBefore;
    if (notBefore != null && _clock().millisecondsSinceEpoch < notBefore) return null;
    final registered = await _registrar.register();
    _registrationAttempted = true;
    if (registered == null) return null;
    _device = registered;
    try {
      await _store.writeRegisteredDevice(registered);
    } catch (_) {
      // It lives for this session only.
    }
    log(
      FeedbackLogLevel.debug,
      'Feedback device registered: ${registered.method.wire}, ${registered.level.name}'
      '${registered.reason == null ? '' : ' (${registered.reason})'}',
      src: 'overblast',
    );
    notifyListeners();
    return registered;
  }

  Future<void> _loadDevice() async {
    if (_deviceLoaded) return;
    _deviceLoaded = true;
    FeedbackDeviceRegistration? stored;
    try {
      stored = await _store.readRegisteredDevice();
    } catch (_) {
      stored = null;
    }
    if (stored == null) return;
    if (stored.scope != _registrar.scope) {
      // Registered against another key or door: that workspace's device, not this one's.
      await _forget(stored);
      return;
    }
    _device = stored;
    notifyListeners();
  }

  /// Drops the device, its record and its native key (an App Attest key cannot be deleted, only
  /// forgotten).
  Future<void> _dropDevice() async {
    final device = _device;
    _device = null;
    if (device != null) {
      await _forget(device);
      notifyListeners();
    }
  }

  Future<void> _forget(FeedbackDeviceRegistration device) async {
    if (device.alias != null) await _keys.deleteKey(device.alias!);
    try {
      await _store.writeRegisteredDevice(null);
    } catch (_) {
      // A stale record is read as a stranger's next time and dropped then.
    }
  }

  /// The device to sign with, waiting at most [wait] for a registration in flight.
  Future<FeedbackDeviceRegistration?> _deviceWithin(Duration wait) async {
    if (!deviceVerification) return null;
    final device = await prepareDevice().timeout(wait, onTimeout: () => null);
    // A device kept from when the key had verification on signs nothing once it is off.
    return _registers ? device : null;
  }

  /// Sends [body], signed when there is a device, and handles the device refusals of §8.3:
  ///
  /// - `401 unknown_device` or `device_signature_invalid`: the device is dropped (and its key), a
  ///   new one registered, and the report resent once;
  /// - `403 device_required`: a device is registered if none has been tried yet, and the report
  ///   resent once.
  ///
  /// The body is encoded once per attempt and those exact bytes are what is signed and sent.
  Future<FeedbackResult> _deliver(Map<String, Object?> body) async {
    var device = await _deviceWithin(deviceWait);
    var resentForDevice = false;
    var resentForRequired = false;
    while (true) {
      final bytes = utf8.encode(jsonEncode(body));
      final headers = device == null ? const <String, String>{} : await _signOrDrop(device, bytes);
      try {
        return await _transport.sendBytes(bytes, headers: headers);
      } on OverblastFeedbackException catch (e) {
        final signed = headers.isNotEmpty;
        if (signed &&
            !resentForDevice &&
            e.status == 401 &&
            (e.code == 'unknown_device' || e.code == 'device_signature_invalid')) {
          resentForDevice = true;
          log(FeedbackLogLevel.debug, 'Feedback device refused (${e.code}); registering again', src: 'overblast');
          await _dropDevice();
          _registrar.retryNotBefore = null;
          device = await _deviceWithin(deviceWait);
          continue;
        }
        if (!signed && !resentForRequired && e.status == 403 && e.code == 'device_required' && deviceVerification) {
          resentForRequired = true;
          // The key requires a device, so the kept config is stale: read it again before registering.
          if (!config.verification.registers) await refreshConfig(force: true);
          if (_registers && (_registering != null || !_registrationAttempted)) {
            // Unsigned is refused outright, so waiting for the registration is worth more than the
            // three seconds Send otherwise allows.
            device = await _deviceWithin(_registrar.powBudget + const Duration(seconds: 10));
            if (device != null) continue;
          }
        }
        rethrow;
      }
    }
  }

  /// The three headers, or none: a key that can no longer sign (restored onto another phone, say)
  /// drops the device, and the report goes unsigned while a new one registers.
  Future<Map<String, String>> _signOrDrop(FeedbackDeviceRegistration device, List<int> bytes) async {
    try {
      return await signReport(_keys, device, bytes, timeMs: _clock().millisecondsSinceEpoch);
    } on DeviceKeyException catch (e) {
      log(FeedbackLogLevel.debug, 'Feedback signing failed (${e.code}); sending unsigned', src: 'overblast');
      if (identical(_device, device)) {
        await _dropDevice();
        unawaited(prepareDevice());
      }
      return const {};
    }
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
    FeedbackTrigger trigger = FeedbackTrigger.api,
    int? openedAt,
    FeedbackCrash? crash,
    List<FeedbackLogEntry>? logs,
  }) async {
    final opened = openedAt ?? _clock().millisecondsSinceEpoch;
    final logLines = logs ?? _logs.entries;
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
        openedAt: opened,
        trigger: trigger,
      ),
      element: element,
      screenshot: screenshot,
      logs: logLines,
      // A report about the previous session carries its logs, and no network calls of this one.
      network: crash == null ? _network.toList() : const [],
      crash: crash,
      logAnchor: crash == null ? null : (crash.at ?? (logLines.isEmpty ? null : logLines.last.t)),
    );
  }

  /// Sends [payload], signed by the registered device when there is one (waiting at most
  /// [deviceWait] for a registration in flight). A `429`, or no answer at all, keeps the report on
  /// the device for [retryPending] and throws with [OverblastFeedbackException.savedForLater] set;
  /// nothing is retried here beyond the single resend the device refusals call for.
  Future<FeedbackResult> submit(FeedbackPayload payload) async {
    if (!categories.contains(payload.category)) {
      // The worker would refuse it (403 category_not_accepted); it is not sent at all.
      throw OverblastFeedbackException(
        status: 403,
        code: 'category_not_accepted',
        message: categories.length == 1 && categories.single == FeedbackCategory.bug
            ? 'This app only takes problem reports.'
            : fallbackSentence('category_not_accepted'),
      );
    }
    final body = payload.toJson();
    try {
      return await _deliver(body);
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
    final openedAt = _clock().millisecondsSinceEpoch;
    final logsAtOpen = _logs.entries;
    FeedbackScreenshot? shot;
    if (includeScreenshot && screenshotsAllowed) {
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
      trigger: FeedbackTrigger.api,
      openedAt: openedAt,
      logs: logsAtOpen,
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
          await _deliver(report.body); // signed afresh: a draft's time and signature would be stale
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
    unawaited(_errors.close());
    _persistTimer?.cancel();
    _persistTimer = null;
    releaseCaptures();
    if (identical(current, this)) current = null;
    super.dispose();
  }
}

/// A session that ended unexpectedly: how, and the logs it had saved.
class FeedbackPreviousSession {
  const FeedbackPreviousSession({required this.crash, required this.logs, required this.startedAt});

  final FeedbackCrash crash;
  final List<FeedbackLogEntry> logs;

  /// Milliseconds since the epoch.
  final int startedAt;
}

/// The on-disk log, one `{"s": seq, ...entry}` per line, back into entries: a line written again
/// (its `repeat` grew) replaces the earlier copy in place, and a line a crash cut in half is skipped.
List<FeedbackLogEntry> parseDiskLog(List<String> lines) {
  final bySeq = <int, FeedbackLogEntry>{};
  for (final line in lines) {
    Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (json is! Map || json['s'] is! int) continue;
    final entry = FeedbackLogEntry.fromJson(json);
    if (entry != null) bySeq[json['s']! as int] = entry;
  }
  return bySeq.values.toList();
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
