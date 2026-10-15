import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'anchor.dart';
import 'capture.dart';
import 'config.dart';
import 'controller.dart';
import 'crash.dart';
import 'log_buffer.dart';
import 'payload.dart';
import 'route_observer.dart';
import 'shake.dart';
import 'store/store.dart';
import 'transport.dart';
import 'ui/crash_offer.dart';
import 'ui/error_prompt.dart';
import 'ui/layer.dart';
import 'ui/session.dart';

/// Shake-to-report around a Flutter app.
///
/// ```dart
/// runApp(OverblastFeedback(
///   feedbackKey: 'obfk_...',
///   child: MaterialApp(
///     navigatorObservers: [OverblastFeedback.navigatorObserver],
///     home: const HomeScreen(),
///   ),
/// ));
/// ```
///
/// It owns a `RepaintBoundary` around [child], which is what the screenshot captures, and draws its
/// sheet beside it rather than inside it, so the sheet is never in the image. Put it around the
/// `MaterialApp` (preferred: it then sees the whole app, dialogs included, and is first to hear the
/// Android back button) or inside `MaterialApp.builder` (`builder: (context, child) =>
/// OverblastFeedback(controller: feedback, child: child!)`); it works in either place because it
/// brings its own overlay, theme and localizations where there are none.
class OverblastFeedback extends StatefulWidget {
  const OverblastFeedback({
    super.key,
    this.feedbackKey,
    this.controller,
    this.endpoint,
    this.reporter,
    this.appVersion,
    this.buildNumber,
    this.enableShake = true,
    this.shakeOptions = const ShakeOptions(),
    this.captureDebugPrint = true,
    this.captureErrors = true,
    this.retryPendingOnStart = true,
    this.deviceVerification = true,
    this.trackCrashes = true,
    this.offerReportAfterCrash = true,
    this.screenshots = true,
    this.errorPrompt = true,
    this.appHosts = const [],
    this.theme,
    this.httpClient,
    this.store,
    required this.child,
  }) : assert(feedbackKey != null || controller != null, 'OverblastFeedback needs a feedbackKey or a controller');

  /// The workspace's public feedback key, `obfk_...` (Feedback keys in the console). Not needed when
  /// a [controller] is given.
  final String? feedbackKey;

  /// A controller made earlier (in `main()`, to log from the first line). When null, the widget
  /// makes one from the parameters below and disposes it with itself.
  final OverblastFeedbackController? controller;

  final Uri? endpoint;
  final FeedbackReporter? reporter;
  final String? appVersion;
  final String? buildNumber;

  /// Shaking the phone opens the sheet. iOS and Android only.
  final bool enableShake;
  final ShakeOptions shakeOptions;

  /// Copy `debugPrint` output into the report's logs.
  final bool captureDebugPrint;

  /// Log `FlutterError.onError` and `PlatformDispatcher.onError`, then pass each on unchanged.
  final bool captureErrors;

  /// Try the reports kept after a `429` once, a few seconds after start.
  final bool retryPendingOnStart;

  /// Register the device and sign reports (docs/feedback-reports.md §8). On iOS it needs the App
  /// Attest capability to reach `attested`; see the README. Ignored when a [controller] is given,
  /// which carries its own.
  final bool deviceVerification;

  /// Keep the log on disk and mark the session open and closed, so the next launch knows the app
  /// ended unexpectedly (docs/feedback-reports.md §3.4). Ignored when a [controller] is given.
  final bool trackCrashes;

  /// After an unexpected end, offer once at the next launch: "The app closed unexpectedly. Send a
  /// report?". Off, the previous session is still in `controller.pendingCrash` for the app's own UI,
  /// and `show(trigger: FeedbackTrigger.relaunch)` opens the sheet for it.
  final bool offerReportAfterCrash;

  /// Offer a screenshot in the sheet. Only turns it off; the key's `screenshots` decides otherwise.
  /// Ignored when a [controller] is given.
  final bool screenshots;

