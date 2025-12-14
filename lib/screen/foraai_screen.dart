import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
// import 'package:image_picker/image_picker.dart'; // Deshabilitado hasta que haya soporte de imágenes
import '../config/api_config.dart';
import '../widgets/elegant_notification.dart';

/// Simple token for cancelling HTTP requests
class CancelToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
  }

  void checkCancelled() {
    if (_isCancelled) {
      throw TimeoutException('Request was cancelled', null);
    }
  }
}

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
  // final ImagePicker _imagePicker = ImagePicker(); // Deshabilitado hasta que haya soporte de imágenes

  List<ChatSession> _sessions = [];
  String? _currentSessionId;
  bool _isLoading = false;
  bool _sidebarOpen = false; // Se cargará desde SharedPreferences
  AIProvider _selectedProvider = ApiConfig.activeProvider;
  File?
  _selectedImage; // Mantener para compatibilidad con API, aunque no se use actualmente

  // Sistema de límites
  final Map<AIProvider, int> _apiCallsRemaining = {};
  final Map<AIProvider, DateTime> _lastResetTime = {};

  // HTTP request management
  http.Client? _httpClient;
  final List<CancelToken> _pendingRequests = [];

  // Preferencias del usuario
  String _userName = 'Usuario';
  String _aiPersonality = 'amigable'; // amigable, profesional, casual
  String _responseLength = 'balanceado'; // corto, balanceado, detallado

  @override
  void initState() {
    super.initState();
    _httpClient = http.Client();
    _loadSidebarState();
    _loadUserPreferences();
    _loadSessions();
    _loadRateLimits();
    // Scroll al último mensaje después de que el widget se construya
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    // Cancel all pending HTTP requests
    for (final token in _pendingRequests) {
      token.cancel();
    }
    _pendingRequests.clear();

    // Close HTTP client
    _httpClient?.close();

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
    AIProvider.groq: 50,
    AIProvider.openrouter: 30,
    AIProvider.gpt_oss: 1000000, // Ilimitado prácticamente
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
  // SIDEBAR STATE PERSISTENCE
  // ============================================================================

  Future<void> _loadSidebarState() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sidebarOpen = prefs.getBool('sidebar_open') ?? true;
    });
  }

  Future<void> _saveSidebarState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sidebar_open', _sidebarOpen);
  }

  // ============================================================================
  // USER PREFERENCES
  // ============================================================================

  Future<void> _loadUserPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _userName = prefs.getString('user_name') ?? 'Usuario';
      _aiPersonality = prefs.getString('ai_personality') ?? 'amigable';
      _responseLength = prefs.getString('response_length') ?? 'balanceado';
    });
  }

  Future<void> _saveUserPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', _userName);
    await prefs.setString('ai_personality', _aiPersonality);
    await prefs.setString('response_length', _responseLength);
  }

  void _showPreferencesDialog() {
    final nameController = TextEditingController(text: _userName);
    String tempPersonality = _aiPersonality;
    String tempLength = _responseLength;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 40,
            vertical: 24,
          ),
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          title: Row(
            children: [
              const Icon(Icons.settings, color: Colors.purpleAccent),
              const SizedBox(width: 8),
              Text(
                widget.getText('preferences', fallback: 'Preferencias'),
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
          content: SizedBox(
            width: double
                .maxFinite, // Forza al diálogo a tomar todo el ancho permitido por insetPadding
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Cómo te llamo
                  Text(
                    widget.getText(
                      'how_to_call_you',
                      fallback: '¿Cómo quieres que te llame?',
                    ),
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Tu nombre',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Personalidad de la IA
                  Text(
                    widget.getText(
                      'ai_personality',
                      fallback: 'Personalidad de la IA',
                    ),
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  ...[
                    ('amigable', 'Amigable y cercano'),
                    ('profesional', 'Profesional y formal'),
                    ('casual', 'Casual y relajado'),
                  ].map(
                    (option) => RadioListTile<String>(
                      value: option.$1,
                      groupValue: tempPersonality,
                      onChanged: (value) {
                        setDialogState(() => tempPersonality = value!);
                      },
                      title: Text(
                        option.$2,
                        style: const TextStyle(color: Colors.white),
                      ),
                      activeColor: Colors.purpleAccent,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Longitud de respuestas
                  Text(
                    widget.getText(
                      'response_length',
                      fallback: 'Longitud de respuestas',
                    ),
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  ...[
                    ('corto', 'Cortas y directas'),
                    ('balanceado', 'Balanceadas'),
                    ('detallado', 'Detalladas y completas'),
                  ].map(
                    (option) => RadioListTile<String>(
                      value: option.$1,
                      groupValue: tempLength,
                      onChanged: (value) {
                        setDialogState(() => tempLength = value!);
                      },
                      title: Text(
                        option.$2,
                        style: const TextStyle(color: Colors.white),
                      ),
                      activeColor: Colors.purpleAccent,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                widget.getText('cancel', fallback: 'Cancelar'),
                style: const TextStyle(color: Colors.white54),
              ),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _userName = nameController.text.trim().isEmpty
                      ? 'Usuario'
                      : nameController.text.trim();
                  _aiPersonality = tempPersonality;
                  _responseLength = tempLength;
                });
                _saveUserPreferences();
                Navigator.pop(context);
                _showSnackBar(
                  widget.getText(
                    'preferences_saved',
                    fallback: 'Preferencias guardadas',
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purpleAccent,
                foregroundColor: Colors.white,
              ),
              child: Text(widget.getText('save', fallback: 'Guardar')),
            ),
          ],
        ),
      ),
    );
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
    if (_currentSessionId == null || _sessions.isEmpty) return null;
    try {
      return _sessions.firstWhere(
        (s) => s.id == _currentSessionId,
        orElse: () => _sessions.first,
      );
    } catch (_) {
      return null;
    }
  }

  // ============================================================================
  // SELECTOR DE IMAGEN (DESHABILITADO - Ningún modelo actual soporta imágenes)
  // ============================================================================

  /*
  Future<void> _pickImage() async {
    // Ningún proveedor actual soporta imágenes
    _showSnackBar(
      widget.getText(
        'images_not_supported',
        fallback: 'Las imágenes no están disponibles actualmente',
      ),
    );
  }
  */

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

  // ============================================================================
  // CONSTRUCCIÓN DE MENSAJES POR PROVEEDOR
  // ============================================================================

  /// Construye mensajes para Groq (Muyai) - Rápido y directo
  List<Map<String, dynamic>> _buildMessagesForGroq(
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

    // Construir prompt personalizado
    String personalityPrompt = '';
    switch (_aiPersonality) {
      case 'amigable':
        personalityPrompt =
            'Sé amigable y buena onda con el usuario. Puedes responder con confianza. ';
        break;
      case 'profesional':
        personalityPrompt =
            'Mantén un tono profesional y formal. Sé respetuoso y preciso. ';
        break;
      case 'casual':
        personalityPrompt =
            'Sé casual y relajado. Puedes usar expresiones coloquiales apropiadas. ';
        break;
    }

    String lengthPrompt = '';
    switch (_responseLength) {
      case 'corto':
        lengthPrompt = 'Proporciona respuestas breves y al punto. ';
        break;
      case 'balanceado':
        lengthPrompt =
            'Proporciona respuestas balanceadas, ni muy cortas ni muy largas. ';
        break;
      case 'detallado':
        lengthPrompt =
            'Proporciona respuestas detalladas con explicaciones completas. ';
        break;
    }

    // Determinar si es el primer mensaje (sin historial)
    final isFirstMessage = picked.isEmpty;
    String introPrompt = isFirstMessage
        ? 'Si es tu primera interacción, preséntate brevemente como Muyai. '
        : '';

    return [
      {
        'role': 'system',
        'content':
            'Eres Muyai, un asistente de IA rápido y eficiente. '
            '$introPrompt'
            'Tienes capacidad para buscar en internet información actualizada. '
            'Tu objetivo es proporcionar respuestas claras, concisas y precisas. '
            'Siempre responde en el idioma que el usuario te habla. '
            'Para código, usa formato markdown con bloques de código apropiados. '
            'Si el usuario pide generar imágenes, indícale que use la sección "Generación de Imágenes" de la aplicación. '
            '$personalityPrompt'
            '$lengthPrompt'
            'El usuario prefiere que lo llames "$_userName". '
            'Sé directo y evita rodeos innecesarios. '
            'NO te presentes en cada respuesta, solo responde directamente a la pregunta.',
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

  /// Construye mensajes para GPT OSS (Oseiku) - Más detallado y educativo
  List<Map<String, dynamic>> _buildMessagesForGptOss(
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

    // Construir prompt personalizado
    String personalityPrompt = '';
    switch (_aiPersonality) {
      case 'amigable':
        personalityPrompt =
            'Sé amigable y buena onda con el usuario. Puedes responder con confianza. ';
        break;
      case 'profesional':
        personalityPrompt =
            'Mantén un tono profesional y formal. Sé respetuoso y preciso. ';
        break;
      case 'casual':
        personalityPrompt =
            'Sé casual y relajado. Puedes usar expresiones coloquiales apropiadas. ';
        break;
    }

    String lengthPrompt = '';
    switch (_responseLength) {
      case 'corto':
        lengthPrompt = 'Proporciona respuestas breves y al punto. ';
        break;
      case 'balanceado':
        lengthPrompt =
            'Proporciona respuestas balanceadas, ni muy cortas ni muy largas. ';
        break;
      case 'detallado':
        lengthPrompt =
            'Proporciona respuestas detalladas con explicaciones completas. ';
        break;
    }

    // Determinar si es el primer mensaje (sin historial)
    final isFirstMessage = picked.isEmpty;
    String introPrompt = isFirstMessage
        ? 'Si es tu primera interacción, preséntate brevemente como Oseiku. '
        : '';

    return [
      {
        'role': 'system',
        'content':
            'Eres Oseiku, un asistente de IA paciente y educativo. '
            '$introPrompt'
            'Tienes capacidad para buscar en internet información actualizada. '
            'Te tomas el tiempo para explicar conceptos de manera detallada y comprensible. '
            'Siempre responde en el idioma que el usuario te habla. '
            'Cuando proporciones código, incluye comentarios explicativos y usa markdown. '
            'Si el usuario pide generar imágenes, explícale amablemente que debe usar la sección "Generación de Imágenes". '
            '$personalityPrompt'
            '$lengthPrompt'
            'El usuario prefiere que lo llames "$_userName". '
            'Puedes proporcionar ejemplos adicionales cuando sea útil para la comprensión. '
            'NO te presentes en cada respuesta, solo responde directamente a la pregunta.',
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

  /// Construye mensajes para OpenRouter (Agayosu) - Balanceado y versátil
  List<Map<String, dynamic>> _buildMessagesForOpenRouter(
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

    // Construir prompt personalizado
    String personalityPrompt = '';
    switch (_aiPersonality) {
      case 'amigable':
        personalityPrompt =
            'Sé amigable y buena onda con el usuario. Puedes responder con confianza. ';
        break;
      case 'profesional':
        personalityPrompt =
            'Mantén un tono profesional y formal. Sé respetuoso y preciso. ';
        break;
      case 'casual':
        personalityPrompt =
            'Sé casual y relajado. Puedes usar expresiones coloquiales apropiadas. ';
        break;
    }

    String lengthPrompt = '';
    switch (_responseLength) {
      case 'corto':
        lengthPrompt = 'Proporciona respuestas breves y al punto. ';
        break;
      case 'balanceado':
        lengthPrompt =
            'Proporciona respuestas balanceadas, ni muy cortas ni muy largas. ';
        break;
      case 'detallado':
        lengthPrompt =
            'Proporciona respuestas detalladas con explicaciones completas. ';
        break;
    }

    // Determinar si es el primer mensaje (sin historial)
    final isFirstMessage = picked.isEmpty;
    String introPrompt = isFirstMessage
        ? 'Si es tu primera interacción, preséntate brevemente como Agayosu. '
        : '';

    return [
      {
        'role': 'system',
        'content':
            'Eres Agayosu, un asistente de IA balanceado y versátil. '
            '$introPrompt'
            'Tienes capacidad para buscar en internet información actualizada. '
            'Combinas velocidad con profundidad según lo requiera la situación. '
            'Siempre responde en el idioma que el usuario te habla. '
            'Eres capaz de adaptarte al tono de la conversación: formal, casual, técnico o creativo. '
            'Para código, usa markdown con sintaxis apropiada. '
            'Si el usuario pide generar imágenes, sugiérele usar la sección "Generación de Imágenes". '
            '$personalityPrompt'
            '$lengthPrompt'
            'El usuario prefiere que lo llames "$_userName". '
            'Proporciona respuestas bien estructuradas y fáciles de seguir. '
            'NO te presentes en cada respuesta, solo responde directamente a la pregunta.',
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

  Future<String> _callGroqAPI(
    List<Map<String, dynamic>> messages,
    CancelToken token,
  ) async {
    try {
      token.checkCancelled();

      final response = await _httpClient!
          .post(
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
          )
          .timeout(const Duration(seconds: 30));

      token.checkCancelled();

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
    } on TimeoutException {
      if (token.isCancelled) {
        throw TimeoutException('Request cancelled', null);
      }
      rethrow;
    }
  }

  Future<String> _callGptOssAPI(
    List<Map<String, dynamic>> messages,
    CancelToken token,
  ) async {
    try {
      token.checkCancelled();

      // Convertir historial de mensajes a un solo prompt de texto
      // El API de Dorratz espera un parámetro 'prompt' en la URL

      final StringBuffer promptBuffer = StringBuffer();

      for (final msg in messages) {
        final role = msg['role'] == 'user'
            ? 'User'
            : (msg['role'] == 'system' ? 'System' : 'AI');
        final content = msg['content'];
        promptBuffer.writeln('$role: $content');
      }

      // Añadir indicador final para el modelo
      promptBuffer.write('AI: ');

      final prompt = promptBuffer.toString();
      final encodedPrompt = Uri.encodeComponent(prompt);

      // Construir URL: https://api.dorratz.com/ai/gpt?prompt=...
      final url = '${ApiConfig.dorratzGptEndpoint}?prompt=$encodedPrompt';

      debugPrint('[Foraai] Call GPT OSS: $url');

      final response = await _httpClient!
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 45));

      token.checkCancelled();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        // Formato esperado: {"creator": "...", "result": "..."}
        try {
          final data = jsonDecode(response.body);
          final result = data['result'];

          if (result != null && result is String) {
            String cleanResult = result;
            // Remover comillas envolventes si existen
            if (cleanResult.startsWith('"') &&
                cleanResult.endsWith('"') &&
                cleanResult.length > 1) {
              cleanResult = cleanResult.substring(1, cleanResult.length - 1);
            }

            // Decodificar caracteres escapados que la API devuelve literalmente
            cleanResult = cleanResult
                .replaceAll(r'\n', '\n')
                .replaceAll(r'\"', '"')
                .replaceAll(r'\t', '\t');

            return cleanResult;
          } else {
            return 'Error: Formato de respuesta inesperado';
          }
        } catch (e) {
          // Si no es JSON válido, tal vez devolvió texto plano?
          if (response.body.isNotEmpty) return response.body;
          return 'Error parseando respuesta: $e';
        }
      } else {
        throw Exception('Failed (${response.statusCode}): ${response.body}');
      }
    } on TimeoutException {
      if (token.isCancelled) {
        throw TimeoutException('Request cancelled', null);
      }
      rethrow;
    }
  }

  Future<String> _callOpenRouterAPI(
    List<Map<String, dynamic>> messages, {
    File? imageFile,
    required CancelToken token,
  }) async {
    try {
      token.checkCancelled();

      // OpenRouter usa formato OpenAI compatible
      final apiMessages = <Map<String, dynamic>>[];

      // Agregar mensajes del historial
      for (var msg in messages) {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }

      // Si hay imagen, modificar el último mensaje de usuario para incluirla
      if (imageFile != null && apiMessages.isNotEmpty) {
        // Encontrar el último mensaje de usuario
        for (int i = apiMessages.length - 1; i >= 0; i--) {
          if (apiMessages[i]['role'] == 'user') {
            final bytes = await imageFile.readAsBytes();
            final base64Image = base64Encode(bytes);

            // Convertir contenido a formato con imagen
            final textContent = apiMessages[i]['content'];
            apiMessages[i]['content'] = [
              {'type': 'text', 'text': textContent},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$base64Image'},
              },
            ];
            break;
          }
        }
      }

      token.checkCancelled();

      final endpoint = ApiConfig.getEndpointForProvider(_selectedProvider);
      final apiKey = ApiConfig.getApiKeyForProvider(_selectedProvider);
      final model = ApiConfig.getModelForProvider(_selectedProvider);

      final response = await _httpClient!
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': model,
              'messages': apiMessages,
              'temperature': 0.7,
              'max_tokens': 2048,
            }),
          )
          .timeout(const Duration(seconds: 30));

      token.checkCancelled();

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
    } on TimeoutException {
      if (token.isCancelled) {
        throw TimeoutException('Request cancelled', null);
      }
      rethrow;
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
      // Construir mensajes según el proveedor seleccionado
      final List<Map<String, dynamic>> messages;
      switch (_selectedProvider) {
        case AIProvider.groq:
          messages = _buildMessagesForGroq(session, text);
          break;
        case AIProvider.gpt_oss:
          messages = _buildMessagesForGptOss(session, text);
          break;
        case AIProvider.openrouter:
          messages = _buildMessagesForOpenRouter(session, text);
          break;
      }

      String result;

      // Create cancel token for this request
      final cancelToken = CancelToken();
      _pendingRequests.add(cancelToken);

      try {
        // Llamar a la API correspondiente
        switch (_selectedProvider) {
          case AIProvider.groq:
            result = await _callGroqAPI(messages, cancelToken);
            break;
          case AIProvider.gpt_oss:
            result = await _callGptOssAPI(messages, cancelToken);
            break;
          case AIProvider.openrouter:
            result = await _callOpenRouterAPI(
              messages,
              imageFile: _selectedImage,
              token: cancelToken,
            );
            break;
        }
      } finally {
        _pendingRequests.remove(cancelToken);
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
          _showSnackBar(
            widget.getText(
              'image_processed',
              fallback: '✓ Imagen procesada correctamente',
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        // Check if request was cancelled
        final isCancelled =
            e is TimeoutException && e.message == 'Request was cancelled';

        setState(() {
          session.messages.add(
            ChatMessage(
              role: 'ai',
              content: isCancelled
                  ? '⏸ ${widget.getText('cancelled', fallback: 'Cancelado')}'
                  : 'Error (${ApiConfig.getProviderName(_selectedProvider)}): $e',
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
      // Solo eliminar la respuesta de la IA, NO el mensaje del usuario
      setState(() => session.messages.removeLast());

      if (session.messages.isNotEmpty && session.messages.last.role == 'user') {
        final lastUserMessage = session.messages.last.content;
        // NO eliminar el mensaje del usuario, solo regenerar la respuesta
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

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _showSnackBar(
      widget.getText('copied', fallback: 'Copiado al portapapeles'),
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
                selectedTileColor: Theme.of(context).cardTheme.color,
                onTap: () {
                  setState(() => _currentSessionId = s.id);
                  _scrollToBottom();
                },
                trailing: isSelected
                    ? IconButton(
                        icon: Icon(
                          Icons.delete,
                          size: 16,
                          color: Theme.of(
                            context,
                          ).iconTheme.color?.withOpacity(0.54),
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
              top: BorderSide(color: Theme.of(context).dividerColor),
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
                      color: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.color?.withOpacity(0.5),
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
                        widget.getText(
                          'api_calls',
                          fallback:
                              'Llamadas: ${_apiCallsRemaining[_selectedProvider]}/${_rateLimits[_selectedProvider]}',
                        ),
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
    _showSnackBar(
      widget.getText(
        'limits_reset_manually',
        fallback: 'Límites restablecidos manualmente',
      ),
    );
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
            onPressed: () {
              setState(() => _sidebarOpen = !_sidebarOpen);
              _saveSidebarState();
            },
            tooltip: widget.getText(
              'toggle_sidebar',
              fallback: 'Alternar barra lateral',
            ),
          ),
          const SizedBox(width: 8),
          const Spacer(),
          // Botón de configuración
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _showPreferencesDialog,
            tooltip: widget.getText('preferences', fallback: 'Preferencias'),
            color: Colors.white70,
          ),
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
                      child: CallbackShortcuts(
                        bindings: {
                          const SingleActivator(LogicalKeyboardKey.enter):
                              _handleKeyPress,
                        },
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          style: TextStyle(
                            fontSize: 15,
                            color: Theme.of(context).textTheme.bodyLarge?.color,
                          ),
                          decoration: InputDecoration(
                            hintText: widget.getText(
                              'foraai_input_hint',
                              fallback: 'Escribe un mensaje...',
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
                        ),
                      ),
                    ),

                    // Botones de acción
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Botón de imagen (deshabilitado - ningún modelo soporta imágenes actualmente)
                        // Descomentar cuando haya un modelo con soporte de imágenes

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
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<AIProvider>(
            value: _selectedProvider,
            dropdownColor: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(10),
            focusColor: Colors.transparent, // Evita el resaltado persistente
            icon: Icon(
              Icons.keyboard_arrow_down,
              size: 14,
              color: Theme.of(context).iconTheme.color?.withOpacity(0.54),
            ),
            isDense: true,
            style: TextStyle(
              color: Theme.of(context).textTheme.bodyLarge?.color,
              fontSize: 11,
            ),
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
        color: Theme.of(context).cardTheme.color,
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
          Expanded(
            child: Text(
              'Imagen lista para enviar',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(
                  context,
                ).textTheme.bodyMedium?.color?.withOpacity(0.7),
              ),
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
                  : Theme.of(context).cardTheme.color,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(10),
                topRight: const Radius.circular(10),
                bottomLeft: isUser ? const Radius.circular(10) : Radius.zero,
                bottomRight: isUser ? Radius.zero : const Radius.circular(10),
              ),
              border: Border.all(
                color: isUser
                    ? Colors.purpleAccent.withOpacity(0.3)
                    : Theme.of(context).dividerColor,
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
                          ApiConfig.getProviderName(_selectedProvider),
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
                          onTapLink: (text, href, title) {
                            if (href != null) {
                              // Abrir enlace en el navegador
                              launchUrl(
                                Uri.parse(href),
                                mode: LaunchMode.externalApplication,
                              );
                            }
                          },
                          builders: {
                            'code': CodeElementBuilder(context, widget.getText),
                          },
                          styleSheet: MarkdownStyleSheet(
                            p: const TextStyle(fontSize: 15, height: 1.5),
                            a: const TextStyle(
                              color: Colors.blueAccent,
                              decoration: TextDecoration.underline,
                            ),
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Botón copiar
                  IconButton(
                    onPressed: _isLoading
                        ? null
                        : () => _copyToClipboard(msg.content),
                    icon: const Icon(Icons.copy, size: 16),
                    tooltip: widget.getText('copy', fallback: 'Copiar'),
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.white54,
                      padding: const EdgeInsets.all(8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Botón regenerar
                  IconButton(
                    onPressed: _isLoading ? null : _regenerateLastResponse,
                    icon: const Icon(Icons.refresh, size: 16),
                    tooltip: widget.getText(
                      'regenerate',
                      fallback: 'Regenerar',
                    ),
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.white54,
                      padding: const EdgeInsets.all(8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
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
