import 'dart:async';
import 'package:flutter/material.dart';


class HomeContent extends StatefulWidget {
  final String Function(String key, {String? fallback}) getText;
  final List<String> recentScreens;
  final Function(String) onNavigate;

  const HomeContent({
    super.key,
    required this.getText,
    this.recentScreens = const [],
    required this.onNavigate,
  });

  @override
  State<HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends State<HomeContent> {
  DateTime _now = DateTime.now();
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  String _getGreeting() {
    final hour = _now.hour;
    if (hour >= 5 && hour < 12) {
      return widget.getText('greeting_morning', fallback: 'Buenos días');
    } else if (hour >= 12 && hour < 19) {
      return widget.getText('greeting_afternoon', fallback: 'Buenas tardes');
    } else {
      return widget.getText('greeting_night', fallback: 'Buenas noches');
    }
  }

  IconData _getGreetingIcon() {
    final hour = _now.hour;
    if (hour >= 5 && hour < 12) {
      return Icons.wb_sunny; // Morning
    } else if (hour >= 12 && hour < 19) {
      return Icons.wb_sunny_outlined; // Afternoon
    } else {
      return Icons.nightlight_round; // Night
    }
  }

  String _getWeekday() {
    final weekdays = [
      widget.getText('monday', fallback: 'Lunes'),
      widget.getText('tuesday', fallback: 'Martes'),
      widget.getText('wednesday', fallback: 'Miércoles'),
      widget.getText('thursday', fallback: 'Jueves'),
      widget.getText('friday', fallback: 'Viernes'),
      widget.getText('saturday', fallback: 'Sábado'),
      widget.getText('sunday', fallback: 'Domingo'),
    ];
    return weekdays[_now.weekday - 1];
  }

  String _getMonth() {
    final months = [
      widget.getText('january', fallback: 'Enero'),
      widget.getText('february', fallback: 'Febrero'),
      widget.getText('march', fallback: 'Marzo'),
      widget.getText('april', fallback: 'Abril'),
      widget.getText('may', fallback: 'Mayo'),
      widget.getText('june', fallback: 'Junio'),
      widget.getText('july', fallback: 'Julio'),
      widget.getText('august', fallback: 'Agosto'),
      widget.getText('september', fallback: 'Septiembre'),
      widget.getText('october', fallback: 'Octubre'),
      widget.getText('november', fallback: 'Noviembre'),
      widget.getText('december', fallback: 'Diciembre'),
    ];
    return months[_now.month - 1];
  }

  /// Botones de la sección principal, en el MISMO orden y con los MISMOS
  /// iconos que forawn_mobile: video = video_collection, música =
  /// library_music, reproductor = play_circle_fill.
  List<Map<String, Object?>> get _mainButtons => [
    {
      'id': 'video',
      'icon': Icons.video_collection,
      'color': Colors.blueAccent,
      'label': widget.getText('vid_title', fallback: 'Video'),
    },
    {
      'id': 'music',
      'icon': Icons.library_music,
      'color': Colors.purpleAccent,
      'label': widget.getText('download_button', fallback: 'Música'),
    },
    {
      'id': 'player',
      'icon': Icons.play_circle_fill,
      'color': Colors.purpleAccent,
      'label': widget.getText('music_player_title', fallback: 'Reproductor'),
    },
  ];

  /// Botones de acceso rápido: traductor y QR (igual que forawn_mobile; el
  /// descargador de video vive ahora en la sección principal).
  List<Map<String, Object?>> get _quickButtons => [
    {
      'id': 'translate',
      'icon': Icons.translate,
      'color': Colors.greenAccent,
      'label': widget.getText('translate_title', fallback: 'Traductor'),
    },
    {
      'id': 'qr',
      'icon': Icons.qr_code,
      'color': Colors.orangeAccent,
      'label': widget.getText('qr_title', fallback: 'Generador QR'),
    },
  ];

  /// Card de navegación con el estilo de forawn_mobile.
  Widget _buildNavCard(Map<String, Object?> item) {
    return InkWell(
      onTap: () => widget.onNavigate(item['id'] as String),
      borderRadius: BorderRadius.circular(12),
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          // Mismo color de card que forawn_mobile.
          color: const Color.fromARGB(255, 45, 45, 45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(item['icon'] as IconData, size: 32, color: item['color'] as Color?),
            const SizedBox(height: 12),
            Text(
              item['label'] as String,
              // En forawn_mobile el título usa el mismo color del icono.
              style: TextStyle(
                color: item['color'] as Color?,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final timeStr =
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    final dateStr =
        '${_getWeekday()}, ${_now.day} - ${_getMonth()} - ${_now.year}';
    final greeting = _getGreeting();
    final greetingIcon = _getGreetingIcon();

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(40.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Greeting and Clock Area (Top)
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(greetingIcon, size: 24, color: Colors.amber),
                          const SizedBox(width: 12),
                          Text(
                            greeting,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        dateStr,
                        style: TextStyle(
                          fontSize: 16,
                          color: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.color?.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    timeStr,
                    style: const TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      height: 1,
                      letterSpacing: -1,
                    ),
                  ),
                ],
              ),              const SizedBox(height: 60),

              // Accesos a las screens hardcodeados, organizados en dos
              // secciones como en forawn_mobile (Android).
              Text(
                widget.getText('main_sections', fallback: 'Main Sections'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.color?.withOpacity(0.9),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _buildNavCard(_mainButtons[0])),
                  const SizedBox(width: 16),
                  Expanded(child: _buildNavCard(_mainButtons[1])),
                ],
              ),
              const SizedBox(height: 16),
              // Segunda fila de la sección principal: Reproductor (igual que
              // la fila "Local music" de forawn_mobile).
              Row(
                children: [
                  Expanded(child: _buildNavCard(_mainButtons[2])),
                ],
              ),

              const SizedBox(height: 24),

              Text(
                widget.getText('quick_access', fallback: 'Quick Access'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.color?.withOpacity(0.9),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _buildNavCard(_quickButtons[0])),
                  const SizedBox(width: 16),
                  Expanded(child: _buildNavCard(_quickButtons[1])),
                ],
              ),
            ],
          ),
        ),

      ],
    );
  }


}
