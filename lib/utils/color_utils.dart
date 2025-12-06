import 'package:flutter/material.dart';

Color readableTextColorFor(Color background) {
  final luminance = background.computeLuminance();
  return luminance > 0.5 ? Colors.black : Colors.white;
}
