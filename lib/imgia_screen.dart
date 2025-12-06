import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:typed_data';
import 'package:window_manager/window_manager.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class AiImageScreen extends StatefulWidget {
  final TextGetter getText;
  final String currentLang;
  final void Function(VoidCallback)? onRegisterFolderAction;

  const AiImageScreen({
    super.key,
    required this.getText,
    required this.currentLang,
    this.onRegisterFolderAction,
  });

  @override
  State<AiImageScreen> createState() => _AiImageScreenState();
}

class _AiImageScreenState extends State<AiImageScreen> with WindowListener {
  final TextEditingController _promptController = TextEditingController();
  String _ratio = '16:9';
  bool _loading = false;
  String? _imageUrl;
  Uint8List? _imageBytes;
  String? _saveFolder;
  SharedPreferences? _prefs;
  String _statusText = '';

  static const _prefsKey = 'image_download_folder';

  // Input area altura y arrastre
  double _inputHeight = 80;
  bool _isDraggingHandle = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _loadFolderPref();

    if (widget.onRegisterFolderAction != null) {
      widget.onRegisterFolderAction!(_selectFolder);
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _promptController.dispose();
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

  Future<void> _saveFolderPref() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      if (_saveFolder != null) await _prefs!.setString(_prefsKey, _saveFolder!);
    } catch (_) {}
  }

  Future<void> _selectFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    _saveFolder = p.normalize(dir);
    await _saveFolderPref();
    if (!mounted) return;
    setState(() {
      _statusText =
          '${widget.getText('save_folder_set', fallback: 'Save folder set')}: $_saveFolder';
    });
  }

  String _buildApiUrl(String prompt, String ratio) {
    final encoded = Uri.encodeComponent(prompt);
    final r = Uri.encodeComponent(ratio);
    return 'yourapi';
  }

  Future<void> _generateImage() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      if (!mounted) return;
      setState(() {
        _statusText = widget.getText(
          'enter_prompt',
          fallback: 'Enter a prompt',
        );
      });
      return;
    }

    if (_loading) return;
    setState(() {
      _loading = true;
      _imageUrl = null;
      _imageBytes = null;
      _statusText = widget.getText('generating', fallback: 'Generating...');
    });

    try {
      final url = _buildApiUrl(prompt, _ratio);
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final parsed = jsonDecode(res.body) as Map<String, dynamic>;
      final data = parsed['data'] as Map<String, dynamic>?;
      final imageLink = data?['image_link'] as String?;
      final status = data?['status'] as String?;
      if (status != 'success' || imageLink == null) {
        throw Exception('API error or no image');
      }

      // Download bytes
      final imgRes = await http
          .get(Uri.parse(imageLink))
          .timeout(const Duration(seconds: 20));
      if (imgRes.statusCode != 200) {
        throw Exception('Image download ${imgRes.statusCode}');
      }

      _imageUrl = imageLink;
      _imageBytes = imgRes.bodyBytes;
      if (!mounted) return;
      setState(() {
        _statusText = widget.getText('generated', fallback: 'Generated');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText =
            '${widget.getText('generate_error', fallback: 'Error generating')}: ${e.toString()}';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _saveImageToFolder() async {
    if (_imageBytes == null) {
      if (!mounted) return;
      setState(() {
        _statusText = widget.getText(
          'no_image_to_save',
          fallback: 'No image to save',
        );
      });
      return;
    }

    String folder = _saveFolder ?? '';
    if (folder.isEmpty) {
      final picked = await FilePicker.platform.getDirectoryPath();
      if (picked == null) {
        if (!mounted) return;
        setState(() {
          _statusText = widget.getText(
            'save_cancelled',
            fallback: 'Save cancelled',
          );
        });
        return;
      }
      folder = p.normalize(picked);
      _saveFolder = folder;
      await _saveFolderPref();
    }

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final ext = _guessExtensionFromBytes(_imageBytes!) ?? '.jpg';
      final fileName = 'ai_image_$timestamp$ext';
      final path = p.join(folder, fileName);
      final f = File(path);
      await f.create(recursive: true);
      await f.writeAsBytes(_imageBytes!);
      if (!mounted) return;
      setState(() {
        _statusText =
            '${widget.getText('saved_to', fallback: 'Saved to')}: $path';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText =
            '${widget.getText('save_error', fallback: 'Error saving')}: ${e.toString()}';
      });
    }
  }

  String? _guessExtensionFromBytes(Uint8List bytes) {
    if (bytes.length >= 4) {
      // JPEG
      if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes.last == 0xD9) {
        return '.jpg';
      }
      // PNG
      if (bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47) {
        return '.png';
      }
      // GIF
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
        return '.gif';
      }
    }
    return null;
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
                          controller: _promptController,
                          expands: true,
                          maxLines: null,
                          minLines: null,
                          textAlignVertical: TextAlignVertical.top,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: get(
                              'prompt_hint',
                              fallback: 'Describe the image you want',
                            ),
                          ),
                          style: const TextStyle(fontSize: 14),
                          onSubmitted: (_) {
                            if (!_loading) _generateImage();
                          },
                        ),
                      ),
                    ),

                    // botón debajo del área de texto
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
                                : const Icon(Icons.image),
                            label: Text(
                              get('generate_button', fallback: 'Generate'),
                            ),
                            onPressed: _loading ? null : _generateImage,
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
                                255,
                                251,
                                18,
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
                              .clamp(48.0, 300.0);
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
                                ? const Color.fromARGB(255, 255, 251, 18)
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
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(get('ratio_label', fallback: 'Ratio')),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: _ratio,
                          underline: const SizedBox.shrink(),
                          items:
                              <String>[
                                    '16:9',
                                    '9:16',
                                    '1:1',
                                    '4:3',
                                    '3:4',
                                    '9:19',
                                  ]
                                  .map(
                                    (r) => DropdownMenuItem(
                                      value: r,
                                      child: Text(r),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => _ratio = v);
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 12),
                ],
              ),

              const SizedBox(height: 12),

              if (_statusText.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _statusText,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),

              const SizedBox(height: 12),

              Expanded(
                child: _imageBytes != null
                    ? Column(
                        children: [
                          Expanded(
                            child: Image.memory(
                              _imageBytes!,
                              fit: BoxFit.contain,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ElevatedButton.icon(
                                icon: const Icon(Icons.save),
                                label: Text(
                                  get('save_button', fallback: 'Save'),
                                ),
                                onPressed: _saveImageToFolder,
                                style: ElevatedButton.styleFrom(
                                  shape: const RoundedRectangleBorder(
                                    borderRadius: BorderRadius.all(
                                      Radius.circular(10),
                                    ),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              ElevatedButton.icon(
                                icon: const Icon(Icons.open_in_new),
                                label: Text(
                                  get('open_link', fallback: 'Open link'),
                                ),
                                onPressed: _imageUrl == null
                                    ? null
                                    : () async {
                                        final uri = Uri.tryParse(_imageUrl!);
                                        if (uri != null) {
                                          try {
                                            if (Platform.isWindows) {
                                              await Process.start('explorer', [
                                                uri.toString(),
                                              ]);
                                            } else if (Platform.isMacOS) {
                                              await Process.start('open', [
                                                uri.toString(),
                                              ]);
                                            } else {
                                              await Process.start('xdg-open', [
                                                uri.toString(),
                                              ]);
                                            }
                                          } catch (_) {}
                                        }
                                      },
                                style: ElevatedButton.styleFrom(
                                  shape: const RoundedRectangleBorder(
                                    borderRadius: BorderRadius.all(
                                      Radius.circular(10),
                                    ),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      )
                    : Center(
                        child: Text(
                          get('no_image_ui', fallback: 'No image yet'),
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
