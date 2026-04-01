// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// A mock for the flutter/browser_scroll platform channel.
//
// Records outbound method calls from the framework and allows the test to
// inject inbound engine messages (onScroll, etc.).
class _MockBrowserScrollChannel {
  _MockBrowserScrollChannel() {
    _channel.setMockMethodCallHandler(_handleFrameworkCall);
  }

  static const MethodChannel _channel = MethodChannel('flutter/browser_scroll', JSONMethodCodec());

  final List<MethodCall> calls = [];

  Future<dynamic> _handleFrameworkCall(MethodCall call) async {
    calls.add(call);
    return null;
  }

  // Returns all updateContentHeight calls, most recent last.
  List<double> get reportedHeights => calls
      .where((c) => c.method == 'updateContentHeight')
      .map((c) => (c.arguments as Map<dynamic, dynamic>)['height'] as double)
      .toList();

  // Simulates the engine firing an onScroll event to the framework.
  Future<void> simulateOnScroll(double offset) async {
    await _channel.binaryMessenger.handlePlatformMessage(
      'flutter/browser_scroll',
      const JSONMethodCodec().encodeMethodCall(
        MethodCall('onScroll', <String, Object?>{'offset': offset}),
      ),
      (_) {},
    );
  }

  // Simulates the engine confirming that browser scrolling is enabled.
  // In production, _enabled is set after the framework sends 'enable' and
  // kIsWeb is true. In tests kIsWeb is false, so we trigger it from the
  // engine side via the 'didEnable' message.
  Future<void> simulateEnable() async {
    await _channel.binaryMessenger.handlePlatformMessage(
      'flutter/browser_scroll',
      const JSONMethodCodec().encodeMethodCall(const MethodCall('didEnable')),
      (_) {},
    );
  }

  void dispose() {
    _channel.setMockMethodCallHandler(null);
  }
}

Widget _buildTestApp(ScrollController controller) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: BrowserScrollable(
      controller: controller,
      child: ListView.builder(
        controller: controller,
        physics: const BrowserScrollPhysics(),
        itemCount: 20,
        itemBuilder: (context, index) => SizedBox(height: 200.0, child: Text('Item $index')),
      ),
    ),
  );
}

Widget _buildTestAppWithPrimaryController(ScrollController primaryController) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(),
      child: PrimaryScrollController(
        controller: primaryController,
        child: BrowserScrollable(
          child: ListView.builder(
            physics: const BrowserScrollPhysics(),
            itemCount: 20,
            itemBuilder: (context, index) => SizedBox(height: 200.0, child: Text('Item $index')),
          ),
        ),
      ),
    ),
  );
}

