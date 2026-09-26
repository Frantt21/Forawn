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
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'
    show Color, Colors, Theme, Brightness, BuildContext;
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Inicializa el plugin (solo Windows: es donde la app lo usa hoy) y
  /// aplica el efecto persistido, degradándolo si el OS no lo soporta.
  /// Devuelve el efecto efectivamente aplicado (o null si no se aplicó
  /// ninguno, p. ej. Linux/macOS sin efecto o error).
  Future<acrylic.WindowEffect?> initialize() async {
    if (_initialized) return null;
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

        final prefs = await SharedPreferences.getInstance();
        final applied = await _applySavedEffect(prefs);
        return applied;
      }
      // Linux/macOS: la app pinta fondo sólido propio (gNativeAcrylicAvailable
      // queda false y el ColoredBox de main.dart cubre la ventana).
      _nativeAvailable = false;
    } catch (e) {
      debugPrint('[WindowEffects] initialize error: $e');
      _nativeAvailable = false;
    }
    return null;
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

    try {
      await acrylic.Window.setEffect(
        effect: chosen.effect,
        color: color,
        dark: dark,
      );
      _currentKey = chosen.key;
      debugPrint(
        '[WindowEffects] applied "${chosen.key}" on $_osLabel (win11=$_isWindows11)',
      );
      return chosen.effect;
    } catch (e) {
      debugPrint('[WindowEffects] apply saved effect error: $e');
      return null;
    }
  }

  /// Aplica un efecto en caliente (desde settings) y lo persiste.
  Future<void> applyAndPersist(WindowEffectOption option, Color color,
      {bool dark = true}) async {
    try {
      await acrylic.Window.setEffect(
        effect: option.effect,
        color: color,
        dark: dark,
      );
      _currentKey = option.key;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefEffectKey, option.key);
      await prefs.setInt(_prefColorKey, color.value);
      await prefs.setBool(_prefDarkKey, dark);
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
