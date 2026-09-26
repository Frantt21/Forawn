// window_effects_service.dart
//
// Efectos de ventana translúcidos gestionados POR SISTEMA OPERATIVO.
//
// Realidad por plataforma (verificada contra flutter_acrylic 1.1.4 y el
// compositor de cada OS):
//
//  · Windows 11 (build >= 22000): soporta acrylic, mica y tabbed de forma
//    nativa y SIN el lag de arrastre (Microsoft lo corrigió en Win11).
//  · Windows 10 (build < 22000): acrylic existe desde 1803 pero el
//    arrastre/redimensionado es notoriamente laggy (issue conocido del
//    compositor; flutter_acrylic lo documenta). Solo se ofrecen solid y
//    transparent; si el usuario tenía acrylic/mica guardado se degrada.
//  · Linux: flutter_acrylic solo implementa disabled/solid/transparent.
//    El blur de KWin es un compositor script (no invocable desde la app),
//    así que NO se ofrece; queda solid/transparent.
//  · macOS: flutter_acrylic implementa materiales NSVisualEffectView
//    (titlebar, sidebar, hudWindow, etc.). Se exponen los más seguros.
//
// El servicio centraliza: qué efectos existen en el OS actual, validación
// del efecto persistido (degrada a solid si no es soportado) y los presets
// de color que ofrece settings.
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'
    show Color, Colors, Theme, Brightness, BuildContext;
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'win_diag.dart';

const String _prefEffectKey = 'window_effect';
const String _prefColorKey = 'window_color';
const String _prefDarkKey = 'window_dark';

/// Color por defecto del acrílico (gris oscuro translúcido, el histórico).
const Color kDefaultWindowColor = Color(0xCC222222);

class WindowEffectsService {
  WindowEffectsService._();
  static final WindowEffectsService instance = WindowEffectsService._();

  bool _initialized = false;
  bool _nativeAvailable = false;
  bool _isWindows11 = false;
  String _osLabel = 'Windows';

  /// Guardia: el efecto se aplica UNA sola vez por sesión de la app.
  ///
  /// Cada SetEffect en Windows hace ACCENT_DISABLED → re-aplicar; llamarlo
  /// varias veces (arranque + refuerzos) corrompe el backdrop del DWM (el
  /// efecto desaparece) y degrada el rendimiento del compositor (~3 FPS).
  bool _appliedThisSession = false;

  /// Completa cuando el efecto de la sesión ya fue aplicado (o no
  /// corresponde). La UI puede await-arlo para pintar transparente solo
  /// cuando el backdrop del compositor ya está activo (evita el frame
  /// negro del arranque: antes de completarse, la app pinta fondo sólido).
  final Completer<void> _appliedCompleter = Completer<void>();

  /// Instante del último setEffect. Se usa para debouncear los refuerzos:
  /// el backdrop del DWM puede no tomarse si el apply inicial corre con la
  /// ventana desenfocada (p. ej. el usuario minimiza la carpeta del .exe
  /// mientras Forawn abre), y se re-aplica al recuperar el foco.
  DateTime? _lastApplyAt;

  /// true si la ventana se minimizó después del último apply: al restaurar,
  /// el SYSTEMBACKDROP_TYPE se pierde y hay que re-aplicarlo. No aplica al
  /// simple desenfoque, que no destruye el backdrop.
  bool _minimizedSinceApplied = false;

  /// Anti-solapamiento: evita que dos eventos (focus + restore) lancen dos
  /// setEffect simultáneos, que se corrompen entre sí.
  bool _reapplying = false;

  /// Guardia del reintento diferido del apply inicial (ver
  /// [_scheduleFocusRetry]).
  bool _focusRetryScheduled = false;

  /// Anti-carrera del apply inicial: el timer de reintento y el evento de
  /// foco pueden disparar a la vez; sin esta guardia ambos pasaban el chequeo
  /// de [_appliedThisSession] y se hacían dos setEffect superpuestos.
  bool _applyingInitial = false;

