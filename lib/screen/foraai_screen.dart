import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import '../config/api_config.dart';
import '../widgets/elegant_notification.dart';

class ForaaiScreen extends StatefulWidget {
  final String Function(String key, {String? fallback}) getText;
  final String currentLang;

  const ForaaiScreen({
    super.key,
    required this.getText,
    required this.currentLang,
  });

  @override
  State<ForaaiScreen> createState() => _ForaaiScreenState();
}

class _ForaaiScreenState extends State<ForaaiScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();

  List<ChatSession> _sessions = [];
  String? _currentSessionId;
  bool _isLoading = false;
  bool _sidebarOpen = true;
  AIProvider _selectedProvider = ApiConfig.activeProvider;
  File? _selectedImage;

  // Sistema de límites
  final Map<AIProvider, int> _apiCallsRemaining = {};
  final Map<AIProvider, DateTime> _lastResetTime = {};

  @override
  void initState() {
    super.initState();
    _loadSessions();
    _loadRateLimits();
    // Scroll al último mensaje después de que el widget se construya
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ============================================================================
  // SISTEMA DE LÍMITES DE LLAMADAS
  // ============================================================================

  /// Límites por proveedor (llamadas por hora)
  static const Map<AIProvider, int> _rateLimits = {
    AIProvider.groq: 100, // Para testing, cambiar a 30 después
    AIProvider.gemini: 100, // Para testing, cambiar a 15 después
    AIProvider.openrouter: 0, // Para testing, cambiar a 20 después
  };

  Future<void> _loadRateLimits() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    for (var provider in AIProvider.values) {
      final key = 'rate_limit_${provider.name}';
      final remaining = prefs.getInt(key) ?? _rateLimits[provider]!;
      final lastReset = prefs.getString('${key}_reset');

      _apiCallsRemaining[provider] = remaining;
      _lastResetTime[provider] = lastReset != null
          ? DateTime.parse(lastReset)
          : DateTime.now();
    }

    setState(() {});
    _checkAndResetLimits();
  }

  Future<void> _saveRateLimits() async {
    final prefs = await SharedPreferences.getInstance();

    for (var provider in AIProvider.values) {
      final key = 'rate_limit_${provider.name}';
      await prefs.setInt(key, _apiCallsRemaining[provider] ?? 0);
      await prefs.setString(
        '${key}_reset',
        _lastResetTime[provider]!.toIso8601String(),
      );
    }
  }

  void _checkAndResetLimits() {
    final now = DateTime.now();
    bool needsSave = false;

    for (var provider in AIProvider.values) {
      final lastReset = _lastResetTime[provider]!;
      final hoursSinceReset = now.difference(lastReset).inHours;

      if (hoursSinceReset >= 1) {
        _apiCallsRemaining[provider] = _rateLimits[provider]!;
        _lastResetTime[provider] = now;
        needsSave = true;
      }
    }

    if (needsSave) {
      setState(() {});
      _saveRateLimits();
    }
  }

  bool _canMakeApiCall(AIProvider provider) {
    _checkAndResetLimits();
    return (_apiCallsRemaining[provider] ?? 0) > 0;
  }

  void _decrementApiCall(AIProvider provider) {
    if (_apiCallsRemaining[provider] != null &&
        _apiCallsRemaining[provider]! > 0) {
      _apiCallsRemaining[provider] = _apiCallsRemaining[provider]! - 1;
      setState(() {});
      _saveRateLimits();
    }
  }

  String _getTimeUntilReset(AIProvider provider) {
    final lastReset = _lastResetTime[provider];
    if (lastReset == null) return '60 min';

    final nextReset = lastReset.add(const Duration(hours: 1));
    final diff = nextReset.difference(DateTime.now());

    if (diff.inMinutes <= 0) return '0 min';
    return '${diff.inMinutes} min';
  }

  // ============================================================================
  // GESTIÓN DE SESIONES
  // ============================================================================

  Future<void> _loadSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final sessionsJson = prefs.getStringList('foraai_sessions') ?? [];

      setState(() {
        _sessions =
            sessionsJson
                .map((s) => ChatSession.fromJson(jsonDecode(s)))
                .toList()
              ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

        if (_sessions.isNotEmpty && _currentSessionId == null) {
          _currentSessionId = _sessions.first.id;
        } else if (_sessions.isEmpty) {
          _createNewSession();
        }
      });
    } catch (e) {
      debugPrint('Error loading sessions: $e');
      // En caso de error (data corrupta), iniciamos limpio para no crashear
      setState(() {
        _sessions = [];
        _createNewSession();
      });
    }
  }

  Future<void> _saveSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = _sessions.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList('foraai_sessions', sessionsJson);
  }

  void _createNewSession() {
    final newSession = ChatSession(
      id: const Uuid().v4(),
      title: widget.getText('new_chat', fallback: 'Nuevo Chat'),
      messages: [],
      timestamp: DateTime.now(),
    );
    setState(() {
      _sessions.insert(0, newSession);
      _currentSessionId = newSession.id;
    });
    _saveSessions();
  }

  void _deleteSession(String id) {
    setState(() {
      _sessions.removeWhere((s) => s.id == id);
      if (_currentSessionId == id) {
        if (_sessions.isNotEmpty) {
          _currentSessionId = _sessions.first.id;
        } else {
          _createNewSession();
        }
      }
    });
    _saveSessions();
  }

  ChatSession? get _currentSession {
    try {
      return _sessions.firstWhere((s) => s.id == _currentSessionId);
    } catch (_) {
      return null;
    }
  }

  // ============================================================================
  // SELECTOR DE IMAGEN
  // ============================================================================

  Future<void> _pickImage() async {
    if (_selectedProvider != AIProvider.gemini) {
      _showSnackBar(widget.getText('images_only_gemini', fallback: 'Las imágenes solo están disponibles con Gemini'));
      return;
    }

    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _selectedImage = File(image.path);
        });
      }
    } catch (e) {
      _showSnackBar('${widget.getText('select_image_error', fallback: 'Error al seleccionar imagen')}: $e');
    }
  }

  void _removeImage() {
    setState(() {
      _selectedImage = null;
    });
  }

  void _handleKeyPress() {
    if (!_isLoading) {
      _sendMessage();
    }
  }

  // ============================================================================
  // API CALLS
  // ============================================================================

  List<Map<String, dynamic>> _buildMessagesForAPI(
    ChatSession session,
    String newUserText,
  ) {
    const int maxChars = 4000;
    int total = 0;
    final List<ChatMessage> reversed = List.from(session.messages.reversed);
    final List<ChatMessage> picked = [];

    for (final m in reversed) {
      if (total + m.content.length > maxChars) break;
      picked.insert(0, m);
      total += m.content.length;
    }

    return [
      {
        'role': 'system',
        'content':
            'Eres un modelo de IA avanzado entrando por Google y Meta. Tienes capacidad para buscar en internet información actualizada. '
            'Siempre trata de responder en el idioma que el usuario te habla.'
            'IMPORTANTE: Si el usuario te pide generar imágenes, aclárale que para eso debe usar la sección "Generación de Imágenes" de esta aplicación. '
            'Responde de forma clara, concisa y útil. Para código usa markdown. '
            'Tu límite de búsquedas diarias es de 500 (gratis). Úsalas sabiamente si se requiere información en tiempo real.',
      },
      ...picked.map(
        (m) => {
          'role': m.role == 'user' ? 'user' : 'assistant',
          'content': m.content,
        },
      ),
      {'role': 'user', 'content': newUserText},
    ];
  }

  Future<String> _callGroqAPI(List<Map<String, dynamic>> messages) async {
    final response = await http.post(
      Uri.parse(ApiConfig.getEndpointForProvider(_selectedProvider)),
      headers: {
        'Authorization':
            'Bearer ${ApiConfig.getApiKeyForProvider(_selectedProvider)}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': ApiConfig.getModelForProvider(_selectedProvider),
        'messages': messages,
        'temperature': 0.7,
        'max_tokens': 1024,
      }),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final data = jsonDecode(response.body);
      final choices = data['choices'] as List<dynamic>?;
      final content = choices?.isNotEmpty == true
          ? choices![0]['message']['content']
          : null;

      return (content is String && content.trim().isNotEmpty)
          ? content
          : 'Error: Respuesta vacía';
    } else {
      String errMsg = 'Failed (${response.statusCode})';
      try {
        final err = jsonDecode(response.body);
        errMsg =
            err['error']?['message']?.toString() ??
            err['message']?.toString() ??
            errMsg;
      } catch (_) {}
      throw Exception(errMsg);
    }
  }

  Future<String> _callGeminiAPI(
    List<Map<String, dynamic>> messages, {
    File? imageFile,
  }) async {
    final contents = <Map<String, dynamic>>[];

    for (var msg in messages.where((m) => m['role'] != 'system')) {
      contents.add({
        'role': msg['role'] == 'assistant' ? 'model' : 'user',
        'parts': [
          {'text': msg['content']},
        ],
      });
    }

    // Agregar imagen al último mensaje si existe
    if (imageFile != null && contents.isNotEmpty) {
      final bytes = await imageFile.readAsBytes();
      final base64Image = base64Encode(bytes);

      (contents.last['parts'] as List).add({
        'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image},
      });
    }

    final systemMsg = messages.firstWhere(
      (m) => m['role'] == 'system',
      orElse: () => {'content': ''},
    )['content'];
    if (systemMsg!.isNotEmpty && contents.isNotEmpty) {
      final firstPart = (contents.first['parts'] as List).first;
      firstPart['text'] = '$systemMsg\n\n${firstPart['text']}';
    }

    // Construir URL correcta con el modelo
    final model = ApiConfig.getModelForProvider(_selectedProvider);
    final endpoint =
        '${ApiConfig.getEndpointForProvider(_selectedProvider)}/$model:generateContent';
    final apiKey = ApiConfig.getApiKeyForProvider(_selectedProvider);

    final response = await http.post(
      Uri.parse(endpoint),
      headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey},
      body: jsonEncode({
        'contents': contents,
        'tools': [
          {'google_search': {}},
        ],
        'generationConfig': {'temperature': 0.7, 'maxOutputTokens': 2048},
      }),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final data = jsonDecode(response.body);
      return data['candidates']?[0]?['content']?['parts']?[0]?['text'] ??
          'Error: Respuesta vacía';
    } else {
      // Mostrar más detalles del error
      String errorMsg = 'HTTP ${response.statusCode}';
      try {
        final errorData = jsonDecode(response.body);
        errorMsg = errorData['error']?['message'] ?? errorMsg;
      } catch (_) {
        errorMsg = response.body;
      }
      throw Exception(errorMsg);
    }
  }

  Future<void> _sendMessage({
    String? manualText,
    bool isRegenerate = false,
  }) async {
    final text = manualText ?? _controller.text.trim();
    if (text.isEmpty) return;

    final session = _currentSession;
    if (session == null) return;

    // Verificar límite de llamadas
    if (!_canMakeApiCall(_selectedProvider)) {
      _showSnackBar(
        '${widget.getText('limit_reached', fallback: 'Límite alcanzado')}. ${widget.getText('reset_in', fallback: 'Se restablecerá en')} ${_getTimeUntilReset(_selectedProvider)}',
      );
      return;
    }

    // Validar configuración
    if (!ApiConfig.isProviderConfigured(_selectedProvider)) {
      _showSnackBar(
        '${widget.getText('api_key_not_configured', fallback: 'API key no configurada')}: ${ApiConfig.getProviderName(_selectedProvider)}',
      );
      return;
    }

    if (!isRegenerate) {
      _controller.clear();

      // Agregar mensaje del usuario
      String userContent = text;

      setState(() {
        session.messages.add(
          ChatMessage(
            role: 'user',
            content: userContent,
            imagePath: _selectedImage?.path,
          ),
        );
        session.timestamp = DateTime.now();
        _sessions.remove(session);
        _sessions.insert(0, session);
        _isLoading = true;
      });
      // Mantener el foco
      _focusNode.requestFocus();
    } else {
      setState(() => _isLoading = true);
    }

    _scrollToBottom();
    _saveSessions();

    if (session.messages.length == 1) {
      setState(() {
        session.title = text.length > 30 ? '${text.substring(0, 30)}...' : text;
      });
    }

    try {
      final messages = _buildMessagesForAPI(session, text);
      String result;

      // Llamar a la API correspondiente
      switch (_selectedProvider) {
        case AIProvider.groq:
        case AIProvider.openrouter:
          result = await _callGroqAPI(messages);
          break;
        case AIProvider.gemini:
          result = await _callGeminiAPI(messages, imageFile: _selectedImage);
          break;
      }

      // Decrementar contador de llamadas
      _decrementApiCall(_selectedProvider);

      // Limpiar imagen después de enviar
      final hadImage = _selectedImage != null;
      if (_selectedImage != null) {
        setState(() => _selectedImage = null);
      }

      if (mounted) {
        setState(() {
          session.messages.add(ChatMessage(role: 'ai', content: result));
          _isLoading = false;
        });
        _scrollToBottom();
        _saveSessions();

        if (hadImage) {
          _showSnackBar(widget.getText('image_processed', fallback: '✓ Imagen procesada correctamente'));
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          session.messages.add(
            ChatMessage(
              role: 'ai',
              content:
                  'Error (${ApiConfig.getProviderName(_selectedProvider)}): $e',
            ),
          );
          _isLoading = false;
          _selectedImage = null; // Limpiar imagen en caso de error
        });
        _scrollToBottom();
        _saveSessions();
      }
    }
  }

  void _regenerateLastResponse() {
    final session = _currentSession;
    if (session == null || session.messages.isEmpty) return;

    if (session.messages.last.role == 'ai') {
      setState(() => session.messages.removeLast());

      if (session.messages.isNotEmpty && session.messages.last.role == 'user') {
        final lastUserMessage = session.messages.last.content;
        setState(() => session.messages.removeLast());
        _sendMessage(manualText: lastUserMessage, isRegenerate: true);
      }
    }
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

  void _showSnackBar(String message) {
    if (!mounted) return;
    showElegantNotification(
      context,
      message,
      backgroundColor: const Color(0xFF2C2C2C),
      textColor: Colors.white,
      icon: Icons.info_outline,
      iconColor: Colors.white70,
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = _currentSession;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sidebar
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          width: _sidebarOpen ? 260 : 0,
          color: Colors.black.withOpacity(0.2),
          clipBehavior: Clip.hardEdge,
          child: OverflowBox(
            minWidth: 260,
            maxWidth: 260,
            alignment: Alignment.topLeft,
            child: Material(
              color: Colors.transparent,
              child: SizedBox(width: 260, child: _buildSidebar()),
            ),
          ),
        ),

        // Chat Area
        Expanded(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: session == null
                    ? const Center(child: CircularProgressIndicator())
                    : _buildMessagesList(session),
              ),
              _buildInputArea(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSidebar() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: ElevatedButton.icon(
            onPressed: _createNewSession,
            icon: const Icon(Icons.add),
            label: Text(widget.getText('new_chat', fallback: 'Nuevo Chat')),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purpleAccent.withOpacity(0.2),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 45),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: Colors.purpleAccent.withOpacity(0.5)),
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _sessions.length,
            itemBuilder: (context, index) {
              final s = _sessions[index];
              final isSelected = s.id == _currentSessionId;
              return ListTile(
                title: Text(
                  s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white70,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                selected: isSelected,
                selectedTileColor: Colors.white.withOpacity(0.05),
                onTap: () {
                  setState(() => _currentSessionId = s.id);
                  _scrollToBottom();
                },
                trailing: isSelected
                    ? IconButton(
                        icon: const Icon(
                          Icons.delete,
                          size: 16,
                          color: Colors.white54,
                        ),
                        onPressed: () => _deleteSession(s.id),
                      )
                    : null,
              );
            },
          ),
        ),
        // Información del proveedor actual
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.1)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.smart_toy,
                    size: 14,
                    color: Colors.purpleAccent.withOpacity(0.7),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    ApiConfig.getProviderName(_selectedProvider),
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              InkWell(
                onTap: _forceResetLimits,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 2,
                    horizontal: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Llamadas: ${_apiCallsRemaining[_selectedProvider]}/${_rateLimits[_selectedProvider]}',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.white.withOpacity(0.4),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.refresh,
                        size: 10,
                        color: Colors.white.withOpacity(0.3),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _forceResetLimits() {
    setState(() {
      for (var provider in AIProvider.values) {
        _apiCallsRemaining[provider] = _rateLimits[provider]!;
        _lastResetTime[provider] = DateTime.now();
      }
    });
    _saveRateLimits();
    _showSnackBar(widget.getText('limits_reset_manually', fallback: 'Límites restablecidos manualmente'));
  }

  Widget _buildHeader() {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(_sidebarOpen ? Icons.menu_open : Icons.menu),
            onPressed: () => setState(() => _sidebarOpen = !_sidebarOpen),
            tooltip: widget.getText(
              'toggle_sidebar',
              fallback: 'Alternar barra lateral',
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildMessagesList(ChatSession session) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(20),
      itemCount: session.messages.length + (_isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == session.messages.length) {
          return _buildLoadingBubble();
        }
        final msg = session.messages[index];
        final isLast = index == session.messages.length - 1;
        return _buildMessageBubble(msg, isLast: isLast);
      },
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Preview de imagen
          if (_selectedImage != null) _buildImagePreview(),

          // Input Container
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Input de texto
                    Expanded(
                      child: CallbackShortcuts(
                        bindings: {
                          const SingleActivator(LogicalKeyboardKey.enter):
                              _handleKeyPress,
                        },
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          style: const TextStyle(fontSize: 15),
                          decoration: InputDecoration(
                            hintText: widget.getText(
                              'foraai_input_hint',
                              fallback: 'Escribe un mensaje...',
                            ),
                            hintStyle: TextStyle(
                              color: Colors.white.withOpacity(0.3),
                            ),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            isDense: true,
                          ),
                          minLines: 1,
                          maxLines: 6,
                        ),
                      ),
                    ),

                    // Botones de acción
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Botón de imagen (solo para Gemini)
                        if (_selectedProvider == AIProvider.gemini)
                          IconButton(
                            onPressed: _isLoading ? null : _pickImage,
                            icon: const Icon(
                              Icons.add_photo_alternate_outlined,
                              size: 20,
                            ),
                            tooltip: 'Adjuntar imagen',
                            style: IconButton.styleFrom(
                              foregroundColor: Colors.white70,
                              padding: const EdgeInsets.all(8),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        const SizedBox(width: 4),
                        // Botón enviar
                        IconButton(
                          onPressed: _isLoading ? null : () => _sendMessage(),
                          icon: _isLoading
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
                            backgroundColor: _isLoading
                                ? Colors.grey
                                : Colors.purpleAccent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.all(8),
                            minimumSize: const Size(36, 36),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                // Barra inferior con selector de modelo pequeño
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 8, right: 8),
                  child: Row(
                    children: [
                      _buildSmallProviderSelector(),
                      const Spacer(),
                      Text(
                        '${_apiCallsRemaining[_selectedProvider]}/${_rateLimits[_selectedProvider]} • Reset: ${_getTimeUntilReset(_selectedProvider)}',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.white.withOpacity(0.3),
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
    );
  }

  Widget _buildSmallProviderSelector() {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<AIProvider>(
            value: _selectedProvider,
            dropdownColor: const Color(0xFF2d2d2d),
            icon: const Icon(
              Icons.keyboard_arrow_down,
              size: 14,
              color: Colors.white54,
            ),
            isDense: true,
            style: const TextStyle(color: Colors.white, fontSize: 11),
            onChanged: _isLoading
                ? null
                : (AIProvider? newValue) {
                    if (newValue != null) {
                      setState(() {
                        _selectedProvider = newValue;
                        _selectedImage = null;
                      });
                    }
                  },
            items: AIProvider.values.map((AIProvider provider) {
              return DropdownMenuItem<AIProvider>(
                value: provider,
                child: Text(ApiConfig.getProviderName(provider)),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildImagePreview() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.purpleAccent.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.file(
              _selectedImage!,
              width: 60,
              height: 60,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Imagen lista para enviar',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
          IconButton(
            onPressed: _removeImage,
            icon: const Icon(Icons.close, size: 18),
            style: IconButton.styleFrom(
              foregroundColor: Colors.white54,
              padding: const EdgeInsets.all(8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, {required bool isLast}) {
    final isUser = msg.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.all(16),
            constraints: const BoxConstraints(maxWidth: 800),
            decoration: BoxDecoration(
              color: isUser
                  ? Colors.purpleAccent.withOpacity(0.2)
                  : Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(10),
                topRight: const Radius.circular(10),
                bottomLeft: isUser ? const Radius.circular(10) : Radius.zero,
                bottomRight: isUser ? Radius.zero : const Radius.circular(10),
              ),
              border: Border.all(
                color: isUser
                    ? Colors.purpleAccent.withOpacity(0.3)
                    : Colors.white.withOpacity(0.1),
              ),
            ),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Mostrar imagen si existe
                  if (msg.imagePath != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxHeight: 300,
                            maxWidth: 300,
                          ),
                          child: Image.file(
                            File(msg.imagePath!),
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                const Text(
                                  '[Imagen no disponible]',
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                          ),
                        ),
                      ),
                    ),

                  if (!isUser) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.auto_awesome,
                          size: 16,
                          color: Colors.purpleAccent,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'ForaAI',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.purpleAccent.withOpacity(0.8),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  isUser
                      ? Text(
                          msg.content,
                          style: const TextStyle(fontSize: 15, height: 1.5),
                        )
                      : MarkdownBody(
                          data: msg.content,
                          selectable: false,
                          builders: {
                            'code': CodeElementBuilder(context, widget.getText),
                          },
                          styleSheet: MarkdownStyleSheet(
                            p: const TextStyle(fontSize: 15, height: 1.5),
                            code: const TextStyle(
                              backgroundColor: Colors.transparent,
                              fontFamily: 'monospace',
                              fontSize: 14,
                            ),
                            codeblockDecoration: const BoxDecoration(
                              color: Colors.transparent,
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ),
          if (!isUser && isLast)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 8),
              child: TextButton.icon(
                onPressed: _isLoading ? null : _regenerateLastResponse,
                icon: const Icon(
                  Icons.refresh,
                  size: 14,
                  color: Colors.white54,
                ),
                label: Text(
                  widget.getText('regenerate', fallback: 'Regenerar'),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLoadingBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: const SizedBox(
          width: 40,
          height: 20,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
    );
  }
}

// ====== CLASES AUXILIARES ======
class CodeElementBuilder extends MarkdownElementBuilder {
  final BuildContext context;
  final String Function(String key, {String? fallback}) getText;

  CodeElementBuilder(this.context, this.getText);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    var language = '';
    if (element.attributes['class'] != null) {
      String lg = element.attributes['class'] as String;
      language = lg.startsWith('language-') ? lg.substring(9) : lg;
    }

    final textContent = element.textContent;
    final isBlock = language.isNotEmpty || textContent.contains('\n');
    if (!isBlock) return null;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(8),
                topRight: Radius.circular(8),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  language.isEmpty ? 'Code' : language,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: textContent));
                    showElegantNotification(
                      context,
                      getText('code_copied', fallback: 'Copiado'),
                      backgroundColor: const Color(0xFF2C2C2C),
                      textColor: Colors.white,
                      icon: Icons.check_circle_outline,
                      iconColor: Colors.green,
                    );
                  },
                  child: const Row(
                    children: [
                      Icon(Icons.copy, size: 14, color: Colors.white60),
                      SizedBox(width: 4),
                      Text(
                        'Copiar',
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              textContent,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ChatSession {
  String id;
  String title;
  List<ChatMessage> messages;
  DateTime timestamp;

  ChatSession({
    required this.id,
    required this.title,
    required this.messages,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'messages': messages.map((m) => m.toJson()).toList(),
    'timestamp': timestamp.toIso8601String(),
  };

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'],
      title: json['title'],
      messages: (json['messages'] as List)
          .map((m) => ChatMessage.fromJson(m))
          .toList(),
      timestamp: DateTime.parse(json['timestamp']),
    );
  }
}

class ChatMessage {
  final String role;
  final String content;
  final String? imagePath;

  ChatMessage({required this.role, required this.content, this.imagePath});

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    if (imagePath != null) 'imagePath': imagePath,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    role: json['role'],
    content: json['content'],
    imagePath: json['imagePath'],
  );
}
