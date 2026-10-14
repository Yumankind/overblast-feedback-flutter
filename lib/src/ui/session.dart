import 'dart:async';

import 'package:flutter/widgets.dart';

import '../capture.dart';
import '../payload.dart';
import '../transport.dart';

enum FeedbackStage { sheet, picking, done }

/// One open sheet: what the reporter has typed and chosen so far. It outlives the sheet's widgets,
/// which come and go as the reporter switches to the picker and back.
class FeedbackSession extends ChangeNotifier {
  FeedbackSession({FeedbackCategory? category, String? message, required this.askEmail})
    : category = category ?? FeedbackCategory.bug,
      messageController = TextEditingController(text: message ?? ''),
      emailController = TextEditingController();

  final TextEditingController messageController;
  final TextEditingController emailController;

  /// The reporter's email is not known to the app, so the sheet offers the field.
  final bool askEmail;

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

  bool _includeScreenshot = false;
  bool get includeScreenshot => _includeScreenshot && _capture != null;
  set includeScreenshot(bool v) => _set(() => _includeScreenshot = v);

  bool _sending = false;
  bool get sending => _sending;
  set sending(bool v) => _set(() => _sending = v);

  String? _error;
  String? get error => _error;
  set error(String? v) => _set(() => _error = v);

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

  /// The selected element's box in the captured surface's logical pixels.
  Rect? anchorRect(Size surface) {
    final a = _anchor;
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