  /// Allow the error prompt (docs/feedback-reports.md §3.6), which shows only when the key has it
  /// enabled. False turns it off here whatever the key says. It reads its kinds from the controller,
  /// so with a [controller] given, this switch still applies.
  final bool errorPrompt;

  /// The app's own hosts, whose failed requests count towards the error prompt. Ignored when a
  /// [controller] is given (pass them to the controller).
  final List<String> appHosts;

  /// The sheet's theme. Defaults to Material 3 following the system's light or dark setting.
  final ThemeData? theme;

  final http.Client? httpClient;
  final FeedbackStore? store;
  final Widget child;

  /// The controller of the nearest [OverblastFeedback] above [context].
  static OverblastFeedbackController of(BuildContext context) {
    final controller = maybeOf(context);
    if (controller == null) {
      throw FlutterError(
        'OverblastFeedback.of() was called with a context that has no OverblastFeedback above it.\n'
        'Wrap the app in OverblastFeedback(feedbackKey: ..., child: MaterialApp(...)), or reach the '
        'controller through OverblastFeedback.current.',
      );
    }
    return controller;
  }

  static OverblastFeedbackController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_FeedbackScope>()?.controller;

  /// The controller created last, for code without a `BuildContext`.
  static OverblastFeedbackController? get current => OverblastFeedbackController.current;

  /// Add to `navigatorObservers` so reports name the screen they came from. A new observer each time
  /// it is read, so it can be given to more than one navigator.
  static NavigatorObserver get navigatorObserver => OverblastNavigatorObserver();

  @override
  State<OverblastFeedback> createState() => _OverblastFeedbackState();
}

class _FeedbackScope extends InheritedWidget {
  const _FeedbackScope({required this.controller, required super.child});

  final OverblastFeedbackController controller;

  @override
  bool updateShouldNotify(_FeedbackScope old) => !identical(old.controller, controller);
}

