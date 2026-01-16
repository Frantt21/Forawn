import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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

  String _getScreenName(String id) {
    switch (id) {
      case 'music':
        return widget.getText('download_button', fallback: 'Música');
      case 'video':
        return widget.getText('vid_title', fallback: 'Video');
      case 'images':
        return widget.getText('ai_image_title', fallback: 'Imágenes');
      case 'notes':
        return widget.getText('notes_title', fallback: 'Notas');
      case 'translate':
        return widget.getText('translate_title', fallback: 'Traductor');
      case 'qr':
        return widget.getText('qr_title', fallback: 'Generador QR');
      case 'player':
        return widget.getText('music_player_title', fallback: 'Reproductor');
      default:
        return id;
    }
  }

  IconData _getScreenIcon(String id) {
    switch (id) {
      case 'music':
        return Icons.music_note;
      case 'video':
        return Icons.video_library;
      case 'images':
        return Icons.image;
      case 'notes':
        return Icons.note;
      case 'translate':
        return Icons.translate;
      case 'qr':
        return Icons.qr_code;
      case 'player':
        return Icons.play_circle_fill;
      default:
        return Icons.circle;
    }
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
              ),

              const SizedBox(height: 60),

              // Recent Screens
              if (widget.recentScreens.isNotEmpty) ...[
                Text(
                  widget.getText('recent_screens', fallback: 'Recientes'),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.color?.withOpacity(0.9),
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: widget.recentScreens.map((id) {
                    return InkWell(
                      onTap: () => widget.onNavigate(id),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: 140,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardTheme.color,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _getScreenIcon(id),
                              size: 32,
                              color: Colors.purpleAccent,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _getScreenName(id),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),

        // API Status Button - Bottom Right
        Positioned(right: 20, bottom: 20, child: _buildApiStatusButton()),
      ],
    );
  }

  Widget _buildApiStatusButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () async {
          final uri = Uri.parse('https://www.foranly.space/apis-status');
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.getText('api_status', fallback: 'Estado de APIs'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.color?.withOpacity(0.8),
                  decoration: TextDecoration.underline,
                  decorationColor: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.color?.withOpacity(0.5),
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.open_in_new,
                size: 14,
                color: Theme.of(context).iconTheme.color?.withOpacity(0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
