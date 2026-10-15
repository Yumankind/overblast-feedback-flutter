import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../capture.dart';
import '../payload.dart';
import 'session.dart';

/// Everything the sheet draws, laid over the app but outside its captured surface.
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

/// The sheet's theme: the integrator's, or Material 3 following the system's brightness.
ThemeData feedbackTheme(BuildContext context, ThemeData? theme) {
  final brightness =
      MediaQuery.maybePlatformBrightnessOf(context) ?? View.of(context).platformDispatcher.platformBrightness;
  return theme ?? ThemeData(useMaterial3: true, brightness: brightness, colorSchemeSeed: const Color(0xFF5B5BD6));
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

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.session, required this.onClose, required this.onSend, required this.surfaceSize});

  final FeedbackSession session;
  final VoidCallback onClose;
  final VoidCallback onSend;
  final Size Function() surfaceSize;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.viewInsetsOf(context);
    final padding = MediaQuery.paddingOf(context);
    return Stack(
      children: [
        Positioned.fill(
          child: Semantics(
            label: 'Close the report',
            button: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: session.sending ? null : onClose,
              child: const ColoredBox(color: Color(0x8A000000)),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: insets.bottom),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 640,
                maxHeight: (MediaQuery.sizeOf(context).height - insets.bottom - padding.top - 24).clamp(
                  200.0,
                  double.infinity,
                ),
              ),
              child: FeedbackSheet(session: session, onClose: onClose, onSend: onSend, surfaceSize: surfaceSize),
            ),
          ),
        ),
      ],
    );
  }
}

/// The sheet itself: message, category, the element, the screenshot, what will be sent, Send.
class FeedbackSheet extends StatelessWidget {
  const FeedbackSheet({
    super.key,
    required this.session,
    required this.onClose,
    required this.onSend,
    required this.surfaceSize,
  });

  final FeedbackSession session;
  final VoidCallback onClose;
  final VoidCallback onSend;
  final Size Function() surfaceSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomPad = MediaQuery.viewInsetsOf(context).bottom > 0 ? 16.0 : 16.0 + MediaQuery.paddingOf(context).bottom;
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Report a problem',
      child: Material(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 12, 20, bottomPad),
          child: session.stage == FeedbackStage.done
              ? _Done(session: session, onClose: onClose)
              : _Form(session: session, onClose: onClose, onSend: onSend, surfaceSize: surfaceSize),
        ),
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 32,
      height: 4,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

class _Form extends StatelessWidget {
  const _Form({required this.session, required this.onClose, required this.onSend, required this.surfaceSize});

  final FeedbackSession session;
  final VoidCallback onClose;
  final VoidCallback onSend;
  final Size Function() surfaceSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final anchor = session.anchor;
    final busy = session.sending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Handle(),
        Semantics(header: true, child: Text('Report a problem', style: theme.textTheme.titleLarge)),
        // Only the key's categories (§2); with one, nothing to choose.
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
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('overblast_feedback.message'),
          controller: session.messageController,
          enabled: !busy,
          autofocus: session.messageController.text.isEmpty,
          minLines: 3,
          maxLines: 8,
          maxLength: FeedbackLimits.message,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          buildCounter: (context, {required currentLength, required isFocused, maxLength}) =>
              currentLength > FeedbackLimits.message - 200 ? Text('$currentLength / $maxLength') : null,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'What happened?',
            hintText: 'What you did, what you expected, what you saw instead',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        if (session.askEmail) ...[
          const SizedBox(height: 8),
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
              border: OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (anchor == null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const ValueKey('overblast_feedback.point'),
              onPressed: busy ? null : () => session.stage = FeedbackStage.picking,
              icon: const Icon(Icons.ads_click),
              label: const Text('Point at the problem'),
            ),
          )
        else
          InputChip(
            key: const ValueKey('overblast_feedback.selected'),
            avatar: const Icon(Icons.ads_click, size: 18),
            label: Text(_describe(anchor), overflow: TextOverflow.ellipsis),
            onPressed: busy ? null : () => session.stage = FeedbackStage.picking,
            onDeleted: busy ? null : () => session.anchor = null,
            deleteButtonTooltipMessage: 'Clear the selection',
          ),
        const SizedBox(height: 4),
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
        if (session.includeScreenshot) _Thumbnail(session: session, surfaceSize: surfaceSize),
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
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: busy ? null : onClose, child: const Text('Cancel')),
            const SizedBox(width: 8),
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
      ],
    );
  }
}

