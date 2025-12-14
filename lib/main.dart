import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:forawn/screen/notes_screen.dart';
import 'package:forawn/screen/qrcode_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'screen/spotify_screen.dart';
import 'screen/music_player_screen.dart';
import 'settings.dart';
import 'imgia_screen.dart';
import 'r34.dart';
import 'translate.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'services/download_manager.dart';
import 'services/global_keyboard_service.dart';
import 'version.dart';
import 'package:url_launcher/url_launcher.dart';
import 'widgets/fade_transition_screen.dart';
import 'screen/video_downloader.dart';
import 'widgets/sidebar_navigation.dart';
import 'widgets/mini_music_player.dart';
import 'screen/home_content.dart';
import 'screen/foraai_screen.dart';
import 'services/discord_service.dart';

const String kDefaultLangCode = 'en';
const _prefEffectKey = 'window_effect';
const _prefColorKey = 'window_color';
const _prefDarkKey = 'window_dark';

String currentLang = kDefaultLangCode;
Map<String, String> lang = {};
bool gNativeAcrylicAvailable = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicialización FFI para sqflite en escritorio
  try {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  } catch (_) {}

  // Inicializar hotkey_manager
  try {
    await hotKeyManager.unregisterAll();
  } catch (e) {
    debugPrint('[HotkeyManager] Error unregistering: $e');
  }

  // Inicializar flutter_acrylic
  if (Platform.isWindows) {
    try {
      await acrylic.Window.initialize();
      await acrylic.Window.hideWindowControls();
      gNativeAcrylicAvailable = true;
      final prefs = await SharedPreferences.getInstance();
      final savedEffect = prefs.getString(_prefEffectKey) ?? 'solid';
      final savedColor = Color(prefs.getInt(_prefColorKey) ?? 0xCC222222);
      final savedDark = prefs.getBool(_prefDarkKey) ?? true;

      // Validar que el efecto guardado sea válido
      acrylic.WindowEffect effect;
      try {
        effect = acrylic.WindowEffect.values.firstWhere(
          (e) => e.name == savedEffect,
          orElse: () => acrylic.WindowEffect.solid,
        );
      } catch (_) {
        effect = acrylic.WindowEffect.solid;
      }

      await acrylic.Window.setEffect(
        effect: effect,
        color: savedColor,
        dark: savedDark,
      );
    } catch (e) {
      debugPrint('[Acrylic Init Error] $e');
      gNativeAcrylicAvailable = false;
    }
  } else {
    gNativeAcrylicAvailable = false;
  }

  // Inicializar window_manager
  try {
    await windowManager.ensureInitialized();
    await DownloadManager().loadPersisted();
    await windowManager.setAsFrameless();
    final options = WindowOptions(
      size: const Size(1024, 600),
      center: true,
      title: 'Forawn',
    );
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setResizable(true);
      await windowManager.setMinimumSize(const Size(1024, 600));
      await windowManager.show();
      await windowManager.focus();
    });
  } catch (_) {}

  // Cargar preferencia de idioma antes de runApp
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('preferred_lang') ?? kDefaultLangCode;
  currentLang = saved;
  lang = await loadLanguageFromExeOrAssets(saved);

  // Inicializar Discord Rich Presence si está habilitado
  final discordEnabled = prefs.getBool('discord_enabled') ?? false;
  if (discordEnabled) {
    try {
      await DiscordService().initialize();
    } catch (e) {
      debugPrint('[Discord] Error al inicializar: $e');
    }
  }

  runApp(ForawnAppRoot(initialLangCode: currentLang, initialLangMap: lang));
}

Future<Map<String, String>> loadLanguageFromExeOrAssets(String code) async {
  final Map<String, String> empty = <String, String>{};

  try {
    final base = _exeBaseDir();
    final external = File(p.join(base, 'lang', '$code.json'));
    if (await external.exists()) {
      final s = await external.readAsString();
      final Map<String, dynamic> parsed = jsonDecode(s);
      return parsed.map((k, v) => MapEntry(k, v.toString()));
    }
  } catch (_) {}

  try {
    final content = await rootBundle.loadString('lang/$code.json');
    final Map<String, dynamic> parsed = jsonDecode(content);
    return parsed.map((k, v) => MapEntry(k, v.toString()));
  } catch (_) {}

  return empty;
}