  /// true cuando el apply inicial se difirió por falta de foco. En ese caso
  /// el DWM ya compuso la ventana en su estado inactivo y, aunque después
  /// reciba foco, sigue pintando el material como sólido (verificado: la
  /// ventana es foreground y backdrop=3, pero sigue gris). La única salida es
  /// RECREAR la composición (hide → show) antes de aplicar el efecto.
  bool _applyWasDeferred = false;

  /// Color e intensidad vigentes en memoria: necesarios para re-aplicar sin
  /// depender de prefs (que tienen debounce de escritura).
  Color _currentColor = kDefaultWindowColor;
  bool _currentDark = true;

  /// Future que se completa al aplicar el efecto de la sesión.
  Future<void> get applied => _appliedCompleter.future;

  /// Debounce de persistencia: escribir prefs en CADA movimiento de
  /// color/efecto es innecesario; el efecto se aplica al instante, la
  /// escritura se agrupa.
  Timer? _persistDebounce;

  /// Clave del efecto actualmente aplicado ('solid', 'acrylic', ...).
  String? _currentKey;

  /// true si el plugin se inicializó y el OS soporta efectos nativos.
  bool get nativeAvailable => _nativeAvailable;

  /// Clave del efecto activo (null si no se aplicó ninguno).
  String? get currentKey => _currentKey;

  /// true cuando hay un efecto TRANSLÚCIDO activo (acrylic, mica, sidebar,
  /// transparent...). Con 'solid' o sin efecto nativo devuelve false y las
  /// superficies deben usar sus colores por defecto.
  bool get translucentSurfaces =>
      _nativeAvailable && _currentKey != null && _currentKey != 'solid';

  /// Color de superficie adaptado al efecto de ventana activo:
  ///  · Sin efecto translúcido → [solid] (color hardcodeado actual).
  ///  · Con efecto (acrylic/mica/...) → overlay translúcido que deja ver
  ///    el material del compositor detrás (white/black [overlay] según tema).
  Color surface(
    BuildContext context, {
    Color solid = const Color(0xFF1C1C1E),
    double overlay = 0.06,
  }) {
    if (!translucentSurfaces) return solid;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? Colors.white.withOpacity(overlay)
        : Colors.black.withOpacity(overlay);
  }

  /// true solo en Windows 11 (build >= 22000): acrylic/mica sin lag.
  bool get isWindows11 => _isWindows11;

  /// Etiqueta del OS actual ('Windows', 'Linux', 'macOS').
  String get osLabel => _osLabel;

  /// Efectos que el OS actual soporta realmente, con etiqueta y tooltip
  /// (reason) para mostrar en settings. Orden = orden del menú.
  List<WindowEffectOption> get availableEffects {
    if (Platform.isWindows) {
      if (_isWindows11) {
        return const [
          WindowEffectOption(
            key: 'solid',
            effect: acrylic.WindowEffect.solid,
            labelKey: 'effect_solid',
            fallback: 'Solid',
          ),
          WindowEffectOption(
            key: 'acrylic',
            effect: acrylic.WindowEffect.acrylic,
            labelKey: 'effect_acrylic',
            fallback: 'Acrylic',
          ),
          WindowEffectOption(
            key: 'mica',
            effect: acrylic.WindowEffect.mica,
            labelKey: 'effect_mica',
            fallback: 'Mica',
          ),
        ];
      }
      // Windows 10: acrylic/mica existirían pero arrastran la ventana con
      // lag (limitación del compositor corregida en Windows 11).
      return const [
        WindowEffectOption(
          key: 'solid',
          effect: acrylic.WindowEffect.solid,
          labelKey: 'effect_solid',
          fallback: 'Solid',
        ),
        WindowEffectOption(
          key: 'transparent',
          effect: acrylic.WindowEffect.transparent,
          labelKey: 'effect_transparent',
          fallback: 'Transparent',
        ),
      ];
    }
    if (Platform.isLinux) {
      // flutter_acrylic en Linux: solo disabled/solid/transparent.
      // El blur de KWin no es invocable desde la app.
      return const [
        WindowEffectOption(
          key: 'solid',
          effect: acrylic.WindowEffect.solid,
          labelKey: 'effect_solid',
          fallback: 'Solid',
        ),
        WindowEffectOption(
          key: 'transparent',
          effect: acrylic.WindowEffect.transparent,
          labelKey: 'effect_transparent',
          fallback: 'Transparent',
        ),
      ];
    }
    if (Platform.isMacOS) {
      return const [
        WindowEffectOption(
          key: 'solid',
          effect: acrylic.WindowEffect.solid,
          labelKey: 'effect_solid',
          fallback: 'Solid',
        ),
        WindowEffectOption(
          key: 'sidebar',
          effect: acrylic.WindowEffect.sidebar,
          labelKey: 'effect_acrylic',
          fallback: 'Vibrancy',
        ),
        WindowEffectOption(
          key: 'hudWindow',
          effect: acrylic.WindowEffect.hudWindow,
          labelKey: 'effect_mica',
          fallback: 'HUD',
        ),
      ];
    }
    return const [
      WindowEffectOption(
        key: 'solid',
        effect: acrylic.WindowEffect.solid,
        labelKey: 'effect_solid',
        fallback: 'Solid',
      ),
    ];
  }

