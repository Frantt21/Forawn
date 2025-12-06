class Note {
  final int? id;
  final String title;
  final String description;
  final String content;
  final String? imagePath;
  final String? category;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool isArchived;
  final bool isDeleted;
  final bool pinned;
  final int backgroundColorValue;

  Note({
    this.id,
    required this.title,
    required this.description,
    required this.content,
    this.imagePath,
    this.category,
    required this.createdAt,
    this.updatedAt,
    this.isArchived = false,
    this.isDeleted = false,
    this.pinned = false,
    this.backgroundColorValue = 0xFF121212,
  });

  Note copyWith({
    int? id,
    String? title,
    String? description,
    String? content,
    String? imagePath,
    String? category,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isArchived,
    bool? isDeleted,
    bool? pinned,
    int? backgroundColorValue,
  }) {
    return Note(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      content: content ?? this.content,
      imagePath: imagePath ?? this.imagePath,
      category: category ?? this.category,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isArchived: isArchived ?? this.isArchived,
      isDeleted: isDeleted ?? this.isDeleted,
      pinned: pinned ?? this.pinned,
      backgroundColorValue: backgroundColorValue ?? this.backgroundColorValue,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'content': content,
      'imagePath': imagePath,
      'category': category,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
      'isArchived': isArchived ? 1 : 0,
      'isDeleted': isDeleted ? 1 : 0,
      'pinned': pinned ? 1 : 0,
      'backgroundColorValue': backgroundColorValue,
    };
  }

  factory Note.fromMap(Map<String, dynamic> m) {
    return Note(
      id: m['id'] as int?,
      title: m['title'] as String? ?? '',
      description: m['description'] as String? ?? '',
      content: m['content'] as String? ?? '',
      imagePath: m['imagePath'] as String?,
      category: m['category'] as String?,
      createdAt: DateTime.parse(m['createdAt'] as String),
      updatedAt: m['updatedAt'] != null ? DateTime.parse(m['updatedAt'] as String) : null,
      isArchived: (m['isArchived'] as int? ?? 0) == 1,
      isDeleted: (m['isDeleted'] as int? ?? 0) == 1,
      pinned: (m['pinned'] as int? ?? 0) == 1,
      backgroundColorValue: m['backgroundColorValue'] as int? ?? 0xFF121212,
    );
  }
}
