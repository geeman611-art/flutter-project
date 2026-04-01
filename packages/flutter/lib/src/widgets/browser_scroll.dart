// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart' show experimental;

import 'binding.dart';
import 'framework.dart';
import 'notification_listener.dart';
import 'primary_scroll_controller.dart';
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
/// If no [controller] is provided, the widget automatically uses the
/// [PrimaryScrollController] from the widget tree. This matches how most
/// scrollables work in Flutter, where a [ListView] inside a [Scaffold]
/// attaches to the primary controller without any explicit setup.
///
/// Example with explicit controller:
/// ```dart
/// final ScrollController controller = ScrollController();
/// BrowserScrollable(
///   controller: controller,
///   child: ListView.builder(
///     controller: controller,
///     physics: const BrowserScrollPhysics(),
///     itemCount: 100,
///     itemBuilder: (context, index) => ListTile(title: Text('Item $index')),
///   ),
/// )
/// ```
///
/// Example using PrimaryScrollController (simpler):
/// ```dart
/// BrowserScrollable(
///   child: ListView.builder(
///     physics: const BrowserScrollPhysics(),
///     itemCount: 100,
///     itemBuilder: (context, index) => ListTile(title: Text('Item $index')),
///   ),
/// )
/// ```
@experimental
class BrowserScrollable extends StatefulWidget {
  /// Creates a widget that enables browser-driven scrolling for its child.
  const BrowserScrollable({super.key, this.controller, required this.child});

  /// The scroll controller for the outermost scrollable.
  ///
  /// If null, the [PrimaryScrollController] from the widget tree is used.
  /// This controller is used to sync the browser's scroll position with
  /// Flutter and to read content extent for reporting to the engine.
  final ScrollController? controller;

  /// The child widget, typically a scrollable like [ListView].
  final Widget child;

  @override
  State<BrowserScrollable> createState() => _BrowserScrollableState();
}

class _BrowserScrollableState extends State<BrowserScrollable> {
  static const MethodChannel _channel = MethodChannel('flutter/browser_scroll', JSONMethodCodec());
  static final Set<TargetPlatform> _allPlatforms = TargetPlatform.values.toSet();

  bool _enabled = false;

  // The highest scroll position the user has reached. Used to size the
  // placeholder so it reflects revealed content rather than the lazy
  // layout overestimate.
  double _maxReachedPixels = 0;

  // Set to true once the user has scrolled to the very bottom of the
  // content. After that, the lookahead stays at zero because we know
  // the true content size and don't need extra room to scroll into.
  bool _reachedBottom = false;

  ScrollController? _fallbackController;
  ScrollController? _attachedController;

  ScrollController get _effectiveController {
    if (widget.controller != null) {
      return widget.controller!;
    }
    return _fallbackController ??= PrimaryScrollController.of(context);
  }

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handleEngineMessage);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ScrollController controller = _effectiveController;
    if (_attachedController != controller) {
      _attachedController?.removeListener(_onScrollPositionChanged);
      controller.addListener(_onScrollPositionChanged);
      _attachedController = controller;
    }

    if (kIsWeb && !_enabled) {
      _enableBrowserScrolling();
    }
  }

  @override
  void didUpdateWidget(BrowserScrollable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _fallbackController = null;
      final ScrollController controller = _effectiveController;
      _attachedController?.removeListener(_onScrollPositionChanged);
      controller.addListener(_onScrollPositionChanged);
      _attachedController = controller;
    }
  }

  @override
  void dispose() {
    _attachedController?.removeListener(_onScrollPositionChanged);
    _attachedController = null;
    _fallbackController = null;
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

  void _syncScrollFromBrowser(double scrollTop) {
    if (!_effectiveController.hasClients) {
      return;
    }

    final ScrollPosition position = _effectiveController.position;
    final double clampedOffset = clampDouble(
      scrollTop,
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
  double _lastReportedHeight = 0;

  void _onScrollPositionChanged() {
    if (!_effectiveController.hasClients || !_enabled) {
      return;
    }

    final ScrollPosition position = _effectiveController.position;

    // When the browser drives scrolling, it sends onScroll which calls
    // forcePixels. We must not echo that back as a scrollTo or we'd create
    // a feedback loop. Only sync the DOM scrollTop when Flutter is driving
    // the scroll, e.g. programmatic animateTo.
    if (!_isBrowserDriving) {
      _channel.invokeMethod<void>('scrollTo', <String, Object?>{'offset': position.pixels});
    }

    _reportContentExtent();
  }

  void _reportContentExtent() {
    if (!_effectiveController.hasClients || !_enabled) {
      return;
    }

    final ScrollPosition position = _effectiveController.position;

    if (position.pixels > _maxReachedPixels) {
      _maxReachedPixels = position.pixels;
    }

    if (position.pixels >= position.maxScrollExtent - 1.0) {
      _reachedBottom = true;
    }

    // The placeholder height is based on the furthest point the user has
    // scrolled to, plus a lookahead buffer so there's always room to
    // scroll forward without hitting the placeholder bottom prematurely.
    //
    // Once the user has reached the actual content bottom, the lookahead
    // stays at zero permanently. We know the true content size at that
    // point, so re-adding lookahead when scrolling back up would create
    // a dead zone where the scrollbar can scroll past the content.
    final double lookahead;
    if (_reachedBottom) {
      lookahead = 0;
    } else {
      final double remainingContent = position.maxScrollExtent - _maxReachedPixels;
      lookahead = clampDouble(remainingContent, 0, position.viewportDimension);
    }
    final double totalHeight = _maxReachedPixels + position.viewportDimension + lookahead;

    if ((totalHeight - _lastReportedHeight).abs() < 1.0) {
      return;
    }

    _lastReportedHeight = totalHeight;
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
      child: PrimaryScrollController(
        controller: _effectiveController,
        automaticallyInheritForPlatforms: _allPlatforms,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: widget.child,
        ),
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
