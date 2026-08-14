import 'package:flutter/material.dart';

/// Ratio de contraste WCAG entre dos colores (1..21).
/// Basado en la luminancia relativa según WCAG 2.x.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

/// Devuelve blanco o negro según el color de fondo, eligiendo el que tenga
/// mayor ratio de contraste WCAG. Garantiza legibilidad sobre fondos claros
/// y oscuros (texto/iconos de la title bar, botones, etc.).
Color readableTextColorFor(Color background) {
  final withWhite = contrastRatio(background, Colors.white);
  final withBlack = contrastRatio(background, Colors.black);
  return withWhite >= withBlack ? Colors.white : Colors.black;
}
