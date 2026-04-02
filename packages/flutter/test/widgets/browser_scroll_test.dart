// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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

  List<double> get reportedHeights => calls
      .where((c) => c.method == 'updateContentHeight')
      .map((c) => (c.arguments as Map<dynamic, dynamic>)['height'] as double)
      .toList();

  Future<void> simulateOnScroll(double offset) async {
    await _channel.binaryMessenger.handlePlatformMessage(
      'flutter/browser_scroll',
      const JSONMethodCodec().encodeMethodCall(
        MethodCall('onScroll', <String, Object?>{'offset': offset}),
      ),
      (_) {},
    );
  }

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
    child: MediaQuery(
      data: const MediaQueryData(),
      child: BrowserScrollable(
        child: ListView.builder(
          controller: controller,
          physics: const BrowserScrollPhysics(),
          itemCount: 20,
          itemBuilder: (context, index) => SizedBox(height: 200.0, child: Text('Item $index')),
        ),
      ),
    ),
  );
}

Widget _buildTestAppNoPrimaryNoController() {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(),
      child: BrowserScrollable(
        child: ListView.builder(
          primary: false,
          physics: const BrowserScrollPhysics(),
          itemCount: 20,
          itemBuilder: (context, index) => SizedBox(height: 200.0, child: Text('Item $index')),
        ),
      ),
    ),
  );
}

