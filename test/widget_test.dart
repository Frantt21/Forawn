import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forawn/utils/color_utils.dart';
import 'package:forawn/widgets/app_title_bar.dart';

void main() {
  group('readableTextColorFor', () {
    test('devuelve blanco sobre fondos oscuros', () {
      expect(readableTextColorFor(const Color(0xFF1E1E1E)), Colors.white);
      expect(readableTextColorFor(const Color(0xFF000000)), Colors.white);
    });

    test('devuelve negro sobre fondos claros', () {
      expect(readableTextColorFor(const Color(0xFFF5F5F5)), Colors.black);
      expect(readableTextColorFor(const Color(0xFFFFFFFF)), Colors.black);
    });

    test('elige el color con mayor ratio de contraste', () {
      final bg = const Color(0xFF767676); // gris medio
      final withWhite = contrastRatio(bg, Colors.white);
      final withBlack = contrastRatio(bg, Colors.black);
      final chosen = readableTextColorFor(bg);
      expect(chosen, withWhite >= withBlack ? Colors.white : Colors.black);
    });
  });

  group('AppTitleBar', () {
    String getText(String key, {String? fallback}) => fallback ?? key;

    testWidgets('usa texto blanco con tint oscuro', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppTitleBar(
              title: const Text('Mi Playlist'),
              getText: getText,
              tintColor: const Color(0xFF1E1E1E),
              windowBackgroundColor: const Color(0xFF1E1E1E),
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('Mi Playlist'));
      final resolved = DefaultTextStyle.of(
        tester.element(find.text('Mi Playlist')),
      ).style;
      expect(resolved.color, Colors.white);
      expect(text.style?.color, isNull); // hereda del DefaultTextStyle
    });

    testWidgets('usa texto negro con tint claro', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppTitleBar(
              title: const Text('Mi Playlist'),
              getText: getText,
              tintColor: const Color(0xFFF5F5F5),
              windowBackgroundColor: const Color(0xFFF5F5F5),
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('Mi Playlist'));
      final resolved = DefaultTextStyle.of(
        tester.element(find.text('Mi Playlist')),
      ).style;
      expect(resolved.color, Colors.black);
      expect(text.style?.color, isNull); // hereda del DefaultTextStyle
    });
  });
}
