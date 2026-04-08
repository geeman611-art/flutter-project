// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/services.dart';
import 'package:meta/meta.dart' show experimental;

import 'framework.dart';
import 'notification_listener.dart';
import 'scroll_configuration.dart';
import 'scroll_metrics.dart';
import 'scroll_notification.dart';
import 'scroll_physics.dart';

/// The platform channel used to communicate with the browser's native
/// scroll system. Shared by [ScrollableState] for position syncing and
/// by [BrowserScrollable] for touch overscroll forwarding.
const MethodChannel browserScrollChannel = MethodChannel(
  'flutter/browser_scroll',
  JSONMethodCodec(),
);

/// A [ScrollPhysics] that accepts user scroll gestures but converts all
/// movement into overscroll, designed for use when the browser drives the
/// outermost scroll.
///
/// By accepting gestures, the outer scrollable participates in gesture
/// disambiguation. On touch devices this is critical: if no scrollable
/// accepted the vertical drag, the gesture would be lost. Once accepted,
/// all deltas are returned as overscroll via [applyBoundaryConditions],
/// which the framework catches and forwards to the browser via the
/// `scrollBy` platform channel.
///
/// For desktop wheel events, the engine handles scroll chaining by
/// selectively calling `preventDefault()` based on whether a nested
/// scrollable consumed the event.
///
/// When a [Scrollable] detects [BrowserScrollPhysics] in its physics chain,
/// it automatically sets up the `flutter/browser_scroll` platform channel
/// to sync positions with the browser. This means browser-driven scrolling
/// works regardless of how the scrollable obtains its controller: user-
/// provided, inherited from [PrimaryScrollController], or the internal
/// fallback created by [ScrollableState].
@experimental
class BrowserScrollPhysics extends ScrollPhysics {
  /// Creates scroll physics that delegates scrolling to the browser.
  const BrowserScrollPhysics({super.parent});

  @override
  BrowserScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return BrowserScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  bool get allowImplicitScrolling => false;

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    return offset;
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    return value - position.pixels;
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    return null;
  }
}

/// A wrapper widget that enables browser-driven scrolling, forwards
/// touch-driven overscroll to the browser, and disables Flutter scrollbars.
///
/// Place this above the outermost scrollable. It sets
/// [ScrollBehavior.enableBrowserScrolling] to true, which causes
/// [ScrollableState] to set up the browser-scroll channel and automatically
/// apply [BrowserScrollPhysics]. This widget adds two things on top:
///
/// 1. Catches [OverscrollNotification] from touch drag gestures and forwards
///    them to the browser via `scrollBy`, except at the edges where
///    [RefreshIndicator] or load-more indicators need the notification.
/// 2. Disables Flutter-drawn scrollbars since the browser provides its own.
///
/// Example:
/// ```dart
/// BrowserScrollable(
///   child: ListView.builder(
///     itemCount: 100,
///     itemBuilder: (context, index) => ListTile(title: Text('Item $index')),
///   ),
/// )
/// ```
@experimental
class BrowserScrollable extends StatelessWidget {
  /// Creates a widget that enables browser-driven scrolling for its child.
  const BrowserScrollable({super.key, required this.child});

  /// The child widget, typically a scrollable like [ListView].
  final Widget child;

  /// Scrolls to the given offset using the browser's native scroll mechanism.
  ///
  /// Unlike [ScrollController.animateTo], this delegates entirely to the
  /// browser, avoiding issues with lazy layout causing [maxScrollExtent] to
  /// change mid-animation. The browser clamps the scroll to the actual content
  /// height automatically.
  ///
  /// Set [smooth] to `false` for an instant jump with no animation. Defaults
  /// to `true` for smooth scrolling.
  ///
  /// Note: [ScrollController.animateTo] does not work with
  /// [BrowserScrollPhysics] because [BrowserScrollPhysics.applyBoundaryConditions]
  /// returns the entire delta as overscroll, so [ScrollPosition.pixels] never
  /// moves. Use this method instead.
  static Future<void> scrollTo(double offset, {bool smooth = true}) async {
    await browserScrollChannel.invokeMethod<void>(
      smooth ? 'smoothScrollTo' : 'scrollTo',
      <String, Object?>{'offset': offset},
    );
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<OverscrollNotification>(
      onNotification: _handleOverscrollNotification,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(
          context,
        ).copyWith(scrollbars: false, enableBrowserScrolling: true),
        child: child,
      ),
    );
  }

  static bool _handleOverscrollNotification(OverscrollNotification notification) {
    final double delta = notification.overscroll;
    final ScrollMetrics metrics = notification.metrics;

    if (delta < 0 && metrics.pixels <= metrics.minScrollExtent) {
      return false;
    }
    if (delta > 0 && metrics.pixels >= metrics.maxScrollExtent) {
      return false;
    }

    if (delta.abs() > 0.5) {
      browserScrollChannel.invokeMethod<void>('scrollBy', <String, Object?>{'delta': delta});
    }
    return true;
  }
}
