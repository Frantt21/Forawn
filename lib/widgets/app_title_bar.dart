import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../utils/color_utils.dart';

/// Barra de título reutilizable de la app (unificada en los 3 SO).
///
/// Misma apariencia que la title bar de HomeScreen: fondo transparente o
/// tintado, arrastre de ventana, botones min/max/cerrar (salvo en macOS,
/// donde los pone el sistema) y contraste automático del texto/iconos.
class AppTitleBar extends StatelessWidget {
  /// Texto (o widget) del título.
  final Widget title;

  /// Si no es null, la barra se pinta con este color (tint) en vez de
  /// transparente; el color de texto/iconos se calcula desde él.
  final Color? tintColor;

  /// Color de fondo de la ventana usado para calcular el contraste cuando
  /// [tintColor] es null (fondo transparente).
  final Color windowBackgroundColor;

  /// Widget opcional a la izquierda del título (p. ej. botón atrás/home).
  final Widget? leading;

  /// Acciones opcionales a la derecha (antes de los botones de ventana).
  final List<Widget>? actions;

  /// Traductor de la app para los tooltips de los botones de ventana.
  final String Function(String key, {String? fallback}) getText;

  const AppTitleBar({
    super.key,
    required this.title,
    required this.getText,
    this.tintColor,
    required this.windowBackgroundColor,
    this.leading,
    this.actions,
  });

  /// true si la app dibuja sus propios botones de ventana.
  /// En macOS los pone el sistema (traffic lights).
  bool get _showWindowButtons => !Platform.isMacOS;

  /// Espacio a la izquierda para los traffic lights nativos de macOS.
  double get _macTrafficLightInset => Platform.isMacOS ? 78 : 0;

  @override
  Widget build(BuildContext context) {
    // Contraste: si hay tint, el color de primer plano se calcula contra él;
    // si no, contra el color de fondo real de la ventana.
    final background = tintColor ?? windowBackgroundColor;
    final fg = readableTextColorFor(background);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: tintColor ?? Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: fg.withOpacity(0.12),
              width: 0.5,
            ),
          ),
        ),
        child: IconTheme(
          data: IconThemeData(color: fg),
          child: Row(
            children: [
              // Espacio para traffic lights nativos en macOS
              if (_macTrafficLightInset > 0)
                SizedBox(width: _macTrafficLightInset),
              if (leading != null) ...[
                leading!,
                const SizedBox(width: 8),
              ],
              // Título
              DefaultTextStyle(
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
                child: title,
              ),
              const Spacer(),
              if (actions != null) ...actions!,
              if (_showWindowButtons) ...[
                IconButton(
                  tooltip: getText('minimize', fallback: 'Minimize'),
                  icon: const Icon(Icons.remove, size: 18),
                  onPressed: () => windowManager.minimize(),
                ),
                IconButton(
                  tooltip: getText('maximize', fallback: 'Maximize'),
                  icon: const Icon(Icons.crop_square, size: 18),
                  onPressed: () async {
                    final isMax = await windowManager.isMaximized();
                    if (isMax) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                  },
                ),
                IconButton(
                  tooltip: getText('close', fallback: 'Close'),
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => windowManager.close(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