String _describe(NativeAnchor a) {
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

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.session, required this.surfaceSize});

  final FeedbackSession session;
  final Size Function() surfaceSize;

  @override
  Widget build(BuildContext context) {
    final capture = session.capture!;
    final size = capture.logicalSize;
    final aspect = size.height <= 0 ? 1.0 : size.width / size.height;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          image: true,
          label: 'Screenshot to be sent',
          child: Container(
            height: 180,
            decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outlineVariant)),
            child: AspectRatio(
              aspectRatio: aspect,
              child: CustomPaint(
                foregroundPainter: _HighlightPainter(session.anchorRect(size), size),
                child: RawImage(image: capture.image, fit: BoxFit.fill),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        TextButton.icon(
          key: const ValueKey('overblast_feedback.remove_screenshot'),
          onPressed: session.sending ? null : () => session.includeScreenshot = false,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Remove'),
        ),
      ],
    );
  }
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter(this.rect, this.surface);

  final Rect? rect;
  final Size surface;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect;
    if (r == null || surface.width <= 0 || surface.height <= 0) return;
    final sx = size.width / surface.width;
    final sy = size.height / surface.height;
    paintHighlight(canvas, Rect.fromLTRB(r.left * sx, r.top * sy, r.right * sx, r.bottom * sy), 1);
  }

  @override
  bool shouldRepaint(_HighlightPainter old) => old.rect != rect || old.surface != surface;
}

class _Done extends StatelessWidget {
  const _Done({required this.session, required this.onClose});

  final FeedbackSession session;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = session.result;
    final lines = <String>[];
    if (session.savedForLater) {
      lines.add(session.error ?? 'The report could not be sent now.');
      lines.add('It is saved on this device and will be sent later.');
    } else {
      lines.add('Thank you. Your report was sent.');
      if (result?.notice != null) lines.add(result!.notice!);
      if (result?.conversationId != null) lines.add('The team can reply to you by email.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Handle(),
        Icon(
          session.savedForLater ? Icons.schedule_send : Icons.check_circle_outline,
          size: 40,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 12),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Semantics(
              liveRegion: true,
              child: Text(line, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
            ),
          ),
        const SizedBox(height: 12),
        Center(
          child: FilledButton(
            key: const ValueKey('overblast_feedback.close'),
            onPressed: onClose,
            child: const Text('Close'),
          ),
        ),
      ],
    );
  }
}

class _Picker extends StatelessWidget {
  const _Picker({required this.session, required this.onPick, required this.surfaceSize});

  final FeedbackSession session;
  final void Function(Offset globalPosition) onPick;
  final Size Function() surfaceSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final capture = session.capture;
    final surface = surfaceSize();
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
              foregroundPainter: _HighlightPainter(session.anchorRect(surface), surface),
              child: capture == null
                  ? const ColoredBox(color: Color(0x1A000000))
                  : RawImage(image: capture.image, fit: BoxFit.fill),
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          top: MediaQuery.paddingOf(context).top + 8,
          child: Material(
            color: theme.colorScheme.inverseSurface,
            borderRadius: BorderRadius.circular(16),
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      session.pickerNote ?? 'Tap the part of the screen that is wrong.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onInverseSurface),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      session.pickerNote = null;
                      session.stage = FeedbackStage.sheet;
                    },
                    child: Text('Cancel', style: TextStyle(color: theme.colorScheme.inversePrimary)),
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
