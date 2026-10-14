import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'payload.dart';
import 'private.dart';
import 'tree.dart';

/// Finds the widget under [point] (in [boundary]'s logical coordinates) and describes it as the
/// contract's `native` element.
///
/// How: the live render tree is hit tested at the point, exactly as a tap would be, which already
/// knows what is on top, what is offstage and what ignores pointers. The deepest render object hit
/// is mapped back to its element by one walk of the element tree under [root] (no `debugCreator`,
/// so it works in release builds too), and from there the ancestors are climbed to pick the widget a
/// person would name: the nearest interactive widget (a button, a field, a list tile, anything
/// with a `ValueKey`), or failing that the nearest widget that is not framework plumbing.
///
/// Returns null when nothing under [root] is at the point.
NativeAnchor? anchorAt(Element root, RenderBox boundary, Offset point) {
  final picked = pickElementAt(root, boundary, point);
  if (picked == null) return null;
  return describeElement(picked.chosen, picked.chain, root, boundary);
}

/// The element chosen at a point, with the chain of elements from the deepest hit up to (not
/// including) the root.
class PickedElement {
  const PickedElement(this.chosen, this.chain);

  final Element chosen;

  /// Deepest first; [chosen] is one of them.
  final List<Element> chain;
}

PickedElement? pickElementAt(Element root, RenderBox boundary, Offset point) {
  final bounds = Offset.zero & boundary.size;
  if (!bounds.contains(point)) return null;
  final result = BoxHitTestResult();
  boundary.hitTest(result, position: point);

  final byRender = <RenderObject, Element>{};
  walkElements(root, (e) {
    if (e is RenderObjectElement) byRender[e.renderObject] = e;
    return true;
  });

  Element? deepest;
  for (final entry in result.path) {
    final target = entry.target;
    if (target is RenderObject && !identical(target, boundary)) {
      final element = byRender[target];
      if (element != null) {
        deepest = element;
        break;
      }
    }
  }
  if (deepest == null) return null;

  final chain = <Element>[deepest];
  deepest.visitAncestorElements((a) {
    if (identical(a, root)) return false;
    chain.add(a);
    return true;
  });

  return PickedElement(chain[_chooseIndex(chain, boundary)], chain);
}

int _chooseIndex(List<Element> chain, RenderBox boundary) {
  final viewportArea = boundary.size.width * boundary.size.height;
  double areaOf(Element e) {
    final ro = e.findRenderObject();
    if (ro is! RenderBox) return double.infinity;
    final r = rectIn(ro, boundary);
    return r == null ? double.infinity : r.width * r.height;
  }

  // The nearest interactive (or keyed) widget, unless it is most of the screen: a GestureDetector
  // around a whole page says less than the Text that was tapped.
  int? interactive;
  for (var i = 0; i < chain.length; i++) {
    if (_isInteractive(chain[i].widget)) {
      if (areaOf(chain[i]) <= viewportArea * 0.5) interactive = i;
      break;
    }
  }
  if (interactive != null) {
    // A button is an InkWell inside a ButtonStyleButton inside an ElevatedButton, a field an
    // EditableText inside a TextField inside a TextFormField: climb to the outermost of such a
    // cluster, which is the one the code names, while it stays about the same size.
    final base = areaOf(chain[interactive]);
    var best = interactive;
    for (var i = interactive + 1; i < chain.length && i <= interactive + 60; i++) {
      final w = chain[i].widget;
      if (!_isInteractive(w)) continue;
      final a = areaOf(chain[i]);
      if (a > base * 2.0 + 1) break;
      best = i;
    }
    return best;
  }
  for (var i = 0; i < chain.length; i++) {
    if (!isFrameworkNoise(chain[i].widget)) return i;
  }
  return 0;
}

