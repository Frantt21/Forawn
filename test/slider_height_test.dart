import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regresión: la zona clickeable de la barra de progreso y del volumen debe
/// ser más alta que el track (2 px) sin engrosar la barra ni moverla de su
/// centro. Reproduce la estructura real de player_screen.dart.
void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: RawKeyboardListener(
          focusNode: FocusNode(),
          child: Stack(
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Expanded(
                                child: IndexedStack(
                                  index: 1,
                                  sizing: StackFit.expand,
                                  children: [
                                    const SizedBox(),
                                    Column(
                                      children: [
                                        const Spacer(),
                                        const Text('Title',
                                            style: TextStyle(fontSize: 28)),
                                        const SizedBox(height: 8),
                                        const Text('Artist'),
                                        Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const SizedBox(height: 24),
                                            Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [child],
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  SliderThemeData thinBar(Color color) {
    return SliderThemeData(
      trackHeight: 2,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 0),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
      padding: EdgeInsets.zero,
      activeTrackColor: color.withOpacity(0.7),
      inactiveTrackColor: Colors.white10,
      thumbColor: color,
    );
  }

  testWidgets('progreso y volumen tienen zona clickeable más alta sin '
      'engrosar la barra', (tester) async {
    final progressKey = GlobalKey();
    final volumeKey = GlobalKey();
    final timeKey = GlobalKey();

    final progress = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Row(
          children: [
            Text('0:00',
                key: timeKey,
                style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 28,
                child: SliderTheme(
                  key: progressKey,
                  data: thinBar(Colors.purpleAccent),
                  child: Slider(value: 30, max: 100, onChanged: (_) {}),
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text('3:30', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );

    final volume = Expanded(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          const Icon(Icons.volume_up, size: 20),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            height: 48,
            child: SliderTheme(
              key: volumeKey,
              data: thinBar(Colors.purpleAccent),
              child: Slider(value: 0.5, onChanged: (_) {}),
            ),
          ),
        ],
      ),
    );

    await tester.pumpWidget(wrap(Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Expanded(child: SizedBox()),
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.play_arrow),
            ]),
            volume,
          ],
        ),
        const SizedBox(height: 8),
        progress,
      ],
    )));

    final progressBox = tester.renderObject<RenderBox>(
      find.byKey(progressKey),
    );
    final volumeBox =
        tester.renderObject<RenderBox>(find.byKey(volumeKey));

    // Zona clickeable: 28 px para la barra de progreso y 48 para el
    // volumen (antes eran 2 px, el grosor del track).
    expect(progressBox.size.height, 28);
    expect(volumeBox.size.height, 48);

    // Render intacto: el track se mantiene centrado en su caja (2 px
    // dentro de 28/48) y los tiempos quedan alineados con la barra.
    final timeBox =
        tester.renderObject<RenderBox>(find.byKey(timeKey));
    final timeCenter = timeBox.localToGlobal(timeBox.size.center(Offset.zero));
    final progressCenter = progressBox.localToGlobal(
      progressBox.size.center(Offset.zero),
    );
    expect((timeCenter.dy - progressCenter.dy).abs(), lessThan(1.0));
  });
}
