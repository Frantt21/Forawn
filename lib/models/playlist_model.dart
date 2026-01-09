import 'dart:io';
import 'package:flutter/material.dart';
import 'song_model.dart';

class Playlist {
  final String id;
  final String name;
  final String? description;
  final String? imagePath;
  final DateTime createdAt;
  final DateTime? lastOpened;
  final bool isPinned;
  final List<Song> songs;

  Playlist({
    required this.id,
    required this.name,
    this.description,
    this.imagePath,
    required this.createdAt,
    this.lastOpened,
    this.isPinned = false,
    required this.songs,
  });

  Playlist copyWith({
    String? name,
    String? description,
    String? imagePath,
    bool? isPinned,
    DateTime? lastOpened,
    List<Song>? songs,
  }) {
    return Playlist(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      imagePath: imagePath ?? this.imagePath,
      createdAt: createdAt,
      lastOpened: lastOpened ?? this.lastOpened,
      isPinned: isPinned ?? this.isPinned,
      songs: songs ?? this.songs,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'imagePath': imagePath,
    'createdAt': createdAt.toIso8601String(),
    'lastOpened': lastOpened?.toIso8601String(),
    'isPinned': isPinned,
    'songs': songs.map((s) => s.toJson()).toList(),
  };

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String?,
    imagePath: json['imagePath'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
    lastOpened: json['lastOpened'] != null
        ? DateTime.parse(json['lastOpened'] as String)
        : null,
    isPinned: json['isPinned'] as bool? ?? false,
    songs:
        (json['songs'] as List<dynamic>?)
            ?.map((e) => Song.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
  );

  // ==================== HELPER METHODS ====================

  /// Obtiene el ImageProvider apropiado para la imagen de la playlist
  ///
  /// Retorna FileImage si es un archivo local que existe,
  /// NetworkImage si es una URL, o null si no hay imagen
  ImageProvider? getImageProvider() {
    if (imagePath == null || imagePath!.isEmpty) return null;

    // Verificar si es una URL
    if (imagePath!.startsWith('http://') || imagePath!.startsWith('https://')) {
      return NetworkImage(imagePath!);
    }

    // Verificar si es un archivo local que existe
    final file = File(imagePath!);
    if (file.existsSync()) {
      return FileImage(file);
    }

    // Si el archivo no existe, intentar como NetworkImage por si acaso
    return NetworkImage(imagePath!);
  }

  /// Calcula la duración total de todas las canciones en la playlist
  ///
  /// Solo cuenta canciones que tienen duración definida
  Duration getTotalDuration() {
    int totalMs = 0;
    for (var song in songs) {
      if (song.duration != null) {
        totalMs += song.duration!.inMilliseconds;
      }
    }
    return Duration(milliseconds: totalMs);
  }

  /// Formatea la duración total en formato legible
  ///
  /// Ejemplos:
  /// - "45 min" para menos de 1 hora
  /// - "1 h 30 min" para 1 hora o más
  String formatDuration() {
    final duration = getTotalDuration();
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);

    if (hours > 0) {
      return '$hours h $minutes min';
    } else {
      return '$minutes min';
    }
  }

  /// Obtiene el número de canciones en la playlist
  int get songCount => songs.length;

  /// Verifica si la playlist está vacía
  bool get isEmpty => songs.isEmpty;

  /// Verifica si la playlist tiene canciones
  bool get isNotEmpty => songs.isNotEmpty;

  /// Verifica si una canción específica está en la playlist
  bool containsSong(String songId) {
    return songs.any((song) => song.id == songId);
  }
}
