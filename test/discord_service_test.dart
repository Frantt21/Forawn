import 'package:flutter_test/flutter_test.dart';

import 'package:forawn/config/api_config.dart';
import 'package:forawn/services/discord_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initialize no lanza y devuelve bool', () async {
    // Con client ID en ApiConfig intenta conectar (true si Discord está
    // corriendo); sin ID o sin Discord conectado devuelve false. En ambos
    // casos no debe lanzar excepciones.
    final ok = await DiscordService().initialize();
    expect(ok, isA<bool>());
  });

  test('la config expone la clave discordClientId', () {
    // La clave existe (aunque esté vacía hasta que el desarrollador la
    // rellene en lib/config/api_config.dart, que está en .gitignore).
    expect(ApiConfig.discordClientId, isA<String>());
  });
}