/// Builds the anchor for [chosen], given the [chain] it was picked from (deepest first).
NativeAnchor describeElement(Element chosen, List<Element> chain, Element root, RenderBox boundary) {
  final chosenIndex = chain.indexOf(chosen);
  final upTo = chosenIndex < 0 ? 0 : chosenIndex;

  // id: the nearest ValueKey from the chosen widget down to what was hit, then a Semantics identifier.
  String? id;
  for (var i = upTo; i >= 0 && id == null; i--) {
    id = _meaningfulKey(chain[i].widget);
  }
  for (var i = upTo; i >= 0 && id == null; i--) {
    final w = chain[i].widget;
    if (w is Semantics) {
      final ident = w.properties.identifier;
      if (ident != null && ident.trim().isNotEmpty) id = ident.trim();
    }
  }

  // Inside something private, or private itself: the type and the box only, never the text.
  final insidePrivate = isSensitiveWidget(chosen.widget) || chain.skip(upTo).any((e) => isSensitiveWidget(e.widget));
  final label = insidePrivate ? null : _labelOf(chosen, chain.take(upTo + 1).toList());

  // Path: the ancestors from the outside in, plumbing dropped, the chosen widget last.
  final names = <String>[];
  for (var i = chain.length - 1; i >= upTo; i--) {
    final e = chain[i];
    if (i != upTo && isFrameworkNoise(e.widget)) continue;
    final name = typeName(e.widget);
    if (names.isNotEmpty && names.last == name) continue;
    names.add(name);
  }

  final ro = chosen.findRenderObject();
  final size = boundary.size;
  Rect rect = Rect.zero;
  if (ro is RenderBox) rect = rectIn(ro, boundary) ?? Rect.zero;
  // Only the part on screen: a row half scrolled away is described by the half the reporter saw.
  final bounds = Offset.zero & size;
  if (rect.overlaps(bounds)) rect = rect.intersect(bounds);
  final w = size.width <= 0 ? 1.0 : size.width;
  final h = size.height <= 0 ? 1.0 : size.height;

  return NativeAnchor(
    path: names,
    type: typeName(chosen.widget),
    id: id,
    label: label,
    rect: FeedbackRect(x: rect.left / w, y: rect.top / h, w: rect.width / w, h: rect.height / h),
    viewportWidth: size.width,
    viewportHeight: size.height,
  );
}

/// The widget's type as written in code: `ElevatedButton`, `CartRow`, `ValueListenableBuilder<int>`.
/// In a build compiled with `--obfuscate` these are minified names.
String typeName(Widget widget) => widget.runtimeType.toString();

String? _keyString(Key? key) {
  // Exactly ValueKey (what `Key('x')` and `ValueKey('x')` make), not the framework's subclasses
  // such as the list delegates' salted keys.
  if (key is ValueKey && key.runtimeType.toString().startsWith('ValueKey<')) {
    final v = key.value;
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }
  return null;
}

/// The widget's ValueKey as an id, when it is one the app chose: any ValueKey on an app widget, and
/// a string ValueKey on a framework one (`SizedBox(key: ValueKey('iban'))`). The framework keys its
/// own plumbing with ValueKeys too (a Scaffold's `LayoutId` by an enum, a list's `KeyedSubtree` by
/// index), never with a string.
String? _meaningfulKey(Widget w) {
  final s = _keyString(w.key);
  if (s == null) return null;
  if (!isFrameworkNoise(w)) return s;
  return (w.key! as ValueKey).value is String ? s : null;
}

String? _labelOf(Element chosen, List<Element> below) {
  // A Semantics label on the chosen widget or between it and what was hit.
  for (final e in below.reversed) {
    final w = e.widget;
    if (w is Semantics && (w.properties.label?.trim().isNotEmpty ?? false)) return _tidy(w.properties.label!);
  }
  // Otherwise the tooltip or the visible text inside it, skipping anything private and every text
  // field's content (EditableText is never read).
  final parts = <String>[];
  var length = 0;
  String? tooltip;
  void take(String s) {
    final t = s.trim();
    if (t.isEmpty || length > FeedbackLimits.elementLabel) return;
    parts.add(t);
    length += t.length + 1;
  }

  void visit(Element e) {
    final w = e.widget;
    if (isSensitiveWidget(w) || w is EditableText) return;
    if (w is Tooltip && tooltip == null && (w.message?.trim().isNotEmpty ?? false)) tooltip = w.message;
    if (w is Semantics && (w.properties.label?.trim().isNotEmpty ?? false)) {
      take(w.properties.label!);
      return;
    }
    if (w is Text) {
      take(w.data ?? w.textSpan?.toPlainText() ?? '');
      return;
    }
    if (w is RichText) {
      take(w.text.toPlainText());
      return;
    }
    if (w is Icon && (w.semanticLabel?.isNotEmpty ?? false)) take(w.semanticLabel!);
    if (length > FeedbackLimits.elementLabel) return;
    e.visitChildElements(visit);
  }

  visit(chosen);
  final text = parts.isNotEmpty ? parts.join(' ') : tooltip;
  return text == null ? null : _tidy(text);
}

