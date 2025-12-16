import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:typed_data';
import 'package:window_manager/window_manager.dart';
import 'package:uuid/uuid.dart';
import 'config/api_config.dart';
import 'widgets/elegant_notification.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class ImageMessage {
  final String id;
  final String prompt;
  final String ratio;
  final String? imageUrl;
  final Uint8List? imageBytes;
  final bool isGenerating;
  final String? error;
  final DateTime timestamp;

  ImageMessage({
    String? id,
    required this.prompt,
    required this.ratio,
    this.imageUrl,
    this.imageBytes,
    this.isGenerating = false,
    this.error,
    DateTime? timestamp,
  }) : id = id ?? const Uuid().v4(),
       timestamp = timestamp ?? DateTime.now();

  ImageMessage copyWith({
    String? prompt,
    String? ratio,
    String? imageUrl,
    Uint8List? imageBytes,
    bool? isGenerating,
    String? error,
  }) {
    return ImageMessage(
      id: id,
      prompt: prompt ?? this.prompt,
      ratio: ratio ?? this.ratio,
      imageUrl: imageUrl ?? this.imageUrl,
      imageBytes: imageBytes ?? this.imageBytes,
      isGenerating: isGenerating ?? this.isGenerating,
      error: error ?? this.error,
      timestamp: timestamp,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'prompt': prompt,
      'ratio': ratio,
      'imageUrl': imageUrl,
      'imageBytes': imageBytes != null ? base64Encode(imageBytes!) : null,
      'isGenerating': isGenerating,
      'error': error,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory ImageMessage.fromJson(Map<String, dynamic> json) {
    return ImageMessage(
      id: json['id'] as String,
      prompt: json['prompt'] as String,
      ratio: json['ratio'] as String,
      imageUrl: json['imageUrl'] as String?,
      imageBytes: json['imageBytes'] != null
          ? base64Decode(json['imageBytes'] as String)
          : null,
      isGenerating: json['isGenerating'] as bool? ?? false,
      error: json['error'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}

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
  final ScrollController _scrollController = ScrollController();
  String _ratio = '16:9';
  bool _loading = false;
  String? _saveFolder;
  SharedPreferences? _prefs;
  List<ImageMessage> _messages = [];
  final http.Client _http = http.Client();

  static const _prefsKey = 'image_download_folder';
  static const _messagesPrefsKey = 'imgia_messages';

  // Helper: GET seguro (similar a Spotify screen)
  Future<http.Response?> _safeGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    try {
      final res = await _http.get(uri).timeout(timeout);
      return res;
    } on TimeoutException catch (e, st) {
      debugPrint('[AiImageScreen] Timeout GET $uri: $e\n$st');
      return null;
    } on SocketException catch (e, st) {
      debugPrint('[AiImageScreen] SocketException GET $uri: $e\n$st');
      return null;
    } on HttpException catch (e, st) {
      debugPrint('[AiImageScreen] HttpException GET $uri: $e\n$st');
      return null;
    } catch (e, st) {
      if (e.toString().contains('Connection closed') ||
          e.toString().contains('Socket is closed')) {
        debugPrint(
          '[AiImageScreen] Connection closed (widget likely disposed): $uri',
        );
        return null;
      }
      debugPrint('[AiImageScreen] Unknown error GET $uri: $e\n$st');
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _loadFolderPref();
    _loadMessages();

    if (widget.onRegisterFolderAction != null) {
      widget.onRegisterFolderAction!(_selectFolder);
    }

    // Scroll al último mensaje después de que el widget se construya
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _promptController.dispose();
    _scrollController.dispose();
    _saveMessages();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
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

  Future<void> _loadMessages() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final messagesJson = _prefs!.getStringList(_messagesPrefsKey) ?? [];
      if (!mounted) return;
      setState(() {
        _messages = messagesJson
            .map((s) => ImageMessage.fromJson(jsonDecode(s)))
            .toList();
      });
    } catch (_) {}
  }

  Future<void> _saveMessages() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final messagesJson = _messages
          .map((m) => jsonEncode(m.toJson()))
          .toList();
      await _prefs!.setStringList(_messagesPrefsKey, messagesJson);
    } catch (_) {}
  }

  Future<void> _selectFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    _saveFolder = p.normalize(dir);
    await _saveFolderPref();
    if (!mounted) return;
    showElegantNotification(
      context,
      '${widget.getText('save_folder_set', fallback: 'Save folder set')}: $_saveFolder',
      backgroundColor: const Color(0xFF2C2C2C),
      textColor: Colors.white,
      icon: Icons.folder_open,
      iconColor: Colors.blue,
    );
  }

  String _buildApiUrl(String prompt, String ratio) {
    final encoded = Uri.encodeComponent(prompt);
    final r = Uri.encodeComponent(ratio);
    return '${ApiConfig.dorratzBaseUrl}/v3/ai-image?prompt=$encoded&ratio=$r';
  }

  Future<void> _generateImage() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      if (!mounted) return;
      showElegantNotification(
        context,
        widget.getText('enter_prompt', fallback: 'Enter a prompt'),
        backgroundColor: const Color(0xFFE53935),
        textColor: Colors.white,
        icon: Icons.error_outline,
        iconColor: Colors.white,
      );
      return;
    }

    if (_loading) return;

    // Add message to chat
    final messageId = const Uuid().v4();
    if (!mounted) return;
    setState(() {
      _messages.add(
        ImageMessage(
          id: messageId,
          prompt: prompt,
          ratio: _ratio,
          isGenerating: true,
        ),
      );
      _loading = true;
      _promptController.clear();
    });
    _scrollToBottom();
    _saveMessages();

    try {
      debugPrint('[AiImageScreen] Starting image generation...');
      final url = _buildApiUrl(prompt, _ratio);
      debugPrint('[AiImageScreen] Requesting: $url');

      final res = await _safeGet(Uri.parse(url));

      if (res == null) {
        throw Exception('Failed to connect to API');
      }

      debugPrint('[AiImageScreen] Response status: ${res.statusCode}');
      debugPrint('[AiImageScreen] Response body: ${res.body}');

      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }

      // Parse JSON safely
      final dynamic parsedJson = jsonDecode(res.body);
      if (parsedJson is! Map<String, dynamic>) {
        throw Exception(
          'Invalid JSON structure: expected Map, got ${parsedJson.runtimeType}',
        );
      }

      final parsed = parsedJson;

      // Check for data field
      if (!parsed.containsKey('data')) {
        throw Exception('Missing "data" field in response');
      }

      final dynamic dataField = parsed['data'];
      if (dataField is! Map<String, dynamic>) {
        throw Exception(
          'Invalid "data" field: expected Map, got ${dataField.runtimeType}',
        );
      }

      final data = dataField;
      final imageLink = data['image_link'] as String?;
      final status = data['status'] as String?;

      debugPrint('[AiImageScreen] Status: $status, Image link: $imageLink');

      if (status != 'success' || imageLink == null || imageLink.isEmpty) {
        throw Exception('API error: status=$status, imageLink=$imageLink');
      }

      // Download image bytes using safe GET
      debugPrint('[AiImageScreen] Downloading image from: $imageLink');
      final imgRes = await _safeGet(Uri.parse(imageLink));

      if (imgRes == null) {
        throw Exception('Failed to download image: network error');
      }

      if (imgRes.statusCode != 200) {
        throw Exception('Image download failed: HTTP ${imgRes.statusCode}');
      }

      final imageBytes = imgRes.bodyBytes;
      debugPrint(
        '[AiImageScreen] Image downloaded successfully, size: ${imageBytes.length} bytes',
      );

      if (!mounted) {
        debugPrint('[AiImageScreen] Widget unmounted, aborting');
        return;
      }

      try {
        debugPrint('[AiImageScreen] Updating message state...');
        setState(() {
          final index = _messages.indexWhere((m) => m.id == messageId);
          debugPrint('[AiImageScreen] Message index: $index');
          if (index != -1) {
            _messages[index] = _messages[index].copyWith(
              imageUrl: imageLink,
              imageBytes: imageBytes,
              isGenerating: false,
            );
            debugPrint('[AiImageScreen] Message updated successfully');
          }
          _loading = false;
        });

        debugPrint('[AiImageScreen] State updated, scrolling...');
        _scrollToBottom();

        debugPrint('[AiImageScreen] Saving messages...');
        await _saveMessages();
        debugPrint('[AiImageScreen] Generation completed successfully!');
      } catch (e, stackTrace) {
        debugPrint('[AiImageScreen] Error in setState/save: $e');
        debugPrint('[AiImageScreen] Stack trace: $stackTrace');
        rethrow;
      }
    } on SocketException catch (e) {
      debugPrint('[AiImageScreen] SocketException: $e');
      if (!mounted) return;
      setState(() {
        final index = _messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          _messages[index] = _messages[index].copyWith(
            isGenerating: false,
            error: widget.getText('network_error', fallback: 'Network error'),
          );
        }
        _loading = false;
      });
      _saveMessages();
    } on HttpException catch (e) {
      debugPrint('[AiImageScreen] HttpException: $e');
      if (!mounted) return;
      setState(() {
        final index = _messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          _messages[index] = _messages[index].copyWith(
            isGenerating: false,
            error: widget.getText('network_error', fallback: 'Network error'),
          );
        }
        _loading = false;
      });
      _saveMessages();
    } on TimeoutException catch (e) {
      debugPrint('[AiImageScreen] TimeoutException: $e');
      if (!mounted) return;
      setState(() {
        final index = _messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          _messages[index] = _messages[index].copyWith(
            isGenerating: false,
            error: widget.getText(
              'timeout_error',
              fallback: 'La generación tardó demasiado. Intenta de nuevo.',
            ),
          );
        }
        _loading = false;
      });
      _saveMessages();
    } catch (e) {
      // Silently ignore connection closed errors during dispose
      if (e.toString().contains('Connection closed') ||
          e.toString().contains('Socket is closed')) {
        debugPrint(
          '[AiImageScreen] Connection closed (widget likely disposed)',
        );
        return;
      }

      debugPrint('[AiImageScreen] Error: $e');
      if (!mounted) return;

      setState(() {
        final index = _messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          _messages[index] = _messages[index].copyWith(
            isGenerating: false,
            error:
                widget.getText(
                  'generation_error',
                  fallback: 'Error al generar imagen',
                ) +
                ': ${e.toString().split('\n').first}',
          );
        }
        _loading = false;
      });
      _saveMessages();
    }
  }

  Future<void> _saveImage(ImageMessage message) async {
    if (message.imageBytes == null) {
      showElegantNotification(
        context,
        widget.getText('no_image_to_save', fallback: 'No image to save'),
        backgroundColor: const Color(0xFFE53935),
        textColor: Colors.white,
        icon: Icons.error_outline,
        iconColor: Colors.white,
      );
      return;
    }

    String folder = _saveFolder ?? '';
    if (folder.isEmpty) {
      final picked = await FilePicker.platform.getDirectoryPath();
      if (picked == null) {
        showElegantNotification(
          context,
          widget.getText('save_cancelled', fallback: 'Save cancelled'),
          backgroundColor: const Color(0xFF2C2C2C),
          textColor: Colors.white,
          icon: Icons.cancel_outlined,
          iconColor: Colors.orange,
        );
        return;
      }
      folder = p.normalize(picked);
      _saveFolder = folder;
      await _saveFolderPref();
    }

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final ext = _guessExtensionFromBytes(message.imageBytes!) ?? '.jpg';
      final fileName = 'ai_image_$timestamp$ext';
      final path = p.join(folder, fileName);
      final f = File(path);
      await f.create(recursive: true);
      await f.writeAsBytes(message.imageBytes!);

      if (!mounted) return;
      showElegantNotification(
        context,
        '${widget.getText('saved_to', fallback: 'Saved to')}: $path',
        backgroundColor: const Color(0xFF2C2C2C),
        textColor: Colors.white,
        icon: Icons.save_alt,
        iconColor: Colors.green,
      );
    } catch (e) {
      if (!mounted) return;
      showElegantNotification(
        context,
        '${widget.getText('save_error', fallback: 'Error saving')}: $e',
        backgroundColor: const Color(0xFFE53935),
        textColor: Colors.white,
        icon: Icons.error_outline,
        iconColor: Colors.white,
      );
    }
  }

  void _deleteMessage(String messageId) {
    setState(() {
      _messages.removeWhere((m) => m.id == messageId);
    });
    _saveMessages();
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

  void _showContextMenu(ImageMessage message, Offset position) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 100,
        position.dy + 100,
      ),
      items: [
        if (message.imageBytes != null)
          PopupMenuItem(
            child: Row(
              children: [
                const Icon(Icons.save, size: 18),
                const SizedBox(width: 8),
                Text(widget.getText('save_button', fallback: 'Save')),
              ],
            ),
            onTap: () => _saveImage(message),
          ),
        if (message.imageUrl != null)
          PopupMenuItem(
            child: Row(
              children: [
                const Icon(Icons.open_in_new, size: 18),
                const SizedBox(width: 8),
                Text(widget.getText('open_link', fallback: 'Open link')),
              ],
            ),
            onTap: () async {
              final uri = Uri.tryParse(message.imageUrl!);
              if (uri != null) {
                try {
                  if (Platform.isWindows) {
                    await Process.start('explorer', [uri.toString()]);
                  } else if (Platform.isMacOS) {
                    await Process.start('open', [uri.toString()]);
                  } else {
                    await Process.start('xdg-open', [uri.toString()]);
                  }
                } catch (_) {}
              }
            },
          ),
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.delete, size: 18, color: Colors.red),
              const SizedBox(width: 8),
              Text(
                widget.getText('delete_button', fallback: 'Delete'),
                style: const TextStyle(color: Colors.red),
              ),
            ],
          ),
          onTap: () => _deleteMessage(message.id),
        ),
      ],
    );
  }

  Widget _buildMessageBubble(ImageMessage message) {
    return GestureDetector(
      onSecondaryTapDown: (details) {
        _showContextMenu(message, details.globalPosition);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Prompt bubble
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.purpleAccent.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.purpleAccent.withOpacity(0.3)),
              ),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.7,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    message.prompt,
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodyLarge?.color,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Ratio badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardTheme.color,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Theme.of(context).dividerColor),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.aspect_ratio,
                          size: 12,
                          color: Theme.of(
                            context,
                          ).iconTheme.color?.withOpacity(0.6),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          message.ratio,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(
                              context,
                            ).textTheme.bodyMedium?.color?.withOpacity(0.7),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Image response or error
          if (message.error != null)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.red,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          message.error!,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            )
          else if (message.isGenerating)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(widget.getText('generating', fallback: 'Generating...')),
                ],
              ),
            )
          else if (message.imageBytes != null)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.65,
                maxHeight: 300,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(message.imageBytes!, fit: BoxFit.contain),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final get = widget.getText;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            // Chat messages area
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.image_not_supported,
                            size: 48,
                            color: Colors.white.withOpacity(0.3),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            get('no_image_ui', fallback: 'No images yet'),
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.5),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        return _buildMessageBubble(_messages[index]);
                      },
                    ),
            ),

            // Input area
            Container(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Input container with styled input
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardTheme.color,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(context).dividerColor),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            // Input de texto
                            Expanded(
                              child: TextField(
                                controller: _promptController,
                                style: const TextStyle(fontSize: 15),
                                decoration: InputDecoration(
                                  hintText: get(
                                    'prompt_hint',
                                    fallback: 'Describe the image you want...',
                                  ),
                                  hintStyle: Theme.of(
                                    context,
                                  ).inputDecorationTheme.hintStyle,
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  isDense: true,
                                ),
                                minLines: 1,
                                maxLines: 6,
                                onSubmitted: (_) {
                                  if (!_loading) _generateImage();
                                },
                              ),
                            ),

                            // Botón enviar
                            IconButton(
                              onPressed: _loading
                                  ? null
                                  : () => _generateImage(),
                              icon: _loading
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.arrow_upward, size: 20),
                              style: IconButton.styleFrom(
                                backgroundColor: _loading
                                    ? Colors.grey
                                    : const Color.fromARGB(255, 255, 251, 18),
                                foregroundColor: Colors.black87,
                                padding: const EdgeInsets.all(8),
                                minimumSize: const Size(36, 36),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ],
                        ),

                        // Barra inferior con selector de ratio
                        Padding(
                          padding: const EdgeInsets.only(
                            top: 8,
                            left: 8,
                            right: 8,
                          ),
                          child: Row(
                            children: [
                              Container(
                                height: 24,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).cardTheme.color,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    DropdownButton<String>(
                                      value: _ratio,
                                      underline: const SizedBox.shrink(),
                                      dropdownColor:
                                          Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? const Color(0xFF1E1E1E)
                                          : const Color(0xFFEEEEEE),
                                      borderRadius: BorderRadius.circular(10),
                                      focusColor: Colors
                                          .transparent, // Evita el resaltado persistente
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
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
