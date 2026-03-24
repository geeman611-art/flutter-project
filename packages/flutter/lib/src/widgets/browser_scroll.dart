// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'binding.dart';
import 'framework.dart';
import 'notification_listener.dart';
import 'scroll_configuration.dart';
import 'scroll_controller.dart';
import 'scroll_metrics.dart';
import 'scroll_notification.dart';
import 'scroll_physics.dart';
import 'scroll_position.dart';

/// A [ScrollPhysics] that accepts user scroll gestures but converts all
/// movement into overscroll, designed for use when the browser drives the
/// outermost scroll.
///
/// By accepting gestures, the outer scrollable participates in gesture
/// disambiguation. On touch devices this is critical: if no scrollable
/// accepted the vertical drag, the gesture would be lost. Once accepted,
/// all deltas are returned as overscroll via [applyBoundaryConditions],
/// which [BrowserScrollable] catches and forwards to the browser via the
/// `scrollBy` platform channel.
///
/// For desktop wheel events, the engine handles scroll chaining by
/// selectively calling `preventDefault()` based on whether a nested
/// scrollable consumed the event.
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

/// Manages the communication between a Flutter [ScrollController] and the
/// browser's native scroll system via the `flutter/browser_scroll` platform
/// channel.
///
/// Wrap the outermost scrollable with this widget to enable browser-driven
/// scrolling. The widget:
///
/// 1. Enables browser scrolling mode in the engine on mount
/// 2. Listens for browser scroll position updates and syncs them to the
///    [ScrollController]
/// 3. Reports content extent changes back to the engine so the browser
///    knows how much content is scrollable
/// 4. Disables browser scrolling on unmount
///
/// Example:
/// ```dart
/// BrowserScrollable(
///   controller: _scrollController,
///   child: ListView.builder(
///     controller: _scrollController,
///     physics: const BrowserScrollPhysics(),
///     itemCount: 100,
///     itemBuilder: (context, index) => ListTile(title: Text('Item $index')),
///   ),
/// )
/// ```
class BrowserScrollable extends StatefulWidget {
  /// Creates a widget that enables browser-driven scrolling for its child.
  const BrowserScrollable({super.key, required this.controller, required this.child});

  /// The scroll controller for the outermost scrollable. This controller
  /// is used to sync the browser's scroll position with Flutter and to
  /// read content extent for reporting to the engine.
  final ScrollController controller;

  /// The child widget, typically a scrollable like [ListView].
  final Widget child;

  @override
  State<BrowserScrollable> createState() => _BrowserScrollableState();
}

class _BrowserScrollableState extends State<BrowserScrollable> {
  static const MethodChannel _channel = MethodChannel('flutter/browser_scroll', JSONMethodCodec());

  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handleEngineMessage);
    widget.controller.addListener(_onScrollPositionChanged);

    if (kIsWeb) {
      _enableBrowserScrolling();
    }
  }

  @override
  void didUpdateWidget(BrowserScrollable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScrollPositionChanged);
      widget.controller.addListener(_onScrollPositionChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScrollPositionChanged);
    if (_enabled) {
      _disableBrowserScrolling();
    }
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _enableBrowserScrolling() async {
    await _channel.invokeMethod<void>('enable');
    _enabled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportContentExtent();
    });
  }

  Future<void> _disableBrowserScrolling() async {
    _enabled = false;
    await _channel.invokeMethod<void>('disable');
  }

  Future<dynamic> _handleEngineMessage(MethodCall call) async {
    if (call.method == 'onScroll') {
      final args = call.arguments as Map<dynamic, dynamic>;
      final double offset = (args['offset'] as num).toDouble();
      _syncScrollFromBrowser(offset);
    }
  }

  void _syncScrollFromBrowser(double offset) {
    if (!widget.controller.hasClients) {
      return;
    }

    final ScrollPosition position = widget.controller.position;
    final double clampedOffset = clampDouble(
      offset,
      position.minScrollExtent,
      position.maxScrollExtent,
    );

    if ((position.pixels - clampedOffset).abs() > 0.5) {
      _isBrowserDriving = true;
      // Use forcePixels instead of jumpTo to avoid cancelling any active
      // drag activity. jumpTo calls goIdle+goBallistic which would kill
      // the drag gesture and stop further scroll updates.
      // ignore: invalid_use_of_protected_member
      position.forcePixels(clampedOffset);
      _isBrowserDriving = false;
    }
  }

  bool _isBrowserDriving = false;

  void _onScrollPositionChanged() {
    if (!widget.controller.hasClients || !_enabled) {
      return;
    }

    final ScrollPosition position = widget.controller.position;

    // When the browser drives scrolling, it sends onScroll which calls
    // jumpTo. We must not echo that back as a scrollTo or we'd create a
    // feedback loop. Only sync the DOM scrollTop when Flutter is driving
    // the scroll, e.g. programmatic animateTo.
    if (!_isBrowserDriving) {
      final double clamped = clampDouble(
        position.pixels,
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      _channel.invokeMethod<void>('scrollTo', <String, Object?>{'offset': clamped});
    }

    _reportContentExtent();
  }

  void _reportContentExtent() {
    if (!widget.controller.hasClients || !_enabled) {
      return;
    }

    final ScrollPosition position = widget.controller.position;

    // During programmatic scrolls, pixels can temporarily exceed
    // maxScrollExtent because the ListView recalculates lazily. Use
    // whichever is larger so the DOM placeholder is always tall enough.
    final double scrollableRange = position.maxScrollExtent > position.pixels
        ? position.maxScrollExtent
        : position.pixels;
    final double totalHeight = position.viewportDimension + scrollableRange;

    _channel.invokeMethod<void>('updateContentHeight', <String, Object?>{'height': totalHeight});
  }

  /// Scrolls to the given offset using the browser's native smooth scrolling.
  ///
  /// Unlike [ScrollController.animateTo], this delegates the animation
  /// entirely to the browser, avoiding issues with lazy layout causing
  /// [maxScrollExtent] to change mid-animation. The browser clamps the
  /// scroll to the actual content height automatically.
  Future<void> scrollTo(double offset, {bool smooth = true}) async {
    await _channel.invokeMethod<void>(smooth ? 'smoothScrollTo' : 'scrollTo', <String, Object?>{
      'offset': offset,
    });
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: widget.child,
      ),
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (!_enabled) {
      return false;
    }

    if (notification is OverscrollNotification) {
      final double delta = notification.overscroll;
      if (delta.abs() > 0.5) {
        _channel.invokeMethod<void>('scrollBy', <String, Object?>{'delta': delta});
      }
      return true;
    }

    return false;
  }
}
