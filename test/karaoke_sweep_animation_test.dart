// test/karaoke_sweep_animation_test.dart
//
// El sweep palabra por palabra se pinta con la posición de audio, que llega
// cada ~200 ms (onPositionChanged). Si el relleno saltara de un valor al
// siguiente se vería a golpes: eso es el bug reportado ("los lyrics word by
// word no tienen una animación suave").
//
// KaraokeWordFill interpola cada cambio de progreso; estas pruebas lo
// verifican con el reloj de frames del test (sin UI real ni plugins).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forawn/screen/lyrics_display_widget.dart';

void main() {
  Widget buildWord(double progress) => MaterialApp(
    home: Scaffold(
      body: KaraokeWordFill(
        word: 'Hola ',
        progress: progress,
        style: const TextStyle(fontSize: 24),
        activeColor: Colors.white,
        inactiveColor: Colors.white54,
        // Fijo para que las aserciones de tiempo sean deterministas.
        smoothing: const Duration(milliseconds: 180),
      ),
    ),
  );

  group('sweepSmoothingFor (ritmo real de las señales)', () {
    test('señales fluidas (60 fps) -> interpolación mínima, sin retardo', () {
      expect(
        sweepSmoothingFor(const Duration(milliseconds: 16)),
        const Duration(milliseconds: 40),
      );
    });

    test('señales cuantizadas a ~200 ms -> cubre el hueco', () {
      expect(
        sweepSmoothingFor(const Duration(milliseconds: 200)),
        const Duration(milliseconds: 200),
      );
    });

    test('señales lentas -> tope de 250 ms', () {
      expect(
        sweepSmoothingFor(const Duration(milliseconds: 900)),
        const Duration(milliseconds: 250),
      );
    });

    test('intervalo cero no rompe el cálculo', () {
      expect(
        sweepSmoothingFor(Duration.zero),
        const Duration(milliseconds: 40),
      );
    });
  });

  KaraokeWordFillState stateOf(WidgetTester tester) =>
      tester.state<KaraokeWordFillState>(find.byType(KaraokeWordFill));

  testWidgets('arranca en el progreso recibido, sin animación inicial', (
    tester,
  ) async {
    await tester.pumpWidget(buildWord(0.4));
    expect(stateOf(tester).value, closeTo(0.4, 0.001));
  });

  testWidgets('interpola cada señal de posición de forma continua', (
    tester,
  ) async {
    await tester.pumpWidget(buildWord(0.10));
    expect(stateOf(tester).value, closeTo(0.10, 0.001));

    // Siguiente señal de posición (llegan cada ~200 ms): 0.10 -> 0.50.
    await tester.pumpWidget(buildWord(0.50));
    await tester.pump();
    // Recién empieza: sigue cerca del valor anterior, no salta.
    expect(stateOf(tester).value, lessThan(0.2));

    // A mitad de la interpolación avanzó de forma parcial.
    await tester.pump(const Duration(milliseconds: 90));
    final mid = stateOf(tester).value;
    expect(mid, greaterThan(0.15));
    expect(mid, lessThan(0.45));

    // Al terminar queda exactamente en el valor de la señal.
    await tester.pump(const Duration(milliseconds: 120));
    expect(stateOf(tester).value, closeTo(0.50, 0.001));

    // Sin señales nuevas no se desborda (no sigue avanzando solo).
    await tester.pump(const Duration(milliseconds: 500));
    expect(stateOf(tester).value, closeTo(0.50, 0.001));
  });

  testWidgets('si llega un valor a mitad de animación no hay salto', (
    tester,
  ) async {
    await tester.pumpWidget(buildWord(0.10));
    await tester.pumpWidget(buildWord(0.90));
    await tester.pump(const Duration(milliseconds: 90));
    final before = stateOf(tester).value;

    // Nueva señal a mitad de la animación: 0.90 -> 0.20.
    await tester.pumpWidget(buildWord(0.20));
    await tester.pump();
    final after = stateOf(tester).value;

    // Continuidad: sigue desde el valor pintado.
    expect((after - before).abs(), lessThan(0.05));

    // Y ahora converge al nuevo objetivo.
    await tester.pump(const Duration(milliseconds: 200));
    expect(stateOf(tester).value, closeTo(0.20, 0.001));
  });

  testWidgets('palabra resuelta se pinta activa, sin animación', (tester) async {
    await tester.pumpWidget(buildWord(1.0));
    expect(stateOf(tester).value, 1.0);
    expect(
      tester.widget<Text>(find.text('Hola ')).style?.color,
      Colors.white,
    );
  });

  testWidgets('palabra futura se pinta inactiva', (tester) async {
    await tester.pumpWidget(buildWord(0.0));
    expect(stateOf(tester).value, 0.0);
    expect(
      tester.widget<Text>(find.text('Hola ')).style?.color,
      Colors.white54,
    );
  });
}
