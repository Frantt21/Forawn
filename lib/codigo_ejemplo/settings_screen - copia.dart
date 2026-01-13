import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/version_check_service.dart';
import '../services/language_service.dart';

import '../services/metadata_service.dart';
import '../services/lyrics_service.dart';
import '../services/groq_assistant_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notificationsEnabled = false;
  String _version = 'Cargando...';
  static const String _notificationsKey = 'notifications_enabled';

  @override
  void initState() {
    super.initState();
    _loadNotificationPreference();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      setState(() {
        _version = packageInfo.version;
      });
    } catch (e) {
      print('Error loading version: $e');
      setState(() {
        _version = '1.0.0';
      });
    }
  }

  Future<void> _loadNotificationPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _notificationsEnabled = prefs.getBool(_notificationsKey) ?? false;
      });
    } catch (e) {
      print('Error loading notification preference: $e');
    }
  }

  Future<void> _saveNotificationPreference(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_notificationsKey, value);
    } catch (e) {
      print('Error saving notification preference: $e');
    }
  }

  Future<void> _checkForUpdates() async {
    // Mostrar indicador de carga
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(LanguageService().getText('checking_updates')),
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final result = await VersionCheckService.checkForUpdate();

      if (!mounted) return;

      if (result.hasUpdate) {
        // Hay actualización disponible
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(LanguageService().getText('update_available')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${LanguageService().getText('current_version')}: ${result.currentVersion}',
                ),
                Text(
                  '${LanguageService().getText('new_version')}: ${result.latestVersion}',
                ),
                if (result.releaseNotes != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    LanguageService().getText('release_notes'),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    result.releaseNotes!,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(LanguageService().getText('close')),
              ),
              if (result.downloadUrl != null)
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '${LanguageService().getText('download_update')}: ${result.downloadUrl}',
                        ),
                        duration: const Duration(seconds: 5),
                      ),
                    );
                  },
                  child: Text(LanguageService().getText('download_update')),
                ),
            ],
          ),
        );
      } else {
        // No hay actualización
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(LanguageService().getText('latest_version'))),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${LanguageService().getText('update_check_error')}: $e',
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 34, 34, 34),
      appBar: AppBar(
        title: Text(LanguageService().getText('settings')),
        backgroundColor: const Color.fromARGB(255, 34, 34, 34),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(
          left: 16.0,
          right: 16.0,
          top: 16.0,
          bottom: 100.0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(LanguageService().getText('general')),
            const SizedBox(height: 12),
            _buildSettingCard(
              child: Column(
                children: [
                  // Language Selector
                  ListTile(
                    leading: const Icon(
                      Icons.language,
                      color: Colors.blueAccent,
                    ),
                    title: Text(
                      LanguageService().getText('language'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Text(
                      LanguageService().getText('select_language'),
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    trailing: DropdownButton<String>(
                      value: LanguageService().currentLanguage,
                      dropdownColor: const Color.fromARGB(255, 45, 45, 45),
                      underline: Container(),
                      items: LanguageService.availableLanguages.map((lang) {
                        return DropdownMenuItem(
                          value: lang['code'],
                          child: Text(lang['name']!),
                        );
                      }).toList(),
                      onChanged: (String? newValue) async {
                        if (newValue != null) {
                          await LanguageService().changeLanguage(newValue);
                          setState(() {}); // Rebuild to show new language
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  LanguageService().getText('language_changed'),
                                ),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          }
                        }
                      },
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),

                  // Notifications Switch
                  SwitchListTile(
                    value: _notificationsEnabled,
                    onChanged: (value) async {
                      setState(() {
                        _notificationsEnabled = value;
                      });
                      await _saveNotificationPreference(value);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              value
                                  ? LanguageService().getText(
                                      'notifications_enabled',
                                    )
                                  : LanguageService().getText(
                                      'notifications_disabled',
                                    ),
                            ),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      }
                    },
                    title: Text(
                      LanguageService().getText('notifications'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Text(
                      LanguageService().getText('receive_alerts'),
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    activeThumbColor: Theme.of(context).colorScheme.primary,
                    secondary: Icon(
                      _notificationsEnabled
                          ? Icons.notifications_active
                          : Icons.notifications_off_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _buildSectionTitle(LanguageService().getText('storage')),
            const SizedBox(height: 12),
            _buildSettingCard(
              child: Column(
                children: [
                  const StorageBar(),

                  ListTile(
                    leading: const Icon(
                      Icons.music_note,
                      color: Colors.purpleAccent,
                    ),
                    title: Text(
                      LanguageService().getText('clear_music_cache'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Text(
                      LanguageService().getText('clear_music_cache_desc'),
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_sweep),
                      color: Colors.purpleAccent,
                      onPressed: () async {
                        await MetadataService().clearAllCaches();
                        // Force UI update if needed or notify listeners
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                LanguageService().getText(
                                  'music_cache_cleared',
                                ),
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),

                  ListTile(
                    leading: const Icon(Icons.lyrics, color: Colors.pinkAccent),
                    title: Text(
                      LanguageService().getText('clear_lyrics_cache'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Text(
                      LanguageService().getText('clear_lyrics_cache_desc'),
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_sweep),
                      color: Colors.pinkAccent,
                      onPressed: () async {
                        await LyricsService().clearCache();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                LanguageService().getText(
                                  'lyrics_cache_cleared',
                                ),
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),

                  ListTile(
                    leading: const Icon(Icons.chat, color: Colors.orangeAccent),
                    title: Text(
                      LanguageService().getText('clear_assistant_history'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Text(
                      LanguageService().getText('clear_assistant_history_desc'),
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_sweep),
                      color: Colors.orangeAccent,
                      onPressed: () async {
                        // Limpiar historial del servicio
                        GroqAssistantService().clearHistory();

                        // Limpiar historial de SharedPreferences
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.remove('assistant_chat_history');

                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                LanguageService().getText(
                                  'assistant_history_cleared',
                                ),
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _buildSectionTitle(LanguageService().getText('information')),
            const SizedBox(height: 12),
            _buildSettingCard(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.info_outline,
                      color: Colors.blueAccent,
                    ),
                    title: Text(LanguageService().getText('app_version')),
                    subtitle: Text(_version),
                    trailing: ElevatedButton(
                      onPressed: _checkForUpdates,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary.withOpacity(0.1),
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      child: Text(LanguageService().getText('check_updates')),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _buildSectionTitle(LanguageService().getText('danger_zone')),
            const SizedBox(height: 12),
            _buildSettingCard(
              borderColor: Colors.redAccent.withOpacity(0.3),
              child: ListTile(
                leading: const Icon(Icons.restore, color: Colors.redAccent),
                title: Text(
                  LanguageService().getText('reset_settings'),
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  LanguageService().getText('reset_settings_desc'),
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: _showResetConfirmation,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4.0),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildSettingCard({required Widget child, Color? borderColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color.fromARGB(255, 45, 45, 45),
        borderRadius: BorderRadius.circular(16),
        // border: Border.all(
        //   color: borderColor ?? Colors.white.withOpacity(0.1),
        //   width: 1,
        // ),
      ),
      child: child,
    );
  }

  void _showResetConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color.fromARGB(255, 34, 34, 34),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          // side: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        title: Text(LanguageService().getText('reset_confirmation')),
        content: Text(
          LanguageService().getText('reset_message'),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(LanguageService().getText('cancel')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              setState(() {
                _notificationsEnabled = false;
              });
              await _saveNotificationPreference(false);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(LanguageService().getText('settings_reset')),
                  ),
                );
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(LanguageService().getText('reset')),
          ),
        ],
      ),
    );
  }
}

/// Widget que muestra espacio disponible en disco con barra de progreso horizontal
class StorageBar extends StatefulWidget {
  const StorageBar({super.key});

  @override
  State<StorageBar> createState() => _StorageBarState();
}

class _StorageBarState extends State<StorageBar> {
  static const MethodChannel _channel = MethodChannel('forawn/saf');
  String _free = '...';
  double _percentage = 0.0;

  @override
  void initState() {
    super.initState();
    _fetchFreeSpace();
  }

  Future<void> _fetchFreeSpace() async {
    try {
      final result = await _channel.invokeMethod('getFreeSpace');
      if (result != null) {
        final bytes = result is int
            ? result
            : int.tryParse(result.toString()) ?? 0;
        setState(() {
          _free = _formatBytes(bytes);
          // Simulamos un porcentaje (en producción deberías obtener el total también)
          // Por ahora usamos un valor fijo para la demo
          _percentage = 0.65; // 65% usado como ejemplo
        });
      }
    } catch (e) {
      setState(() {
        _free = 'N/D';
        _percentage = 0.0;
      });
    }
  }

  String _formatBytes(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    final accentColor = theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              LanguageService().getText('storage'),
              style: TextStyle(
                color: textColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '$_free ${LanguageService().getText('storage_available')}',
              style: TextStyle(color: textColor.withOpacity(0.7), fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Barra de progreso
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: _percentage,
            minHeight: 8,
            backgroundColor: theme.colorScheme.onSurface.withOpacity(0.1),
            valueColor: AlwaysStoppedAnimation<Color>(accentColor),
          ),
        ),
      ],
    );
  }
}
