import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../capture.dart';
import '../payload.dart';
import 'balanced_text.dart';
import 'redaction.dart';
import 'session.dart';
import 'theme.dart';

/// Everything the window draws, laid over the app but outside its captured surface.
///
/// The layer brings its own ambient widgets (media query, localizations, theme, text editing
/// shortcuts, an overlay for the text field's selection handles) where the app does not already
/// provide them, because the widget can sit above `MaterialApp`, where none of them exist yet.
class FeedbackLayer extends StatelessWidget {
  const FeedbackLayer({
    super.key,
    required this.session,
    required this.theme,
    required this.onClose,
    required this.onPick,
    required this.onSend,
    required this.surfaceSize,
  });

  final FeedbackSession session;

  /// The resolved theme (`resolveFeedbackTheme`); null for the default.
  final ThemeData? theme;
  final VoidCallback onClose;
  final void Function(Offset globalPosition) onPick;
  final VoidCallback onSend;
  final Size Function() surfaceSize;

  @override
  Widget build(BuildContext context) {
    Widget content = Builder(
      builder: (context) {
        return Theme(
          data: feedbackTheme(context, theme),
          child: Shortcuts(
            shortcuts: WidgetsApp.defaultShortcuts,
            child: Actions(
              actions: WidgetsApp.defaultActions,
              child: DefaultTextEditingShortcuts(
                child: TapRegionSurface(
                  child: FocusScope(
                    child: BlockSemantics(
                      child: Overlay.wrap(
                        child: Material(
                          type: MaterialType.transparency,
                          child: ListenableBuilder(
                            listenable: session,
                            builder: (context, _) => switch (session.stage) {
                              FeedbackStage.picking => _Picker(
                                session: session,
                                onPick: onPick,
                                surfaceSize: surfaceSize,
                              ),
                              FeedbackStage.editing => _Editor(session: session),
                              _ => _SheetFrame(
                                session: session,
                                onClose: onClose,
                                onSend: onSend,
                                surfaceSize: surfaceSize,
                              ),
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    return wrapAmbient(context, content);
  }
}

/// [theme] when given, otherwise Material 3 following the system's brightness (with the window's
/// radius extension).
ThemeData feedbackTheme(BuildContext context, ThemeData? theme) {
  if (theme != null) return theme;
  final brightness =
      MediaQuery.maybePlatformBrightnessOf(context) ?? View.of(context).platformDispatcher.platformBrightness;
  return resolveFeedbackTheme(brightness: brightness);
}

/// Localizations, directionality and a media query around [content], where the app above has none
/// (the widget may sit above `MaterialApp`).
Widget wrapAmbient(BuildContext context, Widget content) {
  if (Localizations.of<MaterialLocalizations>(context, MaterialLocalizations) == null) {
    content = Localizations(
      locale: const Locale('en', 'US'),
      delegates: const [DefaultMaterialLocalizations.delegate, DefaultWidgetsLocalizations.delegate],
      child: content,
    );
  } else if (Directionality.maybeOf(context) == null) {
    content = Directionality(textDirection: TextDirection.ltr, child: content);
  }
  if (MediaQuery.maybeOf(context) == null) {
    content = MediaQuery.fromView(view: View.of(context), child: content);
  }
  return content;
}

// ── The sheet ──────────────────────────────────────────────────────────────────────────────────

/// The two resting sizes of the sheet, as fractions of the height it may use; dragged below
/// [closeSize] it closes.
const double halfSize = 0.62;
const double fullSize = 1.0;
const double closeSize = 0.3;

/// Below this usable height (logical pixels), the sheet opens at full size.
const double smallScreenHeight = 600;

/// The scrim and the sheet. The sheet is a bottom sheet with a drag handle and two sizes, half and
/// full, inside the height left between the status bar and the keyboard: it can never be taller than
/// the screen, its body scrolls, and its Send bar is pinned to its foot, which is always just above
/// the keyboard. When the keyboard comes up it goes to full size.
class _SheetFrame extends StatefulWidget {
  const _SheetFrame({required this.session, required this.onClose, required this.onSend, required this.surfaceSize});

  final FeedbackSession session;
  final VoidCallback onClose;
  final VoidCallback onSend;
  final Size Function() surfaceSize;

  @override
  State<_SheetFrame> createState() => _SheetFrameState();
}

class _SheetFrameState extends State<_SheetFrame> {
  final DraggableScrollableController _sheet = DraggableScrollableController();
  bool _closing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _sheet.isAttached && _sheet.size < fullSize) _sheet.jumpTo(fullSize);
      });
    }
  }

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  void _dragHandle(DragUpdateDetails d, double height) {
    if (!_sheet.isAttached || height <= 0) return;
    _sheet.jumpTo((_sheet.size - d.delta.dy / height).clamp(closeSize, fullSize));
  }

  void _releaseHandle(double height) {
    if (!_sheet.isAttached) return;
    final size = _sheet.size;
    final target = size < (closeSize + halfSize) / 2
        ? closeSize
        : size < (halfSize + fullSize) / 2
        ? halfSize
        : fullSize;
    if (target == closeSize) {
      _close();
    } else {
      _sheet.jumpTo(target);
    }
  }

  void _close() {
    if (_closing || widget.session.sending) return;
    _closing = true;
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final done = session.stage == FeedbackStage.done;
    return Stack(
      children: [
        Positioned.fill(
          child: Semantics(
            label: 'Close the report',
            button: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: session.sending ? null : _close,
              child: ColoredBox(color: done ? const Color(0x33000000) : const Color(0x8A000000)),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: media.padding.top + 8,
          bottom: keyboard,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = constraints.maxHeight;
              if (done) {
                return Align(
                  alignment: Alignment.bottomCenter,
                  child: _Done(session: session, onClose: widget.onClose),
                );
              }
              return Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: NotificationListener<DraggableScrollableNotification>(
                    onNotification: (n) {
                      if (n.extent <= closeSize + 0.005) _close();
                      return false;
                    },
                    child: DraggableScrollableSheet(
                      controller: _sheet,
                      // Half of a small screen is too little to write in: there it opens full.
                      initialChildSize: keyboard > 0 || height < smallScreenHeight ? fullSize : halfSize,
                      minChildSize: closeSize,
                      maxChildSize: fullSize,
                      snap: true,
                      snapSizes: const [halfSize],
                      snapAnimationDuration: media.disableAnimations ? const Duration(milliseconds: 1) : null,
                      builder: (context, scroll) => FeedbackSheet(
                        session: session,
                        scrollController: scroll,
                        onClose: _close,
                        onSend: widget.onSend,
                        surfaceSize: widget.surfaceSize,
                        onHandleDrag: (d) => _dragHandle(d, height),
                        onHandleRelease: () => _releaseHandle(height),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The sheet: a drag handle, the scrolling form, and the Cancel / Send bar pinned at its foot.
class FeedbackSheet extends StatelessWidget {
  const FeedbackSheet({
    super.key,
    required this.session,
    required this.onClose,
    required this.onSend,
    required this.surfaceSize,
    this.scrollController,
    this.onHandleDrag,
    this.onHandleRelease,
  });

  final FeedbackSession session;
  final VoidCallback onClose;
  final VoidCallback onSend;
  final Size Function() surfaceSize;
  final ScrollController? scrollController;
  final GestureDragUpdateCallback? onHandleDrag;
  final VoidCallback? onHandleRelease;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = FeedbackStyle.radiusOf(context);
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final bottomSafe = keyboardUp ? 0.0 : MediaQuery.paddingOf(context).bottom;
    final form = _Form(session: session, surfaceSize: surfaceSize);
    final bar = _SendBar(session: session, onClose: onClose, onSend: onSend, bottomSafe: bottomSafe);
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Report a problem',
      child: Material(
        key: const ValueKey('overblast_feedback.sheet'),
        color: theme.colorScheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(radius))),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // So little room (a phone on its side with the keyboard up, huge text) that a pinned bar
            // would not fit beside anything: then everything scrolls together, nothing overflows.
            if (constraints.maxHeight < 160) {
              return SingleChildScrollView(
                controller: scrollController,
                child: Column(mainAxisSize: MainAxisSize.min, children: [_handle(context), form, bar]),
              );
            }
            return Column(
              children: [
                _handle(context),
                Expanded(
                  child: SingleChildScrollView(
                    key: const ValueKey('overblast_feedback.body'),
                    controller: scrollController,
                    child: form,
                  ),
                ),
                bar,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _handle(BuildContext context) => Semantics(
    label: 'Drag to resize',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: onHandleDrag,
      onVerticalDragEnd: onHandleRelease == null ? null : (_) => onHandleRelease!(),
      child: SizedBox(
        height: 24,
        child: Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Form extends StatelessWidget {
  const _Form({required this.session, required this.surfaceSize});

  final FeedbackSession session;
  final Size Function() surfaceSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy = session.sending;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(header: true, child: Text('Report a problem', style: theme.textTheme.titleLarge)),
          // Only the key's categories (§2), at the top; with one, nothing to choose.
          if (session.categories.length > 1) ...[
            const SizedBox(height: 12),
            Wrap(
              key: const ValueKey('overblast_feedback.categories'),
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final c in session.categories)
                  ChoiceChip(
                    label: Text(c.label),
                    selected: session.category == c,
                    onSelected: busy ? null : (_) => session.setCategory(c),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('overblast_feedback.message'),
            controller: session.messageController,
            enabled: !busy,
            autofocus: session.messageController.text.isEmpty,
            minLines: 5,
            maxLines: 12,
            maxLength: FeedbackLimits.message,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            buildCounter: (context, {required currentLength, required isFocused, maxLength}) =>
                currentLength > FeedbackLimits.message - 200 ? Text('$currentLength / $maxLength') : null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'What happened?',
              hintText: 'What you did, what you expected, what you saw instead',
              alignLabelWithHint: true,
            ),
          ),
          if (session.askEmail) ...[
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('overblast_feedback.email'),
              controller: session.emailController,
              enabled: !busy,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Email (optional)',
                helperText: 'Only if you would like a reply.',
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (session.anchor == null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                key: const ValueKey('overblast_feedback.point'),
                onPressed: busy ? null : session.startPicking,
                icon: const Icon(Icons.ads_click),
                label: const Text('Point at the problem'),
              ),
            )
          else
            _PickTile(session: session, surfaceSize: surfaceSize),
          const SizedBox(height: 8),
          // The key can switch screenshots off (§2.1); then there is nothing to offer.
          if (session.screenshotsAllowed)
            SwitchListTile(
              key: const ValueKey('overblast_feedback.screenshot'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Attach a screenshot'),
              subtitle: Text(
                session.captureFailed
                    ? 'A screenshot could not be taken on this screen.'
                    : !session.captureReady
                    ? 'Taking the screenshot…'
                    : 'Private fields are blanked out.',
              ),
              value: session.includeScreenshot,
              onChanged: busy || session.capture == null ? null : (v) => session.includeScreenshot = v,
            ),
          if (session.includeScreenshot) _ShotPreview(session: session),
          const SizedBox(height: 8),
          Text(
            _whatWillBeSent(session),
            key: const ValueKey('overblast_feedback.summary'),
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (session.error != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                session.error!,
                key: const ValueKey('overblast_feedback.error'),
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Cancel and Send, pinned at the foot of the sheet. An `OverflowBar`, so at large text sizes the
/// buttons stack instead of overflowing.
class _SendBar extends StatelessWidget {
  const _SendBar({required this.session, required this.onClose, required this.onSend, required this.bottomSafe});

  final FeedbackSession session;
  final VoidCallback onClose;
  final VoidCallback onSend;
  final double bottomSafe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = session.sending;
    return DecoratedBox(
      key: const ValueKey('overblast_feedback.bar'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6))),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + bottomSafe),
        child: OverflowBar(
          alignment: MainAxisAlignment.end,
          overflowAlignment: OverflowBarAlignment.end,
          spacing: 8,
          overflowSpacing: 4,
          children: [
            TextButton(onPressed: busy ? null : onClose, child: const Text('Cancel')),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: session.messageController,
              builder: (context, value, _) => FilledButton.icon(
                key: const ValueKey('overblast_feedback.send'),
                onPressed: busy || value.text.trim().isEmpty ? null : onSend,
                icon: busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send),
                label: Text(busy ? 'Sending' : 'Send'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String describeAnchor(NativeAnchor a) {
  final label = a.label;
  return label == null || label.isEmpty ? a.type : '${a.type} “$label”';
}

/// The sentence the contract asks for (§6): what leaves the device.
String _whatWillBeSent(FeedbackSession s) {
  final parts = <String>['your message'];
  if (s.anchor != null) parts.add('the selected element');
  if (s.includeScreenshot) parts.add('the screenshot');
  final email = s.emailController.text.trim();
  if (s.askEmail && email.isNotEmpty) parts.add('your email');
  parts.add('device and app details');
  if (s.previous != null) {
    parts.add('how the app closed last time and that session’s logs');
  } else {
    parts.add('this session’s logs and network calls (no contents)');
  }
  final head = parts.sublist(0, parts.length - 1).join(', ');
  return 'Sent: $head, and ${parts.last}.';
}

/// The pick, back in the form: a thumbnail of the frozen screen round the element with its box
/// drawn, its label, and Change / Remove.
class _PickTile extends StatelessWidget {
  const _PickTile({required this.session, required this.surfaceSize});

  final FeedbackSession session;
  final Size Function() surfaceSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final anchor = session.anchor!;
    final capture = session.capture;
    final busy = session.sending;
    final radius = FeedbackStyle.radiusOf(context) * 0.5;
    final thumb = capture == null
        ? Icon(Icons.ads_click, size: 32, color: theme.colorScheme.primary)
        : ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: SizedBox(
              width: 112,
              height: 84,
              child: CustomPaint(
                key: const ValueKey('overblast_feedback.pick_thumbnail'),
                painter: PickThumbnailPainter(
                  image: capture.image,
                  pixelRatio: capture.pixelRatio,
                  surface: capture.logicalSize,
                  element: session.anchorRect(capture.logicalSize)!,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          );
    return Semantics(
      container: true,
      label: 'Selected: ${describeAnchor(anchor)}',
      child: DecoratedBox(
        key: const ValueKey('overblast_feedback.selected'),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ExcludeSemantics(child: thumb),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(describeAnchor(anchor), style: theme.textTheme.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                    Wrap(
                      children: [
                        TextButton(
                          key: const ValueKey('overblast_feedback.pick_change'),
                          onPressed: busy ? null : session.startPicking,
                          child: const Text('Change'),
                        ),
                        TextButton(
                          key: const ValueKey('overblast_feedback.pick_remove'),
                          onPressed: busy ? null : () => session.anchor = null,
                          child: const Text('Remove'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints the part of the frozen screen round [element] ([pickCropRect]) to fill the canvas, with the
/// element's box drawn in [color].
class PickThumbnailPainter extends CustomPainter {
  PickThumbnailPainter({
    required this.image,
    required this.pixelRatio,
    required this.surface,
    required this.element,
    required this.color,
  });

  final ui.Image image;
  final double pixelRatio;
  final Size surface;
  final Rect element;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final crop = pickCropRect(element, surface, aspect: size.width / size.height);
    if (crop.isEmpty) return;
    final src = Rect.fromLTRB(
      crop.left * pixelRatio,
      crop.top * pixelRatio,
      crop.right * pixelRatio,
      crop.bottom * pixelRatio,
    );
    canvas.drawImageRect(image, src, Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);
    final sx = size.width / crop.width;
    final sy = size.height / crop.height;
    final box = Rect.fromLTRB(
      (element.left - crop.left) * sx,
      (element.top - crop.top) * sy,
      (element.right - crop.left) * sx,
      (element.bottom - crop.top) * sy,
    );
    canvas.drawRect(box, Paint()..color = color.withValues(alpha: 0.14));
    canvas.drawRect(
      box.deflate(1),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(PickThumbnailPainter old) =>
      old.image != image || old.element != element || old.color != color || old.surface != surface;
}

/// The screenshot as it will be sent (redactions and the selected element's box on it), with Edit
/// and Remove. Tapping it opens the editor.
class _ShotPreview extends StatelessWidget {
  const _ShotPreview({required this.session});

  final FeedbackSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final capture = session.capture!;
    final size = capture.logicalSize;
    final aspect = size.height <= 0 ? 1.0 : size.width / size.height;
    final radius = FeedbackStyle.radiusOf(context) * 0.5;
    final busy = session.sending;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          image: true,
          button: true,
          label: 'Screenshot to be sent. Double tap to cover or blur parts of it.',
          child: GestureDetector(
            key: const ValueKey('overblast_feedback.edit_screenshot'),
            onTap: busy ? null : () => session.stage = FeedbackStage.editing,
            child: Container(
              height: 200,
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(radius),
              ),
              clipBehavior: Clip.antiAlias,
              child: AspectRatio(
                aspectRatio: aspect,
                child: CustomPaint(
                  painter: ScreenshotPainter(
                    image: capture.image,
                    pixelRatio: capture.pixelRatio,
                    surface: size,
                    redactions: session.redactions,
                    highlight: session.anchorRect(size),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.redactions.isEmpty
                    ? 'Tap it to cover or blur anything private.'
                    : '${session.redactions.length} part${session.redactions.length == 1 ? '' : 's'} hidden.',
                style: theme.textTheme.bodySmall,
              ),
              TextButton.icon(
                onPressed: busy ? null : () => session.stage = FeedbackStage.editing,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              ),
              TextButton.icon(
                key: const ValueKey('overblast_feedback.remove_screenshot'),
                onPressed: busy ? null : () => session.includeScreenshot = false,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Paints the frozen screen scaled to the canvas, with [redactions] and [highlight] (logical pixels).
class ScreenshotPainter extends CustomPainter {
  ScreenshotPainter({
    required this.image,
    required this.pixelRatio,
    required this.surface,
    this.redactions = const [],
    this.highlight,
    this.drawing,
    this.drawingKind,
  });

  final ui.Image image;
  final double pixelRatio;
  final Size surface;
  final List<FeedbackRedaction> redactions;
  final Rect? highlight;

  /// The rectangle being dragged in the editor, not yet added.
  final Rect? drawing;
  final FeedbackRedactionKind? drawingKind;

  @override
  void paint(Canvas canvas, Size size) {
    if (surface.width <= 0) return;
    final scale = size.width / image.width;
    paintRedacted(canvas, image, pixelRatio: pixelRatio, scale: scale, redactions: redactions);
    final k = size.width / surface.width; // canvas units per logical pixel
    Rect toCanvas(Rect r) => Rect.fromLTRB(r.left * k, r.top * k, r.right * k, r.bottom * k);
    final h = highlight;
    if (h != null) paintHighlight(canvas, toCanvas(h), 1);
    final d = drawing;
    if (d != null) {
      final r = toCanvas(d);
      canvas.drawRect(r, Paint()..color = const Color(0x5526282B));
      canvas.drawRect(
        r,
        Paint()
          ..color = drawingKind == FeedbackRedactionKind.blur ? const Color(0xFF2E7DF6) : privateFill
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(ScreenshotPainter old) =>
      old.image != image ||
      old.redactions.length != redactions.length ||
      old.highlight != highlight ||
      old.drawing != drawing ||
      old.drawingKind != drawingKind;
}

// ── After sending ──────────────────────────────────────────────────────────────────────────────

/// The words after a send: the usual thank-you, or §3.3's when the report joined a known issue.
String sentLine(FeedbackSession session) =>
    session.result?.known == true ? "Thanks. We already know about this one and we're on it." : 'Sent, thank you.';

/// How long the confirmation stays when nobody touches it: long enough to read its sentence.
const Duration sentConfirmation = Duration(seconds: 2);
const Duration knownConfirmation = Duration(seconds: 4);

/// After a send: a small card with a check, the sentence and Done (in the accent), which closes at
/// once; so do dragging the card down, tapping the scrim and Back. Left alone it closes after
/// [sentConfirmation] or [knownConfirmation], the clock held while a pointer is over the card or
/// accessibility focus is on Done, and started afresh when either leaves. When the report was kept
/// for later, the reason and Close, and no clock.
class _Done extends StatefulWidget {
  const _Done({required this.session, required this.onClose});

  final FeedbackSession session;
  final VoidCallback onClose;

  @override
  State<_Done> createState() => _DoneState();
}

class _DoneState extends State<_Done> {
  Timer? _timer;
  bool _hovered = false;
  bool _focused = false;
  double _dragged = 0;

  bool get _saved => widget.session.savedForLater;

  Duration get _stay => widget.session.result?.known == true ? knownConfirmation : sentConfirmation;

  @override
  void initState() {
    super.initState();
    if (!_saved) _restart();
  }

  void _restart() {
    _timer?.cancel();
    _timer = _hovered || _focused ? null : Timer(_stay, widget.onClose);
  }

  void _hold({bool? hovered, bool? focused}) {
    _hovered = hovered ?? _hovered;
    _focused = focused ?? _focused;
    if (!_saved) _restart();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final theme = Theme.of(context);
    final radius = FeedbackStyle.radiusOf(context);
    final saved = _saved;
    final lines = saved
        ? [session.error ?? 'The report could not be sent now.', 'It is saved on this device and will be sent later.']
        : [sentLine(session), if (session.result?.notice != null) session.result!.notice!];
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: MouseRegion(
          onEnter: (_) => _hold(hovered: true),
          onExit: (_) => _hold(hovered: false),
          child: GestureDetector(
            // Dragged down far or fast enough, it goes, as a sheet would.
            onVerticalDragStart: (_) => _dragged = 0,
            onVerticalDragUpdate: (d) => _dragged += d.delta.dy,
            onVerticalDragEnd: (d) {
              if (_dragged > 32 || (d.primaryVelocity ?? 0) > 300) widget.onClose();
            },
            child: Material(
              key: const ValueKey('overblast_feedback.done'),
              color: theme.colorScheme.surfaceContainerHigh,
              elevation: 6,
              borderRadius: BorderRadius.circular(radius),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(
                          saved ? Icons.schedule_send : Icons.check_circle,
                          color: theme.colorScheme.primary,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Semantics(
                            liveRegion: true,
                            child: BalancedText(lines.first, style: theme.textTheme.bodyLarge),
                          ),
                        ),
                      ],
                    ),
                    for (final line in lines.skip(1))
                      Padding(
                        padding: const EdgeInsets.only(top: 6, left: 40),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: BalancedText(line, style: theme.textTheme.bodyMedium),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: saved
                          ? TextButton(
                              key: const ValueKey('overblast_feedback.close'),
                              onPressed: widget.onClose,
                              child: const Text('Close'),
                            )
                          : FilledButton(
                              key: const ValueKey('overblast_feedback.done_button'),
                              // Focus goes here once the sentence is announced, so a keyboard or
                              // switch user closes it with one press.
                              autofocus: true,
                              onPressed: widget.onClose,
                              // Inside the button, so the handlers merge into the button's own node.
                              child: Semantics(
                                onDidGainAccessibilityFocus: () => _hold(focused: true),
                                onDidLoseAccessibilityFocus: () => _hold(focused: false),
                                child: const Text('Done'),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Point at the problem ───────────────────────────────────────────────────────────────────────

/// The frozen screen, full size. A one-line hint at the top; a tap selects the widget there and
/// draws its box; "Use this" confirms, "Pick again" clears.
class _Picker extends StatelessWidget {
  const _Picker({required this.session, required this.onPick, required this.surfaceSize});

  final FeedbackSession session;
  final void Function(Offset globalPosition) onPick;
  final Size Function() surfaceSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final capture = session.capture;
    final surface = surfaceSize();
    final pending = session.pendingAnchor;
    final media = MediaQuery.of(context);
    final radius = FeedbackStyle.radiusOf(context) * 0.6;
    return Stack(
      fit: StackFit.expand,
      children: [
        Semantics(
          label: 'The screen as it was. Tap the part that is wrong.',
          button: true,
          child: GestureDetector(
            key: const ValueKey('overblast_feedback.picker'),
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => onPick(d.globalPosition),
            child: CustomPaint(
              foregroundPainter: _PickPainter(session.anchorRect(surface, pending: true), surface, scheme.primary),
              child: capture == null
                  ? const ColoredBox(color: Color(0x1A000000))
                  : RawImage(image: capture.image, fit: BoxFit.fill),
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          top: media.padding.top + 8,
          child: Material(
            color: scheme.inverseSurface,
            borderRadius: BorderRadius.circular(radius),
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: BalancedText(
                        session.pickerNote ?? "Tap the part that's wrong",
                        maxLines: 2,
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onInverseSurface),
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('overblast_feedback.pick_cancel'),
                    onPressed: session.cancelPicking,
                    child: Text('Cancel', style: TextStyle(color: scheme.inversePrimary)),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (pending != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: media.padding.bottom + 12,
            child: Material(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(radius),
              elevation: 6,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8, top: 4),
                      child: Text(describeAnchor(pending), style: theme.textTheme.bodyLarge),
                    ),
                    OverflowBar(
                      alignment: MainAxisAlignment.end,
                      spacing: 8,
                      children: [
                        TextButton(
                          key: const ValueKey('overblast_feedback.pick_again'),
                          onPressed: () => session.pendingAnchor = null,
                          child: const Text('Pick again'),
                        ),
                        FilledButton(
                          key: const ValueKey('overblast_feedback.pick_confirm'),
                          onPressed: session.confirmPick,
                          child: const Text('Use this'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The pending pick on the frozen screen: everything else dimmed, the element's box in the accent.
class _PickPainter extends CustomPainter {
  _PickPainter(this.rect, this.surface, this.color);

  final Rect? rect;
  final Size surface;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect;
    if (r == null || surface.width <= 0 || surface.height <= 0) return;
    final sx = size.width / surface.width;
    final sy = size.height / surface.height;
    final box = Rect.fromLTRB(r.left * sx, r.top * sy, r.right * sx, r.bottom * sy);
    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(box.inflate(4));
    canvas.drawPath(dim, Paint()..color = const Color(0x73000000));
    canvas.drawRRect(
      RRect.fromRectAndRadius(box.inflate(3), const Radius.circular(6)),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_PickPainter old) => old.rect != rect || old.surface != surface || old.color != color;
}

// ── The screenshot editor ──────────────────────────────────────────────────────────────────────

/// The screenshot, full size, to draw rectangles on that cover (solid) or blur what is under them.
/// Private regions are already painted over in the image itself, so no tool here can uncover them.
class _Editor extends StatefulWidget {
  const _Editor({required this.session});

  final FeedbackSession session;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  Offset? _start;
  Rect? _drawing;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final capture = session.capture;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);
    if (capture == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => session.stage = FeedbackStage.sheet);
      return const SizedBox.shrink();
    }
    final surface = capture.logicalSize;
    return ColoredBox(
      color: scheme.surface,
      child: Padding(
        padding: EdgeInsets.only(top: media.padding.top, bottom: media.padding.bottom),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Drag over anything private. Private fields are already covered.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    key: const ValueKey('overblast_feedback.editor_done'),
                    onPressed: () => session.stage = FeedbackStage.sheet,
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final fitted = applyBoxFit(BoxFit.contain, surface, constraints.biggest);
                  final dest = Alignment.center.inscribe(fitted.destination, Offset.zero & constraints.biggest);
                  final k = dest.width / surface.width; // screen units per logical pixel of the capture
                  Offset toSurface(Offset p) => Offset(
                    ((p.dx - dest.left) / k).clamp(0, surface.width),
                    ((p.dy - dest.top) / k).clamp(0, surface.height),
                  );
                  return GestureDetector(
                    key: const ValueKey('overblast_feedback.editor_canvas'),
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (d) => setState(() {
                      _start = toSurface(d.localPosition);
                      _drawing = Rect.fromPoints(_start!, _start!);
                    }),
                    onPanUpdate: (d) => setState(() => _drawing = Rect.fromPoints(_start!, toSurface(d.localPosition))),
                    onPanEnd: (_) {
                      final r = _drawing;
                      setState(() {
                        _drawing = null;
                        _start = null;
                      });
                      if (r != null && r.width >= 4 && r.height >= 4) {
                        session.addRedaction(FeedbackRedaction(r, session.tool));
                      }
                    },
                    child: Stack(
                      children: [
                        Positioned.fromRect(
                          rect: dest,
                          child: Semantics(
                            image: true,
                            label: 'Screenshot. Drag to draw a box over a part to hide.',
                            child: CustomPaint(
                              painter: ScreenshotPainter(
                                image: capture.image,
                                pixelRatio: capture.pixelRatio,
                                surface: surface,
                                redactions: session.redactions,
                                highlight: session.anchorRect(surface),
                                drawing: _drawing,
                                drawingKind: session.tool,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  SegmentedButton<FeedbackRedactionKind>(
                    segments: const [
                      ButtonSegment(
                        value: FeedbackRedactionKind.cover,
                        icon: Icon(Icons.rectangle),
                        label: Text('Cover', key: ValueKey('overblast_feedback.editor_cover')),
                      ),
                      ButtonSegment(
                        value: FeedbackRedactionKind.blur,
                        icon: Icon(Icons.blur_on),
                        label: Text('Blur', key: ValueKey('overblast_feedback.editor_blur')),
                      ),
                    ],
                    selected: {session.tool},
                    onSelectionChanged: (s) => session.setTool(s.first),
                  ),
                  TextButton.icon(
                    key: const ValueKey('overblast_feedback.editor_undo'),
                    onPressed: session.redactions.isEmpty ? null : session.undoRedaction,
                    icon: const Icon(Icons.undo),
                    label: const Text('Undo'),
                  ),
                  TextButton.icon(
                    key: const ValueKey('overblast_feedback.editor_clear'),
                    onPressed: session.redactions.isEmpty ? null : session.clearRedactions,
                    icon: const Icon(Icons.layers_clear),
                    label: const Text('Clear'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