  /// Nota explicativa según OS (clave de locale + fallback).
  ({String key, String fallback})? get noteForPlatform {
    if (Platform.isWindows && !_isWindows11) {
      return (
        key: 'effect_win10_lag',
        fallback:
            'Acrylic and Mica are available on Windows 11 (they lag when dragging on Windows 10).',
      );
    }
    if (Platform.isLinux) {
      return (
        key: 'effect_compositor_note',
        fallback:
            'Native blur depends on your compositor (e.g. KDE KWin) and is not available in-app.',
      );
    }
    return null;
  }

  /// Presets de color para el efecto (misma idea que la versión anterior).
  List<Color> get colorPresets => const [
        Color(0xCC222222), // gris oscuro (default)
        Color(0xCC101018), // azul noche
        Color(0xCC1E2A26), // verde bosque
        Color(0xCC2A1E2E), // púrpura
        Color(0xCC2E2418), // ámbar café
        Color(0x99303034), // gris humo más translúcido
      ];

  /// Inicializa el plugin (solo Windows) y valida el efecto persistido
  /// contra el OS. NO aplica el efecto aquí: aplicarlo antes de que la
  /// ventana sea visible hace que Windows no tome el backdrop (abre negro)
  /// y re-aplicarlo varias veces corrompe el DWM. La aplicación única
  /// diferida la hace [applyPersistedOnce] cuando la ventana ya es visible.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    _osLabel = Platform.isWindows
        ? 'Windows'
        : Platform.isLinux
            ? 'Linux'
            : 'macOS';

