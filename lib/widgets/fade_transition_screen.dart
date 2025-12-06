import 'package:flutter/material.dart';

class FadeTransitionScreen extends StatelessWidget {
  final Widget child;
  const FadeTransitionScreen({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AnimatedOpacity(
        opacity: 1.0,
        duration: const Duration(milliseconds: 200),
        child: child,
      ),
    );
  }
}