String _exeBaseDir() {
  try {
    final resolved = Platform.resolvedExecutable;
    if (resolved.isNotEmpty) return File(resolved).parent.path;
  } catch (_) {}
  try {
    return Directory.current.path;
  } catch (_) {}
  return '.';
}

Future<void> checkForUpdate(
  BuildContext context,
  String Function(String key, {String? fallback}) getText,
) async {
  const repoOwner = 'Frantt21';
  const repoName = 'Forawn';
  const apiUrl =
      'https://api.github.com/repos/$repoOwner/$repoName/releases/latest';

  try {
    final client = HttpClient();
    final req = await client
        .getUrl(Uri.parse(apiUrl))
        .timeout(const Duration(seconds: 8));
    final res = await req.close().timeout(const Duration(seconds: 8));
    final body = await res.transform(utf8.decoder).join();
    client.close(force: true);

    if (res.statusCode != 200) return;

    final data = jsonDecode(body);
    final latestTag = data['tag_name']?.toString() ?? '';
    final releaseUrl = data['html_url']?.toString() ?? '';

    if (latestTag.isNotEmpty && latestTag != currentVersion) {
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          title: Text(
            getText('update_title', fallback: 'Nueva versión disponible'),
            style: const TextStyle(color: Colors.white),
          ),
          content: Text(
            '${getText('update_current', fallback: 'Versión actual')}: $currentVersion\n${getText('update_latest', fallback: 'Última versión')}: $latestTag',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                getText('close_button', fallback: 'Cerrar'),
                style: const TextStyle(color: Colors.white54),
              ),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.download),
              label: Text(getText('update_button', fallback: 'Actualizar')),
              onPressed: () async {
                Navigator.of(context).pop();
                await launchUrl(
                  Uri.parse(releaseUrl),
                  mode: LaunchMode.externalApplication,
                );
              },
              style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                backgroundColor: Colors.purpleAccent,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      );
    }
  } catch (e) {
    debugPrint('[UpdateCheck] error: $e');
  }
}

class ForawnAppRoot extends StatefulWidget {
  final String initialLangCode;
  final Map<String, String> initialLangMap;
  const ForawnAppRoot({
    super.key,
    required this.initialLangCode,
    required this.initialLangMap,
  });

  @override
  State<ForawnAppRoot> createState() => _ForawnAppRootState();
}

class _ForawnAppRootState extends State<ForawnAppRoot> {
  late String _langCode;
  late Map<String, String> _langMap;
  late FocusNode _globalFocusNode;
  bool _isDarkBackground = true; // Track if background is dark or light

  @override
  void initState() {
    super.initState();
    _langCode = widget.initialLangCode;
    _langMap = widget.initialLangMap;
    _globalFocusNode = FocusNode();

    // Load background brightness preference
    _loadBackgroundBrightness();

    // Inicializar servicio de teclado global
    GlobalKeyboardService().initialize(_globalFocusNode, null);
  }

