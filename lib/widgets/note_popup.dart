import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../utils/color_utils.dart';
import '../models/note.dart';
import '../db/notes_database.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class NoteData {
  final String title;
  final String description;
  final String content;
  final String? imagePath;
  final String? category;
  final int backgroundColorValue;
  NoteData({
    required this.title,
    required this.description,
    required this.content,
    this.imagePath,
    this.category,
    required this.backgroundColorValue,
  });
}

// showNotePopup ahora recibe getText para localización
// existingNote != null => modo edición
// categories lista que puede estar vacía
// Retorna NoteData al guardar, null si cancela
Future<NoteData?> showNotePopup({
  required BuildContext context,
  required TextGetter getText,
  String initialTitle = '',
  String initialDescription = '',
  String initialContent = '',
  String? initialImagePath,
  String? initialCategory,
  int initialColor = 0xFF121212,
  required List<String> categories,
  String dialogTitleKey = 'create_note_title',
  Note? existingNote,
}) async {
  final titleCtrl = TextEditingController(text: initialTitle);
  final descCtrl = TextEditingController(text: initialDescription);
  final contentCtrl = TextEditingController(text: initialContent);

  double contentHeight = 160.0;
  bool isDraggingContentHandle = false;
  final ScrollController contentScrollController = ScrollController();

  String? imagePath = initialImagePath;
  String? selectedCategory = initialCategory;
  int bgColor = initialColor;
  final db = NotesDatabase.instance;
  var editingNote = existingNote;
  final isEditing = existingNote != null;

  // inputDecoration consistente: sin hover y con borde uniforme;
  // fillColor más atenuado para contrastar con fondo oscuro del diálogo
  final InputDecoration baseInputDecoration = InputDecoration(
    filled: true,
    fillColor: Colors.black26, // inputs más atenuados
    hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    // border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: Colors.transparent),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: Colors.transparent),
    ),
  );

  Future<void> cycleColor(StateSetter setState) async {
    // legacy helper kept but replaced by full color picker below
    const presets = [0xFF121212, 0xFFFFFFFF, 0xFFFFF59D, 0xFFFFCDD2, 0xFFBBDEFB];
    final idx = presets.indexOf(bgColor);
    final next = presets[(idx + 1) % presets.length];

    setState(() {
      bgColor = next;
    });

    if (isEditing && editingNote != null) {
      final current = editingNote!;
      final updated = current.copyWith(backgroundColorValue: next, updatedAt: DateTime.now());
      await db.updateNote(updated);
      editingNote = updated;
    }
  }

  Future<void> showColorPicker(StateSetter setState) async {
    // mini dialog with presets grid
    final presets = [0xFF121212, 0xFFFFFFFF, 0xFFFFF59D, 0xFFFFCDD2, 0xFFBBDEFB, 0xFFE1BEE7, 0xFFC8E6C9];
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.black87, // oscuro y sin blur
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(getText('choose_color', fallback: 'Choose color'), style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: presets.map((c) {
                    return GestureDetector(
                      onTap: () => Navigator.of(ctx).pop(c),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Color(c),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white.withOpacity(0.06)),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: Text(getText('cancel', fallback: 'Cancel'))),
              ],
            ),
          ),
        );
      },
    );

    if (chosen != null) {
      setState(() {
        bgColor = chosen;
      });
      if (isEditing && editingNote != null) {
        final updated = editingNote!.copyWith(backgroundColorValue: chosen, updatedAt: DateTime.now());
        await db.updateNote(updated);
        editingNote = updated;
      }
    }
  }

  try {
    final result = await showDialog<NoteData>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 720, maxWidth: 980),
            child: StatefulBuilder(builder: (ctx, setState) {
              Future<void> pickImage() async {
                final res = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: false);
                if (res != null && res.files.isNotEmpty) {
                  imagePath = res.files.first.path;
                  setState(() {});
                }
              }

              final bgPreview = Color(bgColor);
              final titleText = isEditing ? getText('edit_note_title', fallback: 'Editar nota') : getText(dialogTitleKey, fallback: 'Crear nota');
              final cancelLabel = getText('cancel', fallback: 'Cancelar');
              final saveLabel = isEditing ? getText('save', fallback: 'Guardar') : getText('create', fallback: 'Crear');

              // Contenedor oscuro, sin blur; inputs atenuados y sin hover effects
              return Container(
                decoration: BoxDecoration(
                  color: const Color.fromARGB(255, 58, 58, 58), // más negro
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white.withOpacity(0.04)),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // TITLE area
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
                        child: Row(
                          children: [
                            GestureDetector(
                              onTap: pickImage,
                              child: Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: Colors.black12),
                                child: (imagePath != null && File(imagePath!).existsSync())
                                    ? ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(File(imagePath!), fit: BoxFit.cover))
                                    : const Icon(Icons.image, size: 22),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(titleText, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white))),
                          ],
                        ),
                      ),

                      // CONTENT
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: SizedBox(
                          width: double.maxFinite,
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Título (no redimensionable)
                                TextField(
                                  controller: titleCtrl,
                                  decoration: baseInputDecoration.copyWith(
                                    hintText: getText('title_hint', fallback: 'Título'),
                                  ),
                                  maxLines: 1,
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                                  textCapitalization: TextCapitalization.sentences,
                                  cursorColor: Colors.white70,
                                ),
                                const SizedBox(height: 10),

                                // Descripción (no redimensionable)
                                TextField(
                                  controller: descCtrl,
                                  decoration: baseInputDecoration.copyWith(hintText: getText('description_hint', fallback: 'Descripción')),
                                  maxLines: 1,
                                  style: const TextStyle(fontSize: 16, height: 1.15, color: Colors.white70),
                                  textCapitalization: TextCapitalization.sentences,
                                  cursorColor: Colors.white70,
                                ),
                                const SizedBox(height: 10),

                                // Contenido: redimensionable por el usuario
                                Container(
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    color: Colors.black26,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.white.withOpacity(0.02)),
                                  ),
                                  child: Column(
                                    children: [
                                      SizedBox(
                                        height: contentHeight,
                                        child: Padding(
                                          padding: const EdgeInsets.all(8.0),
                                          child: Scrollbar(
                                            controller: contentScrollController,
                                            thumbVisibility: true,
                                            radius: const Radius.circular(6),
                                            child: TextField(
                                              controller: contentCtrl,
                                              scrollController: contentScrollController,
                                              expands: true,
                                              maxLines: null,
                                              minLines: null,
                                              textAlignVertical: TextAlignVertical.top,
                                              decoration: baseInputDecoration.copyWith(
                                                hintText: getText('content_hint', fallback: 'Contenido'),
                                                border: InputBorder.none,
                                                fillColor: const Color.fromARGB(0, 255, 0, 0),
                                              ),
                                              style: const TextStyle(fontSize: 14, color: Colors.white70),
                                              cursorColor: Colors.white70,
                                            ),
                                          ),
                                        ),
                                      ),
                                      GestureDetector(
                                        behavior: HitTestBehavior.translucent,
                                        onVerticalDragStart: (_) => setState(() => isDraggingContentHandle = true),
                                        onVerticalDragUpdate: (details) {
                                          setState(() {
                                            contentHeight = (contentHeight + details.delta.dy).clamp(80.0, 600.0);
                                          });
                                        },
                                        onVerticalDragEnd: (_) => setState(() => isDraggingContentHandle = false),
                                        child: Container(
                                          height: 10,
                                          alignment: Alignment.center,
                                          child: Container(
                                            width: 48,
                                            height: 4,
                                            decoration: BoxDecoration(
                                              color: isDraggingContentHandle ? Colors.deepPurpleAccent : Colors.white24,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),

                                // Categoria editable (dropdown + opción para escribir)
                                Row(
                                  children: [
                                    Expanded(
                                      child: _EditableCategoryField(
                                        categories: categories,
                                        selected: selectedCategory,
                                        onChanged: (v) => setState(() => selectedCategory = v),
                                        getText: getText,
                                        baseDecoration: baseInputDecoration,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // botón cambiar color: abre mini diálogo de selección
                                    GestureDetector(
                                      onTap: () async {
                                        await showColorPicker(setState);
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.black26,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Icon(Icons.format_paint, color: readableTextColorFor(bgPreview)),
                                      ),
                                    ),
                                  ],
                                ),

                                const SizedBox(height: 10),

                                // Previsualización compacta
                                Container(
                                  height: 88,
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(color: bgPreview, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.black12)),
                                  child: Row(
                                    children: [
                                      if (imagePath != null && File(imagePath!).existsSync())
                                        ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.file(File(imagePath!), width: 72, height: 72, fit: BoxFit.cover))
                                      else
                                        Container(width: 72, height: 72, decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(6)), child: const Icon(Icons.note)),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(titleCtrl.text.isEmpty ? getText('title_preview', fallback: 'Título') : titleCtrl.text, style: TextStyle(color: readableTextColorFor(bgPreview), fontWeight: FontWeight.w600)),
                                            const SizedBox(height: 6),
                                            Text(descCtrl.text.isEmpty ? getText('description_preview', fallback: 'Descripción') : descCtrl.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: readableTextColorFor(bgPreview).withOpacity(0.9), fontSize: 13.5)),
                                            const Spacer(),
                                            Row(
                                              children: [
                                                if (selectedCategory != null && selectedCategory!.isNotEmpty)
                                                  Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: readableTextColorFor(bgPreview).withOpacity(0.12), borderRadius: BorderRadius.circular(16)), child: Text(selectedCategory!, style: TextStyle(color: readableTextColorFor(bgPreview), fontSize: 12))),
                                                const Spacer(),
                                                Text(DateTime.now().toLocal().toString().split('.').first, style: TextStyle(color: readableTextColorFor(bgPreview).withOpacity(0.7), fontSize: 11)),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 12),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // ACTIONS (botones) en la parte inferior
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(cancelLabel)),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: () async {
                                final t = titleCtrl.text.trim();
                                final d = descCtrl.text.trim();
                                final c = contentCtrl.text.trim();
                                if (t.isEmpty) return;

                                // si hay categoría nueva, añadirla a la lista en memoria (para que NotesScreen la vea)
                                if (selectedCategory != null && selectedCategory!.isNotEmpty && !categories.contains(selectedCategory)) {
                                  categories.add(selectedCategory!);
                                }

                                if (isEditing && editingNote != null) {
                                  final updated = editingNote!.copyWith(
                                    title: t,
                                    description: d,
                                    content: c,
                                    imagePath: imagePath,
                                    category: selectedCategory,
                                    backgroundColorValue: bgColor,
                                    updatedAt: DateTime.now(),
                                  );
                                  await db.updateNote(updated);
                                  Navigator.pop(ctx, NoteData(title: t, description: d, content: c, imagePath: imagePath, category: selectedCategory, backgroundColorValue: bgColor));
                                } else {
                                  Navigator.pop(ctx, NoteData(title: t, description: d, content: c, imagePath: imagePath, category: selectedCategory, backgroundColorValue: bgColor));
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                backgroundColor: const Color.fromARGB(255, 255, 255, 255),
                                foregroundColor: Colors.black87,
                              ),
                              child: Text(saveLabel),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        );
      },
    );

    return result;
  } finally {
    contentScrollController.dispose();
    titleCtrl.dispose();
    descCtrl.dispose();
    contentCtrl.dispose();
  }
}

