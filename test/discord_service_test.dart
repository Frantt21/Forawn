import 'package:flutter_test/flutter_test.dart';

import 'package:forawn/config/api_config.dart';
import 'package:forawn/services/discord_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initialize sin client ID deshabilita sin lanzar', () async {
    // Sin client ID configurado (ApiConfig.discordClientId vacío), el RPC
    // queda deshabilitado y no debe lanzar excepciones.
    final ok = await DiscordService().initialize();
    expect(ok, isFalse);
  });

  test('la config expone la clave discordClientId', () {
    // La clave existe (aunque esté vacía hasta que el desarrollador la
    // rellene en lib/config/api_config.dart, que está en .gitignore).
    expect(ApiConfig.discordClientId, isA<String>());
  });
}
