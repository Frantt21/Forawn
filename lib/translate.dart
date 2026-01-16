// translate.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:translator/translator.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class TranslateScreen extends StatefulWidget {
  final TextGetter getText;
  final String currentLang;
  final void Function(VoidCallback)? onRegisterFolderAction;

  const TranslateScreen({
    super.key,
    required this.getText,
    required this.currentLang,
    this.onRegisterFolderAction,
  });

  @override
  State<TranslateScreen> createState() => _TranslateScreenState();
}

class _TranslateScreenState extends State<TranslateScreen> with WindowListener {
  final TextEditingController _inputController = TextEditingController();
  String _translated = '';
  bool _loading = false;
  String? _saveFolder;
  SharedPreferences? _prefs;
  static const _prefsKey = 'translate_save_folder';

  // Country keys that we send to the API (stable internal values)
  static const List<String> _countryKeys = [
    'spain',
    'usa',
    'egipt',
    'france',
    'germany',
    'italy',
    'japan',
    'korea',
    'russia',
    'turkey',
    'uk',
    'china',
    'portuguese',
    'india',
    'sweden',
    'norway',
    'denmark',
    'netherlands',
    'poland',
    'greece',
    'australia',
    'switzerland',
    'saudi_arabia',
    'south_africa',
    'indonesia',
    'thailand',
    'vietnam',
    'israel',
    'hungary',
    'czech',
    'romania',
    'finland',
    'bulgaria',
    'ukraine',
    'serbia',
    'croatia',
    'slovakia',
    'slovenia',
    'estonia',
    'latvia',
    'lithuania',
  ];

  // Selected key (value sent to API)
  late String _selectedCountryKey;

  // Localized labels for the dropdown (key -> localized text)
  Map<String, String> _countryLabels = {};

  // Input resizable
  double _inputHeight = 160;
  bool _isDraggingHandle = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _selectedCountryKey = _defaultCountryForLang(widget.currentLang);
    _loadFolderPref(); // async, does not block UI
    // build localized labels after first frame so widget.getText is available
    WidgetsBinding.instance.addPostFrameCallback((_) => _buildCountryLabels());

