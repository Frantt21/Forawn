// translate.dart — igual al translate_screen.dart de forawn_mobile:
// selector de idioma destino arriba, tarjeta de entrada y tarjeta de
// salida con header verde (greenAccent). Se conservan las funciones de
// desktop (guardar TXT, copiar, folder action).
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:translator/translator.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'services/window_effects_service.dart';

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

class _TranslateScreenState extends State<TranslateScreen> {
  final TextEditingController _inputController = TextEditingController();
  final _translator = GoogleTranslator();

  String _translation = '';
  bool _loading = false;
  String? _error;
  Timer? _debounce;

  String? _saveFolder;
  SharedPreferences? _prefs;
  static const _prefsKey = 'translate_save_folder';

  // Idioma destino: claves de locale (igual que forawn_mobile) mapeadas a
  // códigos de la API de traducción.
  static const Map<String, String> _languageCodes = {
    'lang_english': 'en',
    'lang_spanish': 'es',
    'lang_french': 'fr',
    'lang_german': 'de',
    'lang_portuguese': 'pt',
    'lang_italian': 'it',
    'lang_chinese': 'zh-cn',
    'lang_japanese': 'ja',
    'lang_korean': 'ko',
    'lang_russian': 'ru',
  };

  String _targetLangKey = 'lang_english';

  @override
  void initState() {
    super.initState();
    _targetLangKey = _defaultLangForLocale(widget.currentLang);
    _loadFolderPref();
    if (widget.onRegisterFolderAction != null) {
      widget.onRegisterFolderAction!(_selectFolder);
    }
  }

  @override
  void didUpdateWidget(covariant TranslateScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentLang != widget.currentLang) {
      _targetLangKey = _defaultLangForLocale(widget.currentLang);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _inputController.dispose();
    super.dispose();
  }

  String _defaultLangForLocale(String langCode) {
    final code = langCode.toLowerCase();
    if (code.startsWith('es')) return 'lang_spanish';
    if (code.startsWith('fr')) return 'lang_french';
    if (code.startsWith('de')) return 'lang_german';
    if (code.startsWith('pt')) return 'lang_portuguese';
    if (code.startsWith('ru')) return 'lang_russian';
    if (code.startsWith('ja')) return 'lang_japanese';
    if (code.startsWith('ko')) return 'lang_korean';
    if (code.startsWith('zh')) return 'lang_chinese';
    return 'lang_english';
  }

  // Etiqueta localizada de la clave de idioma (con fallback legible).
  String _langLabel(String key) {
    final name = key.replaceFirst('lang_', '');
    return widget.getText(
      key,
      fallback: name[0].toUpperCase() + name.substring(1),
    );
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
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null) return;
    _saveFolder = p.normalize(dir);
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setString(_prefsKey, _saveFolder!);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _onTextChanged(String text) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    if (text.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _translation = '';
          _error = null;
          _loading = false;
        });
      }
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 800), _translate);
  }

  Future<void> _translate() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final targetCode = _languageCodes[_targetLangKey] ?? 'en';
      final translation = await _translator.translate(text, to: targetCode);

      if (!mounted) return;
      setState(() {
        _translation = translation.text;
      });
    } catch (e) {
      debugPrint('[TranslateScreen] Error: $e');
      if (mounted) {
        setState(() {
          _error = widget.getText(
            'translate_error',
            fallback: 'Translation error',
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _copyToClipboard() async {
    if (_translation.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _translation));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.getText('copied', fallback: 'Copiado al portapapeles'),
          ),
        ),
      );
    }
  }

  Future<void> _downloadTxt() async {
    if (_translation.isEmpty) return;

    String folder = _saveFolder ?? '';
    if (folder.isEmpty) {
      final picked = await FilePicker.getDirectoryPath();
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
      await f.writeAsString(_translation);
    } catch (e) {
      debugPrint('[TranslateScreen] Error saving file: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final get = widget.getText;
    final textColor = Colors.white;
    // Verde como color principal de esta pantalla (igual que forawn_mobile).
    const accentColor = Colors.greenAccent;
    // Superficie adaptada: sólida por defecto, overlay translúcido si hay
    // efecto de ventana activo (acrylic/mica) para que se vea el material.
    final cardBackgroundColor = WindowEffectsService.instance.surface(
      context,
      solid: const Color(0xFF1C1C1E),
      overlay: 0.08,
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Selector de Idioma Destino
              Card(
                color: cardBackgroundColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        get('target_language', fallback: 'Target language'),
                        style: TextStyle(
                          color: textColor.withOpacity(0.8),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _targetLangKey,
                          // Estilo unificado de menús de la app.
                          dropdownColor: const Color(0xFF2C2C2E),
                          borderRadius: BorderRadius.circular(15),
                          icon: const Icon(
                            Icons.arrow_drop_down,
                            color: accentColor,
                          ),
                          style: const TextStyle(
                            color: accentColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                          items: _languageCodes.keys
                              .map(
                                (k) => DropdownMenuItem<String>(
                                  value: k,
                                  child: Text(
                                    _langLabel(k),
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() {
                              _targetLangKey = v;
                            });
                            if (_inputController.text.isNotEmpty) {
                              _translate();
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Área de Entrada (Input)
              Expanded(
                child: Card(
                  color: cardBackgroundColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _inputController,
                            onChanged: _onTextChanged,
                            style: TextStyle(
                              color: textColor,
                              fontSize: 18,
                            ),
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            cursorColor: accentColor,
                            decoration: InputDecoration(
                              hintText: get(
                                'enter_text_translate',
                                fallback: 'Enter text to translate',
                              ),
                              hintStyle: TextStyle(
                                color: textColor.withOpacity(0.3),
                              ),
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Área de Salida (Output)
              Expanded(
                child: Card(
                  color: cardBackgroundColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.translate,
                              size: 18,
                              color: accentColor,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${get('translation', fallback: 'Translation')} (${_langLabel(_targetLangKey)})',
                                style: const TextStyle(
                                  color: accentColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (_loading)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: accentColor,
                                ),
                              ),
                            if (_translation.isNotEmpty) ...[
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.copy, size: 18),
                                tooltip: get(
                                  'copy_tooltip',
                                  fallback: 'Copy',
                                ),
                                onPressed: _copyToClipboard,
                                style: IconButton.styleFrom(
                                  foregroundColor: textColor,
                                  padding: const EdgeInsets.all(6),
                                  minimumSize: const Size(30, 30),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.download, size: 18),
                                tooltip: get(
                                  'download_txt',
                                  fallback: 'Download TXT',
                                ),
                                onPressed: _downloadTxt,
                                style: IconButton.styleFrom(
                                  foregroundColor: textColor,
                                  padding: const EdgeInsets.all(6),
                                  minimumSize: const Size(30, 30),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: SingleChildScrollView(
                            child: _error != null
                                ? Text(
                                    _error!,
                                    style: const TextStyle(
                                      color: Colors.redAccent,
                                    ),
                                  )
                                : SelectableText(
                                    _translation.isEmpty && !_loading
                                        ? get(
                                            'no_translation',
                                            fallback: 'No translation yet',
                                          )
                                        : _translation,
                                    style: TextStyle(
                                      color: _translation.isEmpty
                                          ? textColor.withOpacity(0.3)
                                          : textColor,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    cursorColor: accentColor,
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
      ),
    );
  }
}
