// settings.dart
import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'main.dart' show checkForUpdate;
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'widgets/elegant_notification.dart';
import 'services/discord_service.dart';
import 'services/album_color_cache.dart';
import 'services/lyrics_service.dart';
import 'services/metadata_service.dart';
import 'services/global_theme_service.dart';
import 'package:path/path.dart' as p;
import 'package:audio_metadata_reader/audio_metadata_reader.dart';

typedef TextGetter = String Function(String key, {String? fallback});
typedef LanguageSelector = Future<void> Function(String code);
const String _prefEffectKey = 'window_effect';
const String _prefColorKey = 'window_color';
const String _prefDarkKey = 'window_dark';

extension StringCapitalization on String {
  String capitalize() {
    if (isEmpty) return this;
    return this[0].toUpperCase() + substring(1);
  }
}

class SettingsScreen extends StatefulWidget {
  final String currentLang;
  final TextGetter getText;
  final LanguageSelector onSelectLanguage;
  final Future<void> Function(
    acrylic.WindowEffect effect,
    Color color, {
    bool dark,
  })
  onChangeWindowEffect;

  const SettingsScreen({
    super.key,
    required this.currentLang,
    required this.getText,
    required this.onSelectLanguage,
    required this.onChangeWindowEffect,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WindowListener {
  final Map<String, String> languages = {
    'es': 'Español',
    'en': 'English',
    'ru': 'Русский',
    'pl': 'Polski',
    'de-CH': 'Deutsch (CH)',
    'zh': '中文',
    'ja': '日本語',
    'ko': '한국어',
    'pt': 'Português',
    'fr': 'Français',
  };

  String? _saving;
  bool _nsfw = false;
  static const _nsfwKey = 'nsfw_enabled';
  static const _preferredLangKey = 'preferred_lang';
  String? _selectedLang;
  SharedPreferences? _prefs;

  // Discord
  bool _discordEnabled = false;
  bool _discordConnected = false;
  bool _discordConnecting = false;
  static const _discordEnabledKey = 'discord_enabled';

  // Player Prefs
  bool _useBlurBackground = false;
  bool _autoUpdateColors = false;

  bool _langMenuOpen = false;
  bool _langHovered = false;
  bool _effectMenuOpen = false;
  bool _effectHovered = false;

  // Visual prefs state
  String _selectedEffectLabel = 'solid';
  String _currentEffectKey = 'solid';
  Color _selectedColor = const Color(0xFF222222);
  bool _darkMode = true;

  bool _isWindows11 = false;

  final Map<String, acrylic.WindowEffect> effects = {
    'acrylic': acrylic.WindowEffect.acrylic,
    'mica': acrylic.WindowEffect.mica,
    'solid': acrylic.WindowEffect.solid,
    'transparent': acrylic.WindowEffect.transparent,
  };

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _selectedLang = widget.currentLang;
    _init();
  }

  Future<void> _init() async {
    await _detectWindows11();
    _loadPrefs();
    await _loadVisualPrefs();
  }

  Future<void> _detectWindows11() async {
    if (!Platform.isWindows) return;
    try {
      final proc = await Process.start('powershell', [
        '-NoProfile',
        '-Command',
        r'(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuild',
      ]);
      final output = await proc.stdout.transform(const Utf8Decoder()).join();
      final build = int.tryParse(output.trim()) ?? 0;
      if (mounted) setState(() => _isWindows11 = build >= 22000);
    } catch (_) {}
  }

  Future<void> _loadVisualPrefs() async {
    await Future.delayed(const Duration(milliseconds: 300));
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    final effectName = prefs.getString(_prefEffectKey) ?? 'solid';
    final colorValue = prefs.getInt(_prefColorKey) ?? 0xFF222222;
    final dark = prefs.getBool(_prefDarkKey) ?? true;

    String finalEffectLabel = effectName;
    if (!_isWindows11) finalEffectLabel = 'solid';
    if (!effects.containsKey(finalEffectLabel)) finalEffectLabel = 'solid';

    if (mounted) {
      setState(() {
        _selectedEffectLabel = finalEffectLabel;
        _currentEffectKey = finalEffectLabel;
        _selectedColor = Color(colorValue);
        _darkMode = dark;
      });
    }

    if (!_isWindows11 && effectName != 'solid') {
      if (mounted) await _applyEffect('solid', _selectedColor);
    }
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentLang != widget.currentLang) {
      setState(() => _selectedLang = widget.currentLang);
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final enabled = _prefs!.getBool(_nsfwKey) ?? false;
      final savedLang = _prefs!.getString(_preferredLangKey);
      final discordEnabled = _prefs!.getBool(_discordEnabledKey) ?? false;
      final blurBg = _prefs!.getBool('use_blur_background') ?? false;
      final autoUpdate = await AlbumColorCache().getAutoUpdateOnStartup();

      if (!mounted) return;
      setState(() {
        _nsfw = enabled;
        _discordEnabled = discordEnabled;
        _discordConnected = DiscordService().isConnected;
        _useBlurBackground = blurBg;
        _autoUpdateColors = autoUpdate;
        if (savedLang != null && savedLang.isNotEmpty) {
          _selectedLang = savedLang;
        }
      });
    } catch (_) {}
  }

  Future<void> _applyEffect(String label, Color color) async {
    setState(() {
      _selectedEffectLabel = label;
      _currentEffectKey = label;
      _selectedColor = color;
    });

    final effect = effects[label] ?? acrylic.WindowEffect.solid;
    await widget.onChangeWindowEffect(effect, color, dark: _darkMode);
  }

  Future<void> _toggleNsfw(bool value) async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setBool(_nsfwKey, value);
      if (!mounted) return;
      setState(() => _nsfw = value);
    } catch (_) {}
  }

  Future<void> _toggleDiscord(bool value) async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setBool(_discordEnabledKey, value);

      if (value) {
        setState(() => _discordConnecting = true);
        final success = await DiscordService().initialize();
        if (!mounted) return;
        setState(() {
          _discordEnabled = value;
          _discordConnected = success;
          _discordConnecting = false;
        });
      } else {
        await DiscordService().dispose();
        if (!mounted) return;
        setState(() {
          _discordEnabled = value;
          _discordConnected = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _discordConnecting = false);
    }
  }

  Future<void> _selectLanguage(String code) async {
    if (_saving != null) return;
    setState(() {
      _saving = code;
      _selectedLang = code;
    });

    try {
      await widget.onSelectLanguage(code);
    } catch (e) {
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  Future<void> _minimize() async => await windowManager.minimize();
  Future<void> _maximizeRestore() async {
    final isMax = await windowManager.isMaximized();
    if (isMax) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> _showLanguageMenu(
    BuildContext context,
    RenderBox renderBox,
  ) async {
    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    const cardBackgroundColor = Color(0xFF1C1C1E);
    setState(() {
      _langMenuOpen = true;
      _langHovered = true;
    });

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx,
        offset.dy + size.height,
        offset.dx + size.width,
        offset.dy,
      ),
      items: languages.entries
          .map((e) => PopupMenuItem<String>(value: e.key, child: Text(e.value)))
          .toList(),
      color: cardBackgroundColor,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );

    setState(() {
      _langMenuOpen = false;
      _langHovered = false;
    });

    if (selected != null) {
      _selectLanguage(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final get = widget.getText;
    final theme = Theme.of(context).copyWith(
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,
    );
    final currentTheme = Theme.of(context);

    // If using solid effect, we want transparency to be the theme background color
    // But if using acrylic, we want simple transparency.
    // We stick to transparent scaffold for maximum compatibility with window effects.

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // HEADER
          Theme(
            data: theme,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                color: Colors.transparent,
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          color: Colors.black26,
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.settings,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        get('setting_tittle', fallback: 'Settings'),
                        style: currentTheme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: get('minimize', fallback: 'Minimize'),
                      icon: const Icon(Icons.remove, size: 18),
                      onPressed: _minimize,
                    ),
                    IconButton(
                      tooltip: get('maximize', fallback: 'Maximize'),
                      icon: const Icon(Icons.crop_square, size: 18),
                      onPressed: _maximizeRestore,
                    ),
                    IconButton(
                      tooltip: get('back', fallback: 'Back'),
                      icon: const Icon(Icons.arrow_back, size: 18),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // CONTENT
          Expanded(
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    // GENERAL
                    _SettingsSection(
                      title: get('general', fallback: 'General'),
                      children: [
                        Builder(
                          builder: (ctx) {
                            return _SettingsTile(
                              leadingIcon: Icons.language,
                              leadingColor: Colors.blueAccent,
                              title: get('language', fallback: 'Language'),
                              subtitle: get(
                                'language_subtitle',
                                fallback: 'Choose your preferred language',
                              ),
                              trailing: Row(
                                children: [
                                  Text(
                                    languages[_selectedLang] ??
                                        _selectedLang ??
                                        'English',
                                    style: TextStyle(
                                      color: currentTheme.hintColor,
                                    ),
                                  ),
                                  Icon(
                                    Icons.arrow_drop_down,
                                    color: currentTheme.hintColor,
                                  ),
                                ],
                              ),
                              onTap: () {
                                final rb = ctx.findRenderObject() as RenderBox?;
                                if (rb != null) _showLanguageMenu(ctx, rb);
                              },
                            );
                          },
                        ),
                        Divider(height: 1, color: currentTheme.dividerColor),
                        _SettingsTile(
                          leadingIcon: Icons.system_update,
                          leadingColor: Colors.greenAccent,
                          title: get(
                            'check_update',
                            fallback: 'Check for updates',
                          ),
                          subtitle: get(
                            'click_to_check',
                            fallback: 'Click to check for new versions',
                          ),
                          trailing: IconButton(
                            icon: Icon(
                              Icons.chevron_right,
                              color: currentTheme.hintColor,
                            ),
                            onPressed: () => checkForUpdate(context, get),
                          ),
                        ),
                        Divider(height: 1, color: currentTheme.dividerColor),
                        _SettingsTile(
                          leadingIcon: Icons.explicit,
                          leadingColor: Colors.redAccent,
                          title: get('nsfw_toggle', fallback: 'NSFW Content'),
                          subtitle: get(
                            'nsfw_desc',
                            fallback: 'Show adult content',
                          ),
                          trailing: Switch(
                            value: _nsfw,
                            onChanged: _toggleNsfw,
                            activeColor: Colors.redAccent,
                          ),
                        ),
                      ],
                    ),

                    // PERSONALIZATION SECTION REMOVED

                    // MUSIC PLAYER
                    _SettingsSection(
                      title: get('music_player', fallback: 'Music Player'),
                      children: [
                        _SettingsTile(
                          leadingIcon: Icons.blur_on,
                          leadingColor: Colors.tealAccent,
                          title: get(
                            'blur_bg_title',
                            fallback: 'Blurred Background',
                          ),
                          subtitle: get(
                            'blur_bg_sub',
                            fallback: 'Show blurred album art behind player',
                          ),
                          trailing: Switch(
                            value: _useBlurBackground,
                            onChanged: _toggleBlurBackground,
                            activeColor: Colors.purpleAccent,
                          ),
                        ),
                        Divider(height: 1, color: currentTheme.dividerColor),
                        _SettingsTile(
                          leadingIcon: Icons.colorize,
                          leadingColor: Colors.amberAccent,
                          title: get(
                            'auto_color_title',
                            fallback: 'Auto-update Colors',
                          ),
                          subtitle: get(
                            'auto_color_sub',
                            fallback: 'Extract colors on startup',
                          ),
                          trailing: Switch(
                            value: _autoUpdateColors,
                            onChanged: _toggleAutoUpdate,
                            activeColor: Colors.purpleAccent,
                          ),
                        ),
                        Divider(height: 1, color: currentTheme.dividerColor),
                        _SettingsTile(
                          leadingIcon: Icons.lyrics,
                          leadingColor: Colors.pinkAccent,
                          title: get(
                            'download_lyrics',
                            fallback: 'Missing Lyrics',
                          ),
                          subtitle: get(
                            'download_lyrics_sub',
                            fallback: 'Download for local songs',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.download),
                            onPressed: _downloadMissingLyrics,
                          ),
                        ),
                      ],
                    ),

                    // STORAGE
                    _SettingsSection(
                      title: get('storage', fallback: 'Storage'),
                      children: [
                        _SettingsTile(
                          leadingIcon: Icons.cleaning_services,
                          leadingColor: Colors.redAccent,
                          title: get(
                            'clear_cache_color',
                            fallback: 'Clear Color Cache',
                          ),
                          subtitle: get(
                            'clear_cache_color_sub',
                            fallback: 'Remove saved palette data',
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.redAccent,
                            ),
                            onPressed: () async {
                              await AlbumColorCache().clearCache();
                              if (mounted) {
                                showElegantNotification(
                                  context,
                                  get(
                                    'cache_cleared',
                                    fallback: 'Color Cache Cleared',
                                  ),
                                  backgroundColor: Colors.green,
                                  textColor: Colors.white,
                                  icon: Icons.check,
                                );
                              }
                            },
                          ),
                        ),
                        Divider(height: 1, color: currentTheme.dividerColor),
                        _SettingsTile(
                          leadingIcon: Icons.storage,
                          leadingColor: Colors.orangeAccent,
                          title: get(
                            'clear_cache_meta',
                            fallback: 'Clear Metadata Cache',
                          ),
                          subtitle: get(
                            'clear_cache_meta_sub',
                            fallback: 'Remove Spotify/Server cache',
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.orangeAccent,
                            ),
                            onPressed: () async {
                              MetadataService().clearCache();
                              await MetadataService().clearServerCache();
                              if (mounted) {
                                showElegantNotification(
                                  context,
                                  get(
                                    'spotify_cache_cleared',
                                    fallback: 'Metadata Cache Cleared',
                                  ),
                                  backgroundColor: Colors.green,
                                  textColor: Colors.white,
                                  icon: Icons.check,
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),

                    // INTEGRATION
                    _SettingsSection(
                      title: get('integrations', fallback: 'Integrations'),
                      children: [
                        _SettingsTile(
                          leadingIcon: Icons.discord,
                          leadingColor: const Color(0xFF5865F2),
                          title: 'Discord RPC',
                          subtitle: _discordConnected
                              ? get('discord_on', fallback: 'Connected')
                              : get('discord_off', fallback: 'Disconnected'),
                          trailing: Switch(
                            value: _discordEnabled,
                            onChanged: (v) => _toggleDiscord(v),
                            activeColor: const Color(0xFF5865F2),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 48),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // LOGIC METHODS (COPIED AND PRESERVED)
  Future<void> _toggleBlurBackground(bool value) async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setBool('use_blur_background', value);
      GlobalThemeService().blurBackground.value = value;
      if (!mounted) return;
      setState(() => _useBlurBackground = value);
    } catch (_) {}
  }

  Future<void> _toggleAutoUpdate(bool value) async {
    await AlbumColorCache().setAutoUpdateOnStartup(value);
    if (!mounted) return;
    setState(() => _autoUpdateColors = value);
  }

  Future<List<File>> _getMusicFiles() async {
    _prefs ??= await SharedPreferences.getInstance();
    final folder = _prefs!.getString('download_folder');
    if (folder == null || folder.isEmpty) return [];

    final dir = Directory(folder);
    if (!await dir.exists()) return [];

    final validExt = {'.mp3', '.m4a', '.flac', '.wav', '.ogg'};
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => validExt.contains(p.extension(f.path).toLowerCase()))
        .toList();
  }

  Future<void> _downloadMissingLyrics() async {
    final files = await _getMusicFiles();
    if (files.isEmpty) {
      if (mounted) {
        showElegantNotification(
          context,
          widget.getText('no_files', fallback: 'No music files found'),
          backgroundColor: Colors.orange,
          textColor: Colors.white,
          icon: Icons.warning,
        );
      }
      return;
    }

    if (!mounted) return;
    _showProgressDialog(
      title: widget.getText('scanning_lyrics', fallback: 'Scanning lyrics'),
      items: files,
      onProcess: (file, counters) async {
        String title = p.basename(file.path);
        String artist = 'Unknown Artist';
        try {
          final metadata = await readMetadata(file, getImage: false);
          if (metadata.title?.isNotEmpty == true) title = metadata.title!;
          if (metadata.artist?.isNotEmpty == true) artist = metadata.artist![0];
        } catch (_) {}

        final saved = await LyricsService().getStoredLyrics(title, artist);
        if (saved == null) {
          final downloaded = await LyricsService().fetchLyrics(title, artist);
          if (downloaded != null)
            counters['added'] = (counters['added'] ?? 0) + 1;
        } else {
          counters['skipped'] = (counters['skipped'] ?? 0) + 1;
        }
      },
    );
  }

  Future<void> _preloadColors() async {
    if (mounted) {
      showElegantNotification(
        context,
        widget.getText(
          'use_player_preload',
          fallback: 'Please use the player to preload colors for now.',
        ),
        icon: Icons.info,
        backgroundColor: Colors.blue,
        textColor: Colors.white,
      );
    }
  }

  Future<void> _showProgressDialog({
    required String title,
    required List<File> items,
    required Future<void> Function(File, Map<String, int>) onProcess,
  }) async {
    final ValueNotifier<int> processed = ValueNotifier(0);
    final Map<String, int> counters = {'added': 0, 'skipped': 0};
    bool cancel = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: ValueListenableBuilder<int>(
          valueListenable: processed,
          builder: (context, value, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: items.isEmpty ? 0 : value / items.length,
                  color: Colors.purpleAccent,
                  backgroundColor: Colors.white10,
                ),
                const SizedBox(height: 16),
                Text(
                  '$value / ${items.length}',
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancel = true;
              Navigator.pop(context);
            },
            child: Text(widget.getText('cancel', fallback: 'Cancel')),
          ),
        ],
      ),
    );

    for (final file in items) {
      if (cancel) break;
      await onProcess(file, counters);
      processed.value++;
      if (processed.value % 5 == 0) await Future.delayed(Duration.zero);
    }

    if (!cancel && mounted && Navigator.canPop(context)) {
      Navigator.pop(context);
      showElegantNotification(
        context,
        'Done. Added: ${counters['added']}, Skipped: ${counters['skipped']}',
        icon: Icons.check,
        backgroundColor: Colors.green,
        textColor: Colors.white,
      );
    }
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeService = GlobalThemeService();

    return ValueListenableBuilder<Color?>(
      valueListenable: themeService.dominantColor,
      builder: (context, dominantColor, _) {
        // Use GlobalThemeService color if available, otherwise use theme's card color
        // Use hardcoded color to match input fields as requested
        const containerColor = Color(0xFF1C1C1E);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12, top: 24),
              child: Text(
                title.toUpperCase(),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: containerColor,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(children: children),
            ),
          ],
        );
      },
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData leadingIcon;
  final Color leadingColor;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsTile({
    super.key,
    required this.leadingIcon,
    required this.leadingColor,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: leadingColor.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(leadingIcon, color: leadingColor, size: 20),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.hintColor,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}
