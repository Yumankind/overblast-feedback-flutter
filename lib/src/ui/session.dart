import 'dart:async';

import 'package:flutter/widgets.dart';

import '../capture.dart';
import '../controller.dart' show FeedbackPreviousSession;
import '../crash.dart';
import '../log_buffer.dart';
import '../payload.dart';
import '../transport.dart';
import 'redaction.dart';


/// Where the window is: the form, picking an element on the frozen screen, editing the screenshot,
/// or the short confirmation after sending.
enum FeedbackStage { sheet, picking, editing, done }

/// One open sheet: what the reporter has typed and chosen so far. It outlives the sheet's widgets,
/// which come and go as the reporter switches to the picker and back.
class FeedbackSession extends ChangeNotifier {
  FeedbackSession({
    FeedbackCategory? category,
    String? message,
    required this.askEmail,
    required this.openedAt,
    this.trigger = FeedbackTrigger.button,
    this.previous,
    this.screenshotsAllowed = true,
    this.categories = FeedbackCategory.values,
  }) : category = category ?? FeedbackCategory.bug,
      messageController = TextEditingController(text: message ?? ''),
      emailController = TextEditingController();

  final TextEditingController messageController;
  final TextEditingController emailController;

  /// The reporter's email is not known to the app, so the sheet offers the field.
  final bool askEmail;

  /// When the sheet appeared (§3.4), milliseconds since the epoch.
  final int openedAt;
  final FeedbackTrigger trigger;

  /// For a report about the previous session (`trigger: relaunch`): how it ended and its logs.
  final FeedbackPreviousSession? previous;

  /// The key and the app allow a screenshot (§2.1); otherwise the sheet offers none.
  final bool screenshotsAllowed;

  /// The categories the key accepts (§2); with one, the sheet offers no choice.
  final List<FeedbackCategory> categories;

  final Completer<void> closed = Completer<void>();

  FeedbackStage _stage = FeedbackStage.sheet;
  FeedbackStage get stage => _stage;
  set stage(FeedbackStage v) => _set(() => _stage = v);

  FeedbackCategory category;

  FeedbackCapture? _capture;
  FeedbackCapture? get capture => _capture;
  bool captureFailed = false;
  bool captureReady = false;

  NativeAnchor? _anchor;
  NativeAnchor? get anchor => _anchor;
  set anchor(NativeAnchor? v) => _set(() => _anchor = v);

  /// The element tapped in the picker, waiting for "Use this".
  NativeAnchor? _pendingAnchor;
  NativeAnchor? get pendingAnchor => _pendingAnchor;
  set pendingAnchor(NativeAnchor? v) => _set(() => _pendingAnchor = v);

  /// Opens the picker, starting from the current pick.
  void startPicking() => _set(() {
    _pendingAnchor = _anchor;
    pickerNote = null;
    _stage = FeedbackStage.picking;
  });

  /// "Use this": the pending pick becomes the pick.
  void confirmPick() => _set(() {
    if (_pendingAnchor != null) _anchor = _pendingAnchor;
    _pendingAnchor = null;
    pickerNote = null;
    _stage = FeedbackStage.sheet;
  });

  void cancelPicking() => _set(() {
    _pendingAnchor = null;
    pickerNote = null;
    _stage = FeedbackStage.sheet;
  });

  // ── The screenshot editor ──

  final List<FeedbackRedaction> _redactions = [];
  List<FeedbackRedaction> get redactions => List.unmodifiable(_redactions);
  FeedbackRedactionKind tool = FeedbackRedactionKind.cover;

  void addRedaction(FeedbackRedaction r) => _set(() => _redactions.add(r));
  void undoRedaction() => _set(() {
    if (_redactions.isNotEmpty) _redactions.removeLast();
  });
  void clearRedactions() => _set(_redactions.clear);
  void setTool(FeedbackRedactionKind kind) => _set(() => tool = kind);

  bool _includeScreenshot = false;
  bool get includeScreenshot => screenshotsAllowed && _includeScreenshot && _capture != null;
  set includeScreenshot(bool v) => _set(() => _includeScreenshot = v);

  bool _sending = false;
  bool get sending => _sending;
  set sending(bool v) => _set(() => _sending = v);

  String? _error;
  String? get error => _error;
  set error(String? v) => _set(() => _error = v);

  /// The log as it was when the sheet opened; collection is paused while it is open.
  List<FeedbackLogEntry>? logsAtOpen;

  /// After sending: what the worker said, or that the report was kept for later.
  FeedbackResult? result;
  bool savedForLater = false;

  /// A one-line note shown under the picker's banner ("Nothing there to select").
  String? pickerNote;

  bool _disposed = false;

  void setCategory(FeedbackCategory c) => _set(() => category = c);

  void setCapture(FeedbackCapture? capture) {
    if (_disposed) {
      capture?.dispose();
      return;
    }
    _set(() {
      _capture = capture;
      captureFailed = capture == null;
      captureReady = true;
    });
  }

  /// The selected element's box in the captured surface's logical pixels ([pending]: the pick
  /// waiting for confirmation).
  Rect? anchorRect(Size surface, {bool pending = false}) {
    final a = pending ? _pendingAnchor : _anchor;
    if (a == null) return null;
    return Rect.fromLTWH(
      a.rect.x * surface.width,
      a.rect.y * surface.height,
      a.rect.w * surface.width,
      a.rect.h * surface.height,
    );
  }

  void refresh() => _set(() {});

  void _set(VoidCallback change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _capture?.dispose();
    _capture = null;
    messageController.dispose();
    emailController.dispose();
    if (!closed.isCompleted) closed.complete();
    super.dispose();
  }
}
