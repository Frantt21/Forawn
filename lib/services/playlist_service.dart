import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/playlist_model.dart';
import '../models/song_model.dart';

class PlaylistService extends ChangeNotifier {
  static final PlaylistService _instance = PlaylistService._internal();
  factory PlaylistService() => _instance;
  PlaylistService._internal();

  static const String _playlistsKey = 'user_playlists';
  static const String _favoritesKey = 'user_favorites';

  List<Playlist> _playlists = [];
  final Set<String> _likedSongIds = {};

  List<Playlist> get playlists => List.unmodifiable(_playlists);
  Set<String> get likedSongIds => Set.unmodifiable(_likedSongIds);

  bool isInitialized = false;

  Future<void> init() async {
    if (isInitialized) return;
    await _loadData();
    isInitialized = true;
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();

    // Load Playlists
    final String? playlistsJson = prefs.getString(_playlistsKey);
    if (playlistsJson != null) {
      try {
        final List<dynamic> decoded = json.decode(playlistsJson);
        _playlists = decoded.map((item) => Playlist.fromJson(item)).toList();
        _sortPlaylists(); // Sort on load
      } catch (e) {
        debugPrint('Error loading playlists: $e');
      }
    }

    // Load Favorites
    final List<String>? favoritesList = prefs.getStringList(_favoritesKey);
    if (favoritesList != null) {
      _likedSongIds.addAll(favoritesList);
    }

    notifyListeners();
  }

  void _sortPlaylists() {
    _playlists.sort((a, b) {
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;

      // Sort by lastOpened if available
      final aTime = a.lastOpened ?? a.createdAt;
      final bTime = b.lastOpened ?? b.createdAt;
      return bTime.compareTo(aTime);
    });
  }

  // --- Favorites ---

  bool isLiked(String songId) => _likedSongIds.contains(songId);

  Future<void> toggleLike(String songId) async {
    if (_likedSongIds.contains(songId)) {
      _likedSongIds.remove(songId);
    } else {
      _likedSongIds.add(songId);
    }
    notifyListeners();
    await _saveFavorites();
  }

  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_favoritesKey, _likedSongIds.toList());
  }

  // --- Playlists ---

  Future<void> logPlaylistOpen(String playlistId) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      _playlists[index] = _playlists[index].copyWith(
        lastOpened: DateTime.now(),
      );
      _sortPlaylists();
      notifyListeners();
      await _savePlaylists();
    }
  }

  Future<Playlist> createPlaylist(
    String name, {
    String? description,
    String? imagePath,
  }) async {
    final newPlaylist = Playlist(
      id: const Uuid().v4(),
      name: name,
      description: description,
      imagePath: imagePath,
      createdAt: DateTime.now(),
      lastOpened: DateTime.now(),
      songs: [],
    );

    _playlists.add(newPlaylist);
    _sortPlaylists();
    notifyListeners();
    await _savePlaylists();
    return newPlaylist;
  }

  Future<void> deletePlaylist(String playlistId) async {
    _playlists.removeWhere((p) => p.id == playlistId);
    notifyListeners();
    await _savePlaylists();
  }

  Future<void> updatePlaylist(
    String id, {
    String? name,
    String? description,
    String? imagePath,
  }) async {
    final index = _playlists.indexWhere((p) => p.id == id);
    if (index != -1) {
      _playlists[index] = _playlists[index].copyWith(
        name: name,
        description: description,
        imagePath: imagePath,
      );
      notifyListeners();
      await _savePlaylists();
    }
  }

  Future<void> togglePin(String playlistId) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final p = _playlists[index];
      // Toggling pin always brings to top or re-sorts
      _playlists[index] = p.copyWith(isPinned: !p.isPinned);
      _sortPlaylists();
      notifyListeners();
      await _savePlaylists();
    }
  }

  Future<void> addSongToPlaylist(String playlistId, Song song) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final playlist = _playlists[index];
      if (!playlist.songs.any((s) => s.id == song.id)) {
        final updatedSongs = List<Song>.from(playlist.songs)..add(song);
        // Also update lastOpened when adding song? Maybe not needed, but useful.
        // Let's keep it strictly 'open' event for now, or modifiedAt.
        // User asked for 'last opened or played'.
        _playlists[index] = playlist.copyWith(
          songs: updatedSongs,
          lastOpened: DateTime.now(),
        );
        _sortPlaylists();
        notifyListeners();
        await _savePlaylists();
      }
    }
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final playlist = _playlists[index];
      final updatedSongs = List<Song>.from(playlist.songs)
        ..removeWhere((s) => s.id == songId);
      if (updatedSongs.length != playlist.songs.length) {
        _playlists[index] = playlist.copyWith(songs: updatedSongs);
        notifyListeners();
        await _savePlaylists();
      }
    }
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = json.encode(
      _playlists.map((p) => p.toJson()).toList(),
    );
    await prefs.setString(_playlistsKey, encoded);
  }
}