String _tidy(String s) => clip(s.replaceAll(RegExp(r'\s+'), ' ').trim(), FeedbackLimits.elementLabel);

const Set<String> _interactiveTypes = {
  'ElevatedButton',
  'FilledButton',
  'OutlinedButton',
  'TextButton',
  'IconButton',
  'FloatingActionButton',
  'BackButton',
  'CloseButton',
  'DrawerButton',
  'EndDrawerButton',
  'InkWell',
  'InkResponse',
  'GestureDetector',
  'ListTile',
  'CheckboxListTile',
  'SwitchListTile',
  'RadioListTile',
  'Checkbox',
  'Switch',
  'Radio',
  'Slider',
  'RangeSlider',
  'TextField',
  'TextFormField',
  'DropdownButton',
  'DropdownButtonFormField',
  'DropdownMenu',
  'PopupMenuButton',
  'PopupMenuItem',
  'MenuAnchor',
  'MenuItemButton',
  'SubmenuButton',
  'Chip',
  'ActionChip',
  'ChoiceChip',
  'FilterChip',
  'InputChip',
  'SegmentedButton',
  'ToggleButtons',
  'Tab',
  'NavigationDestination',
  'BottomNavigationBar',
  'NavigationBar',
  'NavigationRail',
  'NavigationDrawerDestination',
  'ExpansionTile',
  'SearchBar',
  'SearchAnchor',
  'CupertinoButton',
  'CupertinoSwitch',
  'CupertinoSlider',
  'CupertinoTextField',
  'CupertinoCheckbox',
  'CupertinoRadio',
  'CupertinoListTile',
  'CupertinoContextMenu',
};

bool _isInteractive(Widget w) {
  // A ValueKey the app chose marks a widget worth naming.
  if (_meaningfulKey(w) != null) return true;
  final name = typeName(w);
  final bare = name.contains('<') ? name.substring(0, name.indexOf('<')) : name;
  return _interactiveTypes.contains(bare);
}