  Future<void> _loadBackgroundBrightness() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool(_prefDarkKey) ?? true;
    if (mounted) {
      setState(() {
        _isDarkBackground = isDark;
      });
    }
  }

  // Call this when returning from settings to refresh theme
  Future<void> _refreshBackgroundBrightness() async {
    await _loadBackgroundBrightness();
  }

  @override
  void dispose() {
    _globalFocusNode.dispose();
    super.dispose();
  }

  Future<void> _changeLanguage(String newCode) async {
    if (newCode == _langCode) return;
    final newMap = await loadLanguageFromExeOrAssets(newCode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('preferred_lang', newCode);
    if (!mounted) return;
    setState(() {
      _langCode = newCode;
      _langMap = newMap;
      currentLang = newCode;
      lang = Map<String, String>.from(newMap);
    });
  }

  String t(String key, {String? fallback}) => _langMap[key] ?? fallback ?? key;

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: _globalFocusNode,
      autofocus: true,
      onKey: (event) {
        // Pasar el evento a un servicio global
        final keyboardService = GlobalKeyboardService();
        keyboardService.handleKeyboardEvent(event);
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(0),
        child: MaterialApp(
          title: 'Forawn',
          theme: _isDarkBackground
              ? ThemeData.dark(useMaterial3: true).copyWith(
                  appBarTheme: const AppBarTheme(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    surfaceTintColor: Colors.transparent,
                    scrolledUnderElevation: 0,
                  ),
                  textTheme: ThemeData.dark().textTheme.apply(
                    bodyColor: Colors.white,
                    displayColor: Colors.white,
                  ),
                  iconTheme: const IconThemeData(color: Colors.white),
                  // Input decoration theme for dark backgrounds
                  inputDecorationTheme: InputDecorationTheme(
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    isDense: true,
                  ),
                  // Card theme for containers
                  cardTheme: CardThemeData(
                    color: Colors.white.withOpacity(0.05),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: Colors.white.withOpacity(0.1)),
                    ),
                  ),
                  dividerColor: Colors.white.withOpacity(0.1),
                )
              : ThemeData.light(useMaterial3: true).copyWith(
                  appBarTheme: const AppBarTheme(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    surfaceTintColor: Colors.transparent,
                    scrolledUnderElevation: 0,
                  ),
                  textTheme: ThemeData.light().textTheme.apply(
                    bodyColor: Colors.black87,
                    displayColor: Colors.black87,
                  ),
                  iconTheme: const IconThemeData(color: Colors.black87),
                  // Input decoration theme for light backgrounds
                  inputDecorationTheme: InputDecorationTheme(
                    hintStyle: TextStyle(color: Colors.black.withOpacity(0.3)),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    isDense: true,
                  ),
                  // Card theme for containers
                  cardTheme: CardThemeData(
                    color: Colors.black.withOpacity(0.05),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: Colors.black.withOpacity(0.1)),
                    ),
                  ),
                  dividerColor: Colors.black.withOpacity(0.1),
                ),
          debugShowCheckedModeBanner: false,
          home: HomeScreen(
            getText: t,
            onRequestLanguageChange: _changeLanguage,
            currentLangCode: _langCode,
            isDarkBackground: _isDarkBackground,
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final Future<void> Function(String) onRequestLanguageChange;
  final String currentLangCode;
  final String Function(String key, {String? fallback}) getText;
  final bool isDarkBackground;

  const HomeScreen({
    super.key,
    required this.getText,
    required this.onRequestLanguageChange,
    required this.currentLangCode,
    required this.isDarkBackground,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WindowListener {
  final ValueNotifier<double> backgroundOpacity = ValueNotifier(1.0);
  String _currentScreen = 'home';
  bool _nsfwEnabled = false;
  List<String> _recentScreens = [];
  VoidCallback? _onFolderAction;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _loadNsfwPref();
    _loadRecentScreens();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // checkForUpdate(context, widget.getText);
    });
  }

  Future<void> _loadNsfwPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('nsfw_enabled') ?? false;
      if (!mounted) return;
      setState(() => _nsfwEnabled = enabled);
    } catch (_) {}
  }

  Future<void> _loadRecentScreens() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final recents = prefs.getStringList('recent_screens') ?? [];
      if (!mounted) return;
      setState(() => _recentScreens = recents);
    } catch (_) {}
  }

  Future<void> _saveRecentScreens() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('recent_screens', _recentScreens);
    } catch (_) {}
  }

  void _handleNavigation(String screenId) {
    // Add to recents
    if (screenId != 'home' && screenId != 'settings') {
      setState(() {
        _recentScreens.remove(screenId);
        _recentScreens.insert(0, screenId);
        if (_recentScreens.length > 5) {
          _recentScreens = _recentScreens.sublist(0, 5);
        }
      });
      _saveRecentScreens();
    }

    setState(() {
      _currentScreen = screenId;
      _onFolderAction = null;
    });

    // Actualizar Discord Rich Presence si está conectado
    if (DiscordService().isConnected) {
      DiscordService().updateScreenPresence(screenId);
    }
  }

  void _registerFolderAction(VoidCallback action) {
    Future.microtask(() {
      if (mounted) {
        setState(() {
          _onFolderAction = action;
        });
      }
    });
  }

  Future<void> _applyWindowEffect(
    acrylic.WindowEffect effect,
    Color color, {
    bool dark = true,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Aplicar el efecto directamente
      await acrylic.Window.setEffect(effect: effect, color: color, dark: dark);

      // Guardar preferencias
      await prefs.setString(_prefEffectKey, effect.name);
      await prefs.setInt(_prefColorKey, color.value);
      await prefs.setBool(_prefDarkKey, dark);

      // Refresh theme in parent widget
      if (mounted &&
          context.findAncestorStateOfType<_ForawnAppRootState>() != null) {
        context
            .findAncestorStateOfType<_ForawnAppRootState>()!
            ._refreshBackgroundBrightness();
      }
    } catch (e) {
      debugPrint('[WindowEffect] error: $e');
    }
  }

  @override
  void onWindowClose() {}

  @override
  void dispose() {
    windowManager.removeListener(this);
    // Limpiar Discord Rich Presence
    DiscordService().dispose();
    super.dispose();
  }

  Widget _getContentWidget() {
    switch (_currentScreen) {
      case 'home':
        return HomeContent(
          getText: widget.getText,
          recentScreens: _recentScreens,
          onNavigate: _handleNavigation,
        );
      case 'music':
        return SpotifyScreen(
          getText: widget.getText,
          currentLang: widget.currentLangCode,
          onRegisterFolderAction: _registerFolderAction,
          onNavigate: _handleNavigation,
        );
      case 'video':
        return VideoDownloaderScreen(
          getText: widget.getText,
          currentLang: widget.currentLangCode,
          onRegisterFolderAction: _registerFolderAction,
        );
      case 'player':
        return MusicPlayerScreen(
          getText: widget.getText,
          onRegisterFolderAction: _registerFolderAction,
        );
      case 'images':
        return AiImageScreen(
          getText: widget.getText,
          currentLang: widget.currentLangCode,
          onRegisterFolderAction: _registerFolderAction,
        );
      case 'notes':
        return NotesScreen(
          getText: widget.getText,
          currentLang: widget.currentLangCode,
        );
      case 'translate':
        return TranslateScreen(
          getText: widget.getText,
          currentLang: widget.currentLangCode,
          onRegisterFolderAction: _registerFolderAction,
        );
      case 'qr':
        return QrGeneratorScreen(
          getText: widget.getText,
          currentLang: widget.currentLangCode,
          onRegisterFolderAction: _registerFolderAction,
        );
      case 'foraai':
        return ForaaiScreen(
          getText: widget.getText,
          currentLang: widget.currentLangCode,
        );
      case 'r34':
        if (_nsfwEnabled) {
          return R34Screen(
            getText: widget.getText,
            currentLang: widget.currentLangCode,
            onRegisterFolderAction: _registerFolderAction,
            onNavigate: _handleNavigation,
          );
        }
        return HomeContent(
          getText: widget.getText,
          recentScreens: _recentScreens,
          onNavigate: _handleNavigation,
        );
      default:
        return HomeContent(
          getText: widget.getText,
          recentScreens: _recentScreens,
          onNavigate: _handleNavigation,
        );
    }
  }

  Widget _windowButtons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: widget.getText('minimize', fallback: 'Minimize'),
          icon: const Icon(Icons.remove, size: 18),
          onPressed: () => windowManager.minimize(),
        ),
        IconButton(
          tooltip: widget.getText('maximize', fallback: 'Maximize'),
          icon: const Icon(Icons.crop_square, size: 18),
          onPressed: () async {
            final isMax = await windowManager.isMaximized();
            if (isMax) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        IconButton(
          tooltip: widget.getText('close', fallback: 'Close'),
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => windowManager.close(),
        ),
      ],
    );
  }

  String _getScreenTitle() {
    switch (_currentScreen) {
      case 'home':
        return widget.getText('home_title', fallback: 'Inicio');
      case 'music':
        return widget.getText('download_button', fallback: 'Música');
      case 'video':
        return widget.getText('vid_title', fallback: 'Video');
      case 'images':
        return widget.getText('ai_image_title', fallback: 'Imágenes');
      case 'player':
        return widget.getText(
          'music_player_title',
          fallback: 'Reproductor de Música',
        );
      case 'notes':
        return widget.getText('notes_title', fallback: 'Notas');
      case 'translate':
        return widget.getText('translate_title', fallback: 'Traductor');
      case 'qr':
        return widget.getText('qr_title', fallback: 'Generador QR');
      case 'foraai':
        return widget.getText('foraai_title', fallback: 'ForaAI');
      case 'r34':
        return widget.getText('r34_title', fallback: 'R34 Buscador');
      default:
        return widget.getText('title', fallback: 'Forawn');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          backgroundColor: Colors.transparent,
          body: ValueListenableBuilder<double>(
            valueListenable: backgroundOpacity,
            builder: (_, opacity, __) {
              return Opacity(
                opacity: opacity,
                child: Row(
                  children: [
                    // Sidebar Navigation (Full Height)
                    SidebarNavigation(
                      key: ValueKey('sidebar_${widget.currentLangCode}'),
                      onNavigate: _handleNavigation,
                      currentScreen: _currentScreen,
                      getText: widget.getText,
                      nsfwEnabled: _nsfwEnabled,
                    ),

                    // Main content area with Title Bar
                    Expanded(
                      child: Column(
                        children: [
                          // Title bar with Screen Title and Controls
                          GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onPanStart: (_) => windowManager.startDragging(),
                            child: Container(
                              height: 42,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              color: Colors.transparent,
                              child: Row(
                                children: [
                                  // Home button
                                  if (_currentScreen != 'home')
                                    IconButton(
                                      tooltip: widget.getText(
                                        'home_title',
                                        fallback: 'Inicio',
                                      ),
                                      icon: const Icon(Icons.home, size: 20),
                                      onPressed: () =>
                                          _handleNavigation('home'),
                                    ),
                                  const SizedBox(width: 8),
                                  // Screen title
                                  Text(
                                    _getScreenTitle(),
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (_onFolderAction != null)
                                    IconButton(
                                      tooltip: widget.getText(
                                        'folder_button',
                                        fallback: 'Folder',
                                      ),
                                      icon: const Icon(
                                        Icons.folder_open,
                                        size: 20,
                                      ),
                                      onPressed: _onFolderAction,
                                    ),
                                  IconButton(
                                    tooltip: widget.getText(
                                      'setting_tittle',
                                      fallback: 'Settings',
                                    ),
                                    icon: const Icon(Icons.settings, size: 20),
                                    onPressed: () async {
                                      backgroundOpacity.value = 0.0;

                                      final selected =
                                          await Navigator.of(
                                            context,
                                          ).push<String?>(
                                            PageRouteBuilder(
                                              opaque: false,
                                              barrierColor: Colors.transparent,
                                              transitionDuration:
                                                  const Duration(
                                                    milliseconds: 400,
                                                  ),
                                              pageBuilder: (_, __, ___) =>
                                                  FadeTransitionScreen(
                                                    child: SettingsScreen(
                                                      currentLang: widget
                                                          .currentLangCode,
                                                      getText: widget.getText,
                                                      onSelectLanguage:
                                                          (
                                                            code,
                                                          ) async => await widget
                                                              .onRequestLanguageChange(
                                                                code,
                                                              ),
                                                      onChangeWindowEffect:
                                                          _applyWindowEffect,
                                                    ),
                                                  ),
                                              transitionsBuilder:
                                                  (_, animation, __, child) {
                                                    return FadeTransition(
                                                      opacity: animation,
                                                      child: child,
                                                    );
                                                  },
                                            ),
                                          );
                                      backgroundOpacity.value = 1.0;
                                      if (!mounted) return;
                                      setState(
                                        () {},
                                      ); // fuerza reconstrucción para limpiar visual
                                      if (selected != null) {
                                        await widget.onRequestLanguageChange(
                                          selected,
                                        );
                                      }
                                      await _loadNsfwPref();
                                    },
                                  ),
                                  _windowButtons(),
                                ],
                              ),
                            ),
                          ),

                          // Content
                          Expanded(child: _getContentWidget()),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        // Mini Music Player overlay
        MiniMusicPlayer(
          getText: widget.getText,
          onExpandPressed: () {
            _handleNavigation('player');
          },
        ),
      ],
    );
  }
}
