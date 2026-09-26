// settings.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart' show checkForUpdate;
import 'widgets/elegant_notification.dart';
import 'services/discord_service.dart';
import 'services/lyrics_service.dart';
import 'services/local_music_database.dart';
import 'services/global_theme_service.dart';
import 'services/global_music_player.dart';
import 'services/window_effects_service.dart';
import 'package:forawn/version.dart';

typedef TextGetter = String Function(String key, {String? fallback});
typedef LanguageSelector = Future<void> Function(String code);
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

  /// Aplica un efecto de ventana por CLAVE ('solid', 'acrylic', 'mica', ...).
  /// La validación por OS y la persistencia las hace WindowEffectsService.
  final Future<void> Function(String effectKey, Color color, {bool dark})
  onChangeWindowEffect;

  /// Volver a home. En modo screen (IndexedStack) lo invoca el botón back
  /// de la AppTitleBar; si es null, el back usa Navigator.pop (modo diálogo).
  final VoidCallback? onBack;

  const SettingsScreen({
    super.key,
    required this.currentLang,
    required this.getText,
    required this.onSelectLanguage,
    required this.onChangeWindowEffect,
    this.onBack,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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
  double _crossfadeDuration = 0.0;
  static const _crossfadeKey = 'crossfade_duration';

  bool _langMenuOpen = false;
  bool _langHovered = false;
  bool _effectMenuOpen = false;
  bool _effectHovered = false;

  // Visual prefs state (validado POR OS vía WindowEffectsService)
  String _selectedEffectLabel = 'solid';
  String _currentEffectKey = 'solid';
  Color _selectedColor = const Color(0xFF222222);
  bool _darkMode = true;

  /// Opciones de efecto que soporta el OS actual (no las de otro OS).
  List<WindowEffectOption> _effectOptions = const [];

  /// Nota explicativa según OS (Win10 lag, Linux compositor) o null.
  ({String key, String fallback})? _effectNote;

  @override
  void initState() {
    super.initState();
    _selectedLang = widget.currentLang;
    _init();
  }

  Future<void> _init() async {
    _loadPrefs();
    await _loadVisualPrefs();
  }

  Future<void> _loadVisualPrefs() async {
    await Future.delayed(const Duration(milliseconds: 300));
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    // Efectos disponibles EN ESTE OS + validación del persistido.
    final svc = WindowEffectsService.instance;
    final options = svc.availableEffects;
    final effective = await svc.loadPersistedOption();
    final colorValue = prefs.getInt(_prefColorKey) ?? kDefaultWindowColor.value;
    final dark = prefs.getBool(_prefDarkKey) ?? true;

    if (mounted) {
      setState(() {
        _effectOptions = options;
        _effectNote = svc.noteForPlatform;
        _selectedEffectLabel = effective.key;
        _currentEffectKey = effective.key;
        _selectedColor = Color(colorValue);
        _darkMode = dark;
      });
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
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final savedLang = _prefs!.getString(_preferredLangKey);
      final discordEnabled = _prefs!.getBool(_discordEnabledKey) ?? false;
      final blurBg = _prefs!.getBool('use_blur_background') ?? false;
      final crossfade =
          (_prefs!.getDouble(_crossfadeKey) ?? 0.0).clamp(0.0, 12.0);

      if (!mounted) return;
      setState(() {
        _discordEnabled = discordEnabled;
        _discordConnected = DiscordService().isConnected;
        _useBlurBackground = blurBg;
        _crossfadeDuration = crossfade;
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

    await widget.onChangeWindowEffect(label, color, dark: _darkMode);
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


  Future<void> _showLanguageMenu(
    BuildContext context,
    RenderBox renderBox,
  ) async {
    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    // Estilo unificado de menús: mismo color/radio/elevación que el resto
    // de context menus y dropdowns de la app.
    const cardBackgroundColor = Color(0xFF2C2C2E);
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
          .map(
            (e) => PopupMenuItem<String>(
              value: e.key,
              child: Text(
                e.value,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          )
          .toList(),
      color: cardBackgroundColor,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    );

    setState(() {
      _langMenuOpen = false;
      _langHovered = false;
    });

    if (selected != null) {
      _selectLanguage(selected);
    }
  }

  /// Menú de efectos de ventana (solo los soportados por el OS actual).
  Future<void> _showEffectMenu(
    BuildContext context,
    RenderBox renderBox,
  ) async {
    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    const cardBackgroundColor = Color(0xFF2C2C2E);
    setState(() => _effectMenuOpen = true);

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx,
        offset.dy + size.height,
        offset.dx + size.width,
        offset.dy,
      ),
      items: _effectOptions
          .map(
            (o) => PopupMenuItem<String>(
              value: o.key,
              child: Row(
                children: [
                  if (o.key == _currentEffectKey)
                    const Icon(Icons.check, color: Colors.white70, size: 18)
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 8),
                  Text(
                    widget.getText(
                      'effect_${o.key}',
                      fallback: o.fallback,
                    ),
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          )
          .toList(),
      color: cardBackgroundColor,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    );

    setState(() => _effectMenuOpen = false);

    if (selected != null) {
      await _applyEffect(selected, _selectedColor);
    }
  }

  /// Diálogo simple de color: presets del servicio + colores extra.
  Future<Color?> _showColorPicker() async {
    final extra = const [
      Colors.white,
      Colors.black,
      Colors.red,
      Colors.green,
      Colors.blue,
      Colors.purple,
      Colors.orange,
      Colors.teal,
    ];
    final base = WindowEffectsService.instance.colorPresets;
    final choices = <Color>[...base, ...extra.map((c) => c.withValues(alpha: 0.8))];

    return showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text(
          widget.getText('pick_color', fallback: 'Pick color'),
          style: const TextStyle(color: Colors.white),
        ),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: choices
              .map(
                (c) => MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => Navigator.of(ctx).pop(c),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final get = widget.getText;
    final currentTheme = Theme.of(context);

    // If using solid effect, we want transparency to be the theme background color
    // But if using acrylic, we want simple transparency.
    // We stick to transparent scaffold for maximum compatibility with window effects.

    return Scaffold(
      backgroundColor: Colors.transparent,
      // La title bar la dibuja el shell de la app (main.dart) — este screen
      // solo aporta el contenido, igual que el resto de screens cacheadas.
      body: SafeArea(
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
                              leadingColor: Colors.green,
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
                          leadingColor: Colors.blueAccent,
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
                          leadingIcon: Icons.info_outline,
                          leadingColor: Colors.blueAccent,
                          title: get('version_title', fallback: 'Version'),
                          subtitle:
                              '${get('version_subtitle', fallback: 'Current: ')} $currentVersion',
                          trailing: const SizedBox(),
                        ),
                      ],
                    ),

                    // ESTILO DE VENTANA (por OS)
                    if (_effectOptions.isNotEmpty) ...[
                      _SettingsSection(
                        title: widget.getText('window_style', fallback: 'Window style'),
                        children: [
                          // Selector de efecto: SOLO los soportados por el
                          // OS actual (validado por WindowEffectsService).
                          Builder(
                            builder: (ctx) {
                              final selected = _effectOptions.firstWhere(
                                (o) => o.key == _currentEffectKey,
                                orElse: () => _effectOptions.first,
                              );
                              return _SettingsTile(
                                leadingIcon: Icons.format_paint,
                                leadingColor: Colors.deepPurpleAccent,
                                title: widget.getText(
                                  'window_style',
                                  fallback: 'Window style',
                                ),
                                subtitle: widget.getText(
                                  selected.labelKey,
                                  fallback: selected.fallback,
                                ),
                                trailing: Row(
                                  children: [
                                    Text(
                                      widget.getText(
                                        selected.labelKey,
                                        fallback: selected.fallback,
                                      ),
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
                                // Tile con acción real → cursor de mano.
                                onTap: () {
                                  final rb =
                                      ctx.findRenderObject() as RenderBox?;
                                  if (rb != null) _showEffectMenu(ctx, rb);
                                },
                              );
                            },
                          ),
                          Divider(
                            height: 1,
                            color: currentTheme.dividerColor,
                          ),
                          // Color del efecto (presets + picker).
                          _SettingsTile(
                            leadingIcon: Icons.colorize,
                            leadingColor: Colors.pinkAccent,
                            title: widget.getText('window_color', fallback: 'Color'),
                            subtitle: widget.getText(
                              'choose_color',
                              fallback: 'Choose color',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ...WindowEffectsService.instance.colorPresets
                                    .take(4)
                                    .map(
                                      (c) => GestureDetector(
                                        onTap: () => _applyEffect(
                                          _currentEffectKey,
                                          c,
                                        ),
                                        child: Container(
                                          width: 22,
                                          height: 22,
                                          margin: const EdgeInsets.only(
                                            left: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: c,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white24,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                IconButton(
                                  tooltip: widget.getText(
                                    'pick_color',
                                    fallback: 'Pick color',
                                  ),
                                  icon: const Icon(Icons.palette, size: 20),
                                  onPressed: () async {
                                    final picked = await _showColorPicker();
                                    if (picked != null) {
                                      await _applyEffect(
                                        _currentEffectKey,
                                        picked,
                                      );
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                          Divider(
                            height: 1,
                            color: currentTheme.dividerColor,
                          ),
                          // Modo oscuro (afecta la vibrancy del efecto).
                          _SettingsTile(
                            leadingIcon: Icons.dark_mode,
                            leadingColor: Colors.indigoAccent,
                            title: widget.getText('dark_mode', fallback: 'Dark mode'),
                            subtitle: widget.getText(
                              'window_dark_sub',
                              fallback: 'Vibrancy tone of the window effect',
                            ),
                            trailing: Switch(
                              value: _darkMode,
                              onChanged: (v) {
                                setState(() => _darkMode = v);
                                _applyEffect(_currentEffectKey, _selectedColor);
                              },
                            ),
                          ),
                          if (_effectNote != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.info_outline,
                                    size: 14,
                                    color: currentTheme.hintColor,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      widget.getText(
                                        _effectNote!.key,
                                        fallback: _effectNote!.fallback,
                                      ),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: currentTheme.hintColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],

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
                          leadingIcon: Icons.graphic_eq,
                          leadingColor: Colors.tealAccent,
                          title: get('crossfade', fallback: 'Crossfade'),
                          subtitle: get(
                            'crossfade_sub',
                            fallback:
                                'Transición suave entre canciones al terminar',
                          ),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _crossfadeDuration > 0
                                  ? Colors.tealAccent.withOpacity(0.15)
                                  : Colors.white.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _crossfadeDuration == 0
                                  ? 'Off'
                                  : '${_crossfadeDuration.toStringAsFixed(0)}s',
                              style: TextStyle(
                                color: _crossfadeDuration > 0
                                    ? Colors.tealAccent
                                    : Colors.white.withOpacity(0.5),
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                        // Slider de duración (estilo forawn_mobile: 0-12s).
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Row(
                            children: [
                              Text(
                                '0s',
                                style: currentTheme.textTheme.bodySmall?.copyWith(
                                  color: currentTheme.hintColor,
                                ),
                              ),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    activeTrackColor: Colors.tealAccent,
                                    inactiveTrackColor: Colors.tealAccent
                                        .withOpacity(0.15),
                                    trackHeight: 4.0,
                                    thumbColor: Colors.tealAccent,
                                    thumbShape:
                                        const RoundSliderThumbShape(
                                            enabledThumbRadius: 6.0),
                                    overlayColor:
                                        Colors.tealAccent.withOpacity(0.1),
                                    overlayShape:
                                        const RoundSliderOverlayShape(
                                            overlayRadius: 12.0),
                                    tickMarkShape:
                                        SliderTickMarkShape.noTickMark,
                                  ),
                                  child: Slider(
                                    value: _crossfadeDuration,
                                    min: 0,
                                    max: 12,
                                    divisions: 12,
                                    label: _crossfadeDuration == 0
                                        ? 'Off'
                                        : '${_crossfadeDuration.toStringAsFixed(0)}s',
                                    onChanged: (value) {
                                      setState(
                                          () => _crossfadeDuration = value);
                                    },
                                    onChangeEnd: (value) async {
                                      try {
                                        final prefs = _prefs ??
                                            await SharedPreferences.getInstance();
                                        _prefs = prefs;
                                        await prefs.setDouble(
                                            _crossfadeKey, value);
                                      } catch (_) {}
                                      // Aplicar en caliente al reproductor global.
                                      await GlobalMusicPlayer()
                                          .setCrossfadeDuration(value);
                                    },
                                  ),
                                ),
                              ),
                              Text(
                                '12s',
                                style: currentTheme.textTheme.bodySmall?.copyWith(
                                  color: currentTheme.hintColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: currentTheme.dividerColor),
                        _SettingsTile(
                          leadingIcon: Icons.palette,
                          leadingColor: Colors.purpleAccent,
                          title: get(
                            'reload_missing_colors',
                            fallback: 'Reload Missing Colors',
                          ),
                          subtitle: get(
                            'reload_missing_colors_sub',
                            fallback: 'Reprocess songs without cached colors',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.refresh),
                            onPressed: () {
                              // This will be handled by music_player_screen
                              showElegantNotification(
                                context,
                                get(
                                  'use_player_reload',
                                  fallback:
                                      'Please use the music player menu to reload colors',
                                ),
                                icon: Icons.info,
                                backgroundColor: Colors.blue,
                                textColor: Colors.white,
                              );
                            },
                          ),
                        ),
                        Divider(height: 1, color: currentTheme.dividerColor),
                        _SettingsTile(
                          leadingIcon: Icons.lyrics,
                          leadingColor: Colors.pinkAccent,
                          title: get(
                            'clear_all_lyrics',
                            fallback: 'Clear All Lyrics',
                          ),
                          subtitle: get(
                            'clear_all_lyrics_sub',
                            fallback: 'Delete all downloaded lyrics',
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.pinkAccent,
                            ),
                            onPressed: _clearAllLyrics,
                          ),
                        ),
                      ],
                    ),

                    // STORAGE
                    _SettingsSection(
                      title: get('storage', fallback: 'Storage'),
                      children: [
                        _SettingsTile(
                          leadingIcon: Icons.music_note,
                          leadingColor: Colors.purpleAccent,
                          title: get(
                            'clear_music_database',
                            fallback: 'Clear Music Database',
                          ),
                          subtitle: get(
                            'clear_music_database_sub',
                            fallback: 'Remove all cached metadata and colors',
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.redAccent,
                            ),
                            onPressed: () async {
                              // Clear colors from LocalMusicDatabase
                              await LocalMusicDatabase().clearDatabase();
                              if (mounted) {
                                showElegantNotification(
                                  context,
                                  get(
                                    'cache_cleared',
                                    fallback: 'Database Cleared',
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
                          leadingIcon: Icons.restore,
                          leadingColor: Colors.redAccent,
                          title: get(
                            'reset_app_data',
                            fallback: 'Restablecer datos de la App',
                          ),
                          subtitle: get(
                            'reset_app_data_sub',
                            fallback:
                                'Borra configuraciones y preferencias (requiere reinicio)',
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.restore,
                              color: Colors.redAccent,
                            ),
                            onPressed: _resetAppData,
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

  Future<void> _clearAllLyrics() async {
    // Confirm with user
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text(
          widget.getText(
            'confirm_clear_lyrics',
            fallback: 'Borrar Todas las Lyrics',
          ),
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          widget.getText(
            'confirm_clear_lyrics_desc',
            fallback:
                '¿Estás seguro de que quieres borrar todas las lyrics descargadas?',
          ),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.getText('cancel', fallback: 'Cancelar')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.pinkAccent),
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.getText('delete', fallback: 'Borrar')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final count = await LyricsService().clearAllLyrics();
      if (mounted) {
        showElegantNotification(
          context,
          widget.getText(
            'lyrics_cleared',
            fallback: '$count lyrics eliminadas',
          ),
          backgroundColor: Colors.green,
          textColor: Colors.white,
          icon: Icons.check,
        );
      }
    } catch (e) {
      if (mounted) {
        showElegantNotification(
          context,
          widget.getText('error', fallback: 'Error al borrar lyrics'),
          backgroundColor: Colors.red,
          textColor: Colors.white,
          icon: Icons.error,
        );
      }
    }
  }

  Future<void> _resetAppData() async {
    // Confirm with user
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text(
          widget.getText('confirm_reset_data', fallback: 'Restablecer Datos'),
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          widget.getText(
            'confirm_reset_data_desc',
            fallback:
                'Esta acción borrará todas las configuraciones, historial y preferencias. ¿Estás seguro?',
          ),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.getText('cancel', fallback: 'Cancelar')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.getText('reset', fallback: 'Restablecer')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.clear();

      if (mounted) {
        showElegantNotification(
          context,
          widget.getText(
            'data_reset_success',
            fallback: 'Datos borrados. Reinicia la aplicación.',
          ),
          backgroundColor: Colors.green,
          textColor: Colors.white,
          icon: Icons.check,
          duration: const Duration(seconds: 5),
        );
      }
    } catch (e) {
      if (mounted) {
        showElegantNotification(
          context,
          widget.getText('error', fallback: 'Error al borrar datos'),
          backgroundColor: Colors.red,
          textColor: Colors.white,
          icon: Icons.error,
        );
      }
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
        // Superficie adaptada al efecto de ventana (solid por defecto,
        // overlay translúcido con acrylic/mica activos).
        final containerColor = WindowEffectsService.instance.surface(
          context,
          solid: const Color.fromARGB(255, 45, 45, 45),
          overlay: 0.06,
        );

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
        // El tile entero NO es un botón: el cursor de mano solo aplica si
        // la fila tiene acción (p. ej. idioma); si no, flecha normal.
        mouseCursor: onTap != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Estilo forawn_mobile: icono plano con su color, sin círculo.
              Icon(leadingIcon, color: leadingColor, size: 24),
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
