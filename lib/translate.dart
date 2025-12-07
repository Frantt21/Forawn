// translate.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'config/api_config.dart';

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
  String _status = '';

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

  // Lightweight http client reuse
  final http.Client _http = http.Client();

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
    _inputController.dispose();
    _http.close();
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
    if (!mounted) return;
    setState(
      () => _status =
          '${widget.getText('save_folder_set', fallback: 'Save folder set')}: $_saveFolder',
    );
  }

  String _defaultCountryForLang(String langCode) {
    final code = langCode.toLowerCase();
    if (code.startsWith('es')) return 'spain';
    if (code.startsWith('en')) return 'usa';
    return 'spain';
  }

  // Build API URI using selected country key
  Uri _buildApiUri(String text, String countryKey) {
    final encoded = Uri.encodeComponent(text);
    final c = Uri.encodeComponent(countryKey);
    return Uri.parse(
      '${ApiConfig.dorratzBaseUrl}/v3/translate?text=$encoded&country=$c',
    );
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

  Future<void> _translate() async {
    final input = _inputController.text.trim();
    if (input.isEmpty) {
      setState(
        () => _status = widget.getText(
          'enter_text',
          fallback: 'Enter text to translate',
        ),
      );
      return;
    }

    setState(() {
      _loading = true;
      _translated = '';
      _status = widget.getText('translating', fallback: 'Translating...');
    });

    try {
      final uri = _buildApiUri(input, _selectedCountryKey);
      final res = await _http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final text = res.body.trim();
      if (!mounted) return;
      setState(() {
        _translated = text;
        _status = widget.getText('translated', fallback: 'Translated');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status =
            '${widget.getText('translate_error', fallback: 'Translation error')}: ${e.toString()}';
      });
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _copyToClipboard() async {
    if (_translated.isEmpty) {
      setState(
        () => _status = widget.getText(
          'nothing_to_copy',
          fallback: 'Nothing to copy',
        ),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: _translated));
    setState(
      () => _status = widget.getText('copied', fallback: 'Copied to clipboard'),
    );
  }

  Future<void> _downloadTxt() async {
    if (_translated.isEmpty) {
      setState(
        () => _status = widget.getText(
          'nothing_to_save',
          fallback: 'Nothing to save',
        ),
      );
      return;
    }

    String folder = _saveFolder ?? '';
    if (folder.isEmpty) {
      final picked = await FilePicker.platform.getDirectoryPath();
      if (picked == null) {
        setState(
          () => _status = widget.getText(
            'save_cancelled',
            fallback: 'Save cancelled',
          ),
        );
        return;
      }
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
      if (!mounted) return;
      setState(
        () => _status =
            '${widget.getText('saved_to', fallback: 'Saved to')}: $path',
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _status =
            '${widget.getText('save_error', fallback: 'Error saving')}: ${e.toString()}',
      );
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
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.04)),
                ),
                child: Column(
                  children: [
                    SizedBox(
                      height: _inputHeight,
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
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
                          ),
                          style: const TextStyle(fontSize: 14),
                          onSubmitted: (_) {
                            if (!_loading) _translate();
                          },
                        ),
                      ),
                    ),

                    // botones
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                        vertical: 2.0,
                      ),
                      child: Row(
                        children: [
                          const Spacer(),
                          ElevatedButton.icon(
                            icon: _loading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.translate),
                            label: Text(
                              get('translate_button', fallback: 'Translate'),
                            ),
                            onPressed: _loading ? null : _translate,
                            style: ElevatedButton.styleFrom(
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(10),
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                              backgroundColor: const Color.fromARGB(
                                255,
                                64,
                                251,
                                104,
                              ),
                              foregroundColor: Colors.black87,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.download),
                            label: Text(
                              get('download_txt', fallback: 'Download TXT'),
                            ),
                            onPressed: _downloadTxt,
                            style: ElevatedButton.styleFrom(
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(10),
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                              backgroundColor: const Color.fromARGB(
                                255,
                                64,
                                251,
                                104,
                              ),
                              foregroundColor: Colors.black87,
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
                                ? const Color.fromARGB(255, 64, 251, 104)
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

              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Text(get('country_label', fallback: 'Country')),
                        const SizedBox(width: 8),
                        // Localized dropdown using keys and _countryLabels
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: DropdownButton<String>(
                            value: _selectedCountryKey,
                            underline: const SizedBox.shrink(),
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
                              setState(() => _selectedCountryKey = v);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 12),
                ],
              ),

              const SizedBox(height: 12),

              if (_status.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_status, style: const TextStyle(fontSize: 12)),
                ),

              const SizedBox(height: 12),

              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white.withOpacity(0.04)),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}