class _EditableCategoryField extends StatefulWidget {
  final List<String> categories;
  final String? selected;
  final ValueChanged<String?> onChanged;
  final TextGetter getText;
  final InputDecoration baseDecoration;
  const _EditableCategoryField({required this.categories, required this.selected, required this.onChanged, required this.getText, required this.baseDecoration});

  @override
  State<_EditableCategoryField> createState() => _EditableCategoryFieldState();
}

class _EditableCategoryFieldState extends State<_EditableCategoryField> {
  bool _editing = false;
  late TextEditingController _ctrl;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.selected);
    _selected = widget.selected;
  }

  @override
  void didUpdateWidget(covariant _EditableCategoryField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != _selected) {
      _selected = widget.selected;
      _ctrl.text = _selected ?? '';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseDecoration = widget.baseDecoration;
    if (_editing) {
      return Row(
        children: [
          Expanded(
            child: TextFormField(
              controller: _ctrl,
              decoration: baseDecoration.copyWith(
                hintText: widget.getText('new_category_hint', fallback: 'Nueva categoría'),
              ),
              onFieldSubmitted: (v) {
                final value = v.trim();
                setState(() => _editing = false);
                _selected = value.isEmpty ? null : value;
                widget.onChanged(_selected);
              },
              onEditingComplete: () {
                final value = _ctrl.text.trim();
                setState(() => _editing = false);
                _selected = value.isEmpty ? null : value;
                widget.onChanged(_selected);
              },
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () {
              final value = _ctrl.text.trim();
              setState(() => _editing = false);
              _selected = value.isEmpty ? null : value;
              widget.onChanged(_selected);
            },
            // simple check icon without hover splash
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.check),
            ),
          ),
        ],
      );
    }

    final items = <DropdownMenuItem<String?>>[
      DropdownMenuItem<String?>(value: null, child: Text(widget.getText('no_category', fallback: 'Sin categoría'))),
      ...widget.categories.map((c) => DropdownMenuItem<String?>(value: c, child: Text(c))),
    ];

    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: DropdownButtonFormField<String?>(
              initialValue: widget.categories.contains(_selected) ? _selected : null,
              items: items,
              onChanged: (v) {
                _selected = v;
                widget.onChanged(v);
              },
              decoration: baseDecoration.copyWith(contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
              dropdownColor: Colors.black87,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: () {
            _ctrl.text = '';
            setState(() => _editing = true);
          },
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.edit),
          ),
        ),
      ],
    );
  }
}
