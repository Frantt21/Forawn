import 'package:flutter/material.dart';

/// Servicio global para compartir el color dominante del reproductor
/// con toda la aplicación (AppBar, Sidebar, etc.)
class GlobalThemeService {
  static final GlobalThemeService _instance = GlobalThemeService._internal();
  factory GlobalThemeService() => _instance;
  GlobalThemeService._internal();

  // ValueNotifier para el color dominante actual
  final ValueNotifier<Color?> dominantColor = ValueNotifier<Color?>(null);

  // ValueNotifier para controlar si se debe usar el tema adaptativo
  final ValueNotifier<bool> useAdaptiveTheme = ValueNotifier<bool>(true);

  // ValueNotifier para el fondo difuminado del reproductor
  final ValueNotifier<bool> blurBackground = ValueNotifier<bool>(false);

  /// Actualizar el color dominante (llamado desde MusicPlayerScreen)
  void updateDominantColor(Color? color) {
    if (useAdaptiveTheme.value) {
      dominantColor.value = color;
    }
  }

  /// Limpiar el color dominante (volver al tema por defecto)
  void clearDominantColor() {
    dominantColor.value = null;
  }

  /// Alternar el uso del tema adaptativo
  void toggleAdaptiveTheme() {
    useAdaptiveTheme.value = !useAdaptiveTheme.value;
    if (!useAdaptiveTheme.value) {
      clearDominantColor();
    }
  }

  /// Obtener color para el AppBar/TitleBar
  Color? getAppBarColor() {
    if (dominantColor.value == null) return null;
    return dominantColor.value!.withOpacity(0.15);
  }

  /// Obtener color para el Sidebar
  Color? getSidebarColor() {
    if (dominantColor.value == null) return null;
    return dominantColor.value!.withOpacity(0.08);
  }

  /// Obtener color para contenedores/cards
  Color? getContainerColor() {
    if (dominantColor.value == null) return null;
    return dominantColor.value!.withOpacity(0.05);
  }

  /// Obtener color de acento para botones/iconos
  Color? getAccentColor() {
    return dominantColor.value;
  }

  void dispose() {
    dominantColor.dispose();
    useAdaptiveTheme.dispose();
  }
}