    try {
      if (Platform.isWindows) {
        await acrylic.Window.initialize();
        await acrylic.Window.hideWindowControls();
        _nativeAvailable = true;
        _isWindows11 = await _detectWindows11Build();

        // Solo VALIDAR el persistido (degrada la clave si el OS no lo
        // soporta); la aplicación real es diferida a applyPersistedOnce.
        final prefs = await SharedPreferences.getInstance();
        final savedKey = prefs.getString(_prefEffectKey) ?? 'solid';
        final supported = availableEffects;
        try {
          _currentKey = supported.firstWhere((e) => e.key == savedKey).key;
        } catch (_) {
          _currentKey = supported.first.key;
          await prefs.setString(_prefEffectKey, _currentKey!);
        }
        unawaited(_log(
          'init: $_osLabel native=$_nativeAvailable win11=$_isWindows11 key=$_currentKey',
        ));
        return;
      }
      // Linux/macOS: la app pinta fondo sólido propio (gNativeAcrylicAvailable
      // queda false y el ColoredBox de main.dart cubre la ventana).
      _nativeAvailable = false;
    } catch (e) {
      debugPrint('[WindowEffects] initialize error: $e');
      _nativeAvailable = false;
    }
  }

  /// Aplica el efecto guardado en prefs; si el OS actual no lo soporta,
  /// degrada a solid (persistiendo la corrección). Devuelve el aplicado.
  Future<acrylic.WindowEffect?> _applySavedEffect(
    SharedPreferences prefs,
  ) async {
    final savedKey = prefs.getString(_prefEffectKey) ?? 'solid';
    final supported = availableEffects;
    WindowEffectOption chosen;
    try {
      chosen = supported.firstWhere((e) => e.key == savedKey);
    } catch (_) {
      // Efecto guardado no soportado en este OS: degradar a solid.
      chosen = supported.first;
      await prefs.setString(_prefEffectKey, chosen.key);
      debugPrint(
        '[WindowEffects] effect "$savedKey" not supported on $_osLabel, degraded to "${chosen.key}"',
      );
    }

    final color = Color(prefs.getInt(_prefColorKey) ?? kDefaultWindowColor.value);
    final dark = prefs.getBool(_prefDarkKey) ?? true;
    _currentColor = color;
    _currentDark = dark;

    try {
      await acrylic.Window.setEffect(
        effect: chosen.effect,
        color: color,
        dark: dark,
      );
      _currentKey = chosen.key;
      _lastApplyAt = DateTime.now();
      debugPrint(
        '[WindowEffects] applied "${chosen.key}" on $_osLabel (win11=$_isWindows11)',
      );
      return chosen.effect;
    } catch (e) {
      debugPrint('[WindowEffects] apply saved effect error: $e');
      return null;
    }
  }

  /// Aplica el efecto persistido UNA SOLA VEZ por sesión, con la ventana
  /// ya visible. Llamadas posteriores son no-op (protege el DWM de los
  /// toggles repetidos ACCENT_DISABLED → apply que rompen el backdrop y
  /// hunden el rendimiento).
  Future<void> applyPersistedOnce() async {
    if (!_nativeAvailable || _currentKey == null) {
      // Sin efecto nativo (Linux/macOS/solid): la superficie sólida es el
      // estado final, no hay nada más que esperar.
      if (!_appliedCompleter.isCompleted) _appliedCompleter.complete();
      return;
    }
    if (_appliedThisSession) {
      // Ya aplicado en esta sesión: los refuerzos por foco/minimizado los
      // maneja el propio servicio (onWindowFocused/onWindowRestored).
      if (!_appliedCompleter.isCompleted) _appliedCompleter.complete();
      return;
    }
    if (_applyingInitial) return;
    _applyingInitial = true;
    // Si el efecto es translúcido y la ventana aún NO está activa, diferir:
    // en Windows el DWM deja el material en su estado "sólido" (gris plano,
    // el que se ve para ventanas inactivas) cuando el PRIMER setEffect corre
    // inactivo, y re-aplicarlo después NO lo recupera. Aplicando por primera
    // vez ya activa se comporta igual que el arranque enfocado que sí anda.
    try {
      if (translucentSurfaces && !await _isWindowFocused()) {
        _applyWasDeferred = true;
        await _log('apply deferred: window not focused yet (key=$_currentKey)');
        _scheduleFocusRetry();
        return;
      }
      if (_applyWasDeferred) {
        _applyWasDeferred = false;
        await _log('recreating composition before first apply');
        await _recreateComposition();
      }
      _appliedThisSession = true;
      _minimizedSinceApplied = false;
      final prefs = await SharedPreferences.getInstance();
      await _applySavedEffect(prefs);
      await _log('applied "$_currentKey" (once, post-show)');
      if (!_appliedCompleter.isCompleted) _appliedCompleter.complete();
    } catch (e) {
      await _log('applyPersistedOnce error: $e');
      if (!_appliedCompleter.isCompleted) _appliedCompleter.complete();
    } finally {
      _applyingInitial = false;
    }
  }

  /// Recrea la composición de la ventana (hide → show → focus). Fuerza al
  /// DWM a rehacer el estado visual de la ventana, necesario porque si el
  /// primer frame se compuso con la ventana inactiva el material queda
  /// "pegado" en sólido y re-aplicar el atributo no lo cambia.
  Future<void> _recreateComposition() async {
    try {
      await windowManager.hide();
      await windowManager.show();
      await windowManager.focus();
      // Pequeña espera para que el compositor procese el show antes del
      // setEffect (aplicar en el mismo frame no siempre engancha).
      await Future<void>.delayed(const Duration(milliseconds: 60));
    } catch (e) {
      debugPrint('[WindowEffects] recreate composition error: $e');
    }
  }

  /// Reintenta el apply diferido por falta de foco (cubre el caso de que la
  /// ventana ya estuviera activa y no llegue ningún evento de foco).
  void _scheduleFocusRetry() {
    if (_focusRetryScheduled) return;
    _focusRetryScheduled = true;
    Timer(const Duration(milliseconds: 500), () {
      _focusRetryScheduled = false;
      if (!_appliedThisSession) applyPersistedOnce();
    });
  }

  /// La ventana perdió el foco (solo traza; el acrílico pasa a sólido por
  /// diseño de Windows).
  Future<void> onWindowBlurred() async {
    if (!_nativeAvailable) return;
    await _log('blur event');
  }

  /// La ventana pasó a primer plano. El backdrop SYSTEMBACKDROP_TYPE del DWM
  /// en Windows solo se "engancha" de forma confiable si setEffect corre con
  /// la ventana ya activa; si el apply del arranque cayó con la ventana
  /// desenfocada (p. ej. se minimizó la carpeta del .exe), el efecto queda
  /// sin aplicar. Re-aplicar al recuperar el foco lo restaura.
  ///
  /// Se hace SIEMPRE (no solo la primera vez) porque el foco puede perderse
  /// varias veces tras el arranque; se debouncea para no togglear el DWM si
  /// el foco oscila rápido (cada setEffect = ACCENT_DISABLED → apply).
  Future<void> onWindowFocused() async {
    if (!_nativeAvailable) return;
    await _log(
      'focus event (applied=$_appliedThisSession '
      'translucent=$translucentSurfaces key=$_currentKey)',
    );
    if (!_appliedThisSession) {
      // El apply del arranque se difirió por falta de foco: aplicarlo ahora
      // que la ventana ya está activa.
      await applyPersistedOnce();
      return;
    }
    if (!translucentSurfaces) {
      if (!_appliedCompleter.isCompleted) _appliedCompleter.complete();
      return;
    }
    await _reapplyCurrentOnce('focus');
    if (!_appliedCompleter.isCompleted) _appliedCompleter.complete();
  }

  /// La ventana se minimizó: en Windows el backdrop se pierde al restaurar.
  void onWindowMinimized() {
    if (!_nativeAvailable) return;
    _minimizedSinceApplied = true;
    unawaited(_log('minimize event'));
  }

  /// La ventana se restauró desde minimizado: re-aplicar el backdrop si se
  /// había perdido. Una vez por restauración, nunca en bucle.
  Future<void> onWindowRestored() async {
    if (!_nativeAvailable || !_minimizedSinceApplied) return;
    _minimizedSinceApplied = false;
    await _log('restore event (translucent=$translucentSurfaces)');
    if (translucentSurfaces) {
      await _reapplyCurrentOnce('restore');
    }
  }

  /// Re-aplica el efecto vigente en memoria (sin leer prefs). Serializado:
  /// ignora llamadas concurrentes porque cada setEffect hace ACCENT_DISABLED
  /// → apply y dos solapados se corrompen.
  Future<void> _reapplyCurrentOnce(String reason) async {
    if (_reapplying) return;
    final option = _optionByKey(_currentKey);
    if (option == null) return;
    // Debounce: evita ráfagas (focus+restore seguidos) que togglearían el
    // DWM innecesariamente.
    final now = DateTime.now();
    if (_lastApplyAt != null &&
        now.difference(_lastApplyAt!).inMilliseconds < 400) {
      return;
    }
    _reapplying = true;
    _lastApplyAt = now;
    try {
      await acrylic.Window.setEffect(
        effect: option.effect,
        color: _currentColor,
        dark: _currentDark,
      );
      await _log('re-applied "$_currentKey" ($reason)');
    } catch (e) {
      await _log('reapply ($reason) error: $e');
    } finally {
      _reapplying = false;
    }
  }

  /// Log del ciclo de vida del backdrop. Escribe también en
  /// %TEMP%/forawn_effects.log para diagnosticar sin consola (el usuario
  /// ejecuta el .exe de release).
  Future<void> _log(String message) async {
    debugPrint('[WindowEffects] $message');
    try {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}forawn_effects.log',
      );
      await file.writeAsString(
        '${DateTime.now().toIso8601String()} $message ${windowDiag()}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  WindowEffectOption? _optionByKey(String? key) {
    if (key == null) return null;
    for (final option in availableEffects) {
      if (option.key == key) return option;
    }
    return null;
  }

  Future<bool> _isWindowFocused() async {
    try {
      return await windowManager.isFocused();
    } catch (_) {
      return true; // Sin dato fiable: asumir foco (comportamiento previo).
    }
  }

  /// Aplica un efecto en caliente (desde settings) y lo persiste con
  /// debounce. Marca la sesión como aplicada: si el usuario ya eligió
  /// efecto/color, el apply diferido del arranque debe ser no-op.
  Future<void> applyAndPersist(WindowEffectOption option, Color color,
      {bool dark = true}) async {
    try {
      await acrylic.Window.setEffect(
        effect: option.effect,
        color: color,
        dark: dark,
      );
      _appliedThisSession = true;
      _lastApplyAt = DateTime.now();
      _minimizedSinceApplied = false;
      _currentKey = option.key;
      _currentColor = color;
      _currentDark = dark;
      if (!_appliedCompleter.isCompleted) _appliedCompleter.complete();
      _persistDebounce?.cancel();
      _persistDebounce = Timer(const Duration(milliseconds: 350), () async {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_prefEffectKey, option.key);
          await prefs.setInt(_prefColorKey, color.value);
          await prefs.setBool(_prefDarkKey, dark);
        } catch (_) {}
      });
    } catch (e) {
      debugPrint('[WindowEffects] applyAndPersist error: $e');
    }
  }

  /// Lee el efecto persistido validándolo contra el OS actual.
  /// Devuelve la opción efectiva (nunca una no soportada).
  Future<WindowEffectOption> loadPersistedOption() async {
    final prefs = await SharedPreferences.getInstance();
    final savedKey = prefs.getString(_prefEffectKey) ?? 'solid';
    final supported = availableEffects;
    try {
      return supported.firstWhere((e) => e.key == savedKey);
    } catch (_) {
      return supported.first;
    }
  }

  Future<bool> _detectWindows11Build() async {
    // Build >= 22000 = Windows 11. Se lee el registro con `reg query`
    // (más liviano y confiable que levantar PowerShell completo).
    try {
      final result = await Process.run('reg', [
        'query',
        r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion',
        '/v',
        'CurrentBuild',
      ]);
      if (result.exitCode == 0) {
        final match =
            RegExp(r'CurrentBuild\s+REG_SZ\s+(\d+)').firstMatch(result.stdout);
        final build = int.tryParse(match?.group(1) ?? '') ?? 0;
        return build >= 22000;
      }
    } catch (e) {
      debugPrint('[WindowEffects] build detection error: $e');
    }
    // Sin dato: asumir Windows 10 (más seguro: se ofrecen menos efectos).
    return false;
  }
}

/// Opción de efecto presentable en settings.
class WindowEffectOption {
  final String key;
  final acrylic.WindowEffect effect;

  /// Clave de locale para la etiqueta.
  final String labelKey;

  /// Texto de respaldo si la clave no está traducida.
  final String fallback;

  const WindowEffectOption({
    required this.key,
    required this.effect,
    required this.labelKey,
    required this.fallback,
  });
}