    if (widget.onRegisterFolderAction != null) {
      widget.onRegisterFolderAction!(_selectFolder);
    }
  }

  @override
  void didUpdateWidget(covariant TranslateScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If language changed, update default country and rebuild labels
    if (oldWidget.currentLang != widget.currentLang) {
      _selectedCountryKey = _defaultCountryForLang(widget.currentLang);
      _buildCountryLabels();
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _debounce?.cancel();
    _inputController.dispose();
    // Don't close HTTP client - prevents "Connection closed" errors in debug mode
    // _http.close();
    super.dispose();
  }

  Future<void> _loadFolderPref() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final f = _prefs!.getString(_prefsKey);
      if (f != null && f.isNotEmpty) {
        _saveFolder = f;
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _selectFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    _saveFolder = p.normalize(dir);
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setString(_prefsKey, _saveFolder!);
    } catch (_) {}
  }

  String _defaultCountryForLang(String langCode) {
    final code = langCode.toLowerCase();
    if (code.startsWith('es')) return 'spain';
    if (code.startsWith('en')) return 'usa';
    return 'usa'; // Default to English
  }

  // Build localized labels map from keys using widget.getText with a 'country_' prefix
  void _buildCountryLabels() {
    final get = widget.getText;
    final Map<String, String> map = {};
    for (final key in _countryKeys) {
      final labelKey = 'country_$key';
      final label = get(labelKey, fallback: _prettyKey(key));
      map[key] = label;
    }
    if (!mounted) {
      _countryLabels = map;
      return;
    }
    setState(() {
      _countryLabels = map;
      if (!_countryLabels.containsKey(_selectedCountryKey)) {
        _selectedCountryKey = _countryKeys.first;
      }
    });
  }

  // Helper fallback for missing translations
  String _prettyKey(String k) {
    return k
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) {
          if (w.isEmpty) return w;
          return w[0].toUpperCase() + (w.length > 1 ? w.substring(1) : '');
        })
        .join(' ');
  }

  final _translator = GoogleTranslator();

  Future<void> _translate() async {
    final input = _inputController.text.trim();
    if (input.isEmpty) {
      return;
    }

    if (!mounted) return;
    setState(() {
      _loading = true;
      _translated = '';
    });

    try {
      // Map country keys to language codes if necessary, or use a better mapping
      // For now, mapping known keys or using 'auto' for source
      // If _selectedCountryKey corresponds to target language

      String targetLang;
      switch (_selectedCountryKey) {
        case 'spain':
          targetLang = 'es';
          break;
        case 'usa':
          targetLang = 'en';
          break;
        case 'france':
          targetLang = 'fr';
          break;
        case 'germany':
          targetLang = 'de';
          break;
        case 'italy':
          targetLang = 'it';
          break;
        case 'japan':
          targetLang = 'ja';
          break;
        case 'korea':
          targetLang = 'ko';
          break;
        case 'russia':
          targetLang = 'ru';
          break;
        case 'china':
          targetLang = 'zh-cn';
          break;
        case 'portuguese':
          targetLang = 'pt';
          break;
        // Add other mappings as needed, default to english if unknown
        default:
          targetLang = 'en';
      }

      final translation = await _translator.translate(input, to: targetLang);

      if (!mounted) return;
      setState(() {
        _translated = translation.text;
      });
    } catch (e) {
      debugPrint('[TranslateScreen] Error: $e');
      if (!mounted) return;
      setState(() {
        _translated = widget.getText(
          'translate_error',
          fallback: 'Translation error',
        );
      });
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _copyToClipboard() async {
    if (_translated.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _translated));
  }

  Future<void> _downloadTxt() async {
    if (_translated.isEmpty) return;

    String folder = _saveFolder ?? '';
    if (folder.isEmpty) {
      final picked = await FilePicker.platform.getDirectoryPath();
      if (picked == null) return;
      folder = p.normalize(picked);
      _saveFolder = folder;
      try {
        _prefs ??= await SharedPreferences.getInstance();
        await _prefs!.setString(_prefsKey, _saveFolder!);
      } catch (_) {}
    }

    try {
      final safe = DateTime.now().toIso8601String().replaceAll(':', '-');
      final filename = 'translation_$safe.txt';
      final path = p.join(folder, filename);
      final f = File(path);
      await f.create(recursive: true);
      await f.writeAsString(_translated);
    } catch (e) {
      debugPrint('[TranslateScreen] Error saving file: $e');
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

  @override
  Widget build(BuildContext context) {
    final get = widget.getText;

    final Color scaffoldBg = Colors.transparent;

    return Scaffold(
      backgroundColor: scaffoldBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Theme.of(context).cardTheme.color,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                child: Column(
                  children: [
                    SizedBox(
                      height: _inputHeight,
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: TextField(
                          controller: _inputController,
                          expands: true,
                          maxLines: null,
                          minLines: null,
                          textAlignVertical: TextAlignVertical.top,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: get(
                              'translate_input_hint',
                              fallback: 'Write the text here',
                            ),
                            hintStyle: Theme.of(
                              context,
                            ).inputDecorationTheme.hintStyle,
                          ),
                          style: const TextStyle(fontSize: 15),
                          onChanged: (text) {
                            if (_debounce?.isActive ?? false)
                              _debounce!.cancel();
                            _debounce = Timer(
                              const Duration(milliseconds: 500),
                              () {
                                _translate();
                              },
                            );
                          },
                          onSubmitted: (_) {
                            if (!_loading) _translate();
                          },
                        ),
                      ),
                    ),

                    // Barra inferior de controles (Selector y botones)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Row(
                        children: [
                          // Selector de idioma (estilo ForaAI)
                          Container(
                            height: 24,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: Theme.of(context).cardTheme.color,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                DropdownButton<String>(
                                  value: _selectedCountryKey,
                                  underline: const SizedBox.shrink(),
                                  dropdownColor:
                                      Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? const Color(0xFF1E1E1E)
                                      : const Color(0xFFEEEEEE),
                                  borderRadius: BorderRadius.circular(10),
                                  focusColor: Colors.transparent,
                                  icon: Icon(
                                    Icons.keyboard_arrow_down,
                                    size: 14,
                                    color: Theme.of(
                                      context,
                                    ).iconTheme.color?.withOpacity(0.54),
                                  ),
                                  isDense: true,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).textTheme.bodyLarge?.color,
                                    fontSize: 11,
                                  ),
                                  items: _countryKeys.map((key) {
                                    final label =
                                        _countryLabels[key] ?? _prettyKey(key);
                                    return DropdownMenuItem<String>(
                                      value: key,
                                      child: Text(label),
                                    );
                                  }).toList(),
                                  onChanged: (v) {
                                    if (v == null) return;
                                    setState(() {
                                      _selectedCountryKey = v;
                                      // Trigger translation immediately on language change if there is text
                                      if (_inputController.text.isNotEmpty) {
                                        _translate();
                                      }
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),

                          const Spacer(),

                          // Indicador de carga o estado
                          if (_loading)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white54,
                              ),
                            ),

                          const SizedBox(width: 8),

                          // Botón descarga txt
                          IconButton(
                            icon: const Icon(Icons.download, size: 20),
                            tooltip: get(
                              'download_txt',
                              fallback: 'Download TXT',
                            ),
                            onPressed: _downloadTxt,
                            style: IconButton.styleFrom(
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.surface.withOpacity(0.1),
                              foregroundColor: Theme.of(
                                context,
                              ).iconTheme.color,
                              padding: const EdgeInsets.all(8),
                              minimumSize: const Size(36, 36),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ],
                      ),
                    ),

                    GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onVerticalDragStart: (_) =>
                          setState(() => _isDraggingHandle = true),
                      onVerticalDragUpdate: (details) {
                        setState(() {
                          _inputHeight = (_inputHeight + details.delta.dy)
                              .clamp(80.0, 600.0);
                        });
                      },
                      onVerticalDragEnd: (_) =>
                          setState(() => _isDraggingHandle = false),
                      child: Container(
                        height: 10,
                        alignment: Alignment.center,
                        child: Container(
                          width: 48,
                          height: 4,
                          decoration: BoxDecoration(
                            color: _isDraggingHandle
                                ? Colors.purpleAccent
                                : Colors.white24,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardTheme.color,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(
                            _translated.isEmpty
                                ? get(
                                    'no_translation',
                                    fallback: 'No translation yet',
                                  )
                                : _translated,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ),
                      if (_translated.isNotEmpty)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            tooltip: get('copy_tooltip', fallback: 'Copy'),
                            onPressed: _copyToClipboard,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
