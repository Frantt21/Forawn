import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Diálogo unificado estilo forawn_mobile para desktop: fondo oscuro con blur,
/// esquinas 24, acciones Cancelar (1/3) + primaria (2/3) tipo bottom sheet.
/// Todos los diálogos de la app (crear/editar playlist, agregar canciones, …)
/// comparten este contenedor para tener exactamente el mismo tamaño y estilo.
class ForawnDialog extends StatelessWidget {
  /// Ancho estándar de todos los diálogos de la app.
  static const double width = 420;

  /// Radio de esquinas estándar.
  static const double radius = 24;

  final String title;
  final List<Widget> children;
  final String cancelLabel;
  final String confirmLabel;

  /// null = cerrar sin acción. El primario se deshabilita si `enabled` es false.
  final VoidCallback? onConfirm;
  final bool confirmEnabled;
  final Color? accentColor;
  final Widget? confirmChild;

  const ForawnDialog({
    super.key,
    required this.title,
    required this.children,
    required this.cancelLabel,
    required this.confirmLabel,
    this.onConfirm,
    this.confirmEnabled = true,
    this.accentColor,
    this.confirmChild,
  });

  static Future<void> show(
    BuildContext context, {
    required String title,
    required List<Widget> children,
    required String cancelLabel,
    required String confirmLabel,
    VoidCallback? onConfirm,
    bool confirmEnabled = true,
    Color? accentColor,
    Widget? confirmChild,
  }) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (_) => ForawnDialog(
        title: title,
        children: children,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
        onConfirm: onConfirm,
        confirmEnabled: confirmEnabled,
        accentColor: accentColor,
        confirmChild: confirmChild,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? Colors.purpleAccent;

    return BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: width,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header + contenido (sin drag handle: esto es un diálogo,
              // no un drag container).
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 20),
                      ...children,
                    ],
                  ),
                ),
              ),

              // Acciones: Cancelar (1) + Primario (2), como forawn_mobile
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: Row(
                  children: [
                    Expanded(
                      flex: 1,
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          cancelLabel,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          disabledBackgroundColor: accent.withOpacity(0.3),
                        ),
                        onPressed: confirmEnabled ? onConfirm : null,
                        child: confirmChild ??
                            Text(
                              confirmLabel,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Input redondeado estándar (fondo blanco 5%, icono opcional) usado dentro
/// de los diálogos forawn.
class ForawnDialogInput extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData? prefixIcon;
  final int maxLines;
  final Color? accentColor;
  final ValueChanged<String>? onChanged;

  const ForawnDialogInput({
    super.key,
    required this.controller,
    required this.hint,
    this.prefixIcon,
    this.maxLines = 1,
    this.accentColor,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? Colors.purpleAccent;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        style: const TextStyle(color: Colors.white, fontSize: 15),
        cursorColor: accent,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 13,
          ),
          border: InputBorder.none,
          prefixIcon: prefixIcon != null
              ? Icon(
                  prefixIcon,
                  color: Colors.white.withOpacity(0.5),
                  size: 20,
                )
              : null,
        ),
      ),
    );
  }
}
