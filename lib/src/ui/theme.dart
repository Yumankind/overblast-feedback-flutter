import 'dart:collection';

import 'package:flutter/material.dart';

/// How the feedback window looks: the sheet, its chips and buttons, the picker, the screenshot
/// editor, the error prompt and the crash card.
///
/// Every field is optional. Unset, the window follows the app's own `ThemeData` (its colour scheme
/// and text theme), found whether the `OverblastFeedback` widget sits under `MaterialApp` or above
/// it; with no app theme at all, Material 3 in the system's light or dark.
///
/// ```dart
/// OverblastFeedback(
///   theme: const FeedbackTheme(accent: Color(0xFF0B7A5A), fontFamily: 'Inter', radius: 16),
///   child: MaterialApp(...),
/// )
/// ```
class FeedbackTheme {
  const FeedbackTheme({this.accent, this.fontFamily, this.radius, this.data});

  /// The colour of the Send button, the selected category, the picker's highlight frame and links.
  final Color? accent;

  /// The font family for every text in the window.
  final String? fontFamily;

  /// The corner radius of the sheet and the cards (buttons and chips take a smaller share of it).
  final double? radius;

  /// A whole theme to start from instead of the app's. [accent], [fontFamily] and [radius] still
  /// apply on top.
  final ThemeData? data;

  static const double defaultRadius = 24;
}

/// What the window's widgets read besides the `ThemeData`: the radius.
class FeedbackStyle extends ThemeExtension<FeedbackStyle> {
  const FeedbackStyle({this.radius = FeedbackTheme.defaultRadius});

  final double radius;

  @override
  FeedbackStyle copyWith({double? radius}) => FeedbackStyle(radius: radius ?? this.radius);

  @override
  FeedbackStyle lerp(FeedbackStyle? other, double t) =>
      other == null ? this : FeedbackStyle(radius: radius + (other.radius - radius) * t);

  static double radiusOf(BuildContext context) =>
      Theme.of(context).extension<FeedbackStyle>()?.radius ?? FeedbackTheme.defaultRadius;
}

/// The window's theme: [custom]'s whole theme, else the app's [app] theme, else Material 3 for
/// [brightness]; then [custom]'s accent, font and radius on top.
ThemeData resolveFeedbackTheme({ThemeData? app, FeedbackTheme? custom, Brightness brightness = Brightness.light}) {
  var base =
      custom?.data ?? app ?? ThemeData(useMaterial3: true, brightness: brightness, colorSchemeSeed: const Color(0xFF5B5BD6));
  final accent = custom?.accent;
  if (accent != null) {
    final onAccent = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black;
    base = base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        onPrimary: onAccent,
        secondaryContainer: Color.alphaBlend(accent.withValues(alpha: 0.22), base.colorScheme.surface),
        onSecondaryContainer: base.colorScheme.onSurface,
      ),
    );
  }
  final font = custom?.fontFamily;
  if (font != null) {
    base = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: font),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: font),
    );
  }
  final radius = custom?.radius ?? FeedbackTheme.defaultRadius;
  final control = RoundedRectangleBorder(borderRadius: BorderRadius.circular((radius * 0.6).clamp(4, 999)));
  final scheme = base.colorScheme;
  return base.copyWith(
    extensions: [...base.extensions.values.where((e) => e is! FeedbackStyle), FeedbackStyle(radius: radius)],
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: control,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        minimumSize: const Size(64, 48),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: control, foregroundColor: scheme.primary, minimumSize: const Size(48, 48)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: control, foregroundColor: scheme.primary, minimumSize: const Size(48, 48)),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular((radius * 0.4).clamp(4, 999))),
      selectedColor: scheme.secondaryContainer,
      checkmarkColor: scheme.primary,
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular((radius * 0.5).clamp(4, 999))),
    ),
  );
}

/// The app's theme as `MaterialApp` resolved it: the nearest `Theme` above [context], or, when the
/// widget sits above `MaterialApp` (the preferred place), the first `Theme` below [below], found by a
/// breadth-first walk of at most [maxElements] elements. Null when the app has none.
ThemeData? findAppTheme(BuildContext context, {Element? below, int maxElements = 400}) {
  if (context.findAncestorWidgetOfExactType<Theme>() != null) return Theme.of(context);
  if (below == null) return null;
  final queue = ListQueue<Element>()..add(below);
  var seen = 0;
  while (queue.isNotEmpty && seen < maxElements) {
    final element = queue.removeFirst();
    seen++;
    final widget = element.widget;
    if (widget is Theme) return widget.data;
    element.visitChildElements(queue.add);
  }
  return null;
}
