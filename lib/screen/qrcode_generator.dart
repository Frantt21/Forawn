// lib/screen/qrcode_generator.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class QrGeneratorScreen extends StatefulWidget {
  final String Function(String key, {String? fallback}) getText;
  final String currentLang;
  final void Function(VoidCallback)? onRegisterFolderAction;

  const QrGeneratorScreen({
    super.key,
    required this.getText,
    required this.currentLang,
    this.onRegisterFolderAction,
  });

  @override
  State<QrGeneratorScreen> createState() => _QrGeneratorScreenState();
}

class _QrGeneratorScreenState extends State<QrGeneratorScreen> {
  final TextEditingController _controller = TextEditingController();
  final GlobalKey _qrKey = GlobalKey();

  String? _errorText;
  bool _processing = false;
  Color _fg = Colors.white;
  Color _bg = Colors.black;
  double _size = 256.0;
  bool _includeMargin = false;
  final double _inputHeight = 56;
  final bool _isDraggingHandle = false;

  // Carpeta de guardado persistente
  String? _saveFolder;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _loadSaveFolder();
    if (widget.onRegisterFolderAction != null) {
      widget.onRegisterFolderAction!(_selectSaveFolder);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadSaveFolder() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final folder = _prefs!.getString('qr_save_folder');
      if (folder != null && folder.isNotEmpty) {
        setState(() => _saveFolder = folder);
      }
    } catch (_) {}
  }

  Future<void> _selectSaveFolder() async {
    final carpeta = await FilePicker.platform.getDirectoryPath();
    if (carpeta == null) return;
    _saveFolder = carpeta;
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setString('qr_save_folder', carpeta);
    } catch (_) {}
    setState(() {});
  }

  bool _isValidUrl(String s) {
    final trimmed = s.trim();
    if (trimmed.isEmpty) return false;
    try {
      final uri = Uri.parse(trimmed);
      return uri.hasScheme && uri.isAbsolute;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openUrl() async {
    final url = _controller.text.trim();
    if (!_isValidUrl(url)) {
      setState(
        () => _errorText = widget.getText(
          'invalid_url',
          fallback: 'URL inválida',
        ),
      );
      return;
    }
    final uri = Uri.parse(url);
    if (!await canLaunchUrl(uri)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.getText('open_error', fallback: 'No se pudo abrir la URL'),
          ),
        ),
      );
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _copyUrl() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.getText('copied', fallback: 'Copiado al portapapeles'),
        ),
      ),
    );
  }

  Future<Uint8List?> _capturePng() async {
    try {
      final boundary =
          _qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final devicePixelRatio = ui.window.devicePixelRatio;
      final image = await boundary.toImage(pixelRatio: devicePixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[QR] capture error: $e');
      return null;
    }
  }

  Future<Directory> _getDownloadsDirectoryFallback() async {
    try {
      final dir = await getDownloadsDirectory();
      if (dir != null) return dir;
    } catch (_) {}
    try {
      final docs = await getApplicationDocumentsDirectory();
      return docs;
    } catch (_) {
      return await getTemporaryDirectory();
    }
  }

  Future<void> _saveAndShare() async {
    final text = _controller.text.trim();
    if (!_isValidUrl(text)) {
      setState(
        () => _errorText = widget.getText(
          'invalid_url',
          fallback: 'URL inválida',
        ),
      );
      return;
    }

    setState(() => _processing = true);
    try {
      final pngBytes = await _capturePng();
      if (pngBytes == null) throw Exception('Capture failed');

      // Usa carpeta seleccionada o fallback
      final baseDir = _saveFolder != null
          ? Directory(_saveFolder!)
          : await _getDownloadsDirectoryFallback();
      if (!baseDir.existsSync()) {
        baseDir.createSync(recursive: true);
      }

      final file = File(
        '${baseDir.path}/qr_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(pngBytes);

      if (kIsWeb) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.getText('saved_web', fallback: 'QR generado')),
          ),
        );
      } else {
        await Share.shareXFiles([
          XFile(file.path),
        ], text: widget.getText('share_qr_text', fallback: 'QR generado'));
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${widget.getText('saved_to', fallback: 'Guardado en')}: ${file.path}',
          ),
        ),
      );
    } catch (e) {
      debugPrint('[QR] save/share error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${widget.getText('save_error', fallback: 'Error al guardar:')} $e',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Widget _buildQrArea() {
    final t = widget.getText;
    final valid = _isValidUrl(_controller.text);
    if (!valid) {
      return Container(
        width: _size,
        height: _size,
        color: Colors.grey[900],
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            t('enter_valid_url', fallback: 'Introduce una URL válida'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return RepaintBoundary(
      key: _qrKey,
      child: Container(
        color: _bg,
        padding: _includeMargin ? const EdgeInsets.all(16) : EdgeInsets.zero,
        child: QrImageView(
          data: _controller.text.trim(),
          size: _size,
          backgroundColor: _bg,
          foregroundColor: _fg,
          errorStateBuilder: (cxt, err) => Container(
            color: Colors.red,
            child: Center(
              child: Text(t('qr_error', fallback: 'Error al generar el QR')),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.getText;
    final isValid = _isValidUrl(_controller.text);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Expanded(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // Input area con handle de redimensionado
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              decoration: InputDecoration(
                                hintText: t(
                                  'qr_label_url',
                                  fallback: 'URL a codificar',
                                ),
                                hintStyle: TextStyle(
                                  color: Colors.white.withOpacity(0.3),
                                ),
                                border: InputBorder.none,
                                errorText: _errorText,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                isDense: true,
                              ),
                              style: const TextStyle(fontSize: 15),
                              keyboardType: TextInputType.url,
                              onChanged: (_) {
                                if (_errorText != null) {
                                  setState(() => _errorText = null);
                                }
                                setState(
                                  () {},
                                ); // refrescar QR mientras escribe
                              },
                              onSubmitted: (_) => _openUrl(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.open_in_new),
                            label: Text(
                              t('open_link', fallback: 'Abrir enlace'),
                            ),
                            onPressed: _openUrl,
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
                                24,
                                124,
                                255,
                              ),
                              foregroundColor: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Acciones principales
                    // Row(
                    //   children: [
                    //     // ElevatedButton.icon(
                    //     //   icon: const Icon(Icons.qr_code),
                    //     //   label: Text(t('generate', fallback: 'Generar')),
                    //     //   onPressed: isValid ? () => setState(() {}) : null,
                    //     //   style: ElevatedButton.styleFrom(
                    //     //     shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
                    //     //     padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    //     //     backgroundColor: const Color.fromARGB(255, 24, 124, 255),
                    //     //     foregroundColor: Colors.black87,
                    //     //   ),
                    //     // ),
                    //     // ElevatedButton.icon(
                    //     //   icon: const Icon(Icons.folder_open),
                    //     //   label: Text(t('folder_button', fallback: 'Carpeta')),
                    //     //   onPressed: _selectSaveFolder,
                    //     //   style: ElevatedButton.styleFrom(
                    //     //     shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
                    //     //     padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    //     //     backgroundColor: Colors.grey[200],
                    //     //     foregroundColor: Colors.black87,
                    //     //   ),
                    //     // ),
                    //     // const SizedBox(width: 12),
                    //     // Expanded(
                    //     //   child: Text(
                    //     //     _saveFolder ?? t('no_folder_selected', fallback: 'Ninguna carpeta seleccionada'),
                    //     //     overflow: TextOverflow.ellipsis,
                    //     //     style: const TextStyle(fontSize: 12),
                    //     //   ),
                    //     // ),
                    //     // const SizedBox(width: 8),
                    //     // ElevatedButton.icon(
                    //     //   icon: const Icon(Icons.copy),
                    //     //   label: Text(t('copy', fallback: 'Copiar')),
                    //     //   onPressed: _copyUrl,
                    //     //   style: ElevatedButton.styleFrom(
                    //     //     shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
                    //     //     padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    //     //     backgroundColor: Colors.grey[200],
                    //     //     foregroundColor: Colors.black87,
                    //     //   ),
                    //     // ),
                    // //     const SizedBox(width: 8),
                    // //     ElevatedButton.icon(
                    // //       icon: const Icon(Icons.open_in_new),
                    // //       label: Text(t('open_link', fallback: 'Abrir enlace')),
                    // //       onPressed: _openUrl,
                    // //       style: ElevatedButton.styleFrom(
                    // //         shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
                    // //         padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    // //         backgroundColor: const Color.fromARGB(255, 24, 124, 255),
                    // //         foregroundColor: Colors.black87,
                    // //       ),
                    // //     ),
                    // //   ],
                    // // ),
                    // // const SizedBox(height: 16),

                    // Área del QR
                    Expanded(child: Center(child: _buildQrArea())),
                    const SizedBox(height: 12),

                    // Control de tamaño
                    Row(
                      children: [
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: const Color.fromARGB(
                                255,
                                24,
                                124,
                                255,
                              ),
                              inactiveTrackColor: Colors.white24,
                              thumbColor: const Color.fromARGB(
                                255,
                                24,
                                124,
                                255,
                              ),
                              overlayColor: const Color.fromARGB(
                                255,
                                24,
                                124,
                                255,
                              ).withOpacity(0.24),
                              valueIndicatorColor: const Color.fromARGB(
                                255,
                                24,
                                124,
                                255,
                              ),
                              trackHeight: 4.0,
                            ),
                            child: Slider(
                              min: 128,
                              max: 640,
                              divisions: 7,
                              label: '${_size.round()}',
                              value: _size,
                              onChanged: (v) => setState(() => _size = v),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('${_size.round()} px'),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Colores y margen
                    Row(
                      children: [
                        Text(t('fg', fallback: 'Color frontal')),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _pickColor(true),
                          child: Container(width: 28, height: 28, color: _fg),
                        ),
                        const SizedBox(width: 16),
                        Text(t('bg', fallback: 'Color de fondo')),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _pickColor(false),
                          child: Container(width: 28, height: 28, color: _bg),
                        ),
                        const SizedBox(width: 16),
                        Row(
                          children: [
                            Checkbox(
                              value: _includeMargin,
                              onChanged: (v) =>
                                  setState(() => _includeMargin = v ?? false),
                              fillColor:
                                  WidgetStateProperty.resolveWith<Color?>((
                                    states,
                                  ) {
                                    if (states.contains(WidgetState.selected)) {
                                      return const Color.fromARGB(
                                        255,
                                        24,
                                        124,
                                        255,
                                      );
                                    }
                                    if (states.contains(WidgetState.disabled)) {
                                      return Colors.grey;
                                    }
                                    return Colors.white24;
                                  }),
                              side: const BorderSide(
                                color: Colors.white30,
                                width: 1,
                              ),
                              splashRadius: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(t('margin', fallback: 'Margen')),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: _processing
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.save),
                            label: Text(
                              t('save_share', fallback: 'Guardar y Compartir'),
                            ),
                            onPressed: (!_processing && isValid)
                                ? _saveAndShare
                                : null,
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
                              backgroundColor: const ui.Color.fromARGB(
                                255,
                                255,
                                255,
                                255,
                              ),
                              foregroundColor: Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickColor(bool foreground) async {
    final choices = <Color>[
      Colors.black,
      Colors.white,
      Colors.red,
      Colors.green,
      Colors.blue,
      Colors.amber,
      Colors.purple,
      Colors.cyan,
    ];
    final color = await showDialog<Color?>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(widget.getText('pick_color', fallback: 'Elegir color')),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: choices.map((c) {
            return GestureDetector(
              onTap: () => Navigator.of(context).pop(c),
              child: Container(width: 36, height: 36, color: c),
            );
          }).toList(),
        ),
      ),
    );
    if (color != null) {
      setState(() {
        if (foreground) {
          _fg = color;
        } else {
          _bg = color;
        }
      });
    }
  }
}
