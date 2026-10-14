import 'package:flutter/widgets.dart';

import 'anchor.dart' show isFrameworkNoise, typeName;
import 'tree.dart';

/// Which screen the app is on, for `context.screen`. Fed by every [OverblastNavigatorObserver]; one
/// per process, because a report is about the screen the person is looking at, whichever navigator
/// put it there.
class FeedbackRouteTracker {
  FeedbackRouteTracker._();

  static final FeedbackRouteTracker instance = FeedbackRouteTracker._();

  Route<dynamic>? _current;

  /// The current page's route name, or, for a route pushed without one (`MaterialPageRoute(builder:)`),
  /// the type of the first widget of the app's own inside it (`CartScreen`).
  String? get currentScreen {
    final route = _current;
    if (route == null) return null;
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    if (route is ModalRoute) {
      final context = route.subtreeContext;
      if (context is Element) {
        String? found;
        walkElements(context, (e) {
          if (found != null) return false;
          if (!isFrameworkNoise(e.widget)) {
            found = typeName(e.widget);
            return false;
          }
          return true;
        });
        if (found != null) return found;
      }
    }
    return route.runtimeType.toString();
  }

  void _set(Route<dynamic>? route) {
    if (route == null || route is PageRoute) _current = route;
  }

  void _gone(Route<dynamic> route, Route<dynamic>? replacement) {
    if (identical(route, _current)) _current = replacement is PageRoute ? replacement : null;
  }

  @visibleForTesting
  void reset() => _current = null;
}

/// Add to the app's navigator so reports say which screen they came from:
/// `navigatorObservers: [OverblastFeedback.navigatorObserver]`. Dialogs and sheets do not change
/// the screen; pages do.
class OverblastNavigatorObserver extends NavigatorObserver {
  FeedbackRouteTracker get _tracker => FeedbackRouteTracker.instance;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _tracker._set(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _tracker._gone(route, previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _tracker._gone(route, previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null && identical(oldRoute, _tracker._current)) _tracker._current = null;
    _tracker._set(newRoute);
  }
}
