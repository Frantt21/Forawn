import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

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
  final ScrollController _scrollController = ScrollController();

  // State
  List<ChatSession> _sessions = [];
  String? _currentSessionId;
  bool _isLoading = false;
  bool _sidebarOpen = true;

  // OpenRouter config (API key hardcodeada aquí)
  static const String endpoint =
      'https://openrouter.ai/api/v1/chat/completions';
  static const String modelId =
      'openai/gpt-oss-20b:free'; // Cambia si quieres otro modelo
  // Reemplaza el valor siguiente por tu API key antes de compilar
  static const String _apiKey =
      'api_key_here';

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList('foraai_sessions') ?? [];

    setState(() {
      _sessions =
          sessionsJson.map((s) => ChatSession.fromJson(jsonDecode(s))).toList()
            ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

      if (_sessions.isNotEmpty && _currentSessionId == null) {
        _currentSessionId = _sessions.first.id;
      } else if (_sessions.isEmpty) {
        _createNewSession();
      }
    });
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

  // Convierte tu historial a formato OpenRouter (OpenAI-like)
  List<Map<String, String>> _buildMessagesForOpenRouter(
    ChatSession session,
    String newUserText,
  ) {
    const int maxChars =
        4000; // límite simple para contexto. Ajusta según modelo.
    int total = 0;
    final List<ChatMessage> reversed = List.from(session.messages.reversed);
    final List<ChatMessage> picked = [];

    for (final m in reversed) {
      if (total + m.content.length > maxChars) break;
      picked.insert(0, m);
      total += m.content.length;
    }

    // Ensambla con system + historial + nuevo input
    final List<Map<String, String>> messages = [
      {
        'role': 'system',
        'content':
            'Eres un asistente útil y directo. Escribe respuestas claras, concisas y bien estructuradas. Cuando respondas con código, usa bloques markdown. Si el mensajes es de un idioma en especifico, responde en ese idioma.',
      },
      ...picked.map(
        (m) => {
          'role': m.role == 'user' ? 'user' : 'assistant',
          'content': m.content,
        },
      ),
      {'role': 'user', 'content': newUserText},
    ];

    return messages;
  }

  Future<void> _sendMessage({
    String? manualText,
    bool isRegenerate = false,
  }) async {
    final text = manualText ?? _controller.text.trim();
    if (text.isEmpty) return;

    final session = _currentSession;
    if (session == null) return;

    if (!isRegenerate) {
      _controller.clear();
      setState(() {
        session.messages.add(ChatMessage(role: 'user', content: text));
        session.timestamp = DateTime.now();
        _sessions.remove(session);
        _sessions.insert(0, session);
        _isLoading = true;
      });
    } else {
      setState(() {
        _isLoading = true;
      });
    }

    _scrollToBottom();
    _saveSessions();

    if (session.messages.length == 1) {
      setState(() {
        session.title = text.length > 30 ? '${text.substring(0, 30)}...' : text;
      });
    }

    // Validar API key hardcodeada
    if (_apiKey.isEmpty ||
        _apiKey ==
            'apy_key_here') {
      setState(() {
        session.messages.add(
          ChatMessage(
            role: 'ai',
            content:
                'Error: API key no configurada. Reemplaza _apiKey en el código por tu clave de OpenRouter.',
          ),
        );
        _isLoading = false;
      });
      _scrollToBottom();
      _saveSessions();
      return;
    }

    try {
      final messages = _buildMessagesForOpenRouter(session, text);

      final body = jsonEncode({
        'model': modelId,
        'messages': messages,
        // Opcionales:
        // 'temperature': 0.7,
        // 'top_p': 0.95,
        // 'max_tokens': 1024,
      });

      final response = await http.post(
        Uri.parse(endpoint),
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
        },
        body: body,
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body);
        final choices = data['choices'] as List<dynamic>?;
        final content = choices?.isNotEmpty == true
            ? choices![0]['message']['content']
            : null;

        final result = (content is String && content.trim().isNotEmpty)
            ? content
            : 'Error: Respuesta vacía';

        if (mounted) {
          setState(() {
            session.messages.add(ChatMessage(role: 'ai', content: result));
            _isLoading = false;
          });
          _scrollToBottom();
          _saveSessions();
        }
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
    } catch (e) {
      if (mounted) {
        setState(() {
          session.messages.add(ChatMessage(role: 'ai', content: 'Error: $e'));
          _isLoading = false;
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
      setState(() {
        session.messages.removeLast();
      });

      if (session.messages.isNotEmpty && session.messages.last.role == 'user') {
        final lastUserMessage = session.messages.last.content;
        setState(() {
          session.messages.removeLast();
        });
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

  @override
  Widget build(BuildContext context) {
    final session = _currentSession;

    return Row(
      children: [
        // Sidebar (History)
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: _sidebarOpen ? 260 : 0,
          color: Colors.black.withOpacity(0.2),
          child: _sidebarOpen
              ? Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: ElevatedButton.icon(
                        onPressed: _createNewSession,
                        icon: const Icon(Icons.add),
                        label: Text(
                          widget.getText('new_chat', fallback: 'Nuevo Chat'),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.purpleAccent.withOpacity(0.2),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 45),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(
                              color: Colors.purpleAccent.withOpacity(0.5),
                            ),
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
                                color: isSelected
                                    ? Colors.white
                                    : Colors.white70,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            selected: isSelected,
                            selectedTileColor: Colors.white.withOpacity(0.05),
                            onTap: () =>
                                setState(() => _currentSessionId = s.id),
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
                  ],
                )
              : null,
        ),

        // Chat Area
        Expanded(
          child: Column(
            children: [
              // Header
              Container(
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
                      onPressed: () =>
                          setState(() => _sidebarOpen = !_sidebarOpen),
                      tooltip: widget.getText(
                        'toggle_sidebar',
                        fallback: 'Alternar barra lateral',
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),

              // Messages
              Expanded(
                child: session == null
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(20),
                        itemCount:
                            session.messages.length + (_isLoading ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == session.messages.length) {
                            return _buildLoadingBubble();
                          }
                          final msg = session.messages[index];
                          final isLast = index == session.messages.length - 1;
                          return _buildMessageBubble(msg, isLast: isLast);
                        },
                      ),
              ),

              // Input
              Container(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.1),
                          ),
                        ),
                        child: TextField(
                          controller: _controller,
                          decoration: InputDecoration(
                            hintText: widget.getText(
                              'foraai_input_hint',
                              fallback: 'Escribe un mensaje...',
                            ),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 14,
                            ),
                          ),
                          onSubmitted: (_) => _sendMessage(),
                          minLines: 1,
                          maxLines: 5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: _isLoading ? null : () => _sendMessage(),
                      icon: const Icon(Icons.send),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color.fromARGB(255, 0, 0, 0),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, {bool isLast = false}) {
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                        selectable: true,
                        builders: {'code': CodeElementBuilder(context, widget.getText)},
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
          if (!isUser && isLast)
            Padding(
              padding: const EdgeInsets.only(left: 8.0, bottom: 8.0),
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
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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

class CodeElementBuilder extends MarkdownElementBuilder {
  final BuildContext context;
  final String Function(String key, {String? fallback}) getText;

  CodeElementBuilder(this.context, this.getText);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    var language = '';

    if (element.attributes['class'] != null) {
      String lg = element.attributes['class'] as String;
      if (lg.startsWith('language-')) {
        language = lg.substring(9);
      } else {
        language = lg;
      }
    }

    final textContent = element.textContent;
    final isBlock = language.isNotEmpty || textContent.contains('\n');

    if (!isBlock) {
      return null;
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          getText('code_copied', fallback: 'Código copiado al portapapeles'),
                        ),
                        duration: const Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                        width: 250,
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Row(
                      children: [
                        const Icon(Icons.copy, size: 14, color: Colors.white60),
                        const SizedBox(width: 4),
                        Text(
                          getText('copy_button', fallback: 'Copiar'),
                          style: const TextStyle(color: Colors.white60, fontSize: 12),
                        ),
                      ],
                    ),
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
  final String role; // 'user' | 'ai'
  final String content;

  ChatMessage({required this.role, required this.content});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(role: json['role'], content: json['content']);
  }
}