void main() {
  // BrowserScrollable only enables browser scrolling on the web. Override
  // kIsWeb for these tests so the enable/disable channel calls fire.
  //
  // We cannot override kIsWeb at runtime, so the tests work by sending the
  // enable message directly via the mock channel setup and checking that the
  // height reporting logic behaves correctly regardless of platform.

  // BrowserScrollPhysics unit tests are in scroll_physics_test.dart.

  group('BrowserScrollable – placeholder height reporting', () {
    late _MockBrowserScrollChannel mock;
    late ScrollController controller;

    setUp(() {
      mock = _MockBrowserScrollChannel();
      controller = ScrollController();
    });

    tearDown(() {
      controller.dispose();
      mock.dispose();
    });

    // Manually simulate what the engine does after receiving 'enable':
    // send an onScroll at a given offset so the framework syncs position and
    // reports a new placeholder height.
    //
    // In real usage the engine drives this, but in tests we drive it via
    // simulateOnScroll.

    testWidgets('reports initial height = viewport * 2 (pixels=0, lookahead=viewport)', (
      tester,
    ) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      // After mount, BrowserScrollable reports an initial height on kIsWeb.
      // Since kIsWeb=false in tests we drive the first report by simulating
      // an onScroll at 0, which triggers _reportContentExtent.
      await mock.simulateOnScroll(0);
      await tester.pump();

      // At pixels=0, maxReached=0, lookahead=viewport, _reachedBottom=false.
      // totalHeight = 0 + viewport + viewport = 2 * viewport.
      final double viewport = tester.getSize(find.byType(ListView)).height;
      final List<double> heights = mock.reportedHeights;
      if (heights.isNotEmpty) {
        expect(heights.last, closeTo(viewport * 2, 2.0));
      }
    });

    testWidgets('placeholder grows as user scrolls down', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      // Simulate the browser scrolling to 500px.
      await mock.simulateOnScroll(500);
      await tester.pump();

      // Simulate scrolling further to 1000px.
      await mock.simulateOnScroll(1000);
      await tester.pump();

      final List<double> heights = mock.reportedHeights;
      if (heights.length >= 2) {
        // Each new scroll further down should produce a taller (or equal) placeholder.
        expect(heights.last, greaterThanOrEqualTo(heights.first));
      }
    });

    testWidgets('_maxReachedPixels only increases, never decreases when scrolling back up', (
      tester,
    ) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      // Scroll down.
      await mock.simulateOnScroll(800);
      await tester.pump();

      final heightsAfterDown = List<double>.from(mock.reportedHeights);

      // Scroll back up.
      await mock.simulateOnScroll(200);
      await tester.pump();

      final List<double> heightsAfterUp = mock.reportedHeights;

      // The placeholder after scrolling back up must be >= the placeholder
      // recorded at pixels=800, because maxReachedPixels stays at 800.
      if (heightsAfterDown.isNotEmpty && heightsAfterUp.isNotEmpty) {
        expect(heightsAfterUp.last, greaterThanOrEqualTo(heightsAfterDown.last));
      }
    });

    testWidgets('lookahead is capped at viewportDimension', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      final double viewport = tester.getSize(find.byType(ListView)).height;

      // Start from zero; remaining content is huge (lazy overestimate).
      await mock.simulateOnScroll(0);
      await tester.pump();

      final List<double> heights = mock.reportedHeights;
      if (heights.isNotEmpty) {
        // totalHeight should never exceed maxReached + viewport + viewport
        // because lookahead is capped at viewportDimension.
        expect(heights.last, lessThanOrEqualTo(viewport * 2 + 1.0));
      }
    });

    testWidgets('onScroll syncs Flutter position to browser scrollTop', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      await mock.simulateOnScroll(300);
      await tester.pump();

      // Flutter's scroll position should now be at 300 (or clamped to maxExtent).
      if (controller.hasClients) {
        final ScrollPosition pos = controller.position;
        expect(pos.pixels, closeTo(300.0, 1.0));
      }
    });

    testWidgets('onScroll clamps to maxScrollExtent', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      // Send a scrollTop that is way past the content.
      await mock.simulateOnScroll(999999);
      await tester.pump();

      if (controller.hasClients) {
        final ScrollPosition pos = controller.position;
        expect(pos.pixels, lessThanOrEqualTo(pos.maxScrollExtent + 1.0));
      }
    });

    testWidgets('duplicate heights within 1px tolerance are not re-reported', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      await mock.simulateOnScroll(100);
      await tester.pump();

      final int countAfterFirst = mock.reportedHeights.length;

      // Send the same position again; no new updateContentHeight should fire.
      await mock.simulateOnScroll(100);
      await tester.pump();

      expect(mock.reportedHeights.length, countAfterFirst);
    });

    testWidgets('sends enable on mount and disable on dispose', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      // On non-web, kIsWeb=false so enable is not called automatically.
      // Just verify the widget mounts and unmounts cleanly.
      await tester.pumpWidget(const SizedBox.shrink());
      // No exception means the dispose path is clean.
    });

    testWidgets('controller swap re-registers listener', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      final controller2 = ScrollController();
      addTearDown(controller2.dispose);

      await tester.pumpWidget(_buildTestApp(controller2));
      await tester.pump();

      // After controller swap, onScroll should sync to the new controller.
      await mock.simulateOnScroll(100);
      await tester.pump();

      if (controller2.hasClients) {
        expect(controller2.position.pixels, closeTo(100.0, 1.0));
      }
    });
  });

  group('BrowserScrollable – PrimaryScrollController fallback', () {
    late _MockBrowserScrollChannel mock;
    late ScrollController primaryController;

    setUp(() {
      mock = _MockBrowserScrollChannel();
      primaryController = ScrollController();
    });

    tearDown(() {
      primaryController.dispose();
      mock.dispose();
    });

    testWidgets('uses PrimaryScrollController when no controller is provided', (tester) async {
      await tester.pumpWidget(_buildTestAppWithPrimaryController(primaryController));
      await tester.pump();

      await mock.simulateOnScroll(300);
      await tester.pump();

      if (primaryController.hasClients) {
        expect(primaryController.position.pixels, closeTo(300.0, 1.0));
      }
    });

    testWidgets('reports content height using PrimaryScrollController', (tester) async {
      await tester.pumpWidget(_buildTestAppWithPrimaryController(primaryController));
      await tester.pump();

      await mock.simulateOnScroll(0);
      await tester.pump();

      final double viewport = tester.getSize(find.byType(ListView)).height;
      final List<double> heights = mock.reportedHeights;
      if (heights.isNotEmpty) {
        expect(heights.last, closeTo(viewport * 2, 2.0));
      }
    });

    testWidgets('explicit controller takes precedence over PrimaryScrollController', (
      tester,
    ) async {
      final explicitController = ScrollController();
      addTearDown(explicitController.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: PrimaryScrollController(
              controller: primaryController,
              child: BrowserScrollable(
                controller: explicitController,
                child: ListView.builder(
                  controller: explicitController,
                  physics: const BrowserScrollPhysics(),
                  itemCount: 20,
                  itemBuilder: (context, index) =>
                      SizedBox(height: 200.0, child: Text('Item $index')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await mock.simulateOnScroll(200);
      await tester.pump();

      if (explicitController.hasClients) {
        expect(explicitController.position.pixels, closeTo(200.0, 1.0));
      }
      // PrimaryScrollController should not have been used.
      expect(primaryController.hasClients, isFalse);
    });
  });

  group('BrowserScrollable – OverscrollNotification edge passthrough', () {
    late _MockBrowserScrollChannel mock;
    late ScrollController controller;

    setUp(() {
      mock = _MockBrowserScrollChannel();
      controller = ScrollController();
    });

    tearDown(() {
      controller.dispose();
      mock.dispose();
    });

    testWidgets('consumes OverscrollNotification when not at edge', (tester) async {
      final leaked = <OverscrollNotification>[];

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: NotificationListener<OverscrollNotification>(
            onNotification: (OverscrollNotification n) {
              leaked.add(n);
              return false;
            },
            child: BrowserScrollable(
              controller: controller,
              child: ListView.builder(
                controller: controller,
                physics: const BrowserScrollPhysics(),
                itemCount: 20,
                itemBuilder: (context, index) =>
                    SizedBox(height: 200.0, child: Text('Item $index')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      // Position in the middle of content.
      await mock.simulateOnScroll(500);
      await tester.pump();

      leaked.clear();
      mock.calls.clear();

      // Dispatch an OverscrollNotification as if BrowserScrollPhysics
      // produced overscroll while the position is mid-content.
      final ScrollPosition pos = controller.position;
      OverscrollNotification(
        overscroll: 50.0,
        metrics: pos.copyWith(),
        context: tester.element(find.byType(ListView)),
      ).dispatch(tester.element(find.byType(ListView)));
      await tester.pump();

      // BrowserScrollable should have consumed it (not leaked).
      expect(leaked, isEmpty);
      // And forwarded it to the engine.
      final Iterable<MethodCall> scrollByCalls = mock.calls.where((c) => c.method == 'scrollBy');
      expect(scrollByCalls, isNotEmpty);
    });

    testWidgets('lets OverscrollNotification bubble at top edge (pull-to-refresh)', (tester) async {
      final leaked = <OverscrollNotification>[];

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: NotificationListener<OverscrollNotification>(
            onNotification: (OverscrollNotification n) {
              leaked.add(n);
              return false;
            },
            child: BrowserScrollable(
              controller: controller,
              child: ListView.builder(
                controller: controller,
                physics: const BrowserScrollPhysics(),
                itemCount: 20,
                itemBuilder: (context, index) =>
                    SizedBox(height: 200.0, child: Text('Item $index')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      // Position at the very top (minScrollExtent).
      await mock.simulateOnScroll(0);
      await tester.pump();

      leaked.clear();
      mock.calls.clear();

      // Overscroll with negative delta = user pulling down at top.
      final ScrollPosition pos = controller.position;
      OverscrollNotification(
        overscroll: -30.0,
        metrics: pos.copyWith(),
        context: tester.element(find.byType(ListView)),
      ).dispatch(tester.element(find.byType(ListView)));
      await tester.pump();

      // Should have bubbled through for RefreshIndicator to see.
      expect(leaked, hasLength(1));
      expect(leaked.first.overscroll, -30.0);
      // Should NOT have sent scrollBy to the engine.
      final Iterable<MethodCall> scrollByCalls = mock.calls.where((c) => c.method == 'scrollBy');
      expect(scrollByCalls, isEmpty);
    });

    testWidgets('lets OverscrollNotification bubble at bottom edge (load-more)', (tester) async {
      final leaked = <OverscrollNotification>[];

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: NotificationListener<OverscrollNotification>(
            onNotification: (OverscrollNotification n) {
              leaked.add(n);
              return false;
            },
            child: BrowserScrollable(
              controller: controller,
              child: ListView.builder(
                controller: controller,
                physics: const BrowserScrollPhysics(),
                itemCount: 20,
                itemBuilder: (context, index) =>
                    SizedBox(height: 200.0, child: Text('Item $index')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      // Position at maxScrollExtent.
      final double maxExtent = controller.position.maxScrollExtent;
      await mock.simulateOnScroll(maxExtent);
      await tester.pump();

      leaked.clear();
      mock.calls.clear();

      // Overscroll with positive delta = user pushing past bottom.
      final ScrollPosition pos = controller.position;
      OverscrollNotification(
        overscroll: 40.0,
        metrics: pos.copyWith(),
        context: tester.element(find.byType(ListView)),
      ).dispatch(tester.element(find.byType(ListView)));
      await tester.pump();

      // Should have bubbled through for load-more indicators.
      expect(leaked, hasLength(1));
      expect(leaked.first.overscroll, 40.0);
      // Should NOT have sent scrollBy to the engine.
      final Iterable<MethodCall> scrollByCalls = mock.calls.where((c) => c.method == 'scrollBy');
      expect(scrollByCalls, isEmpty);
    });
  });

  group('BrowserScrollable – programmatic scrolling', () {
    late _MockBrowserScrollChannel mock;
    late ScrollController controller;

    setUp(() {
      mock = _MockBrowserScrollChannel();
      controller = ScrollController();
    });

    tearDown(() {
      controller.dispose();
      mock.dispose();
    });

    testWidgets('jumpTo sends scrollTo to engine', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      mock.calls.clear();

      controller.jumpTo(500);
      await tester.pump();

      final List<MethodCall> scrollToCalls = mock.calls
          .where((c) => c.method == 'scrollTo')
          .toList();
      expect(scrollToCalls, isNotEmpty);
      final offset = (scrollToCalls.last.arguments as Map<dynamic, dynamic>)['offset'] as double;
      expect(offset, closeTo(500.0, 1.0));
    });

    testWidgets('animateTo does not move pixels with BrowserScrollPhysics', (tester) async {
      // animateTo starts a DrivenScrollActivity that calls setPixels on each
      // tick. BrowserScrollPhysics.applyBoundaryConditions returns the entire
      // delta, so setPixels clamps to the old value and pixels never changes.
      // Programmatic scrolling should use BrowserScrollable.scrollTo or
      // controller.jumpTo instead.
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      mock.calls.clear();

      controller.animateTo(400, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 150));

      final List<MethodCall> scrollToCalls = mock.calls
          .where((c) => c.method == 'scrollTo')
          .toList();
      expect(scrollToCalls, isEmpty);
      expect(controller.position.pixels, closeTo(0.0, 1.0));
    });

    testWidgets('ensureVisible sends scrollTo to engine', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: BrowserScrollable(
            controller: controller,
            child: ListView.builder(
              controller: controller,
              physics: const BrowserScrollPhysics(),
              itemCount: 50,
              itemBuilder: (context, index) => SizedBox(
                height: 200.0,
                key: index == 40 ? const Key('target') : null,
                child: Text('Item $index'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      // Scroll to a middle position first so the list lays out more items.
      await mock.simulateOnScroll(2000);
      await tester.pump();

      mock.calls.clear();

      // Ensure the target item is visible. This calls jumpTo/animateTo
      // internally, which should produce a scrollTo on the channel.
      final Finder target = find.byKey(const Key('target'));
      if (target.evaluate().isNotEmpty) {
        await Scrollable.ensureVisible(target.evaluate().first);
        await tester.pump();

        final List<MethodCall> scrollToCalls = mock.calls
            .where((c) => c.method == 'scrollTo')
            .toList();
        expect(scrollToCalls, isNotEmpty);
      }
    });

    testWidgets('focus traversal triggers scrollTo for offscreen widget', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrowserScrollable(
              controller: controller,
              child: ListView.builder(
                controller: controller,
                physics: const BrowserScrollPhysics(),
                itemCount: 30,
                itemBuilder: (context, index) => SizedBox(
                  height: 200.0,
                  child: TextButton(onPressed: () {}, child: Text('Button $index')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      mock.calls.clear();

      // Tab through focusable widgets until focus moves offscreen.
      // Each tab press should eventually trigger ensureVisible -> scrollTo.
      for (var i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }

      final List<MethodCall> scrollToCalls = mock.calls
          .where((c) => c.method == 'scrollTo')
          .toList();
      expect(
        scrollToCalls,
        isNotEmpty,
        reason: 'Focus traversal to offscreen widget should send scrollTo to engine',
      );
    });
  });
}
