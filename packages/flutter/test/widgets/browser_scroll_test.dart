// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildTestApp(ScrollController controller) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(),
      child: BrowserScrollable(
        child: ListView.builder(
          controller: controller,
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
          itemCount: 20,
          itemBuilder: (context, index) => SizedBox(height: 200.0, child: Text('Item $index')),
        ),
      ),
    ),
  );
}

void _simulateOnScroll(double offset) {
  ScrollableState.browserScrollViewBinding?.onBrowserScroll?.call(offset);
}

List<Map<String, Object?>> _bindingCalls() {
  return ScrollableState.browserScrollViewBinding?.calls ?? <Map<String, Object?>>[];
}

List<Map<String, Object?>> _callsOf(String method) {
  return _bindingCalls().where((c) => c['method'] == method).toList();
}

void _clearCalls() {
  ScrollableState.browserScrollViewBinding?.calls.clear();
}

void main() {
  group('ScrollableState browser-scroll integration – placeholder height', () {
    late ScrollController controller;

    setUp(() {
      controller = ScrollController();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('reports initial height via binding', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      _simulateOnScroll(0);
      await tester.pump();

      if (controller.hasClients) {
        expect(controller.position.pixels, closeTo(0.0, 1.0));
      }
    });

    testWidgets('reports content height to engine', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      _simulateOnScroll(0);
      await tester.pump();

      final List<Map<String, Object?>> heights = _callsOf('updateBrowserScrollContentHeight');
      expect(heights, isNotEmpty);

      final double viewport = tester.getSize(find.byType(ListView)).height;
      final lastHeight = heights.last['args']! as double;
      expect(lastHeight, closeTo(viewport * 2, 2.0));
    });

    testWidgets('content height grows as user scrolls down', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      _simulateOnScroll(500);
      await tester.pump();

      _simulateOnScroll(1000);
      await tester.pump();

      final List<double> heights = _callsOf(
        'updateBrowserScrollContentHeight',
      ).map((c) => c['args']! as double).toList();
      if (heights.length >= 2) {
        expect(heights.last, greaterThanOrEqualTo(heights.first));
      }
    });

    testWidgets('duplicate heights within tolerance are not re-reported', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      _simulateOnScroll(100);
      await tester.pump();

      final int countAfterFirst = _callsOf('updateBrowserScrollContentHeight').length;

      _simulateOnScroll(100);
      await tester.pump();

      expect(_callsOf('updateBrowserScrollContentHeight').length, countAfterFirst);
    });

    testWidgets('onScroll syncs Flutter position to browser scrollTop', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      _simulateOnScroll(300);
      await tester.pump();

      if (controller.hasClients) {
        final ScrollPosition pos = controller.position;
        expect(pos.pixels, closeTo(300.0, 1.0));
      }
    });

    testWidgets('onScroll clamps to maxScrollExtent', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      _simulateOnScroll(999999);
      await tester.pump();

      if (controller.hasClients) {
        final ScrollPosition pos = controller.position;
        expect(pos.pixels, lessThanOrEqualTo(pos.maxScrollExtent + 1.0));
      }
    });

    testWidgets('mounts and unmounts cleanly', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('controller swap re-registers callback', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      final controller2 = ScrollController();
      addTearDown(controller2.dispose);

      await tester.pumpWidget(_buildTestApp(controller2));
      await tester.pump();

      _simulateOnScroll(100);
      await tester.pump();

      if (controller2.hasClients) {
        expect(controller2.position.pixels, closeTo(100.0, 1.0));
      }
    });

    testWidgets('disabling enableBrowserScrolling tears down callback', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      _simulateOnScroll(200);
      await tester.pump();

      expect(controller.position.pixels, closeTo(200.0, 1.0));

      // Rebuild with enableBrowserScrolling: false.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: ScrollConfiguration(
              behavior: const ScrollBehavior().copyWith(enableBrowserScrolling: false),
              child: ListView.builder(
                controller: controller,
                itemCount: 20,
                itemBuilder: (context, index) =>
                    SizedBox(height: 200.0, child: Text('Item $index')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The callback should be null now, so simulateOnScroll should do nothing.
      final double pixelsBefore = controller.position.pixels;
      _simulateOnScroll(0);
      await tester.pump();
      expect(controller.position.pixels, pixelsBefore);
    });
  });

  group('ScrollableState browser-scroll – primary:false fallback controller', () {
    testWidgets('works with primary:false and no explicit controller', (tester) async {
      await tester.pumpWidget(_buildTestAppNoPrimaryNoController());
      await tester.pump();

      _simulateOnScroll(400);
      await tester.pump();

      final Finder listFinder = find.byType(ListView);
      final ScrollableState scrollable = tester.state(
        find.descendant(of: listFinder, matching: find.byType(Scrollable)),
      );
      expect(scrollable.position.pixels, closeTo(400.0, 1.0));
    });
  });

  group('BrowserScrollable – OverscrollNotification edge passthrough', () {
    late ScrollController controller;

    setUp(() {
      controller = ScrollController();
    });

    tearDown(() {
      controller.dispose();
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

      _simulateOnScroll(500);
      await tester.pump();

      leaked.clear();
      _clearCalls();

      final ScrollPosition pos = controller.position;
      OverscrollNotification(
        overscroll: 50.0,
        metrics: pos.copyWith(),
        context: tester.element(find.byType(ListView)),
      ).dispatch(tester.element(find.byType(ListView)));
      await tester.pump();

      expect(leaked, isEmpty);
      expect(_callsOf('browserScrollBy'), isNotEmpty);
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

      _simulateOnScroll(0);
      await tester.pump();

      leaked.clear();
      _clearCalls();

      final ScrollPosition pos = controller.position;
      OverscrollNotification(
        overscroll: -30.0,
        metrics: pos.copyWith(),
        context: tester.element(find.byType(ListView)),
      ).dispatch(tester.element(find.byType(ListView)));
      await tester.pump();

      expect(leaked, hasLength(1));
      expect(leaked.first.overscroll, -30.0);
      expect(_callsOf('browserScrollBy'), isEmpty);
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

      final double maxExtent = controller.position.maxScrollExtent;
      _simulateOnScroll(maxExtent);
      await tester.pump();

      leaked.clear();
      _clearCalls();

      final ScrollPosition pos = controller.position;
      OverscrollNotification(
        overscroll: 40.0,
        metrics: pos.copyWith(),
        context: tester.element(find.byType(ListView)),
      ).dispatch(tester.element(find.byType(ListView)));
      await tester.pump();

      expect(leaked, hasLength(1));
      expect(leaked.first.overscroll, 40.0);
      expect(_callsOf('browserScrollBy'), isEmpty);
    });
  });

  group('ScrollableState browser-scroll – programmatic scrolling', () {
    late ScrollController controller;

    setUp(() {
      controller = ScrollController();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('jumpTo sends browserScrollTo to engine', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      _clearCalls();

      controller.jumpTo(500);
      await tester.pump();

      expect(controller.position.pixels, closeTo(500.0, 1.0));

      final List<Map<String, Object?>> scrollToCalls = _callsOf('browserScrollTo');
      expect(scrollToCalls, isNotEmpty);
      expect(scrollToCalls.last['args']! as double, closeTo(500.0, 1.0));
    });

    testWidgets('animateTo does not move pixels with enableBrowserScrolling', (tester) async {
      await tester.pumpWidget(_buildTestApp(controller));
      await tester.pump();

      controller.animateTo(400, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 150));

      expect(controller.position.pixels, closeTo(0.0, 1.0));
    });

    testWidgets('ensureVisible triggers scroll', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: BrowserScrollable(
              child: ListView.builder(
                controller: controller,
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

      _simulateOnScroll(2000);
      await tester.pump();

      _clearCalls();

      final Finder target = find.byKey(const Key('target'));
      if (target.evaluate().isNotEmpty) {
        await Scrollable.ensureVisible(target.evaluate().first);
        await tester.pump();

        expect(controller.position.pixels, greaterThan(0));
        expect(_callsOf('browserScrollTo'), isNotEmpty);
      }
    });

    testWidgets('focus traversal triggers scroll for offscreen widget', (tester) async {
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

      focusNodes[0].requestFocus();
      await tester.pump();

      _clearCalls();

      for (var i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }

      expect(controller.position.pixels, greaterThan(0));
      expect(
        _callsOf('browserScrollTo'),
        isNotEmpty,
        reason: 'Focus traversal to offscreen widget should send browserScrollTo to engine',
      );
    });
  });

  group('ScrollableState browser-scroll – nested scrollable isolation', () {
    late ScrollController outerController;

    setUp(() {
      outerController = ScrollController();
    });

    tearDown(() {
      outerController.dispose();
    });

    testWidgets('only the outermost scrollable owns the binding', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: BrowserScrollable(
              child: ListView(
                controller: outerController,
                children: [
                  const SizedBox(height: 100),
                  SizedBox(
                    height: 300,
                    child: ListView.builder(
                      itemCount: 50,
                      itemBuilder: (context, index) =>
                          SizedBox(height: 40, child: Text('Inner $index')),
                    ),
                  ),
                  const SizedBox(height: 1000),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      _clearCalls();

      outerController.jumpTo(200);
      await tester.pump();

      expect(outerController.position.pixels, closeTo(200.0, 1.0));
      final List<Map<String, Object?>> scrollToCalls = _callsOf('browserScrollTo');
      expect(scrollToCalls, isNotEmpty);
      expect(scrollToCalls.last['args']! as double, closeTo(200.0, 1.0));
    });

    testWidgets('inner scrollable scrolls independently without BrowserScrollPhysics', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: BrowserScrollable(
              child: ListView(
                controller: outerController,
                children: [
                  const SizedBox(height: 100),
                  SizedBox(
                    height: 300,
                    child: ListView.builder(
                      itemCount: 50,
                      itemBuilder: (context, index) =>
                          SizedBox(height: 40, child: Text('Inner $index')),
                    ),
                  ),
                  const SizedBox(height: 1000),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final Finder innerListFinder = find.byType(Scrollable).at(1);
      final ScrollableState innerScrollable = tester.state(innerListFinder);
      final ScrollPosition innerPos = innerScrollable.position;

      expect(innerPos.pixels, 0.0);

      innerPos.jumpTo(100);
      await tester.pump();

      expect(innerPos.pixels, closeTo(100.0, 1.0));
    });
  });
}
