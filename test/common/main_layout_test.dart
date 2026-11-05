import 'package:PiliPlus/common/widgets/main_layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool atEnd}) =>
      tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 700,
              height: 500,
              child: MainLayout(
                sideBarAtEnd: atEnd,
                sideBar: const SizedBox(key: Key('side'), width: 130),
                bottomNav: null,
                body: const SizedBox.expand(key: Key('body')),
              ),
            ),
          ),
        ),
      );

  testWidgets('side bar on the left by default', (tester) async {
    await pump(tester, atEnd: false);
    final origin = tester.getTopLeft(find.byType(MainLayout));
    expect(
      tester.getTopLeft(find.byKey(const Key('side'))) - origin,
      Offset.zero,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('body'))) - origin,
      const Offset(130, 0),
    );
    expect(tester.getSize(find.byKey(const Key('body'))), const Size(570, 500));
  });

  testWidgets('side bar on the right, below the status bar column', (
    tester,
  ) async {
    await pump(tester, atEnd: true);
    final origin = tester.getTopLeft(find.byType(MainLayout));
    expect(
      tester.getTopLeft(find.byKey(const Key('side'))) - origin,
      const Offset(570, 0),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('body'))) - origin,
      Offset.zero,
    );
    expect(tester.getSize(find.byKey(const Key('body'))), const Size(570, 500));
    // Switching back relayouts.
    await pump(tester, atEnd: false);
    expect(
      tester.getTopLeft(find.byKey(const Key('body'))) - origin,
      const Offset(130, 0),
    );
  });
}
