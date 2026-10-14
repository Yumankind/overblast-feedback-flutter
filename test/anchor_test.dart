import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overblast_feedback/overblast_feedback.dart';
import 'package:overblast_feedback/src/private.dart' show sensitiveRects;
import 'package:overblast_feedback/src/tree.dart' show isPainted;

import 'test_app.dart';

void main() {
  final surfaceKey = GlobalKey();

  Future<(Element, RenderRepaintBoundary)> pumpCart(WidgetTester tester) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: surfaceKey,
        child: const MaterialApp(home: CartScreen()),
      ),
    );
    final element = surfaceKey.currentContext! as Element;
    return (element, element.findRenderObject()! as RenderRepaintBoundary);
  }

  testWidgets('tapping a keyed button names the button, its key, its text and its box', (tester) async {
    final (root, boundary) = await pumpCart(tester);
    final button = find.byKey(const ValueKey('cart.remove'));
    final anchor = anchorAt(root, boundary, tester.getCenter(find.text('Remove')))!;
    expect(anchor.type, 'ElevatedButton');
    expect(anchor.id, 'cart.remove');
    expect(anchor.label, 'Remove');
    final rect = tester.getRect(button);
    expect(anchor.rect.x, closeTo(rect.left / 800, 1e-3));
    expect(anchor.rect.y, closeTo(rect.top / 600, 1e-3));
    expect(anchor.rect.w, closeTo(rect.width / 800, 1e-3));
    expect(anchor.rect.h, closeTo(rect.height / 600, 1e-3));
    expect(anchor.viewportWidth, 800);
    expect(anchor.viewportHeight, 600);
    expect(anchor.path.last, 'ElevatedButton');
    expect(anchor.path, containsAllInOrder(['MaterialApp', 'CartScreen', 'Scaffold', 'ElevatedButton']));
    expect(anchor.path, isNot(contains('Padding')));
    expect(anchor.path, isNot(contains('InkWell')));
    expect(anchor.path, ['MaterialApp', 'CartScreen', 'Scaffold', 'ElevatedButton']);
    expect(anchor.path.any((s) => s.startsWith('_')), isFalse);
    final json = anchor.toJson();
    expect(json['kind'], 'native');
    expect((json['path']! as List).length, lessThanOrEqualTo(12));
  });

  testWidgets('plain text is named as Text, inside the app widget that made it', (tester) async {
    final (root, boundary) = await pumpCart(tester);
    final anchor = anchorAt(root, boundary, tester.getCenter(find.text('Blue mug')))!;
    expect(anchor.type, 'Text');
    expect(anchor.label, 'Blue mug');
    expect(anchor.id, isNull);
    expect(anchor.path.sublist(anchor.path.length - 2), ['CartRow', 'Text']);
  });

  testWidgets('a Semantics identifier is the id when there is no closer key', (tester) async {
    final (root, boundary) = await pumpCart(tester);
    final anchor = anchorAt(root, boundary, tester.getCenter(find.text('Total 12.00')))!;
    expect(anchor.type, 'Text');
    // The Text's own ValueKey is nearer than the Semantics around it.
    expect(anchor.id, 'total-text');
  });

  testWidgets('a private region gives its type and box, never its text', (tester) async {
    final (root, boundary) = await pumpCart(tester);
    final anchor = anchorAt(root, boundary, tester.getCenter(find.byKey(const ValueKey('iban'))))!;
    expect(anchor.label, isNull);
    expect(anchor.toJson().containsKey('label'), isFalse);
    expect(anchor.id, 'iban');
  });

  testWidgets('a text field is named, and its typed value is never the label', (tester) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: surfaceKey,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: TextField(
                  key: ValueKey('note'),
                  decoration: InputDecoration(labelText: 'Note'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('note')), 'my secret words');
    await tester.pump();
    final root = surfaceKey.currentContext! as Element;
    final anchor = anchorAt(
      root,
      root.findRenderObject()! as RenderBox,
      tester.getCenter(find.byKey(const ValueKey('note'))),
    )!;
    expect(anchor.type, 'TextField');
    expect(anchor.id, 'note');
    expect(anchor.label, 'Note');
  });

  testWidgets('a box partly off screen is clamped to the viewport', (tester) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: surfaceKey,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              Positioned(
                left: -100,
                top: 550,
                width: 300,
                height: 100,
                child: ColoredBox(key: ValueKey('edge'), color: Color(0xFF00FF00)),
              ),
            ],
          ),
        ),
      ),
    );
    final root = surfaceKey.currentContext! as Element;
    final anchor = anchorAt(root, root.findRenderObject()! as RenderBox, const Offset(50, 580))!;
    expect(anchor.id, 'edge');
    expect(anchor.rect.x, 0);
    expect(anchor.rect.w, closeTo(0.25, 1e-3)); // 300 wide from -100: the 200 on screen, of 800
    expect(anchor.rect.h, closeTo(50 / 600, 1e-3));
    expect(anchor.rect.x + anchor.rect.w, lessThanOrEqualTo(1));
    expect(anchor.rect.y + anchor.rect.h, lessThanOrEqualTo(1));
  });

  testWidgets('outside the surface there is nothing', (tester) async {
    final (root, boundary) = await pumpCart(tester);
    expect(anchorAt(root, boundary, const Offset(-5, 10)), isNull);
  });

  testWidgets('private rectangles cover only what is painted', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      RepaintBoundary(
        key: surfaceKey,
        child: MaterialApp(navigatorKey: navKey, home: const CartScreen()),
      ),
    );
    final root = surfaceKey.currentContext! as Element;
    final boundary = root.findRenderObject()! as RenderRepaintBoundary;
    final rects = sensitiveRects(root, boundary);
    // The private box and the password field.
    expect(rects.length, 2);
    expect(rects.any((r) => r.contains(tester.getCenter(find.byKey(const ValueKey('iban'))))), isTrue);
    expect(rects.any((r) => r.contains(tester.getCenter(find.byKey(const ValueKey('password'))))), isTrue);

    // Under an opaque page the cart route is offstage: attached and laid out, but not painted.
    navKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Next'))));
    await tester.pumpAndSettle();
    final iban = tester.renderObject(find.byKey(const ValueKey('iban'), skipOffstage: false));
    expect(iban.attached, isTrue);
    expect(isPainted(iban, boundary), isFalse);
    expect(sensitiveRects(root, boundary), isEmpty);

    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(sensitiveRects(root, boundary).length, 2);
  });

  test('framework plumbing is noise, app and named widgets are not', () {
    expect(isFrameworkNoise(const Padding(padding: EdgeInsets.zero)), isTrue);
    expect(isFrameworkNoise(const SizedBox()), isTrue);
    expect(isFrameworkNoise(const AnimatedOpacity(opacity: 1, duration: Duration.zero)), isTrue);
    expect(isFrameworkNoise(const Text('x')), isFalse);
    expect(isFrameworkNoise(ElevatedButton(onPressed: null, child: const Text('x'))), isFalse);
    expect(isFrameworkNoise(const CartScreen()), isFalse);
  });
}
