import 'package:flutter_test/flutter_test.dart';

import 'package:forawn/main.dart' show loadLanguage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('todos los idiomas se cargan desde los assets empaquetados', () async {
    const codes = ['en', 'es', 'de-CH', 'fr', 'ja', 'ko', 'pl', 'pt', 'ru', 'zh'];
    for (final code in codes) {
      final map = await loadLanguage(code);
      expect(map.length, greaterThan(400), reason: 'idioma $code');
      expect(map['settings'], isNotEmpty, reason: 'idioma $code');
      expect(map['language'], isNotEmpty, reason: 'idioma $code');
      // Claves del menu del reproductor y dialogs relacionados
      for (final key in [
        'player_reproducer',
        'done',
        'no_title',
        'no_song',
        'song',
        'songs',
        'full_artwork_mode',
        'square_artwork_mode',
        'lyrics_sweep_title',
        'lyrics_sweep_sub',
      ]) {
        expect(map[key], isNotEmpty, reason: 'idioma $code, clave $key');
      }
    }
  });

  test('codigo inexistente devuelve mapa vacio sin lanzar', () async {
    final map = await loadLanguage('xx');
    expect(map, isEmpty);
  });
}