class _OverblastFeedbackState extends State<OverblastFeedback>
    with WidgetsBindingObserver
    implements FeedbackPresenter {
  final GlobalKey _boundaryKey = GlobalKey(debugLabel: 'overblast_feedback.surface');
  late OverblastFeedbackController _controller;
  bool _ownsController = false;
  ShakeListener? _shake;
  FeedbackSession? _session;
  Timer? _retryTimer;
  FeedbackPreviousSession? _offer;
  ErrorPromptGate? _gate;
  StreamSubscription<FeedbackErrorKind>? _errorSub;
  Completer<(ErrorPromptOutcome, int)>? _prompt;
  int _lastTypedAt = 0;

  @override
  void initState() {
    super.initState();
    _controller = _makeController();
    _controller.attach(this);
    _installCaptures();
    _syncShake();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_controller.refreshConfig());
    _startSession();
    _startErrorPrompt();
    HardwareKeyboard.instance.addHandler(_onKey);
    if (widget.retryPendingOnStart) {
      _retryTimer = Timer(const Duration(seconds: 5), () {
        _controller.retryPending().catchError((Object _) => 0);
      });
    }
  }

  OverblastFeedbackController _makeController() {
    final given = widget.controller;
    if (given != null) {
      _ownsController = false;
      return given;
    }
    _ownsController = true;
    return OverblastFeedbackController(
      feedbackKey: widget.feedbackKey!,
      endpoint: widget.endpoint,
      reporter: widget.reporter,
      appVersion: widget.appVersion,
      buildNumber: widget.buildNumber,
      httpClient: widget.httpClient,
      store: widget.store,
      deviceVerification: widget.deviceVerification,
      trackCrashes: widget.trackCrashes,
      screenshots: widget.screenshots,
      errorPrompt: widget.errorPrompt,
      appHosts: widget.appHosts,
    );
  }

  void _startErrorPrompt() {
    _errorSub?.cancel();
    _gate?.dispose();
    final controller = _controller;
    final gate = ErrorPromptGate(
      now: () => controller.nowMillis,
      startedAt: controller.nowMillis,
      store: controller.store,
      enabledFor: (kind) =>
          widget.errorPrompt && controller.errorPromptAllowed && controller.config.errorPrompt.on.contains(kind),
      minHoursBetween: () => controller.config.errorPrompt.minHoursBetween,
      blocked: _promptBlocked,
      show: _showPrompt,
      log: (line) => controller.log(FeedbackLogLevel.info, line, src: 'overblast'),
      onReport: (openedAt) {
        if (mounted) _present(category: FeedbackCategory.bug, trigger: FeedbackTrigger.errorPrompt, openedAt: openedAt);
      },
    );
    _gate = gate;
    _errorSub = controller.errorsNoticed.listen(gate.notice);
  }

  /// A key pressed in a text field: the person is typing (§3.6). A field that merely has focus is not.
  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused != null &&
          (focused.widget is EditableText || focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
        _lastTypedAt = _controller.nowMillis;
      }
    }
    return false;
  }

  bool _promptBlocked() {
    if (!mounted) return true;
    final keyboardUp = (View.maybeOf(context)?.viewInsets.bottom ?? 0) > 0;
    final typing = _controller.nowMillis - _lastTypedAt < 5000;
    final state = WidgetsBinding.instance.lifecycleState;
    final foreground = state == null || state == AppLifecycleState.resumed;
    return keyboardUp || typing || !foreground || _session != null || _offer != null || _prompt != null;
  }

  Future<(ErrorPromptOutcome, int)> _showPrompt() {
    final completer = Completer<(ErrorPromptOutcome, int)>();
    if (!mounted) {
      completer.complete((ErrorPromptOutcome.timedOut, _controller.nowMillis));
    } else {
      setState(() => _prompt = completer);
    }
    return completer.future;
  }

  void _endPrompt(ErrorPromptOutcome outcome) {
    final completer = _prompt;
    if (completer == null) return;
    final at = _controller.nowMillis;
    setState(() => _prompt = null);
    completer.complete((outcome, at));
  }

  void _startSession() {
    final controller = _controller;
    controller.startSession().then((previous) {
      if (!mounted || !identical(controller, _controller)) return;
      if (previous != null && widget.offerReportAfterCrash && identical(controller.pendingCrash, previous)) {
        setState(() => _offer = previous);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(_controller.closeSession());
      case AppLifecycleState.resumed:
        unawaited(_controller.reopenSession());
        unawaited(_controller.refreshConfig()); // at most every five minutes
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        unawaited(_controller.flushLogs());
    }
  }

  void _answerOffer(bool send) {
    final previous = _offer;
    setState(() => _offer = null);
    if (previous == null) return;
    if (send) {
      present(trigger: FeedbackTrigger.relaunch);
    } else {
      _controller.dismissPendingCrash();
    }
  }

  void _installCaptures() {
    if (widget.captureDebugPrint) _controller.captureDebugPrint();
    if (widget.captureErrors) _controller.captureErrors();
  }

  void _syncShake() {
    if (widget.enableShake && _shake == null) {
      _shake = ShakeListener(onShake: _onShake, options: widget.shakeOptions)..start();
    } else if (!widget.enableShake && _shake != null) {
      _shake!.stop();
      _shake = null;
    }
  }

  void _onShake() {
    if (!mounted || _session != null) return;
    _controller.log(FeedbackLogLevel.info, 'Feedback sheet opened by a shake', src: 'overblast');
    present(trigger: FeedbackTrigger.shake);
  }

  @override
  void didUpdateWidget(OverblastFeedback old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller) && widget.controller != null) {
      _controller.detach(this);
      if (_ownsController) _controller.dispose();
      _controller = _makeController()..attach(this);
      _installCaptures();
      _startErrorPrompt();
    } else if (_ownsController && widget.reporter != old.reporter && widget.reporter != null) {
      final r = widget.reporter!;
      _controller.setReporter(email: r.email, name: r.name, accountRef: r.accountRef);
    }
    if (old.enableShake != widget.enableShake) _syncShake();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.closeSession()); // a clean exit
    HardwareKeyboard.instance.removeHandler(_onKey);
    _errorSub?.cancel();
    _gate?.dispose();
    final prompt = _prompt;
    _prompt = null;
    if (prompt != null && !prompt.isCompleted) prompt.complete((ErrorPromptOutcome.timedOut, _controller.nowMillis));
    if (_session != null) _controller.resumeLogs();
    _shake?.stop();
    _session?.dispose();
    _session = null;
    _controller.detach(this);
    if (_ownsController) {
      _controller.dispose();
    } else {
      _controller.releaseCaptures();
    }
    super.dispose();
  }

  @override
  Future<bool> didPopRoute() async {
    if (_session == null) return false;
    if (_session!.stage == FeedbackStage.picking) {
      _session!.stage = FeedbackStage.sheet;
    } else if (!_session!.sending) {
      _close();
    }
    return true;
  }

  // ── FeedbackPresenter ────────────────────────────────────────────────────────────────────────

  RenderRepaintBoundary? get _boundary {
    final ro = _boundaryKey.currentContext?.findRenderObject();
    return ro is RenderRepaintBoundary && ro.attached && ro.hasSize ? ro : null;
  }

  @override
  FeedbackViewport? get viewport {
    final boundary = _boundary;
    final view = View.maybeOf(context);
    if (boundary == null || view == null) return null;
    return FeedbackViewport(
      width: boundary.size.width,
      height: boundary.size.height,
      devicePixelRatio: view.devicePixelRatio,
    );
  }

  @override
  Future<FeedbackCapture?> capture() async {
    final boundary = _boundary;
    final element = _boundaryKey.currentContext;
    if (boundary == null || element is! Element || !mounted) return null;
    try {
      return await FeedbackCapture.take(
        boundary,
        element,
        devicePixelRatio: View.maybeOf(context)?.devicePixelRatio ?? 2.0,
      );
    } catch (e) {
      _controller.log(FeedbackLogLevel.warn, 'Feedback screenshot failed: $e', src: 'overblast');
      return null;
    }
  }

  @override
  Future<void> present({
    FeedbackCategory? category,
    String? message,
    FeedbackTrigger trigger = FeedbackTrigger.button,
  }) => _present(category: category, message: message, trigger: trigger);

  Future<void> _present({
    FeedbackCategory? category,
    String? message,
    FeedbackTrigger trigger = FeedbackTrigger.button,
    int? openedAt,
  }) {
    final existing = _session;
    if (existing != null) return existing.closed.future;
    // A relaunch report is about the previous session; offered once, so it is taken here.
    final previous = trigger == FeedbackTrigger.relaunch ? _controller.pendingCrash : null;
    if (previous != null) _controller.dismissPendingCrash();
    final session = FeedbackSession(
      category: _controller.acceptedCategory(previous != null ? FeedbackCategory.bug : category),
      categories: _controller.categories,
      message: message,
      askEmail: (_controller.reporter?.email ?? '').trim().isEmpty,
      openedAt: openedAt ?? _controller.nowMillis,
      screenshotsAllowed: _controller.screenshotsAllowed,
      trigger: previous == null && trigger == FeedbackTrigger.relaunch ? FeedbackTrigger.button : trigger,
      previous: previous,
    );
    // The report is of what happened before it was opened: nothing from here on is collected (§3.4).
    final logsAtOpen = _controller.logs;
    session.logsAtOpen = logsAtOpen;
    _controller.pauseLogs();
    final prompt = _prompt;
    setState(() {
      _session = session;
      _offer = null;
      _prompt = null;
    });
    if (prompt != null && !prompt.isCompleted) prompt.complete((ErrorPromptOutcome.timedOut, _controller.nowMillis));
    // The device registers while the reporter types; Send waits at most three seconds more for it.
    unawaited(_controller.prepareDevice());
    // The sheet lives outside the captured surface, so it can appear at once while the capture runs:
    // the image is of the app, not of the sheet.
    capture().then((shot) {
      if (identical(_session, session)) {
        session.setCapture(shot);
      } else {
        shot?.dispose();
      }
    });
    return session.closed.future;
  }

  // ── The flow ─────────────────────────────────────────────────────────────────────────────────

  void _close() {
    final session = _session;
    if (session == null) return;
    _controller.resumeLogs();
    setState(() => _session = null);
    session.dispose();
  }

  Size _surfaceSize() => _boundary?.size ?? Size.zero;

  void _pick(Offset globalPosition) {
    final session = _session;
    final boundary = _boundary;
    final element = _boundaryKey.currentContext;
    if (session == null || boundary == null || element is! Element) return;
    final local = boundary.globalToLocal(globalPosition);
    NativeAnchor? anchor;
    try {
      anchor = anchorAt(element, boundary, local);
    } catch (e) {
      _controller.log(FeedbackLogLevel.warn, 'Feedback element picker failed: $e', src: 'overblast');
    }
    if (anchor == null) {
      session.pickerNote = 'Nothing there to select. Tap another part of the screen.';
      session.refresh();
      return;
    }
    session.pickerNote = null;
    session.anchor = anchor;
    session.stage = FeedbackStage.sheet;
  }

  Future<void> _send() async {
    final session = _session;
    if (session == null || session.sending) return;
    final message = session.messageController.text.trim();
    if (message.isEmpty) {
      session.error = 'Say what happened first.';
      return;
    }
    final email = session.askEmail ? session.emailController.text.trim() : '';
    if (email.isNotEmpty && !isPlausibleEmail(email)) {
      session.error = 'That email address does not look right. Fix it, or leave it empty.';
      return;
    }
    session.error = null;
    session.sending = true;
    try {
      FeedbackScreenshot? shot;
      final capture = session.capture;
      if (session.includeScreenshot && capture != null) {
        final highlight = session.anchorRect(capture.logicalSize);
        final bytes = await capture.encodePng(highlight: highlight);
        if (bytes == null) {
          session.error = 'The screenshot is too large to send. Remove it and send again.';
          return;
        }
        shot = FeedbackScreenshot(bytes: bytes, highlighted: highlight != null);
      }
      final payload = await _controller.buildPayload(
        message: message,
        category: session.category,
        reporter: email.isEmpty ? null : FeedbackReporter(email: email),
        element: session.anchor,
        screenshot: shot,
        trigger: session.trigger,
        openedAt: session.openedAt,
        crash: session.previous?.crash,
        logs: session.previous?.logs ?? session.logsAtOpen,
      );
      final result = await _controller.submit(payload);
      if (!identical(_session, session)) return;
      session.result = result;
      session.stage = FeedbackStage.done;
    } on OverblastFeedbackException catch (e) {
      if (!identical(_session, session)) return;
      session.error = e.message;
      if (e.savedForLater) {
        session.savedForLater = true;
        session.stage = FeedbackStage.done;
      }
    } catch (e) {
      _controller.log(FeedbackLogLevel.warn, 'Feedback report failed: $e', src: 'overblast');
      if (identical(_session, session)) session.error = 'The report could not be prepared. Try again.';
    } finally {
      if (identical(_session, session)) session.sending = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return _FeedbackScope(
      controller: _controller,
      child: Stack(
        fit: StackFit.passthrough,
        textDirection: TextDirection.ltr,
        children: [
          RepaintBoundary(key: _boundaryKey, child: widget.child),
          if (session != null)
            Positioned.fill(
              child: FeedbackLayer(
                key: ObjectKey(session),
                session: session,
                theme: widget.theme,
                onClose: _close,
                onPick: _pick,
                onSend: _send,
                surfaceSize: _surfaceSize,
              ),
            ),
          if (session == null && _offer == null && _prompt != null)
            Positioned.fill(
              child: FeedbackErrorPrompt(
                theme: widget.theme,
                onReport: () => _endPrompt(ErrorPromptOutcome.report),
                onClose: () => _endPrompt(ErrorPromptOutcome.dismissed),
                onTimeout: () => _endPrompt(ErrorPromptOutcome.timedOut),
              ),
            ),
          if (session == null && _offer != null)
            Positioned.fill(
              child: FeedbackCrashOffer(
                theme: widget.theme,
                onSend: () => _answerOffer(true),
                onDismiss: () => _answerOffer(false),
              ),
            ),
        ],
      ),
    );
  }
}
