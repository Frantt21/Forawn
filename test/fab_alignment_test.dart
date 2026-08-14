import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// El botón de descargas del screen de video debe quedar a la misma altura
/// que el de descargas del screen de música (que va dentro de un
/// Padding(bottom: 16) con dos FABs apilados).
void main() {
  Widget musicFabStructure() {
    return Scaffold(
      body: const SizedBox.expand(),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            const FloatingActionButton(
              mini: true,
              heroTag: 'mini',
              onPressed: null,
              child: Icon(Icons.music_note),
            ),
            const SizedBox(height: 16),
            const FloatingActionButton(
              heroTag: 'downloads_music',
              onPressed: null,
              child: Icon(Icons.download),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Widget videoFabStructure({double bottomPadding = 0}) {
    return Scaffold(
      body: const SizedBox.expand(),
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: bottomPadding),
        child: const FloatingActionButton(
          heroTag: 'downloads_video',
          onPressed: null,
          child: Icon(Icons.download),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  testWidgets('FAB de descargas de video alineado con el de música',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: musicFabStructure()));
    final musicBottom = tester.getBottomRight(find.byIcon(Icons.download)).dy;

    // Padding de 16: replica el Padding(bottom: 16) del screen de música.
    await tester.pumpWidget(
      MaterialApp(home: videoFabStructure(bottomPadding: 16)),
    );
    final videoBottom = tester.getBottomRight(find.byIcon(Icons.download)).dy;

    expect(videoBottom, musicBottom,
        reason: 'el FAB de descargas de video debe quedar a la misma '
            'altura que el de música (diferencia '
            '${(videoBottom - musicBottom).toStringAsFixed(1)} px)');
  });
}