// Framework widgets that hold the tree together but say nothing about what is on screen.
const Set<String> _noise = {
  'Padding',
  'Align',
  'Center',
  'SizedBox',
  'ConstrainedBox',
  'UnconstrainedBox',
  'LimitedBox',
  'OverflowBox',
  'SizedOverflowBox',
  'FractionallySizedBox',
  'Expanded',
  'Flexible',
  'Positioned',
  'PositionedDirectional',
  'Row',
  'Column',
  'Flex',
  'Stack',
  'IndexedStack',
  'Wrap',
  'Container',
  'DecoratedBox',
  'ColoredBox',
  'ClipRect',
  'ClipRRect',
  'ClipRSuperellipse',
  'ClipPath',
  'ClipOval',
  'PhysicalModel',
  'PhysicalShape',
  'Opacity',
  'Transform',
  'FittedBox',
  'AspectRatio',
  'IntrinsicHeight',
  'IntrinsicWidth',
  'Baseline',
  'SafeArea',
  'SliverSafeArea',
  'MediaQuery',
  'Builder',
  'StatefulBuilder',
  'LayoutBuilder',
  'SliverLayoutBuilder',
  'KeyedSubtree',
  'Semantics',
  'MergeSemantics',
  'ExcludeSemantics',
  'BlockSemantics',
  'IndexedSemantics',
  'Listener',
  'MouseRegion',
  'RawGestureDetector',
  'AbsorbPointer',
  'IgnorePointer',
  'Focus',
  'FocusScope',
  'FocusTraversalGroup',
  'FocusTraversalOrder',
  'ExcludeFocus',
  'Actions',
  'Shortcuts',
  'CallbackShortcuts',
  'DefaultTextStyle',
  'IconTheme',
  'Theme',
  'Material',
  'Ink',
  'ListenableBuilder',
  'ValueListenableBuilder',
  'StreamBuilder',
  'FutureBuilder',
  'TweenAnimationBuilder',
  'NotificationListener',
  'ScrollConfiguration',
  'Scrollable',
  'Viewport',
  'ShrinkWrappingViewport',
  'SliverList',
  'SliverFixedExtentList',
  'SliverGrid',
  'SliverPadding',
  'SliverToBoxAdapter',
  'SliverFillRemaining',
  'SliverIgnorePointer',
  'RepaintBoundary',
  'CustomPaint',
  'CustomSingleChildLayout',
  'CustomMultiChildLayout',
  'LayoutId',
  'Offstage',
  'TickerMode',
  'Visibility',
  'Overlay',
  'Navigator',
  'HeroControllerScope',
  'Hero',
  'PrimaryScrollController',
  'Directionality',
  'Localizations',
  'Title',
  'CheckedModeBanner',
  'Banner',
  'PageStorage',
  'RestorationScope',
  'UnmanagedRestorationScope',
  'RootRestorationScope',
  'SharedAppData',
  'View',
  'RawView',
  'DefaultTextEditingShortcuts',
  'TextFieldTapRegion',
  'TapRegion',
  'TapRegionSurface',
  'ShortcutRegistrar',
  'RichText',
  'RawImage',
  'MetaData',
  'GlowingOverscrollIndicator',
  'StretchingOverscrollIndicator',
  'Scrollbar',
  'RawScrollbar',
  'CupertinoScrollbar',
  'WidgetsApp',
  'Router',
  'Form',
  'FormField',
  'AutofillGroup',
  'TextSelectionGestureDetector',
  'CompositedTransformTarget',
  'CompositedTransformFollower',
  'UndoHistory',
  'OverblastFeedback',
  'OverblastPrivate',
  'SelectionContainer',
  'SelectionRegistrarScope',
  'InheritedTheme',
  'ScaffoldMessenger',
  'DefaultSelectionStyle',
  'DefaultAssetBundle',
  'MaterialBanner',
  'LookupBoundary',
  'Placeholder',
  'Flow',
  'SliverMainAxisGroup',
  'SliverCrossAxisGroup',
  'NestedScrollView',
  'ProxyWidget',
  'SingleChildScrollView',
  'FractionalTranslation',
  'ScrollNotificationObserver',
  'PopScope',
  'NavigatorPopHandler',
  'BackButtonListener',
  'ModalBarrier',
  'FocusableActionDetector',
};

const List<String> _noisePrefixes = ['Animated', 'Default', 'Sliver', 'Inherited', 'Raw', 'Cupertino'];
const List<String> _noiseSuffixes = ['Theme', 'Transition', 'Scope', 'Provider', 'Notifier', 'Listener', 'Builder'];

/// Whether [widget] is framework plumbing, left out of the path.
///
/// Private types (`_Something`) are framework internals in almost every case and are left out too,
/// which also drops a team's own private widgets. In a debug session where the widget inspector
/// knows the project's root (an IDE run), a private widget created in the app's own code is kept,
/// because widget creation tracking says where it was made. Give a widget that matters a `ValueKey`
/// and it is always the one chosen.
bool isFrameworkNoise(Widget widget) {
  final name = typeName(widget);
  final bare = name.contains('<') ? name.substring(0, name.indexOf('<')) : name;
  if (_interactiveTypes.contains(bare)) return false;
  if (_noise.contains(bare)) return true;
  if (bare.startsWith('_')) return !_createdLocally(widget);
  for (final p in _noisePrefixes) {
    if (bare.startsWith(p) && bare.length > p.length && _isUpper(bare.codeUnitAt(p.length))) {
      // Cupertino* widgets that are not in the interactive list are mostly plumbing as well
      // (CupertinoPageTransition, CupertinoUserInterfaceLevel); the named ones are kept above.
      return true;
    }
  }
  for (final s in _noiseSuffixes) {
    if (bare.endsWith(s) && bare.length > s.length) return !_createdLocally(widget);
  }
  return false;
}

bool _isUpper(int unit) => unit >= 65 && unit <= 90;

bool _createdLocally(Widget widget) {
  try {
    return debugIsWidgetLocalCreation(widget);
  } catch (_) {
    return false;
  }
}
