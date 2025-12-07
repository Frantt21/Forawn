// settings.dart
import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'main.dart' show checkForUpdate;
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'widgets/elegant_notification.dart';

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

  bool _langMenuOpen = false;
  bool _langHovered = false;
  bool _effectMenuOpen = false;
  bool _effectHovered = false;

  // Visual prefs state
  String _selectedEffectLabel = 'solid';
  String _currentEffectKey = 'solid';
  Color _selectedColor = const Color(0xCC222222);
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
    if (!Platform.isWindows) {
      return;
    }
    try {
      final proc = await Process.start('powershell', [
        '-NoProfile',
        '-Command',
        r'(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuild',
      ]);
      final output = await proc.stdout.transform(const Utf8Decoder()).join();
      final build = int.tryParse(output.trim()) ?? 0;
      if (mounted) {
        setState(() {
          _isWindows11 = build >= 22000;
        });
      }
    } catch (e) {
      debugPrint('[Windows Detection] Error: $e');
    }
  }

  Future<void> _loadVisualPrefs() async {
    await Future.delayed(const Duration(milliseconds: 300)); // Esperar a que se detecte SO
    
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    final effectName = prefs.getString(_prefEffectKey) ?? 'solid';
    final colorValue = prefs.getInt(_prefColorKey) ?? 0xCC222222;
    final dark = prefs.getBool(_prefDarkKey) ?? true;

    // En win10 forzamos solid si no lo es
    String finalEffectLabel = effectName;
    if (!_isWindows11) {
      finalEffectLabel = 'solid';
    }

    // fallback si no existe
    if (!effects.containsKey(finalEffectLabel)) {
      finalEffectLabel = 'solid';
    }

    if (mounted) {
      setState(() {
        _selectedEffectLabel = finalEffectLabel;
        _currentEffectKey = finalEffectLabel;
        _selectedColor = Color(colorValue);
        _darkMode = dark;
      });
      debugPrint('[Settings] Loaded prefs - effect: $finalEffectLabel');
    }

    // Aplicar corrección inicial si estamos en win10 y estaba en otro efecto
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
      if (!mounted) return;
      setState(() {
        _nsfw = enabled;
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
    debugPrint('[Settings] Applied effect: $label, current: $_currentEffectKey');

    final effect = effects[label] ?? acrylic.WindowEffect.solid;
    await widget.onChangeWindowEffect(effect, color, dark: _darkMode);
  }

  Future<void> _showEffectsMenu(BuildContext context, RenderBox rb) async {
    _effectMenuOpen = true;
    setState(() {});

    // Filtrar efectos: Win10 solo solid
    final availableKeys = _isWindows11 ? effects.keys.toList() : ['solid'];

    final topLeft = rb.localToGlobal(Offset.zero);
    final items = availableKeys.map((key) {
      final label = widget.getText('effect_$key', fallback: key.capitalize());
      return PopupMenuItem<String>(
        value: key,
        child: Text(label),
      );
    }).toList();

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        topLeft.dx,
        topLeft.dy + rb.size.height,
        topLeft.dx + rb.size.width,
        topLeft.dy,
      ),
      items: items,
      color: Colors.grey[900],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
    );

    _effectMenuOpen = false;
    setState(() {});

    if (selected != null && selected != _selectedEffectLabel) {
      await _applyEffect(selected, _selectedColor);
    }
  }

  Future<void> _pickSolidColor(Color color) async {
    setState(() {
      _selectedColor = color;
      _darkMode =
          ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
    });
    // Si estamos en modo 'solid', reaplicamos para ver el color
    if (_selectedEffectLabel == 'solid') {
      await _applyEffect('solid', color);
    }
  }

  void _openCustomColorDialog() {
    showDialog(context: context, builder: (ctx) => _msgDialog(ctx));
  }

  Widget _msgDialog(BuildContext context) {
    Color tempColor = _selectedColor;
    return StatefulBuilder(
      builder: (context, setSt) {
        return AlertDialog(
          backgroundColor: const Color(0xFF222222),
          title: Text(widget.getText('pick_color', fallback: 'Elige un color')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: tempColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24),
                  ),
                ),
                const SizedBox(height: 20),
                _colorSlider(
                  widget.getText('red', fallback: 'Rojo'),
                  tempColor.red,
                  (v) => setSt(() => tempColor = tempColor.withRed(v.toInt())),
                ),
                _colorSlider(
                  widget.getText('green', fallback: 'Verde'),
                  tempColor.green,
                  (v) =>
                      setSt(() => tempColor = tempColor.withGreen(v.toInt())),
                ),
                _colorSlider(
                  widget.getText('blue', fallback: 'Azul'),
                  tempColor.blue,
                  (v) => setSt(() => tempColor = tempColor.withBlue(v.toInt())),
                ),
                _colorSlider(
                  widget.getText('opacity', fallback: 'Opacidad'),
                  tempColor.alpha,
                  (v) =>
                      setSt(() => tempColor = tempColor.withAlpha(v.toInt())),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(widget.getText('cancel', fallback: 'Cancelar')),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _pickSolidColor(tempColor);
              },
              child: Text(widget.getText('accept', fallback: 'Aceptar')),
            ),
          ],
        );
      },
    );
  }

  Widget _colorSlider(String label, int value, ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: $value',
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
        Slider(
          value: value.toDouble(),
          min: 0,
          max: 255,
          activeColor: Colors.white,
          inactiveColor: Colors.white24,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Future<void> _toggleNsfw(bool value) async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setBool(_nsfwKey, value);
      if (!mounted) return;
      setState(() => _nsfw = value);
    } catch (_) {}
  }

  Future<void> _persistPreferredLang(String code) async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setString(_preferredLangKey, code);
    } catch (_) {}
  }

  Future<void> _selectLanguage(String code) async {
    if (_saving != null) return;
    setState(() {
      _saving = code;
      _selectedLang = code;
    });

    try {
      await widget.onSelectLanguage(code);
      await _persistPreferredLang(code);
      if (!mounted) return;
      Navigator.pop(context, code);
    } catch (e) {
      if (!mounted) return;
      showElegantNotification(
        context,
        widget.getText('error_saving', fallback: 'Error saving language'),
        backgroundColor: const Color(0xFFE53935),
        textColor: Colors.white,
        icon: Icons.error_outline,
        iconColor: Colors.white,
      );
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
      elevation: 4,
      color: Colors.grey[900],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
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
    final Color scaffoldBg = Colors.transparent;

    final theme = Theme.of(context).copyWith(
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,
    );

    final borderColorLang = (_langMenuOpen || _langHovered)
        ? const Color.fromARGB(255, 255, 255, 255)
        : Colors.white.withOpacity(0.04);
    final borderColorEffect = (_effectMenuOpen || _effectHovered)
        ? const Color.fromARGB(255, 255, 255, 255)
        : Colors.white.withOpacity(0.04);

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: scaffoldBg,
        body: Column(
          children: [
            GestureDetector(
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
                            color: Color.fromARGB(255, 255, 255, 255),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        get('setting_tittle', fallback: 'Settings'),
                        style: const TextStyle(
                          fontSize: 14,
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

            Expanded(
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        get('lang_select', fallback: 'Select language:'),
                        style: const TextStyle(fontSize: 16),
                      ),
                      const SizedBox(height: 12),
                      MouseRegion(
                        onEnter: (_) {
                          setState(() => _langHovered = true);
                        },
                        onExit: (_) {
                          if (!_langMenuOpen) {
                            setState(() => _langHovered = false);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black12,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: borderColorLang),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.language),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Builder(
                                  builder: (rowContext) {
                                    return GestureDetector(
                                      behavior: HitTestBehavior.translucent,
                                      onTap: () {
                                        final rb =
                                            rowContext.findRenderObject()
                                                as RenderBox?;
                                        if (rb != null) {
                                          _showLanguageMenu(rowContext, rb);
                                        }
                                      },
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              languages[_selectedLang] ??
                                                  languages[widget
                                                      .currentLang]!,
                                            ),
                                          ),
                                          const Icon(Icons.arrow_drop_down),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              if (_saving != null)
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else if (widget.currentLang ==
                                  (_selectedLang ?? widget.currentLang))
                                const Icon(Icons.check, color: Colors.green),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      Text(
                        get('window_style', fallback: 'Estilo de ventana'),
                        style: const TextStyle(fontSize: 16),
                      ),
                      const SizedBox(height: 12),

                      MouseRegion(
                        onEnter: (_) => setState(() => _effectHovered = true),
                        onExit: (_) {
                          if (!_effectMenuOpen) {
                            setState(() => _effectHovered = false);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black12,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: borderColorEffect),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.format_paint),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Builder(
                                  builder: (rowContext) {
                                    return GestureDetector(
                                      behavior: HitTestBehavior.translucent,
                                      onTap: () {
                                        final rb =
                                            rowContext.findRenderObject()
                                                as RenderBox?;
                                        if (rb != null) {
                                          _showEffectsMenu(rowContext, rb);
                                        }
                                      },
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              widget.getText(
                                                'effect_$_selectedEffectLabel',
                                                fallback: _selectedEffectLabel
                                                    .capitalize(),
                                              ),
                                            ),
                                          ),
                                          const Icon(Icons.arrow_drop_down),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              if (_saving != null)
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else if (_selectedEffectLabel ==
                                  _currentEffectKey)
                                const Icon(Icons.check, color: Colors.green),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      if (_selectedEffectLabel == 'solid') ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            _colorOption(const Color(0xFFFFFFFF)), // Blanco
                            const SizedBox(width: 10),
                            _colorOption(const Color(0xFF222222)), // Default
                            const SizedBox(width: 10),
                            _colorOption(const Color(0xFF000000)), // Negro
                            const SizedBox(width: 10),
                            _colorOption(
                              const Color(0xFF4A148C),
                            ), // Morado opaco
                            const SizedBox(width: 10),
                            InkWell(
                              onTap: _openCustomColorDialog,
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white54),
                                  gradient: const LinearGradient(
                                    colors: [
                                      Colors.red,
                                      Colors.green,
                                      Colors.blue,
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.colorize,
                                  size: 18,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 24),

                      Theme(
                        data: Theme.of(context).copyWith(
                          switchTheme: SwitchThemeData(
                            thumbColor: WidgetStateProperty.resolveWith<Color?>(
                              (states) {
                                if (states.contains(WidgetState.selected)) {
                                  return Colors.white;
                                }
                                return Colors.white54;
                              },
                            ),
                            trackColor: WidgetStateProperty.resolveWith<Color?>(
                              (states) {
                                if (states.contains(WidgetState.selected)) {
                                  return Colors.white24;
                                }
                                return Colors.white10;
                              },
                            ),
                          ),
                        ),
                        child: SwitchListTile(
                          title: Text(
                            get(
                              'nsfw_toggle',
                              fallback: 'Activar sección NSFW',
                            ),
                            style: const TextStyle(color: Colors.white),
                          ),
                          value: _nsfw,
                          onChanged: (v) => _toggleNsfw(v),
                          secondary: const Icon(
                            Icons.warning,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      ElevatedButton.icon(
                        icon: const Icon(Icons.system_update),
                        label: Text(
                          get(
                            'check_update',
                            fallback: 'Verificar actualización',
                          ),
                        ),
                        onPressed: () => checkForUpdate(context, get),
                        style:
                            ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              foregroundColor: Colors.white,
                              shadowColor: Colors.transparent,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              side: const BorderSide(
                                color: Colors.white,
                                width: 1,
                              ),
                            ).merge(
                              ButtonStyle(
                                overlayColor:
                                    WidgetStateProperty.resolveWith<Color?>((
                                      states,
                                    ) {
                                      if (states.contains(
                                        WidgetState.pressed,
                                      )) {
                                        return Colors.white.withOpacity(0.10);
                                      }
                                      if (states.contains(
                                        WidgetState.hovered,
                                      )) {
                                        return Colors.white.withOpacity(0.06);
                                      }
                                      if (states.contains(
                                        WidgetState.focused,
                                      )) {
                                        return Colors.white.withOpacity(0.06);
                                      }
                                      return null;
                                    }),
                              ),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _colorOption(Color color) {
    bool isSelected = _selectedColor.value == color.value;
    return GestureDetector(
      onTap: () => _pickSolidColor(color),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: isSelected
              ? Border.all(color: Colors.white, width: 2)
              : Border.all(color: Colors.transparent),
          boxShadow: isSelected
              ? [const BoxShadow(color: Colors.black26, blurRadius: 4)]
              : null,
        ),
        child: isSelected
            ? const Icon(Icons.check, color: Colors.grey, size: 16)
            : null,
      ),
    );
  }
}