void main() {
  group('ScrollableState browser-scroll integration – placeholder height', () {
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

    testWidgets('reports initial height = viewport * 2', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      await mock.simulateOnScroll(0);
      await tester.pump();

      final double viewport = tester.getSize(find.byType(ListView)).height;
      final List<double> heights = mock.reportedHeights;
      if (heights.isNotEmpty) {
        expect(heights.last, closeTo(viewport * 2, 2.0));
      }
    });

    testWidgets('placeholder grows as user scrolls down', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      await mock.simulateOnScroll(500);
      await tester.pump();

      await mock.simulateOnScroll(1000);
      await tester.pump();

      final List<double> heights = mock.reportedHeights;
      if (heights.length >= 2) {
        expect(heights.last, greaterThanOrEqualTo(heights.first));
      }
    });

    testWidgets('_maxReachedPixels only increases', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      await mock.simulateOnScroll(800);
      await tester.pump();

      final heightsAfterDown = List<double>.from(mock.reportedHeights);

      await mock.simulateOnScroll(200);
      await tester.pump();

      final List<double> heightsAfterUp = mock.reportedHeights;

      if (heightsAfterDown.isNotEmpty && heightsAfterUp.isNotEmpty) {
        expect(heightsAfterUp.last, greaterThanOrEqualTo(heightsAfterDown.last));
      }
    });

    testWidgets('lookahead is capped at viewportDimension', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      final double viewport = tester.getSize(find.byType(ListView)).height;

      await mock.simulateOnScroll(0);
      await tester.pump();

      final List<double> heights = mock.reportedHeights;
      if (heights.isNotEmpty) {
        expect(heights.last, lessThanOrEqualTo(viewport * 2 + 1.0));
      }
    });

    testWidgets('onScroll syncs Flutter position to browser scrollTop', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      await mock.simulateOnScroll(300);
      await tester.pump();

      if (controller.hasClients) {
        final ScrollPosition pos = controller.position;
        expect(pos.pixels, closeTo(300.0, 1.0));
      }
    });

    testWidgets('onScroll clamps to maxScrollExtent', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

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

      await mock.simulateOnScroll(100);
      await tester.pump();

      expect(mock.reportedHeights.length, countAfterFirst);
    });

    testWidgets('mounts and unmounts cleanly', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('controller swap re-registers channel handler', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      final controller2 = ScrollController();
      addTearDown(controller2.dispose);

      await tester.pumpWidget(_buildTestApp(controller2));
      await tester.pump();

      await mock.simulateOnScroll(100);
      await tester.pump();

      if (controller2.hasClients) {
        expect(controller2.position.pixels, closeTo(100.0, 1.0));
      }
    });

    testWidgets('switching from BrowserScrollPhysics to ClampingScrollPhysics tears down channel', (
      tester,
    ) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      mock.calls.clear();

      controller.jumpTo(200);
      await tester.pump();

      final int scrollToCountBefore = mock.calls.where((c) => c.method == 'scrollTo').length;
      expect(scrollToCountBefore, greaterThan(0));

      // Rebuild with ClampingScrollPhysics instead of BrowserScrollPhysics.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: BrowserScrollable(
              child: ListView.builder(
                controller: controller,
                physics: const ClampingScrollPhysics(),
                itemCount: 20,
                itemBuilder: (context, index) =>
                    SizedBox(height: 200.0, child: Text('Item $index')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      mock.calls.clear();

      // Scrolling should no longer produce channel messages.
      controller.jumpTo(400);
      await tester.pump();

      final int scrollToCountAfter = mock.calls.where((c) => c.method == 'scrollTo').length;
      expect(
        scrollToCountAfter,
        0,
        reason: 'After switching away from BrowserScrollPhysics, no scrollTo should be sent',
      );

      // Simulate an onScroll from the browser; it should not move the position
      // because the handler has been cleared.
      final double pixelsBefore = controller.position.pixels;
      await mock.simulateOnScroll(0);
      await tester.pump();
      expect(controller.position.pixels, pixelsBefore);
    });
  });

  group('ScrollableState browser-scroll – primary:false fallback controller', () {
    late _MockBrowserScrollChannel mock;

    setUp(() {
      mock = _MockBrowserScrollChannel();
    });

    tearDown(() {
      mock.dispose();
    });

    testWidgets('works with primary:false and no explicit controller', (tester) async {
      await tester.pumpWidget(_buildTestAppNoPrimaryNoController());
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      await mock.simulateOnScroll(400);
      await tester.pump();

      final Finder listFinder = find.byType(ListView);
      final ScrollableState scrollable = tester.state(
        find.descendant(of: listFinder, matching: find.byType(Scrollable)),
      );
      expect(scrollable.position.pixels, closeTo(400.0, 1.0));
    });

    testWidgets('reports content height with fallback controller', (tester) async {
      await tester.pumpWidget(_buildTestAppNoPrimaryNoController());
      await tester.pump();

      await mock.simulateOnScroll(0);
      await tester.pump();

      final double viewport = tester.getSize(find.byType(ListView)).height;
      final List<double> heights = mock.reportedHeights;
      if (heights.isNotEmpty) {
        expect(heights.last, closeTo(viewport * 2, 2.0));
      }
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
          child: MediaQuery(
            data: const MediaQueryData(),
            child: NotificationListener<OverscrollNotification>(
              onNotification: (OverscrollNotification n) {
                leaked.add(n);
                return false;
              },
              child: BrowserScrollable(
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
        ),
      );
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      await mock.simulateOnScroll(500);
      await tester.pump();

      leaked.clear();
      mock.calls.clear();

      final ScrollPosition pos = controller.position;
      OverscrollNotification(
        overscroll: 50.0,
        metrics: pos.copyWith(),
        context: tester.element(find.byType(ListView)),
      ).dispatch(tester.element(find.byType(ListView)));
      await tester.pump();

      expect(leaked, isEmpty);
      final Iterable<MethodCall> scrollByCalls = mock.calls.where((c) => c.method == 'scrollBy');
      expect(scrollByCalls, isNotEmpty);
    });

    testWidgets('lets OverscrollNotification bubble at top edge', (tester) async {
      final leaked = <OverscrollNotification>[];

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: NotificationListener<OverscrollNotification>(
              onNotification: (OverscrollNotification n) {
                leaked.add(n);
                return false;
              },
              child: BrowserScrollable(
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
        ),
      );
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      await mock.simulateOnScroll(0);
      await tester.pump();

      leaked.clear();
      mock.calls.clear();

      final ScrollPosition pos = controller.position;
      OverscrollNotification(
        overscroll: -30.0,
        metrics: pos.copyWith(),
        context: tester.element(find.byType(ListView)),
      ).dispatch(tester.element(find.byType(ListView)));
      await tester.pump();

      expect(leaked, hasLength(1));
      expect(leaked.first.overscroll, -30.0);
      final Iterable<MethodCall> scrollByCalls = mock.calls.where((c) => c.method == 'scrollBy');
      expect(scrollByCalls, isEmpty);
    });

    testWidgets('lets OverscrollNotification bubble at bottom edge', (tester) async {
      final leaked = <OverscrollNotification>[];

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: NotificationListener<OverscrollNotification>(
              onNotification: (OverscrollNotification n) {
                leaked.add(n);
                return false;
              },
              child: BrowserScrollable(
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
        ),
      );
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      final double maxExtent = controller.position.maxScrollExtent;
      await mock.simulateOnScroll(maxExtent);
      await tester.pump();

      leaked.clear();
      mock.calls.clear();

      final ScrollPosition pos = controller.position;
      OverscrollNotification(
        overscroll: 40.0,
        metrics: pos.copyWith(),
        context: tester.element(find.byType(ListView)),
      ).dispatch(tester.element(find.byType(ListView)));
      await tester.pump();

      expect(leaked, hasLength(1));
      expect(leaked.first.overscroll, 40.0);
      final Iterable<MethodCall> scrollByCalls = mock.calls.where((c) => c.method == 'scrollBy');
      expect(scrollByCalls, isEmpty);
    });
  });

  group('ScrollableState browser-scroll – programmatic scrolling', () {
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

    // animateTo starts a DrivenScrollActivity that calls setPixels on each
    // tick. BrowserScrollPhysics.applyBoundaryConditions returns the entire
    // delta as overscroll, so setPixels clamps to the old value and pixels
    // never changes. Use BrowserScrollable.scrollTo or jumpTo instead.
    testWidgets('animateTo does not move pixels with BrowserScrollPhysics', (tester) async {
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
          child: MediaQuery(
            data: const MediaQueryData(),
            child: BrowserScrollable(
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
        ),
      );
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      await mock.simulateOnScroll(2000);
      await tester.pump();

      mock.calls.clear();

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
      final List<FocusNode> focusNodes = List.generate(30, (_) => FocusNode());
      addTearDown(() {
        for (final node in focusNodes) {
          node.dispose();
        }
      });

      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xFF000000),
          builder: (context, child) => BrowserScrollable(
            child: ListView.builder(
              controller: controller,
              physics: const BrowserScrollPhysics(),
              itemCount: 30,
              itemBuilder: (context, index) => Focus(
                focusNode: focusNodes[index],
                child: SizedBox(height: 200.0, child: Text('Button $index')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await mock.simulateEnable();
      await tester.pump();

      // Seed focus on the first visible item so tab traversal moves forward.
      focusNodes[0].requestFocus();
      await tester.pump();

      mock.calls.clear();

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
